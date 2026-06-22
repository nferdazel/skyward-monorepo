-- =============================================================================
-- SKYWARD SYSTEM UPDATE: LEDGER AUTOMATIC CLEANUP & PRUNING ENGINE (v3.2)
-- Automatically prunes financial ledger entries older than 30 game days during
-- the daily game-day rollover in process_simulation_delta.
-- =============================================================================

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
    
    -- Ledger aggregation buffers
    v_buffered_rev_accum NUMERIC(20,2);
    v_buffered_ops_accum NUMERIC(20,2);
    v_buffered_lease_accum NUMERIC(20,2);
    v_game_current_time_new TIMESTAMP WITH TIME ZONE;
BEGIN
    -- Run bot ticks concurrently on user simulation updates
    PERFORM process_all_bots_simulation();

    -- Fetch user profile
    SELECT * INTO r_user FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Fetch fuel price per liter
    SELECT fuel_price_per_liter INTO v_fuel_price FROM global_game_settings LIMIT 1;
    v_fuel_price := COALESCE(v_fuel_price, 0.85);

    v_now := NOW();
    
    -- Real elapsed seconds since last database update
    v_real_sec := COALESCE(EXTRACT(EPOCH FROM (v_now - r_user.last_active_at)), 0.0);
    
    -- LAZY EVALUATION CAP: Limit offline progress catchup to max 14 days
    IF v_real_sec > 1209600 THEN
        v_real_sec := 1209600;
    END IF;

    -- If delta is too small (less than 2 real seconds), do nothing
    IF v_real_sec < 2 THEN
        cash_before := r_user.cash;
        cash_after := r_user.cash;
        elapsed_real_sec := v_real_sec;
        elapsed_game_days := 0.0;
        flights_run := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    -- Scaling Factor = 30 (1 real second = 30 game seconds)
    v_game_sec := v_real_sec * 30.0;
    v_game_days := v_game_sec / 86400.0;
    v_game_current_time_new := r_user.game_current_time + (v_game_sec * INTERVAL '1 second');
    
    -- 1. Deduct recurring aircraft lease payments
    FOR v_fleet IN 
        SELECT f.*, m.lease_price_per_month 
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.user_id = p_user_id AND f.acquisition_type = 'lease'
    Loop
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
            
            -- Apply maintenance damage
            UPDATE user_fleet 
            SET condition = GREATEST(0.00, condition - (v_flights * v_wear_per_flight))
            WHERE id = v_route.fleet_aircraft_id;
            
            -- Ground low-condition aircraft based on threshold
            UPDATE user_fleet
            SET status = 'grounded'
            WHERE id = v_route.fleet_aircraft_id AND condition < r_user.auto_grounding_threshold;

            v_total_revenue := v_total_revenue + v_revenue;
            v_total_cost_accum := v_total_cost_accum + v_total_cost;
            v_completed_flights_all := v_completed_flights_all + ROUND(v_flights)::INT;
        END IF;
    END LOOP;

    v_total_revenue := GREATEST(0.00, COALESCE(v_total_revenue, 0.00));
    v_total_cost_accum := GREATEST(0.00, COALESCE(v_total_cost_accum, 0.00));

    -- Calculate total cash balance change
    v_net := v_total_revenue - v_total_cost_accum - v_lease_cost;

    -- Update buffers
    v_buffered_rev_accum := COALESCE(r_user.buffered_revenue, 0.00) + v_total_revenue;
    v_buffered_ops_accum := COALESCE(r_user.buffered_ops_cost, 0.00) + v_total_cost_accum;
    v_buffered_lease_accum := COALESCE(r_user.buffered_lease_cost, 0.00) + v_lease_cost;

    -- 3. FLUSH BUFFERED TRANSACTIONS INTO ONE ROW PER GAME DAY CROSSINGS
    IF date_trunc('day', v_game_current_time_new) > date_trunc('day', r_user.game_current_time) THEN
        
        -- Flush Ticket Sales Inflows
        IF v_buffered_rev_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (
                p_user_id, 
                'revenue', 
                'ticket_sales', 
                v_buffered_rev_accum, 
                'Consolidated ticket sales revenue for active routes',
                date_trunc('day', v_game_current_time_new)
            );
        END IF;

        -- Flush Operations Fuel/Tax Outflows
        IF v_buffered_ops_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (
                p_user_id, 
                'expense', 
                'operations', 
                v_buffered_ops_accum, 
                'Consolidated operations fuel, crew maintenance, & landing fees',
                date_trunc('day', v_game_current_time_new)
            );
        END IF;

        -- Flush Leasing Cost Outflows
        IF v_buffered_lease_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (
                p_user_id,
                'expense',
                'aircraft_lease',
                v_buffered_lease_accum,
                'Consolidated leasing fees for active fleet',
                date_trunc('day', v_game_current_time_new)
            );
        END IF;

        -- ── AUTOMATIC CLEANUP MECHANISM ──
        -- Prune transaction ledger records older than 30 game days (1 game month)
        -- to maintain extremely high database performance and light storage footprint.
        DELETE FROM financial_ledger 
        WHERE user_id = p_user_id 
          AND game_date < (v_game_current_time_new - INTERVAL '30 days');

        -- Reset buffers on successful day rollover
        v_buffered_rev_accum := 0.00;
        v_buffered_ops_accum := 0.00;
        v_buffered_lease_accum := 0.00;
    END IF;

    -- 4. UPDATE USER STATE AUTHORITATIVELY
    UPDATE users 
    SET cash = cash + v_net,
        game_current_time = v_game_current_time_new,
        last_active_at = v_now,
        buffered_revenue = v_buffered_rev_accum,
        buffered_ops_cost = v_buffered_ops_accum,
        buffered_lease_cost = v_buffered_lease_accum
    WHERE id = p_user_id;

    -- Return output tuple
    cash_before := r_user.cash;
    cash_after := r_user.cash + v_net;
    elapsed_real_sec := v_real_sec;
    elapsed_game_days := v_game_days;
    flights_run := v_completed_flights_all;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
