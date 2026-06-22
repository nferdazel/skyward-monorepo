-- ==========================================================
-- SKYWARD SIMULATION ENGINE - PILLARS 1, 2, & 3 MASTER MIGRATION SQL
-- ==========================================================

-- 1. CENTRALIZED GLOBAL GAME SETTINGS TABLE
CREATE TABLE IF NOT EXISTS global_game_settings (
    id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    starting_cash BIGINT NOT NULL DEFAULT 15000000,
    starting_cash_desc TEXT NOT NULL DEFAULT 'Starting capital for human players and bots',
    fuel_price_per_liter NUMERIC(10, 4) NOT NULL DEFAULT 0.85,
    fuel_price_per_liter_desc TEXT NOT NULL DEFAULT 'Base price of aviation fuel per liter in USD',
    absolute_minimum_safety_limit NUMERIC(5, 2) NOT NULL DEFAULT 30.00,
    absolute_minimum_safety_limit_desc TEXT NOT NULL DEFAULT 'Hard safety limit (30%) below which no aircraft is allowed to fly',
    max_bot_count INT NOT NULL DEFAULT 5,
    max_bot_count_desc TEXT NOT NULL DEFAULT 'Maximum number of active AI competitor bots allowed in the game',
    base_lease_deposit_percentage NUMERIC(5, 2) NOT NULL DEFAULT 0.10,
    base_lease_deposit_percentage_desc TEXT NOT NULL DEFAULT 'Down payment percentage required to lease an aircraft (e.g. 0.10 = 10%)',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Seed single row if not exists
INSERT INTO global_game_settings (id, starting_cash, fuel_price_per_liter, absolute_minimum_safety_limit, max_bot_count, base_lease_deposit_percentage)
VALUES (1, 15000000, 0.85, 30.00, 5, 0.10)
ON CONFLICT (id) DO NOTHING;

-- 2. UPDATE USERS AND AI_COMPETITORS SCHEMA
ALTER TABLE users ADD COLUMN IF NOT EXISTS hq_airport_iata VARCHAR(3) REFERENCES airports(iata);
ALTER TABLE users ADD COLUMN IF NOT EXISTS auto_grounding_threshold NUMERIC(5, 2) DEFAULT 40.00;

ALTER TABLE ai_competitors ADD COLUMN IF NOT EXISTS hq_airport_iata VARCHAR(3) REFERENCES airports(iata);
ALTER TABLE ai_competitors ADD COLUMN IF NOT EXISTS auto_grounding_threshold NUMERIC(5, 2) DEFAULT 40.00;
ALTER TABLE ai_competitors ADD COLUMN IF NOT EXISTS game_current_time TIMESTAMP WITH TIME ZONE DEFAULT '2020-01-01 00:00:00+00';
ALTER TABLE ai_competitors ADD COLUMN IF NOT EXISTS last_active_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- 3. UPDATE USER_FLEET SCHEMA FOR TAIL NUMBERS AND SEAT CONFIGURATIONS
ALTER TABLE user_fleet ADD COLUMN IF NOT EXISTS tail_number VARCHAR(20);
ALTER TABLE user_fleet ADD COLUMN IF NOT EXISTS economy_seats INT DEFAULT 0;
ALTER TABLE user_fleet ADD COLUMN IF NOT EXISTS business_seats INT DEFAULT 0;
ALTER TABLE user_fleet ADD COLUMN IF NOT EXISTS first_class_seats INT DEFAULT 0;

-- 4. PREFIX AND TAIL NUMBER GENERATION FUNCTIONS
CREATE OR REPLACE FUNCTION get_hq_prefix(p_airport_iata VARCHAR)
RETURNS VARCHAR AS $$
DECLARE
    v_country VARCHAR;
BEGIN
    SELECT country INTO v_country FROM airports WHERE iata = p_airport_iata;
    
    RETURN CASE 
        WHEN v_country = 'Indonesia' THEN 'PK-'
        WHEN v_country = 'Singapore' THEN '9V-'
        WHEN v_country = 'United Kingdom' OR v_country = 'UK' THEN 'G-'
        WHEN v_country = 'Malaysia' THEN '9M-'
        WHEN v_country = 'Thailand' THEN 'HS-'
        WHEN v_country = 'Philippines' THEN 'RP-'
        WHEN v_country = 'Vietnam' THEN 'VN-'
        WHEN v_country = 'Japan' THEN 'JA-'
        WHEN v_country = 'Germany' THEN 'D-'
        WHEN v_country = 'France' THEN 'F-'
        WHEN v_country = 'United States' OR v_country = 'USA' THEN 'N-'
        ELSE '9V-'
    END;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION generate_tail_number(p_airport_iata VARCHAR)
RETURNS VARCHAR AS $$
DECLARE
    v_prefix VARCHAR;
    v_rand VARCHAR := '';
    v_chars VARCHAR := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
BEGIN
    v_prefix := get_hq_prefix(p_airport_iata);
    FOR i IN 1..3 LOOP
        v_rand := v_rand || substr(v_chars, floor(random() * 26 + 1)::int, 1);
    END LOOP;
    RETURN v_prefix || v_rand;
END;
$$ LANGUAGE plpgsql;

-- 5. SEED INITIAL AI COMPETITORS WITH HQs
UPDATE ai_competitors SET hq_airport_iata = 'CGK' WHERE company_name = 'Apex Aero';
UPDATE ai_competitors SET hq_airport_iata = 'SIN' WHERE company_name = 'Vanguard Premium';
UPDATE ai_competitors SET hq_airport_iata = 'KUL' WHERE company_name = 'Nusantara Link';
UPDATE ai_competitors SET hq_airport_iata = 'BKK' WHERE company_name = 'Red Star Wings';
UPDATE ai_competitors SET hq_airport_iata = 'CGK' WHERE company_name = 'Mekong Express';

-- In case they don't exist, insert them cleanly:
INSERT INTO ai_competitors (company_name, ceo_name, archetype, hq_airport_iata, cash, net_worth) VALUES
('Apex Aero', 'Edward Falcon', 'Aggressive', 'CGK', 15000000.00, 15000000.00),
('Vanguard Premium', 'Sophia Rothschild', 'Premium', 'SIN', 15000000.00, 15000000.00),
('Nusantara Link', 'Ahmad Hidayat', 'Regional', 'KUL', 15000000.00, 15000000.00),
('Red Star Wings', 'Viktor Reznov', 'Aggressive', 'BKK', 15000000.00, 15000000.00),
('Mekong Express', 'Linh Nguyen', 'Regional', 'CGK', 15000000.00, 15000000.00)
ON CONFLICT (company_name) DO NOTHING;

-- 6. BOT BANKRUPTCY & CASCADING PURGE TRIGGERS
CREATE OR REPLACE FUNCTION trg_ai_competitor_bankruptcy()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'Bankrupt' THEN
        DELETE FROM ai_competitors WHERE id = NEW.id;
        RETURN NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ai_bankruptcy ON ai_competitors;
CREATE TRIGGER trg_ai_bankruptcy
    AFTER UPDATE OF status ON ai_competitors
    FOR EACH ROW
    WHEN (NEW.status = 'Bankrupt')
    EXECUTE FUNCTION trg_ai_competitor_bankruptcy();

CREATE OR REPLACE FUNCTION trg_ai_competitor_respawn()
RETURNS TRIGGER AS $$
DECLARE
    v_max_bots INT;
    v_current_bots INT;
    v_missing INT;
    v_names VARCHAR[] := ARRAY['Apex Aero', 'Vanguard Premium', 'Nusantara Link', 'Red Star Wings', 'Mekong Express', 'Zephyr Airways', 'Aurora Horizon', 'Pacific Wings', 'Equator Sky', 'Atlas Airway'];
    v_ceos VARCHAR[] := ARRAY['Edward Falcon', 'Sophia Rothschild', 'Ahmad Hidayat', 'Viktor Reznov', 'Linh Nguyen', 'James Sterling', 'Elena Rostova', 'Kenji Sato', 'Hans Muller', 'Chloe Dupont'];
    v_archetypes VARCHAR[] := ARRAY['Regional', 'Aggressive', 'Premium'];
    v_airports VARCHAR[] := ARRAY['CGK', 'SIN', 'LHR', 'KUL', 'BKK'];
    v_random_name VARCHAR;
    v_random_ceo VARCHAR;
    v_random_arch VARCHAR;
    v_random_hq VARCHAR;
    v_starting_cash NUMERIC;
BEGIN
    SELECT max_bot_count, starting_cash INTO v_max_bots, v_starting_cash FROM global_game_settings LIMIT 1;
    v_max_bots := COALESCE(v_max_bots, 5);
    v_starting_cash := COALESCE(v_starting_cash, 15000000.00);

    SELECT COUNT(*)::INT INTO v_current_bots FROM ai_competitors;
    v_missing := v_max_bots - v_current_bots;
    
    WHILE v_missing > 0 LOOP
        v_random_name := v_names[floor(random() * array_length(v_names, 1) + 1)::int] || ' ' || floor(random() * 900 + 100)::text;
        v_random_ceo := v_ceos[floor(random() * array_length(v_ceos, 1) + 1)::int];
        v_random_arch := v_archetypes[floor(random() * array_length(v_archetypes, 1) + 1)::int];
        v_random_hq := v_airports[floor(random() * array_length(v_airports, 1) + 1)::int];

        IF NOT EXISTS (SELECT 1 FROM ai_competitors WHERE company_name = v_random_name) THEN
            INSERT INTO ai_competitors (company_name, ceo_name, archetype, hq_airport_iata, cash, net_worth)
            VALUES (v_random_name, v_random_ceo, v_random_arch, v_random_hq, v_starting_cash, v_starting_cash);
            v_missing := v_missing - 1;
        END IF;
    END LOOP;
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ai_respawn ON ai_competitors;
CREATE TRIGGER trg_ai_respawn
    AFTER DELETE ON ai_competitors
    FOR EACH STATEMENT
    EXECUTE FUNCTION trg_ai_competitor_respawn();

-- 7. REWORK TRANSACTIONAL RPC FUNCTIONS WITH SETTINGS & HOOKS
-- A. REGISTER COMPANY (WITH HQ PARAMETER)
CREATE OR REPLACE FUNCTION register_company(
    p_username VARCHAR,
    p_password VARCHAR,
    p_company_name VARCHAR,
    p_ceo_name VARCHAR,
    p_hq_airport_iata VARCHAR
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

    -- Fetch starting cash from global settings
    SELECT starting_cash INTO v_starting_cash FROM global_game_settings LIMIT 1;
    v_starting_cash := COALESCE(v_starting_cash, 15000000.00);
    
    -- Insert user
    INSERT INTO users(username, password_hash, company_name, ceo_name, hq_airport_iata, cash, net_worth)
    VALUES (
        LOWER(TRIM(p_username)),
        crypt(p_password, gen_salt('bf', 8)),
        TRIM(p_company_name),
        TRIM(p_ceo_name),
        p_hq_airport_iata,
        v_starting_cash,
        v_starting_cash
    )
    RETURNING id INTO v_user_id;

    RETURN QUERY SELECT TRUE, 'Company registration successful!'::VARCHAR, v_user_id;
END;
$$ LANGUAGE plpgsql;

-- B. PURCHASE AIRCRAFT (HQ AWARE & SEAT INITIALIZER)
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
    v_hq_iata VARCHAR(3);
    v_tail VARCHAR(20);
    v_capacity INT;
BEGIN
    SELECT cash, hq_airport_iata INTO v_cash, v_hq_iata FROM users WHERE id = p_user_id;
    SELECT purchase_price, model_name, capacity INTO v_price, v_model_name, v_capacity FROM aircraft_models WHERE id = p_model_id;
    
    -- Verify liquidity
    IF v_cash < v_price THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds to purchase ' || v_model_name || '.')::VARCHAR, v_cash;
        RETURN;
    END IF;
    
    -- Generate unique tail number
    v_tail := generate_tail_number(v_hq_iata);
    
    -- Deduct cash
    UPDATE users SET cash = cash - v_price WHERE id = p_user_id RETURNING cash INTO v_cash;
    
    -- Add fleet aircraft with default seat breakdown (max economy seats)
    INSERT INTO user_fleet (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
    VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'purchase', 100.00, 'active', v_tail, v_capacity, 0, 0);
    
    -- Log transaction
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        p_user_id,
        'expense',
        'aircraft_purchase',
        v_price,
        'Purchased aircraft ' || v_model_name || ' with Tail Number: ' || v_tail || ' (Call Sign: ' || TRIM(p_nickname) || ')',
        (SELECT game_current_time FROM users WHERE id = p_user_id)
    );
    
    RETURN QUERY SELECT TRUE, ('Successfully purchased ' || v_model_name || '!')::VARCHAR, v_cash;
END;
$$ LANGUAGE plpgsql;

-- C. LEASE AIRCRAFT (HQ AWARE, LEASE DEPOSIT PERCENTAGE ACCORDANT & SEAT INITIALIZER)
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
    v_hq_iata VARCHAR(3);
    v_tail VARCHAR(20);
    v_capacity INT;
    v_deposit_pct NUMERIC;
    v_lease_deposit NUMERIC;
BEGIN
    SELECT cash, hq_airport_iata INTO v_cash, v_hq_iata FROM users WHERE id = p_user_id;
    SELECT lease_price_per_month, model_name, capacity INTO v_lease_price, v_model_name, v_capacity FROM aircraft_models WHERE id = p_model_id;
    
    -- Fetch lease deposit pct
    SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1;
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
    
    -- Deposit is monthly lease price scaled by deposit pct factor
    v_lease_deposit := v_lease_price * (v_deposit_pct * 10.0);
    
    IF v_cash < v_lease_deposit THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds for lease down payment of ' || v_model_name || '. Required: $' || ROUND(v_lease_deposit, 2))::VARCHAR, v_cash;
        RETURN;
    END IF;
    
    -- Generate Tail Number
    v_tail := generate_tail_number(v_hq_iata);
    
    -- Deduct deposit cash
    UPDATE users SET cash = cash - v_lease_deposit WHERE id = p_user_id RETURNING cash INTO v_cash;
    
    -- Add leased aircraft with default seat config
    INSERT INTO user_fleet (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
    VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'lease', 100.00, 'active', v_tail, v_capacity, 0, 0);
    
    -- Log transaction
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        p_user_id,
        'expense',
        'aircraft_lease',
        v_lease_deposit,
        'Leased aircraft ' || v_model_name || ' with Tail Number: ' || v_tail || ' (Call Sign: ' || TRIM(p_nickname) || ') - Month deposit',
        (SELECT game_current_time FROM users WHERE id = p_user_id)
    );
    
    RETURN QUERY SELECT TRUE, ('Successfully leased ' || v_model_name || '!')::VARCHAR, v_cash;
END;
$$ LANGUAGE plpgsql;

-- 8. BOT ENGINE SERVER-SIDE SIMULATOR & DECISION EXECUTER
CREATE OR REPLACE FUNCTION execute_bot_decisions()
RETURNS VOID AS $$
DECLARE
    r_bot RECORD;
    v_model_id UUID;
    v_model_name VARCHAR;
    v_lease_price NUMERIC;
    v_purchase_price NUMERIC;
    v_capacity INT;
    v_deposit_pct NUMERIC;
    v_deposit_amount NUMERIC;
    v_tail VARCHAR(20);
    v_new_aircraft_id UUID;
    v_origin_iata VARCHAR(3);
    v_dest_iata VARCHAR(3);
    v_distance DOUBLE PRECISION;
    v_fleet_count INT;
BEGIN
    SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1;
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);

    FOR r_bot IN SELECT * FROM ai_competitors WHERE status = 'Active' LOOP
        SELECT COUNT(*)::INT INTO v_fleet_count FROM user_fleet WHERE ai_competitor_id = r_bot.id;
        
        -- AI decision engine logic (15% chance if bot cash is healthy)
        IF v_fleet_count < 12 AND r_bot.cash > 15000000.00 AND random() < 0.15 THEN
            IF r_bot.archetype = 'Regional' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity 
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity 
                FROM aircraft_models 
                WHERE model_name = 'ATR 72-600' LIMIT 1;
            ELSIF r_bot.archetype = 'Aggressive' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity 
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity 
                FROM aircraft_models 
                WHERE model_name = 'Airbus A320neo' LIMIT 1;
            ELSE
                -- Premium
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity 
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity 
                FROM aircraft_models 
                WHERE model_name = '787-9 Dreamliner' LIMIT 1;
            END IF;

            IF v_model_id IS NOT NULL THEN
                v_deposit_amount := v_lease_price * (v_deposit_pct * 10.0);
                
                IF r_bot.cash >= v_deposit_amount THEN
                    v_tail := generate_tail_number(r_bot.hq_airport_iata);
                    v_new_aircraft_id := gen_random_uuid();
                    
                    INSERT INTO user_fleet (id, ai_competitor_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
                    VALUES (v_new_aircraft_id, r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_capacity, 0, 0);
                    
                    UPDATE ai_competitors SET cash = cash - v_deposit_amount WHERE id = r_bot.id;
                    
                    v_origin_iata := r_bot.hq_airport_iata;
                    
                    SELECT iata INTO v_dest_iata 
                    FROM airports 
                    WHERE iata != v_origin_iata 
                    ORDER BY demand_index DESC, random() LIMIT 1;
                    
                    IF v_dest_iata IS NOT NULL THEN
                        v_distance := 800.0;
                        INSERT INTO user_routes (ai_competitor_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week)
                        VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, 150.00, v_new_aircraft_id, 14)
                        ON CONFLICT DO NOTHING;
                    END IF;
                END IF;
            END IF;
        END IF;

        -- Handle financial distress / bankruptcy updates
        IF r_bot.cash < 0.00 THEN
            UPDATE ai_competitors 
            SET consecutive_negative_days = consecutive_negative_days + 1,
                status = 'Distress'
            WHERE id = r_bot.id;
        ELSE
            UPDATE ai_competitors 
            SET consecutive_negative_days = 0,
                status = 'Active'
            WHERE id = r_bot.id;
        END IF;

        IF r_bot.consecutive_negative_days >= 3 THEN
            UPDATE ai_competitors SET status = 'Bankrupt' WHERE id = r_bot.id;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION process_all_bots_simulation()
RETURNS VOID AS $$
DECLARE
    r_bot RECORD;
    v_now TIMESTAMP WITH TIME ZONE;
    v_real_sec DOUBLE PRECISION;
    v_game_sec DOUBLE PRECISION;
    v_game_days DOUBLE PRECISION;
    v_route RECORD;
    v_fleet RECORD;
    v_flights DOUBLE PRECISION;
    v_revenue NUMERIC(20,2);
    v_fuel_cost NUMERIC(20,2);
    v_maint_cost NUMERIC(20,2);
    v_tax_cost NUMERIC(20,2);
    v_total_cost NUMERIC(20,2);
    v_total_revenue NUMERIC(20,2);
    v_total_cost_accum NUMERIC(20,2);
    v_net NUMERIC(20,2);
    v_demand_multiplier NUMERIC(6,4);
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_wear_per_flight NUMERIC(5,2);
    v_lease_cost NUMERIC(20,2);
    v_fuel_price NUMERIC;
BEGIN
    v_now := NOW();
    
    -- Expose fuel price per liter from settings
    SELECT fuel_price_per_liter INTO v_fuel_price FROM global_game_settings LIMIT 1;
    v_fuel_price := COALESCE(v_fuel_price, 0.85);

    FOR r_bot IN SELECT * FROM ai_competitors WHERE status != 'Bankrupt' LOOP
        v_real_sec := COALESCE(EXTRACT(EPOCH FROM (v_now - r_bot.last_active_at)), 0.0);
        
        IF v_real_sec > 1209600 THEN
            v_real_sec := 1209600;
        END IF;

        IF v_real_sec >= 2 THEN
            v_game_sec := v_real_sec * 30.0;
            v_game_days := v_game_sec / 86400.0;
            
            -- Deduct recurring leases
            v_lease_cost := 0.00;
            FOR v_fleet IN 
                SELECT f.*, m.lease_price_per_month 
                FROM user_fleet f
                JOIN aircraft_models m ON f.aircraft_model_id = m.id
                WHERE f.ai_competitor_id = r_bot.id AND f.acquisition_type = 'lease'
            LOOP
                v_lease_cost := v_lease_cost + COALESCE((v_game_days * (v_fleet.lease_price_per_month / 30.0)), 0.00);
            END LOOP;
            v_lease_cost := GREATEST(0.00, COALESCE(v_lease_cost, 0.00));

            -- Process flights
            v_total_revenue := 0.00;
            v_total_cost_accum := 0.00;

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
                WHERE r.ai_competitor_id = r_bot.id
            LOOP
                IF COALESCE(v_route.condition, 0.00) < COALESCE(r_bot.auto_grounding_threshold, 40.00) OR COALESCE(v_route.status, 'grounded') != 'active' THEN
                    CONTINUE;
                END IF;

                v_flight_duration := COALESCE((v_route.distance_km / NULLIF(v_route.speed_kmh, 0)), 0.0) + 1.0;
                v_flights := COALESCE(v_game_days * (v_route.flights_per_week / 7.0), 0.0);
                
                IF v_flights > 0.0001 THEN
                    v_demand_multiplier := 1.5 - 0.8 * POWER((COALESCE(v_route.ticket_price, 0.00) / NULLIF((50.0 + (COALESCE(v_route.distance_km, 0.0) * 0.12)), 0)), 2);
                    v_demand_multiplier := GREATEST(0.00, LEAST(1.50, COALESCE(v_demand_multiplier, 0.00)));
                    
                    v_passengers := FLOOR(COALESCE(v_route.capacity, 0) * 0.75 * v_demand_multiplier);
                    v_passengers := GREATEST(0, LEAST(COALESCE(v_route.capacity, 0), v_passengers));
                    
                    v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
                    v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price, 0.00);
                    v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
                    v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
                    v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost);
                    
                    v_wear_per_flight := 0.50 + (COALESCE(v_route.distance_km, 0.0) * 0.0001);
                    
                    UPDATE user_fleet 
                    SET condition = GREATEST(0.00, condition - (v_flights * v_wear_per_flight))
                    WHERE id = v_route.fleet_aircraft_id;
                    
                    UPDATE user_fleet
                    SET status = 'grounded'
                    WHERE id = v_route.fleet_aircraft_id AND condition < r_bot.auto_grounding_threshold;

                    v_total_revenue := v_total_revenue + v_revenue;
                    v_total_cost_accum := v_total_cost_accum + v_total_cost;
                END IF;
            END LOOP;

            v_total_revenue := GREATEST(0.00, COALESCE(v_total_revenue, 0.00));
            v_total_cost_accum := GREATEST(0.00, COALESCE(v_total_cost_accum, 0.00));
            
            v_net := v_total_revenue - v_total_cost_accum - v_lease_cost;
            
            UPDATE ai_competitors
            SET cash = cash + v_net,
                game_current_time = game_current_time + (v_game_sec * INTERVAL '1 second'),
                last_active_at = v_now
            WHERE id = r_bot.id;
        END IF;
    END LOOP;

    -- Run AI decisions
    PERFORM execute_bot_decisions();
END;
$$ LANGUAGE plpgsql;

-- D. COMPLETE REWORK FOR PROCESS SIMULATION DELTA (INTEGRATING AIRLINE AUTO-GROUNDING THRESHOLDS & FUEL PRICINGS)
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
    v_fuel_price NUMERIC;
BEGIN
    -- Run bot ticks concurrently on user simulation updates
    PERFORM process_all_bots_simulation();

    -- Fetch the user profile
    SELECT * INTO r_user FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Fetch fuel price per liter from settings
    SELECT fuel_price_per_liter INTO v_fuel_price FROM global_game_settings LIMIT 1;
    v_fuel_price := COALESCE(v_fuel_price, 0.85);

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
        IF COALESCE(v_route.condition, 0.00) < COALESCE(r_user.auto_grounding_threshold, 40.00) OR COALESCE(v_route.status, 'grounded') != 'active' THEN
            CONTINUE;
        END IF;

        -- Flight duration in hours
        v_flight_duration := COALESCE((v_route.distance_km / NULLIF(v_route.speed_kmh, 0)), 0.0) + 1.0;
        v_flights := COALESCE(v_game_days * (v_route.flights_per_week / 7.0), 0.0);
        
        IF v_flights > 0.0001 THEN
            -- Demand calibration multiplier (elasticity index)
            v_demand_multiplier := 1.5 - 0.8 * POWER((COALESCE(v_route.ticket_price, 0.00) / NULLIF((50.0 + (COALESCE(v_route.distance_km, 0.0) * 0.12)), 0)), 2);
            v_demand_multiplier := GREATEST(0.00, LEAST(1.50, COALESCE(v_demand_multiplier, 0.00)));
            
            -- Passenger volume per flight cycle
            v_passengers := FLOOR(COALESCE(v_route.capacity, 0) * 0.75 * v_demand_multiplier);
            v_passengers := GREATEST(0, LEAST(COALESCE(v_route.capacity, 0), v_passengers));
            
            -- Absolute yield calculations
            v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
            v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price, 0.00);
            v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
            v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
            v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost);
            
            v_wear_per_flight := 0.50 + (COALESCE(v_route.distance_km, 0.0) * 0.0001);
            
            -- Apply maintenance damage based on completed flights
            UPDATE user_fleet 
            SET condition = GREATEST(0.00, condition - (v_flights * v_wear_per_flight))
            WHERE id = v_route.fleet_aircraft_id;
            
            -- Force ground low-condition aircraft based on player grounding threshold
            UPDATE user_fleet
            SET status = 'grounded'
            WHERE id = v_route.fleet_aircraft_id AND condition < r_user.auto_grounding_threshold;

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
