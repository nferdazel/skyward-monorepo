-- ==========================================================
-- SKYWARD SIMULATION ENGINE - FINANCIAL PERSISTENCE MIGRATION SQL
-- ==========================================================

-- 1. DROP EXISTING FUNCTIONS TO ALLOW SIGNATURE/RETURN TYPE CHANGES
DROP FUNCTION IF EXISTS register_company(VARCHAR, VARCHAR, VARCHAR, VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS login_company(VARCHAR, VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS validate_session(VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS purchase_aircraft(UUID, UUID, VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS lease_aircraft(UUID, UUID, VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS repair_aircraft(UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS process_simulation_delta(UUID) CASCADE;

-- 2. RENAME COLUMN cash_balance TO cash IF IT EXISTS
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 
        FROM information_schema.columns 
        WHERE table_name = 'users' AND column_name = 'cash_balance'
    ) THEN
        ALTER TABLE users RENAME COLUMN cash_balance TO cash;
    END IF;
END $$;

-- 3. ENSURE cash HAS PROPER TYPE AND DEFAULT VALUE
DROP TRIGGER IF EXISTS trg_user_cash_change ON users;

ALTER TABLE users ALTER COLUMN cash SET DEFAULT 10000000.00;
ALTER TABLE users ALTER COLUMN cash TYPE NUMERIC(20,2);

-- Recreate trigger if the net worth update function exists
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'trg_update_user_net_worth'
    ) THEN
        CREATE TRIGGER trg_user_cash_change
            BEFORE UPDATE OF cash ON users
            FOR EACH ROW
            EXECUTE FUNCTION trg_update_user_net_worth();
    END IF;
END $$;

-- 4. REMOVE SERVER-SIDE CASH CONSTRAINT TO ALLOW DEBT & PREVENT SIMULATION ENGINE CRASHES
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_cash_check;


-- 5. UPDATE USER REGISTRATION FUNCTION
CREATE OR REPLACE FUNCTION register_company(
    p_username VARCHAR,
    p_password VARCHAR,
    p_company_name VARCHAR,
    p_ceo_name VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    user_id UUID
) AS $$
DECLARE
    v_user_id UUID;
    v_starting_cash NUMERIC;
BEGIN
    -- Check uniqueness
    IF EXISTS(SELECT 1 FROM users WHERE username = LOWER(TRIM(p_username))) THEN
        RETURN QUERY SELECT FALSE, 'Username is already taken.'::VARCHAR, NULL::UUID;
        RETURN;
    END IF;
    
    IF EXISTS(SELECT 1 FROM users WHERE company_name = TRIM(p_company_name)) THEN
        RETURN QUERY SELECT FALSE, 'Company name is already registered.'::VARCHAR, NULL::UUID;
        RETURN;
    END IF;
    
    -- Fetch starting cash dynamically from global settings table
    SELECT starting_cash INTO v_starting_cash FROM global_game_settings LIMIT 1;
    v_starting_cash := COALESCE(v_starting_cash, 15000000.00);
    
    -- Insert user with Blowfish (bcrypt) password hash and starting cash
    INSERT INTO users(username, password_hash, company_name, ceo_name, cash, net_worth)
    VALUES (
        LOWER(TRIM(p_username)),
        crypt(p_password, gen_salt('bf', 8)),
        TRIM(p_company_name),
        TRIM(p_ceo_name),
        v_starting_cash,
        v_starting_cash
    )
    RETURNING id INTO v_user_id;

    RETURN QUERY SELECT TRUE, 'Company registration successful!'::VARCHAR, v_user_id;
END;
$$ LANGUAGE plpgsql;


-- 6. UPDATE USER LOGIN FUNCTION
CREATE OR REPLACE FUNCTION login_company(
    p_username VARCHAR,
    p_password VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    session_token VARCHAR,
    user_id UUID,
    company_name VARCHAR,
    ceo_name VARCHAR,
    cash NUMERIC,
    game_current_time TIMESTAMP WITH TIME ZONE
) AS $$
DECLARE
    r_user RECORD;
    v_token VARCHAR;
    v_expires TIMESTAMP WITH TIME ZONE;
BEGIN
    -- Fetch active user
    SELECT * INTO r_user FROM users WHERE username = LOWER(TRIM(p_username));
    
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Invalid username or password.'::VARCHAR, NULL::VARCHAR, NULL::UUID, NULL::VARCHAR, NULL::VARCHAR, 0.00::NUMERIC, NULL::TIMESTAMP WITH TIME ZONE;
        RETURN;
    END IF;
    
    -- Verify password hash
    IF r_user.password_hash != crypt(p_password, r_user.password_hash) THEN
        RETURN QUERY SELECT FALSE, 'Invalid username or password.'::VARCHAR, NULL::VARCHAR, NULL::UUID, NULL::VARCHAR, NULL::VARCHAR, 0.00::NUMERIC, NULL::TIMESTAMP WITH TIME ZONE;
        RETURN;
    END IF;
    
    -- Generate custom session token
    v_token := encode(digest(gen_random_uuid()::text, 'sha256'), 'hex');
    v_expires := NOW() + INTERVAL '30 days';
    
    INSERT INTO sessions (user_id, token, expires_at)
    VALUES (r_user.id, v_token, v_expires);
    
    -- Update last active status to now
    UPDATE users SET last_active_at = NOW() WHERE id = r_user.id;

    RETURN QUERY SELECT 
        TRUE, 
        'Login successful!'::VARCHAR, 
        v_token, 
        r_user.id, 
        r_user.company_name, 
        r_user.ceo_name, 
        r_user.cash, 
        r_user.game_current_time;
END;
$$ LANGUAGE plpgsql;


-- 7. UPDATE SESSION VALIDATION FUNCTION
CREATE OR REPLACE FUNCTION validate_session(
    p_token VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    user_id UUID,
    company_name VARCHAR,
    ceo_name VARCHAR,
    cash NUMERIC,
    game_current_time TIMESTAMP WITH TIME ZONE
) AS $$
DECLARE
    r_session RECORD;
    r_user RECORD;
BEGIN
    -- Validate session existence and lifespan
    SELECT * INTO r_session FROM sessions WHERE token = p_token AND expires_at > NOW();
    
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::VARCHAR, NULL::VARCHAR, 0.00::NUMERIC, NULL::TIMESTAMP WITH TIME ZONE;
        RETURN;
    END IF;
    
    -- Fetch company profile
    SELECT * INTO r_user FROM users WHERE id = r_session.user_id;
    
    -- Roll forward session expiry for active users (sliding window of 30 days)
    UPDATE sessions SET expires_at = NOW() + INTERVAL '30 days' WHERE id = r_session.id;

    RETURN QUERY SELECT 
        TRUE, 
        r_user.id, 
        r_user.company_name, 
        r_user.ceo_name, 
        r_user.cash, 
        r_user.game_current_time;
END;
$$ LANGUAGE plpgsql;


-- 8. UPDATE FLEET PURCHASE FUNCTION
CREATE OR REPLACE FUNCTION purchase_aircraft(
    p_user_id UUID,
    p_model_id UUID,
    p_nickname VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_cash NUMERIC;
    v_price NUMERIC;
    v_model_name VARCHAR;
BEGIN
    -- Fetch user's current cash balance
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    
    -- Fetch target aircraft model price and identifier
    SELECT purchase_price, model_name INTO v_price, v_model_name FROM aircraft_models WHERE id = p_model_id;
    
    -- Verify liquidity
    IF v_cash < v_price THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds to purchase ' || v_model_name || '.')::VARCHAR, v_cash;
        RETURN;
    END IF;
    
    -- Deduct cash balance atomically
    UPDATE users 
    SET cash = cash - v_price 
    WHERE id = p_user_id 
    RETURNING cash INTO v_cash;
    
    -- Add aircraft to user fleet
    INSERT INTO user_fleet (user_id, aircraft_model_id, nickname, acquisition_type, condition, status)
    VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'purchase', 100.00, 'active');
    
    -- Log transaction to the ledger
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        p_user_id,
        'expense',
        'aircraft_purchase',
        v_price,
        'Purchased aircraft ' || v_model_name || ' with Call Sign: ' || TRIM(p_nickname),
        (SELECT game_current_time FROM users WHERE id = p_user_id)
    );
    
    RETURN QUERY SELECT TRUE, ('Successfully purchased ' || v_model_name || '!')::VARCHAR, v_cash;
END;
$$ LANGUAGE plpgsql;


-- 9. UPDATE FLEET LEASE FUNCTION
CREATE OR REPLACE FUNCTION lease_aircraft(
    p_user_id UUID,
    p_model_id UUID,
    p_nickname VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_cash NUMERIC;
    v_lease_price NUMERIC;
    v_model_name VARCHAR;
BEGIN
    -- Fetch user's current cash balance
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    
    -- Fetch target aircraft model lease price and identifier
    SELECT lease_price_per_month, model_name INTO v_lease_price, v_model_name FROM aircraft_models WHERE id = p_model_id;
    
    -- Charge first month's lease up front as down payment
    IF v_cash < v_lease_price THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds for lease down payment of ' || v_model_name || '.')::VARCHAR, v_cash;
        RETURN;
    END IF;
    
    -- Deduct initial lease cash balance atomically
    UPDATE users 
    SET cash = cash - v_lease_price 
    WHERE id = p_user_id 
    RETURNING cash INTO v_cash;
    
    -- Add leased aircraft to user fleet
    INSERT INTO user_fleet (user_id, aircraft_model_id, nickname, acquisition_type, condition, status)
    VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'lease', 100.00, 'active');
    
    -- Log transaction to ledger
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        p_user_id,
        'expense',
        'aircraft_lease',
        v_lease_price,
        'Leased aircraft ' || v_model_name || ' with Call Sign: ' || TRIM(p_nickname) || ' - Initial month deposit',
        (SELECT game_current_time FROM users WHERE id = p_user_id)
    );
    
    RETURN QUERY SELECT TRUE, ('Successfully leased ' || v_model_name || '!')::VARCHAR, v_cash;
END;
$$ LANGUAGE plpgsql;


-- 10. UPDATE FLEET REPAIR FUNCTION
CREATE OR REPLACE FUNCTION repair_aircraft(
    p_user_id UUID,
    p_fleet_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_cash NUMERIC;
    v_condition NUMERIC;
    v_price NUMERIC;
    v_model_name VARCHAR;
    v_repair_cost NUMERIC;
BEGIN
    -- Fetch current aircraft wear condition and purchase price
    SELECT f.condition, m.purchase_price, m.model_name 
    INTO v_condition, v_price, v_model_name
    FROM user_fleet f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id;
    
    -- Verify if repair is needed
    IF v_condition >= 100.00 THEN
        SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
        RETURN QUERY SELECT FALSE, ('Aircraft ' || v_model_name || ' is already in pristine condition.')::VARCHAR, v_cash;
        RETURN;
    END IF;
    
    -- Compute dynamic repair cost (linear factor based on worn condition percentage)
    v_repair_cost := (100.00 - v_condition) * (v_price * 0.0015);
    
    -- Verify liquidity
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    
    IF v_cash < v_repair_cost THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds for repair. Required: $' || ROUND(v_repair_cost, 2))::VARCHAR, v_cash;
        RETURN;
    END IF;
    
    -- Deduct repair cost atomically
    UPDATE users 
    SET cash = cash - v_repair_cost 
    WHERE id = p_user_id 
    RETURNING cash INTO v_cash;
    
    -- Reset aircraft health stats to 100% and toggle state back to active
    UPDATE user_fleet 
    SET condition = 100.00,
        status = 'active'
    WHERE id = p_fleet_id;
    
    -- Log transaction to ledger
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        p_user_id,
        'expense',
        'aircraft_repair',
        v_repair_cost,
        'Repaired ' || v_model_name || ' - Restored condition from ' || ROUND(v_condition::numeric, 2) || '% to 100%',
        (SELECT game_current_time FROM users WHERE id = p_user_id)
    );
    
    RETURN QUERY SELECT TRUE, 'Aircraft maintenance complete. Health restored to 100%!'::VARCHAR, v_cash;
END;
$$ LANGUAGE plpgsql;


-- 11. UPDATE SIMULATION ENGINE FUNCTION WITH LAZY EVALUATION CAP (2 WEEKS SAFETY CAP)
CREATE OR REPLACE FUNCTION process_simulation_delta(p_user_id UUID)
RETURNS TABLE (
    cash_before NUMERIC(20,2),
    cash_after NUMERIC(20,2),
    elapsed_real_sec DOUBLE PRECISION,
    elapsed_game_days DOUBLE PRECISION,
    flights_run INT
) AS $$
DECLARE
    r_user RECORD;
    v_now TIMESTAMP WITH TIME ZONE;
    v_real_sec DOUBLE PRECISION;
    v_game_sec DOUBLE PRECISION;
    v_game_days DOUBLE PRECISION;
    v_route RECORD;
    v_fleet RECORD;
    v_flights DOUBLE PRECISION;
    v_revenue NUMERIC(20,2) := 0;
    v_fuel_cost NUMERIC(20,2) := 0;
    v_maint_cost NUMERIC(20,2) := 0;
    v_tax_cost NUMERIC(20,2) := 0;
    v_total_cost NUMERIC(20,2) := 0;
    v_total_revenue NUMERIC(20,2) := 0;
    v_total_cost_accum NUMERIC(20,2) := 0;
    v_net NUMERIC(20,2) := 0;
    v_demand_multiplier NUMERIC(6,4);
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_wear_per_flight NUMERIC(5,2);
    v_completed_flights_all INT := 0;
    v_lease_cost NUMERIC(20,2) := 0;
BEGIN
    -- Fetch the user profile
    SELECT * INTO r_user FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_now := NOW();
    
    -- Real elapsed seconds since last database update
    v_real_sec := COALESCE(EXTRACT(EPOCH FROM (v_now - r_user.last_active_at)), 0.0);
    
    -- LAZY EVALUATION CAP: Limit offline progress catchup to max 14 days (2 weeks)
    IF v_real_sec > 1209600 THEN
        v_real_sec := 1209600;
    END IF;

    -- If delta is too small (less than 2 real seconds = 1 game minute), do nothing
    IF v_real_sec < 2 THEN
        cash_before := r_user.cash;
        cash_after := r_user.cash;
        elapsed_real_sec := v_real_sec;
        elapsed_game_days := 0.0;
        flights_run := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    -- Scaling Factor = 30 (1 real second = 30 game seconds; 2 real seconds = 1 game minute)
    v_game_sec := v_real_sec * 30.0;
    v_game_days := v_game_sec / 86400.0;
    
    -- 1. Deduct recurring aircraft lease payments based on elapsed game time
    FOR v_fleet IN 
        SELECT f.*, m.lease_price_per_month 
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.user_id = p_user_id AND f.acquisition_type = 'lease'
    LOOP
        v_lease_cost := v_lease_cost + COALESCE((v_game_days * (v_fleet.lease_price_per_month / 30.0)), 0.00);
    END LOOP;
    
    v_lease_cost := GREATEST(0.00, COALESCE(v_lease_cost, 0.00));

    -- 2. Process simulated flight routes and operational revenues
    FOR v_route IN 
        SELECT r.*, 
               f.id AS fleet_aircraft_id, f.condition, f.status,
               m.capacity, m.speed_kmh, m.fuel_burn_per_km, m.maintenance_cost_per_hour,
               org.demand_index AS org_demand, org.airport_tax AS org_tax,
               dst.demand_index AS dst_demand, dst.airport_tax AS dst_tax
        FROM user_routes r
        JOIN user_fleet f ON r.assigned_aircraft_id = f.id
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        JOIN airports org ON r.origin_iata = org.iata
        JOIN airports dst ON r.destination_iata = dst.iata
        WHERE r.user_id = p_user_id
    LOOP
        -- Grounded or low-condition aircraft cannot execute flights
        IF COALESCE(v_route.condition, 0.00) < 40.0 OR COALESCE(v_route.status, 'grounded') != 'active' THEN
            CONTINUE;
        END IF;

        -- Flight duration in hours: Distance / Speed + 1.0 hr ground turnaround time
        v_flight_duration := COALESCE((v_route.distance_km / NULLIF(v_route.speed_kmh, 0)), 0.0) + 1.0;
        
        -- Total completed flights during this game time interval (continuous precision)
        v_flights := COALESCE(v_game_days * (v_route.flights_per_week / 7.0), 0.0);
        
        IF v_flights > 0.0001 THEN
            -- Demand calibration multiplier (elasticity index)
            v_demand_multiplier := 1.5 - 0.8 * POWER((COALESCE(v_route.ticket_price, 0.00) / NULLIF((50.0 + (COALESCE(v_route.distance_km, 0.0) * 0.12)), 0)), 2);
            v_demand_multiplier := GREATEST(0.00, LEAST(1.50, COALESCE(v_demand_multiplier, 0.00)));
            
            -- Passenger volume per flight cycle
            v_passengers := FLOOR(COALESCE(v_route.capacity, 0) * 0.75 * v_demand_multiplier);
            v_passengers := GREATEST(0, LEAST(COALESCE(v_route.capacity, 0), v_passengers));
            
            -- Absolute yield calculations (COALESCE guarded)
            v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
            v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * 1.20, 0.00);
            v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
            v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
            v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost);
            
            v_wear_per_flight := 0.50 + (COALESCE(v_route.distance_km, 0.0) * 0.0001);
            
            -- Apply maintenance damage based on completed flights
            UPDATE user_fleet 
            SET condition = GREATEST(0.00, condition - (v_flights * v_wear_per_flight))
            WHERE id = v_route.fleet_aircraft_id;
            
            -- Force ground low-condition aircraft to prevent catastrophic crashes
            UPDATE user_fleet
            SET status = 'grounded'
            WHERE id = v_route.fleet_aircraft_id AND condition < 40.0;

            -- Accumulate yield totals for final consolidated logs
            v_total_revenue := v_total_revenue + v_revenue;
            v_total_cost_accum := v_total_cost_accum + v_total_cost;
            v_completed_flights_all := v_completed_flights_all + ROUND(v_flights)::INT;
        END IF;
    END LOOP;

    -- Ensure final aggregations are clean and non-negative
    v_total_revenue := GREATEST(0.00, COALESCE(v_total_revenue, 0.00));
    v_total_cost_accum := GREATEST(0.00, COALESCE(v_total_cost_accum, 0.00));

    -- 3. Write exactly one consolidated ledger entry for all route revenues combined
    IF v_total_revenue > 0 THEN
        INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
        VALUES (
            p_user_id, 
            'revenue', 
            'ticket_sales', 
            v_total_revenue, 
            'Consolidated ticket sales revenue for ' || v_completed_flights_all || ' completed flight cycles across active networks',
            r_user.game_current_time + (v_game_sec * INTERVAL '1 second')
        );
    END IF;

    -- 4. Write exactly one consolidated ledger entry for all route operating costs combined
    IF v_total_cost_accum > 0 THEN
        INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
        VALUES (
            p_user_id, 
            'expense', 
            'operations', 
            v_total_cost_accum, 
            'Consolidated operations fuel, crew maintenance, & airport landing fees across active networks',
            r_user.game_current_time + (v_game_sec * INTERVAL '1 second')
        );
    END IF;

    -- Apply leasing deductions
    IF v_lease_cost > 0 THEN
        v_net := v_net - v_lease_cost;
        INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
        VALUES (
            p_user_id,
            'expense',
            'aircraft_lease',
            v_lease_cost,
            'Leasing fees for active fleet over ' || ROUND(v_game_days::numeric, 2) || ' game days',
            r_user.game_current_time + (v_game_sec * INTERVAL '1 second')
        );
    END IF;

    -- Final update to company state (Deducting expenses or adding net cash balance)
    v_net := v_net + v_total_revenue - v_total_cost_accum;

    UPDATE users 
    SET cash = cash + v_net,
        game_current_time = game_current_time + (v_game_sec * INTERVAL '1 second'),
        last_active_at = v_now
    WHERE id = p_user_id;

    -- Return the updated balances
    cash_before := r_user.cash;
    cash_after := r_user.cash + v_net;
    elapsed_real_sec := v_real_sec;
    elapsed_game_days := v_game_days;
    flights_run := v_completed_flights_all;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
