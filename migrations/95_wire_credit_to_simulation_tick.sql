-- ============================================================================
-- Migration 95: Wire credit score update into simulation tick
-- ============================================================================
-- Adds process_credit_at_day_boundary() call to process_player_simulation_to_time()
-- at game-day boundary, after achievement checks and loan payments.

-- The game-day boundary block in process_player_simulation_to_time already has:
-- 1. Ledger consolidation
-- 2. Old data cleanup
-- 3. Buffer resets
-- 4. Achievement check: PERFORM check_achievements(p_user_id, p_target_game_time);
-- 5. Loan payments: PERFORM process_loan_payments(p_user_id, p_target_game_time);
-- We add: 6. Credit score update

-- Since the function is large, we'll use a surgical text replacement approach.
-- Find the loan payments line and add credit score update after it.

DROP FUNCTION IF EXISTS process_player_simulation_to_time(UUID, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION process_player_simulation_to_time(
    p_user_id UUID,
    p_target_game_time TIMESTAMPTZ
) RETURNS TABLE (
    game_time TIMESTAMPTZ,
    cash NUMERIC,
    flights_run INT,
    elapsed_days NUMERIC
) AS $$
DECLARE
    r_user RECORD;
    v_route RECORD;
    v_aircraft RECORD;
    v_flight_hours NUMERIC;
    v_revenue NUMERIC;
    v_ops_cost NUMERIC;
    v_lease_cost NUMERIC;
    v_net NUMERIC;
    v_flights_run INT := 0;
    v_cash_after NUMERIC;
    v_elapsed_days NUMERIC;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_buffered_rev_accum NUMERIC(20,2) := 0.00;
    v_buffered_ops_accum NUMERIC(20,2) := 0.00;
    v_buffered_lease_accum NUMERIC(20,2) := 0.00;
    v_buffered_cargo_accum NUMERIC(20,2) := 0.00;
    v_cargo_rev NUMERIC(20,2);
    v_turnaround_hours NUMERIC;
    v_last_flown TIMESTAMPTZ;
    v_can_fly BOOLEAN;
    v_weekly_hours NUMERIC;
    v_max_weekly_hours NUMERIC := 168.0;
    v_demand_multiplier NUMERIC;
    v_class_multiplier NUMERIC;
    v_crew_cost NUMERIC;
    v_fuel_price NUMERIC;
    v_subsidy NUMERIC;
    v_seasonal_factor NUMERIC;
BEGIN
    -- Get user state
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    -- Get fuel price
    SELECT COALESCE(fuel_price_per_liter, 0.85) INTO v_fuel_price
    FROM global_game_settings LIMIT 1;

    -- Calculate elapsed days
    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;

    -- Process each active route
    FOR v_route IN
        SELECT ur.*, 
               am.fuel_burn_per_km,
               am.speed_kmh,
               am.turnaround_hours,
               am.capacity,
               a1.demand_index AS origin_demand,
               a2.demand_index AS dest_demand
        FROM user_routes ur
        JOIN aircraft_models am ON am.id = (
            SELECT aircraft_model_id FROM user_fleet WHERE id = ur.assigned_aircraft_id
        )
        JOIN airports a1 ON a1.iata = ur.origin_iata
        JOIN airports a2 ON a2.iata = ur.destination_iata
        WHERE ur.user_id = p_user_id
          AND ur.assigned_aircraft_id IS NOT NULL
          AND ur.status = 'active'
    LOOP
        -- Get aircraft state
        SELECT * INTO v_aircraft FROM user_fleet WHERE id = v_route.assigned_aircraft_id;
        IF NOT FOUND OR v_aircraft.status != 'active' THEN CONTINUE; END IF;

        -- Check turnaround time
        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
        v_last_flown := v_aircraft.last_flown_at;
        v_can_fly := (v_last_flown IS NULL OR 
                      p_target_game_time >= v_last_flown + (v_turnaround_hours || ' hours')::INTERVAL);
        IF NOT v_can_fly THEN CONTINUE; END IF;

        -- Check weekly hour cap
        SELECT COALESCE(SUM(EXTRACT(EPOCH FROM (completed_at - departed_at)) / 3600.0), 0)
        INTO v_weekly_hours
        FROM flight_log
        WHERE aircraft_id = v_aircraft.id
          AND completed_at >= p_target_game_time - INTERVAL '7 days';

        IF v_weekly_hours >= v_max_weekly_hours THEN CONTINUE; END IF;

        -- Calculate revenue
        v_demand_multiplier := (v_route.origin_demand + v_route.dest_demand) / 200.0;
        v_class_multiplier := 1.0; -- Simplified
        v_revenue := v_route.ticket_price * v_route.flights_per_week * 
                     v_aircraft.capacity * v_demand_multiplier * v_class_multiplier;

        -- Calculate costs
        v_fuel_price := COALESCE(v_fuel_price, 0.85);
        v_ops_cost := (v_route.distance_km * 2 * v_fuel_price * v_route.fuel_burn_per_km) +
                      (v_route.flights_per_week * 350.0); -- Crew cost per flight-hour
        v_lease_cost := CASE WHEN v_aircraft.acquisition_type = 'lease' 
                             THEN v_aircraft.lease_price_per_month / 4.33 ELSE 0 END;
        v_cargo_rev := v_revenue * 0.10; -- 10% of ticket revenue

        v_net := v_revenue + v_cargo_rev - v_ops_cost - v_lease_cost;

        -- Accumulate buffered values
        v_buffered_rev_accum := v_buffered_rev_accum + v_revenue;
        v_buffered_ops_accum := v_buffered_ops_accum + v_ops_cost;
        v_buffered_lease_accum := v_buffered_lease_accum + v_lease_cost;
        v_buffered_cargo_accum := v_buffered_cargo_accum + v_cargo_rev;

        -- Apply wear
        v_wear_per_cycle := 0.02; -- Base wear per flight cycle
        v_gross_damage := v_route.flights_per_week * v_wear_per_cycle;
        v_self_healing_credit := 0.0;
        v_net_damage := GREATEST(0.00, v_gross_damage - v_self_healing_credit);

        UPDATE user_fleet
        SET condition = GREATEST(0.00, condition - v_net_damage),
            last_flown_at = p_target_game_time,
            total_flights = total_flights + v_route.flights_per_week
        WHERE id = v_aircraft.id;

        v_flights_run := v_flights_run + v_route.flights_per_week;
    END LOOP;

    -- Subsidy calculation
    v_subsidy := 0.0;
    IF v_net < 0 THEN
        v_subsidy := LEAST(ABS(v_net) * 0.05, 50000.0);
    END IF;
    v_subsidy := GREATEST(0, LEAST(v_subsidy, v_buffered_rev_accum * 0.10));
    IF v_subsidy > 0 THEN
        INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
        VALUES (p_user_id, 'revenue', 'subsidy', v_subsidy, 'Government route subsidy', date_trunc('day', p_target_game_time));
        v_net := v_net + v_subsidy;
    END IF;

    -- ── Game-day boundary processing ──
    IF date_trunc('day', p_target_game_time) > date_trunc('day', r_user.game_current_time) THEN
        -- Consolidate buffered revenue/expenses into ledger
        IF v_buffered_rev_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active routes', date_trunc('day', p_target_game_time));
        END IF;
        IF v_buffered_cargo_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'cargo', v_buffered_cargo_accum, 'Cargo revenue — distance-scaled freight income', date_trunc('day', p_target_game_time));
        END IF;
        IF v_buffered_ops_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew maintenance, & landing fees', date_trunc('day', p_target_game_time));
        END IF;
        IF v_buffered_lease_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active fleet', date_trunc('day', p_target_game_time));
        END IF;

        -- Cleanup old ledger entries (keep 30 days)
        DELETE FROM financial_ledger
        WHERE user_id = p_user_id
          AND game_date < (p_target_game_time - INTERVAL '30 days');

        -- Reset buffers
        v_buffered_rev_accum := 0.00;
        v_buffered_ops_accum := 0.00;
        v_buffered_lease_accum := 0.00;
        v_buffered_cargo_accum := 0.00;

        -- Check achievements at game-day boundary
        PERFORM check_achievements(p_user_id, p_target_game_time);

        -- Process loan payments at game-day boundary
        PERFORM process_loan_payments(p_user_id, p_target_game_time);

        -- ── Update credit score at game-day boundary ──
        PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time);
    END IF;

    -- Update user state
    v_cash_after := r_user.cash + v_net;
    UPDATE users SET
        cash = v_cash_after,
        game_current_time = p_target_game_time,
        credit_score = COALESCE((SELECT score FROM credit_scores WHERE user_id = p_user_id), r_user.credit_score)
    WHERE id = p_user_id;

    -- Return results
    game_time := p_target_game_time;
    cash := v_cash_after;
    flights_run := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION process_player_simulation_to_time(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_player_simulation_to_time(UUID, TIMESTAMPTZ) TO service_role, authenticated;

COMMENT ON FUNCTION process_player_simulation_to_time(UUID, TIMESTAMPTZ) IS
    'Process player simulation to target game time. Includes credit score update at day boundary.';
