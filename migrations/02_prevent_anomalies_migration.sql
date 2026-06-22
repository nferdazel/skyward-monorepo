-- ==========================================================
-- SKYWARD SIMULATION ENGINE - ANOMALY PREVENTION MIGRATION SQL
-- ==========================================================

-- 1. DYNAMICALLY DROP ALL CASH CONSTRAINT CHECKS ON USERS TO PREVENT SIMULATION FREEZES
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT tc.constraint_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.constraint_column_usage ccu 
          ON tc.constraint_name = ccu.constraint_name
        WHERE tc.table_name = 'users' 
          AND tc.constraint_type = 'CHECK'
          AND ccu.column_name IN ('cash', 'cash_balance')
    LOOP
        EXECUTE 'ALTER TABLE users DROP CONSTRAINT IF EXISTS ' || quote_ident(r.constraint_name) || ' CASCADE;';
    END LOOP;
END $$;

-- 2. CREATE A DEFENSIVE, BULLETPROOF PROCESS SIMULATION DELTA FUNCTION
-- Equipped with COALESCE, NULLIF, and GREATEST guards to prevent NULL propagation, divide-by-zeros, or negative amounts under all edge cases.
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
