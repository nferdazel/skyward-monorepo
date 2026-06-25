-- ============================================================================
-- Migration 140: Restore world_tick_log success logging + dead column cleanup
-- ============================================================================
-- Fix 1: Restore world_tick_log success INSERT in process_world_tick
-- Fix 2: Drop dead columns from fleet_aircraft (acquired_at, total_flights)
-- Fix 3: Drop dead columns from loans (8 columns)
-- Fix 4: Drop dead columns from bank_transactions (4 columns)
-- Fix 5: Drop dead columns from bank_transactions_archive (4 columns)
-- Fix 6: Drop dead *_created_at columns (5 tables)
-- Fix 7: Clean up expired game_events
-- ============================================================================

BEGIN;


-- ============================================================================
-- Fix 1: Restore world_tick_log success INSERT in process_world_tick
-- ============================================================================
-- Current function (m130) only inserts player_error rows. Restore success
-- logging with all columns populated.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_world_tick(
    p_season_id UUID DEFAULT NULL,
    p_max_ticks INT DEFAULT 10
) RETURNS TABLE (
    season_id UUID,
    ticks_processed INT,
    game_time_after TIMESTAMPTZ,
    players_processed INT,
    bots_processed INT
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
DECLARE
    r_season RECORD;
    v_game_time_before TIMESTAMPTZ;
    v_game_time_after TIMESTAMPTZ;
    v_ticks_processed INT := 0;
    v_players_processed INT := 0;
    v_bots_processed INT := 0;
    r_user RECORD;
    r_player_result RECORD;
    v_lock_key BIGINT;
    v_error_msg TEXT;
    v_start_time TIMESTAMPTZ;
BEGIN
    v_start_time := NOW();

    IF p_season_id IS NOT NULL THEN
        SELECT * INTO r_season FROM season_clock WHERE id = p_season_id;
    ELSE
        SELECT * INTO r_season FROM season_clock WHERE status = 'active' LIMIT 1;
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'No active season found'; END IF;

    v_lock_key := hashtext(r_season.id::text);
    IF NOT pg_try_advisory_xact_lock(v_lock_key) THEN
        RAISE EXCEPTION 'World tick already in progress for season %', r_season.id;
    END IF;

    v_game_time_before := r_season.current_game_time;

    v_game_time_after := r_season.current_game_time
        + (r_season.tick_interval_seconds * r_season.time_scale_multiplier * INTERVAL '1 second');

    PERFORM generate_game_events(v_game_time_after);
    PERFORM deactivate_expired_events(v_game_time_after);

    FOR r_user IN
        SELECT u.id, u.game_current_time
        FROM users u
        WHERE u.season_id = r_season.id
          AND u.actor_type = 'REAL'
          AND COALESCE(u.operational_status, 'Active') != 'Bankrupt'
    LOOP
        BEGIN
            SELECT * INTO r_player_result
            FROM process_player_simulation_to_time(r_user.id, v_game_time_after) LIMIT 1;
            IF COALESCE(r_player_result.elapsed_days, 0.0) > 0.0 THEN
                v_players_processed := v_players_processed + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_error_msg = MESSAGE_TEXT;
            INSERT INTO world_tick_log (season_id, status, message, started_at, finished_at)
            VALUES (r_season.id, 'player_error',
                    'Player ' || r_user.id || ': ' || v_error_msg, NOW(), NOW());
        END;
    END LOOP;

    v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);

    IF date_trunc('day', r_season.current_game_time)::DATE <>
       date_trunc('day', v_game_time_after)::DATE THEN
        PERFORM execute_bot_decisions();
    END IF;

    UPDATE season_clock
    SET current_game_time = v_game_time_after, last_tick_at = NOW(), updated_at = NOW()
    WHERE id = r_season.id;

    v_ticks_processed := 1;

    -- Restore success logging with all columns populated
    INSERT INTO world_tick_log (
        season_id, started_at, finished_at,
        game_time_before, game_time_after,
        ticks_processed, players_processed, bots_processed,
        status, message
    ) VALUES (
        r_season.id, v_start_time, NOW(),
        v_game_time_before, v_game_time_after,
        1, v_players_processed, v_bots_processed,
        'success', 'Tick completed successfully'
    );

    season_id := r_season.id;
    ticks_processed := v_ticks_processed;
    game_time_after := v_game_time_after;
    players_processed := v_players_processed;
    bots_processed := v_bots_processed;
    RETURN NEXT;
END;
$function$;


-- ============================================================================
-- Fix 2: Drop dead columns from fleet_aircraft
-- ============================================================================
-- acquired_at — never read (acquired_game_date is the one used)
-- total_flights — written but never read for game logic
-- ============================================================================

-- 2a. Rewrite process_player_simulation_to_time — remove total_flights write
--     (Based on m130 version, only change: remove total_flights from UPDATE)

CREATE OR REPLACE FUNCTION public.process_player_simulation_to_time(
    p_user_id uuid,
    p_target_game_time timestamp with time zone
)
RETURNS TABLE(
    game_time timestamp with time zone,
    cash numeric,
    flights_run integer,
    elapsed_days numeric
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    r_user RECORD;
    v_route RECORD;
    v_flight_hours NUMERIC;
    v_revenue NUMERIC;
    v_ops_cost NUMERIC;
    v_lease_cost NUMERIC;
    v_net NUMERIC := 0;
    v_flights_run INT := 0;
    v_cash_after NUMERIC;
    v_elapsed_days NUMERIC;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_cargo_rev NUMERIC(20,2);
    v_turnaround_hours NUMERIC;
    v_demand_multiplier NUMERIC;
    v_crew_cost NUMERIC;
    v_fuel_price NUMERIC;
    v_seasonal_factor NUMERIC;
    v_fuel_price_multiplier NUMERIC := 1.0;
    v_maintenance_multiplier NUMERIC := 1.0;
    v_route_demand_event NUMERIC;
    v_route_capacity_event NUMERIC;
    v_effective_capacity NUMERIC;
    v_time_fraction NUMERIC;
    v_payment_periods INT;
    v_i INT;
    v_fuel_cost NUMERIC;
    v_crew_cost_total NUMERIC;
    v_maint_cost NUMERIC;
    v_owned_wear NUMERIC;
    v_leased_wear NUMERIC;
    v_auto_repair_rate NUMERIC;
    v_bankruptcy_threshold NUMERIC;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found: %', p_user_id; END IF;

    v_fuel_price := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_crew_cost := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
    v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);

    SELECT COALESCE(effect_value, 1.0) INTO v_fuel_price_multiplier
    FROM game_events
    WHERE event_type = 'fuel_shock' AND is_active = true
      AND effect_type = 'fuel_price'
      AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_fuel_price_multiplier := 1.0; END IF;

    SELECT COALESCE(effect_value, 1.0) INTO v_maintenance_multiplier
    FROM game_events
    WHERE event_type = 'maintenance_shock' AND is_active = true
      AND effect_type = 'maintenance_cost'
      AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_maintenance_multiplier := 1.0; END IF;

    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;
    v_time_fraction := LEAST(v_elapsed_days / 7.0, 1.0);

    FOR v_route IN
        SELECT ur.*, am.fuel_burn_per_km, am.speed_kmh, am.turnaround_hours,
               am.capacity, am.lease_price_per_month, am.maintenance_cost_per_hour,
               fa.acquisition_type,
               a1.demand_index AS origin_demand, a2.demand_index AS dest_demand
        FROM route_assignments ur
        JOIN fleet_aircraft fa ON fa.id = ur.assigned_aircraft_id
        JOIN aircraft_models am ON am.id = fa.aircraft_model_id
        JOIN airports a1 ON a1.iata = ur.origin_iata
        JOIN airports a2 ON a2.iata = ur.destination_iata
        WHERE ur.user_id = p_user_id AND ur.status = 'active'
          AND fa.status = 'active'
          AND fa.condition >= COALESCE(r_user.auto_grounding_threshold, 40.00)
    LOOP
        v_route_demand_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_demand_event
        FROM game_events
        WHERE event_type = 'demand_surge' AND is_active = true
          AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
          AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
        ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_demand_event := 1.0; END IF;

        v_route_capacity_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_capacity_event
        FROM game_events
        WHERE event_type = 'weather_disruption' AND is_active = true
          AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
          AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
        ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_capacity_event := 1.0; END IF;

        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
        v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
        IF v_flight_hours <= 0 THEN CONTINUE; END IF;

        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price) * v_route_demand_event;
        v_seasonal_factor := 1.0;
        v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);

        v_revenue := v_route.flights_per_week * v_route.ticket_price *
                     LEAST(v_effective_capacity,
                           FLOOR(v_effective_capacity * 0.95 * v_demand_multiplier * v_seasonal_factor));

        v_fuel_cost := v_route.flights_per_week * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
        v_crew_cost_total := v_route.flights_per_week * v_flight_hours * v_crew_cost;
        v_maint_cost := v_route.flights_per_week * v_route.distance_km * COALESCE(v_route.maintenance_cost_per_hour, 0) * COALESCE(v_maintenance_multiplier, 1.0) / NULLIF(v_route.speed_kmh, 0);

        v_ops_cost := v_fuel_cost + v_crew_cost_total + v_maint_cost;

        v_lease_cost := CASE
            WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                         WHERE fa2.id = v_route.assigned_aircraft_id
                           AND fa2.acquisition_type = 'lease')
            THEN COALESCE(v_route.lease_price_per_month, 0) * (v_elapsed_days / 30.0)
            ELSE 0
        END;

        v_revenue := v_revenue * v_time_fraction;
        v_ops_cost := v_ops_cost * v_time_fraction;

        v_cargo_rev := v_revenue * 0.05;

        PERFORM credit_bank_account(p_user_id, v_revenue + v_cargo_rev, 'revenue', 'ticket_revenue',
            'Route ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        PERFORM debit_bank_account(p_user_id, v_fuel_cost * v_time_fraction, 'cogs', 'fuel',
            'Fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        PERFORM debit_bank_account(p_user_id, v_crew_cost_total * v_time_fraction, 'cogs', 'crew',
            'Crew: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        PERFORM debit_bank_account(p_user_id, v_maint_cost * v_time_fraction, 'cogs', 'maintenance',
            'Maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        IF v_lease_cost > 0 THEN
            PERFORM debit_bank_account(p_user_id, v_lease_cost, 'opex', 'aircraft_lease',
                'Lease: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
        END IF;

        v_wear_per_cycle := CASE
            WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
            ELSE v_owned_wear
        END + (v_route.distance_km * 0.0001);
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week * v_elapsed_days / 7.0;
        v_self_healing_credit := v_gross_damage * (1.0 - v_auto_repair_rate);
        v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

        -- Removed total_flights increment (column being dropped)
        UPDATE fleet_aircraft
        SET condition = GREATEST(0, condition - v_net_damage)
        WHERE id = v_route.assigned_aircraft_id;

        v_flights_run := v_flights_run + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
    END LOOP;

    v_cash_after := get_user_balance(p_user_id);

    UPDATE users u
    SET game_current_time = p_target_game_time,
        last_active_at = NOW()
    WHERE u.id = p_user_id;

    -- Bankruptcy check using config threshold
    IF v_cash_after < v_bankruptcy_threshold THEN
        UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
        UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
    END IF;

    IF v_elapsed_days >= 1.0 THEN
        v_payment_periods := GREATEST(1, FLOOR(v_elapsed_days / 7.0)::INT);
        FOR v_i IN 1..v_payment_periods LOOP
            PERFORM process_loan_payments(p_user_id, p_target_game_time);
            PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time);
        END LOOP;

        -- accrue_savings_interest removed (operating accounts do not earn interest)
        PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time);
        PERFORM check_achievements(p_user_id, p_target_game_time);

        v_cash_after := get_user_balance(p_user_id);
        IF v_cash_after < 0 THEN
            UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1
            WHERE id = p_user_id;
            IF (SELECT consecutive_negative_days FROM users WHERE id = p_user_id) >= 30 THEN
                UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
                UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
            END IF;
        ELSE
            UPDATE users SET consecutive_negative_days = 0,
                             recovery_streak_days = recovery_streak_days + 1
            WHERE id = p_user_id;
        END IF;
    END IF;

    v_cash_after := get_user_balance(p_user_id);
    game_time := p_target_game_time;
    cash := v_cash_after;
    flights_run := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$function$;


-- 2b. Rewrite process_all_bots_simulation_to_time — remove total_flights write

CREATE OR REPLACE FUNCTION public.process_all_bots_simulation_to_time(
    p_target_game_time timestamp with time zone,
    p_season_id uuid DEFAULT NULL::uuid
)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    r_bot RECORD;
    v_game_sec DOUBLE PRECISION;
    v_game_days DOUBLE PRECISION;
    v_route RECORD;
    v_flights DOUBLE PRECISION;
    v_revenue NUMERIC(20,2) := 0;
    v_fuel_cost NUMERIC(20,2) := 0;
    v_maint_cost NUMERIC(20,2) := 0;
    v_crew_cost NUMERIC(20,2) := 0;
    v_total_cost NUMERIC(20,2) := 0;
    v_net NUMERIC(20,2) := 0;
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_turnaround_hours NUMERIC;
    v_lease_cost NUMERIC(20,2) := 0;
    v_fuel_price NUMERIC;
    v_fuel_price_multiplier NUMERIC;
    v_crew_cost_per_hour NUMERIC;
    v_absolute_minimum_safety_limit NUMERIC(5,2);
    v_effective_grounding_threshold NUMERIC(5,2);
    v_max_weekly_flights INT;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_cargo_rev NUMERIC(20,2);
    v_processed INT := 0;
    v_demand_multiplier NUMERIC;
    v_seasonal_multiplier NUMERIC;
    v_owned_wear NUMERIC;
    v_leased_wear NUMERIC;
    v_auto_repair_rate NUMERIC;
BEGIN
    v_fuel_price := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_absolute_minimum_safety_limit := COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00);
    v_crew_cost_per_hour := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);

    v_fuel_price_multiplier := 1.0;
    v_seasonal_multiplier := 1.0;

    FOR r_bot IN
        SELECT * FROM users
        WHERE actor_type = 'AI' AND COALESCE(operational_status, 'Active') != 'Bankrupt'
    LOOP
        v_effective_grounding_threshold := GREATEST(
            COALESCE(r_bot.auto_grounding_threshold, 40.00),
            v_absolute_minimum_safety_limit
        );

        v_game_sec := EXTRACT(EPOCH FROM (p_target_game_time - r_bot.game_current_time));
        v_game_days := v_game_sec / 86400.0;
        IF v_game_days <= 0 THEN CONTINUE; END IF;

        FOR v_route IN
            SELECT ra.*, am.fuel_burn_per_km, am.speed_kmh, am.capacity,
                   am.turnaround_hours, am.maintenance_cost_per_hour,
                   am.lease_price_per_month, fa.acquisition_type,
                   a1.demand_index AS origin_demand,
                   a2.demand_index AS dest_demand
            FROM route_assignments ra
            JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id
            JOIN aircraft_models am ON am.id = fa.aircraft_model_id
            JOIN airports a1 ON a1.iata = ra.origin_iata
            JOIN airports a2 ON a2.iata = ra.destination_iata
            WHERE ra.user_id = r_bot.id AND ra.status = 'active'
              AND fa.status = 'active'
              AND fa.condition >= v_effective_grounding_threshold
        LOOP
            v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
            v_flight_duration := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
            IF v_flight_duration <= 0 THEN CONTINUE; END IF;

            v_max_weekly_flights := FLOOR(168.0 / v_flight_duration)::INT;
            v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);

            v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price);
            v_passengers := LEAST(v_route.capacity,
                                  FLOOR(v_route.capacity * 0.95 * v_demand_multiplier * v_seasonal_multiplier));

            v_revenue := v_flights * v_route.ticket_price * v_passengers;
            v_fuel_cost := v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
            v_crew_cost := v_flights * v_flight_duration * v_crew_cost_per_hour;
            v_maint_cost := v_flights * v_route.distance_km * v_route.maintenance_cost_per_hour / NULLIF(v_route.speed_kmh, 0);
            v_cargo_rev := v_revenue * 0.05;
            v_lease_cost := CASE
                WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                             WHERE fa2.id = v_route.assigned_aircraft_id
                               AND fa2.acquisition_type = 'lease')
                THEN COALESCE(v_route.lease_price_per_month, 0) / 4.0
                ELSE 0
            END;

            PERFORM credit_bank_account(r_bot.id, v_revenue + v_cargo_rev, 'revenue', 'ticket_revenue',
                'Bot route ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            PERFORM debit_bank_account(r_bot.id, v_fuel_cost, 'cogs', 'fuel',
                'Bot fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            PERFORM debit_bank_account(r_bot.id, v_crew_cost, 'cogs', 'crew',
                'Bot crew: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            PERFORM debit_bank_account(r_bot.id, v_maint_cost, 'cogs', 'maintenance',
                'Bot maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            IF v_lease_cost > 0 THEN
                PERFORM debit_bank_account(r_bot.id, v_lease_cost, 'opex', 'aircraft_lease',
                    'Bot lease: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
            END IF;

            v_wear_per_cycle := CASE
                WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
                ELSE v_owned_wear
            END + (v_route.distance_km * 0.0001);
            v_gross_damage := v_wear_per_cycle * v_flights * v_game_days / 7.0;
            v_self_healing_credit := v_gross_damage * (1.0 - v_auto_repair_rate);
            v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

            -- Removed total_flights increment (column being dropped)
            UPDATE fleet_aircraft
            SET condition = GREATEST(0, condition - v_net_damage)
            WHERE id = v_route.assigned_aircraft_id;
        END LOOP;

        -- Check achievements at day boundary
        IF date_trunc('day', r_bot.game_current_time)::DATE <>
           date_trunc('day', p_target_game_time)::DATE THEN
            PERFORM check_achievements(r_bot.id, p_target_game_time);
        END IF;

        UPDATE users
        SET game_current_time = p_target_game_time,
            last_active_at = NOW()
        WHERE id = r_bot.id;

        IF v_game_days >= 1.0 THEN
            PERFORM process_loan_payments(r_bot.id, p_target_game_time);
            PERFORM process_aircraft_financing_payments(r_bot.id, p_target_game_time);
            PERFORM process_credit_at_day_boundary(r_bot.id, p_target_game_time);

            IF get_user_balance(r_bot.id) < 0 THEN
                UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1
                WHERE id = r_bot.id;
            ELSE
                UPDATE users SET consecutive_negative_days = 0
                WHERE id = r_bot.id;
            END IF;

            IF (SELECT consecutive_negative_days FROM users WHERE id = r_bot.id) >= 30 THEN
                UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
                UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id;
            END IF;
        END IF;

        v_processed := v_processed + 1;
    END LOOP;
    RETURN v_processed;
END;
$function$;


-- 2c. Drop the columns
ALTER TABLE fleet_aircraft DROP COLUMN IF EXISTS acquired_at;
ALTER TABLE fleet_aircraft DROP COLUMN IF EXISTS total_flights;


-- ============================================================================
-- Fix 3: Drop dead columns from loans
-- ============================================================================
-- game_date_taken, paid_off_at, credit_score_at_origination — metadata only
-- aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment — aircraft
--   financing metadata (use collateral_aircraft_id instead for grounding)
-- payments_made — counter never read for game logic
-- ============================================================================

-- 3a. Rewrite take_loan (5-param internal) — remove dropped columns from INSERT

CREATE OR REPLACE FUNCTION public.take_loan(
    p_user_id uuid, p_principal numeric,
    p_term_weeks integer DEFAULT 52,
    p_loan_type character varying DEFAULT 'unsecured',
    p_collateral_aircraft_id uuid DEFAULT NULL::uuid
)
 RETURNS TABLE(success boolean, message text, new_cash numeric)
 LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_actor_type VARCHAR(10); v_existing_loans INT; v_credit_score INT;
    v_score_record RECORD; v_tier VARCHAR(10); v_config JSONB; v_tier_cfg JSONB;
    v_min_loan NUMERIC; v_max_loans INT; v_interest_rate NUMERIC;
    v_weekly_payment NUMERIC; v_total_repayable NUMERIC; v_cash NUMERIC;
    v_game_time TIMESTAMPTZ; v_max_principal NUMERIC; v_loan_id UUID;
BEGIN
    SELECT u.actor_type, u.game_current_time
    INTO v_actor_type, v_game_time
    FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;

    IF v_actor_type = 'AI' THEN
        SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active';
        IF v_existing_loans >= 3 THEN RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC; RETURN; END IF;
        IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN QUERY SELECT false, 'Bot loan amount must be between $100K and $5M.'::TEXT, 0::NUMERIC; RETURN; END IF;
        SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
        IF NOT FOUND THEN v_credit_score := 500; END IF;
        v_interest_rate := 0.05;
        v_total_repayable := p_principal * (1 + v_interest_rate);
        v_weekly_payment := v_total_repayable / p_term_weeks;
        INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type)
        VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', 'unsecured')
        RETURNING id INTO v_loan_id;
        PERFORM credit_bank_account(p_user_id, p_principal, 'financing', 'loan_disbursement',
            'Loan disbursement', v_game_time);
        v_cash := get_user_balance(p_user_id);
        RETURN QUERY SELECT true, 'Loan disbursed.'::TEXT, v_cash;
        RETURN;
    END IF;

    SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';
    v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
    v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);

    SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active';
    IF v_existing_loans >= v_max_loans THEN
        RETURN QUERY SELECT false, 'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
    IF NOT FOUND THEN v_credit_score := 500; END IF;

    SELECT * INTO v_score_record FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF FOUND THEN v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE v_tier := resolve_credit_tier(v_credit_score); END IF;

    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);

    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
        RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    IF p_loan_type = 'unsecured' THEN
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC; RETURN;
        END IF;
        v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
    ELSE
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000) * 0.5;
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07) + 0.02;
    END IF;

    IF p_principal < v_min_loan THEN
        RETURN QUERY SELECT false, 'Minimum loan amount is $' || v_min_loan::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;
    IF p_principal > v_max_principal THEN
        RETURN QUERY SELECT false, 'Maximum for ' || v_tier || ' tier ' || p_loan_type || ' loan is $' || v_max_principal::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id)
    VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', p_loan_type, p_collateral_aircraft_id)
    RETURNING id INTO v_loan_id;

    PERFORM credit_bank_account(p_user_id, p_principal, 'financing', 'loan_disbursement',
        'Loan disbursement', v_game_time);

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Loan disbursed at ' || ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT, v_cash;
END;
$function$;


-- 3b. Rewrite bot_take_loan — remove dropped columns from INSERT

CREATE OR REPLACE FUNCTION public.bot_take_loan(
    p_bot_id uuid, p_principal numeric, p_term_weeks integer DEFAULT 52
)
 RETURNS boolean
 LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_existing_loans INT;
    v_interest_rate NUMERIC := 0.05;
    v_total_repayable NUMERIC;
    v_weekly_payment NUMERIC;
    v_game_time TIMESTAMPTZ;
BEGIN
    SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_bot_id AND status = 'active';
    IF v_existing_loans >= 3 THEN RETURN false; END IF;
    IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN false; END IF;
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_bot_id;
    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type)
    VALUES (p_bot_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', 'unsecured');

    PERFORM credit_bank_account(p_bot_id, p_principal, 'financing', 'loan_disbursement',
        'Bot loan disbursement', v_game_time);

    RETURN true;
END;
$function$;


-- 3c. Rewrite finance_aircraft (4-param internal) — remove dropped columns,
--     use collateral_aircraft_id instead of fleet_aircraft_id

CREATE OR REPLACE FUNCTION public.finance_aircraft(
    p_user_id uuid, p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20,
    p_term_months integer DEFAULT 36
)
 RETURNS TABLE(success boolean, message text, new_cash numeric)
 LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_actor_type VARCHAR(10); v_model RECORD; v_credit_score INT; v_tier VARCHAR(10);
    v_purchase_price NUMERIC; v_down_payment NUMERIC; v_principal NUMERIC;
    v_interest_rate NUMERIC; v_monthly_payment NUMERIC; v_total_repayable NUMERIC;
    v_cash NUMERIC; v_game_time TIMESTAMPTZ; v_fleet_id UUID; v_hq_iata VARCHAR(3);
    v_max_financing NUMERIC; v_economy_seats INT; v_business_seats INT; v_first_seats INT;
    v_archetype VARCHAR(30);
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC; RETURN; END IF;
    v_purchase_price := v_model.purchase_price;

    SELECT u.actor_type, u.game_current_time, u.hq_airport_iata
    INTO v_actor_type, v_game_time, v_hq_iata
    FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;

    -- Read archetype from bot_profiles for AI users
    IF v_actor_type = 'AI' THEN
        SELECT COALESCE(bp.archetype, 'Balanced') INTO v_archetype
        FROM bot_profiles bp WHERE bp.user_id = p_user_id;
        IF NOT FOUND THEN v_archetype := 'Balanced'; END IF;
    END IF;

    IF v_actor_type = 'AI' THEN
        v_cash := get_user_balance(p_user_id);
        v_down_payment := v_purchase_price * p_down_payment_pct;
        v_principal := v_purchase_price - v_down_payment;
        v_interest_rate := 0.05;
        v_total_repayable := v_principal * (1 + v_interest_rate);
        v_monthly_payment := v_total_repayable / p_term_months;

        IF v_cash < v_down_payment THEN
            RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
        END IF;

        PERFORM debit_bank_account(p_user_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
            'Aircraft financing down payment — ' || v_model.model_name, v_game_time);

        v_economy_seats := CASE WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.80)::INT
                                WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)::INT
                                ELSE FLOOR(v_model.capacity * 0.50)::INT END;
        v_business_seats := CASE WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.15)::INT
                                 WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)::INT
                                 ELSE FLOOR(v_model.capacity * 0.30)::INT END;
        v_first_seats := v_model.capacity - v_economy_seats - v_business_seats;

        INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
        VALUES (p_user_id, p_aircraft_model_id, v_model.model_name, 'BOT-' || left(p_user_id::text, 4), 'finance', 100.00, 'active', v_economy_seats, v_business_seats, v_first_seats)
        RETURNING id INTO v_fleet_id;

        INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id, term_months, monthly_payment)
        VALUES (p_user_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', 'aircraft_financing', v_fleet_id, p_term_months, v_monthly_payment);

        v_cash := get_user_balance(p_user_id);
        RETURN QUERY SELECT true, 'Aircraft financed (bot).'::TEXT, v_cash;
        RETURN;
    END IF;

    -- Human path
    v_cash := get_user_balance(p_user_id);
    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
    v_credit_score := COALESCE(v_credit_score, 500);
    SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = p_user_id;
    v_tier := COALESCE(v_tier, 'Standard');

    v_max_financing := CASE
        WHEN v_tier = 'Platinum' THEN 80000000 WHEN v_tier = 'Gold' THEN 60000000
        WHEN v_tier = 'Silver' THEN 40000000 WHEN v_tier = 'Standard' THEN 20000000
        ELSE 5000000
    END;

    IF v_purchase_price > v_max_financing THEN
        RETURN QUERY SELECT false, 'Aircraft price ($' || v_purchase_price::TEXT || ') exceeds your financing limit ($' || v_max_financing::TEXT || ') for tier ' || v_tier || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;
    IF p_term_months NOT IN (12, 24, 36, 48, 60) THEN
        RETURN QUERY SELECT false, 'Financing term must be 12, 24, 36, 48, or 60 months.'::TEXT, 0::NUMERIC; RETURN;
    END IF;
    IF p_down_payment_pct < 0.10 OR p_down_payment_pct > 0.50 THEN
        RETURN QUERY SELECT false, 'Down payment must be between 10% and 50%.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_interest_rate := CASE
        WHEN v_tier = 'Platinum' THEN 0.03 WHEN v_tier = 'Gold' THEN 0.04
        WHEN v_tier = 'Silver' THEN 0.05 WHEN v_tier = 'Standard' THEN 0.07
        ELSE 0.10
    END;
    v_total_repayable := v_principal * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;

    IF v_cash < v_down_payment THEN
        RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    PERFORM debit_bank_account(p_user_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
        'Aircraft financing down payment — ' || v_model.model_name, v_game_time);

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
    VALUES (p_user_id, p_aircraft_model_id, v_model.model_name, generate_tail_number(COALESCE(v_hq_iata, 'CGK')), 'finance', 100.00, 'active', v_model.capacity, 0, 0)
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id, term_months, monthly_payment)
    VALUES (p_user_id, v_principal, v_interest_rate, v_total_repayable, 0, 'active', 'aircraft_financing', v_fleet_id, p_term_months, v_monthly_payment);

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$function$;


-- 3d. Rewrite bot_finance_aircraft — remove dropped columns

CREATE OR REPLACE FUNCTION public.bot_finance_aircraft(
    p_bot_id uuid, p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 60
)
 RETURNS boolean
 LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_model RECORD;
    v_purchase_price NUMERIC;
    v_down_payment NUMERIC;
    v_principal NUMERIC;
    v_interest_rate NUMERIC := 0.05;
    v_monthly_payment NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_fleet_id UUID;
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN RETURN false; END IF;
    v_purchase_price := v_model.purchase_price;
    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_monthly_payment := (v_principal * (1 + v_interest_rate)) / p_term_months;
    v_cash := get_user_balance(p_bot_id);
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_bot_id;
    IF v_cash < v_down_payment THEN RETURN false; END IF;

    PERFORM debit_bank_account(p_bot_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
        'Aircraft financing down payment — ' || v_model.model_name, v_game_time);

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
    VALUES (p_bot_id, p_aircraft_model_id, v_model.model_name, 'finance', 100.00, 'active', 'BOT-' || left(p_bot_id::text, 4), FLOOR(v_model.capacity * 0.70)::INT, FLOOR(v_model.capacity * 0.20)::INT, FLOOR(v_model.capacity * 0.10)::INT)
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id, term_months, monthly_payment)
    VALUES (p_bot_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', 'aircraft_financing', v_fleet_id, p_term_months, v_monthly_payment);

    RETURN true;
END;
$function$;


-- 3e. Rewrite process_loan_payments — remove paid_off_at from UPDATE

CREATE OR REPLACE FUNCTION public.process_loan_payments(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path = public, pg_catalog
 AS $function$
DECLARE
    v_actor_type VARCHAR(10);
    r_loan RECORD;
    v_cash NUMERIC;
    v_payment NUMERIC;
    v_late_fee NUMERIC;
    v_effective_weekly NUMERIC;
BEGIN
    SELECT actor_type INTO v_actor_type FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN; END IF;
    v_cash := get_user_balance(p_user_id);

    FOR r_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id AND status = 'active' AND loan_type != 'aircraft_financing'
        ORDER BY taken_at ASC
    LOOP
        IF COALESCE(r_loan.weekly_payment, 0) > 0 THEN
            v_effective_weekly := r_loan.weekly_payment;
        ELSIF COALESCE(r_loan.monthly_payment, 0) > 0 THEN
            v_effective_weekly := r_loan.monthly_payment / 4.33;
        ELSE
            CONTINUE;
        END IF;

        IF v_actor_type = 'AI' THEN
            IF v_cash >= v_effective_weekly THEN
                PERFORM debit_bank_account(p_user_id, v_effective_weekly, 'financing', 'loan_payment',
                    'Weekly loan payment', p_game_date);
                v_cash := v_cash - v_effective_weekly;
                UPDATE loans SET remaining_balance = remaining_balance - v_effective_weekly WHERE id = r_loan.id;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', remaining_balance = 0 WHERE id = r_loan.id;
                END IF;
            ELSE
                UPDATE loans SET remaining_balance = remaining_balance * 1.10,
                                 missed_payments = missed_payments + 1 WHERE id = r_loan.id;
                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
                END IF;
            END IF;
        ELSE
            v_payment := v_effective_weekly;
            IF v_cash >= v_payment THEN
                PERFORM debit_bank_account(p_user_id, v_payment, 'financing', 'loan_payment',
                    'Weekly loan payment', p_game_date);
                v_cash := v_cash - v_payment;
                UPDATE loans SET remaining_balance = remaining_balance - v_payment WHERE id = r_loan.id;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', remaining_balance = 0 WHERE id = r_loan.id;
                END IF;
            ELSE
                v_late_fee := v_payment * 0.10;
                UPDATE loans SET remaining_balance = remaining_balance + v_late_fee,
                                 missed_payments = missed_payments + 1 WHERE id = r_loan.id;
                INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after,
                    description, game_date, ifrs_category, ifrs_subcategory)
                SELECT ba.id, p_user_id, 'late_fee', v_late_fee, ba.balance,
                    'Loan payment late fee', p_game_date, 'financing', 'loan_late_fee'
                FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'operating' LIMIT 1;
                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
                    IF r_loan.collateral_aircraft_id IS NOT NULL THEN
                        UPDATE fleet_aircraft SET status = 'grounded' WHERE id = r_loan.collateral_aircraft_id;
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$function$;


-- 3f. Rewrite process_aircraft_financing_payments — remove dropped columns,
--     use collateral_aircraft_id for grounding

CREATE OR REPLACE FUNCTION public.process_aircraft_financing_payments(
    p_user_id uuid,
    p_game_date timestamp with time zone
)
 RETURNS void
 LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_loan RECORD;
    v_cash NUMERIC;
    v_payment NUMERIC;
    v_late_fee NUMERIC;
BEGIN
    v_cash := get_user_balance(p_user_id);

    FOR v_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id AND loan_type = 'aircraft_financing' AND status = 'active'
    LOOP
        v_payment := v_loan.monthly_payment;

        IF v_cash >= v_payment THEN
            PERFORM debit_bank_account(p_user_id, v_payment, 'financing', 'financing_payment',
                'Aircraft financing payment', p_game_date);
            v_cash := v_cash - v_payment;
            UPDATE loans SET remaining_balance = remaining_balance - v_payment WHERE id = v_loan.id;

            IF (SELECT remaining_balance FROM loans WHERE id = v_loan.id) <= 0 THEN
                UPDATE loans SET status = 'paid_off', remaining_balance = 0 WHERE id = v_loan.id;
            END IF;
        ELSE
            v_late_fee := v_payment * 0.05;
            UPDATE loans SET remaining_balance = remaining_balance + v_late_fee,
                             missed_payments = missed_payments + 1 WHERE id = v_loan.id;

            INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after,
                description, game_date, ifrs_category, ifrs_subcategory)
            SELECT ba.id, p_user_id, 'late_fee', v_late_fee, ba.balance,
                'Aircraft financing late fee', p_game_date, 'financing', 'financing_late_fee'
            FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'operating' LIMIT 1;

            IF (SELECT missed_payments FROM loans WHERE id = v_loan.id) >= 3 THEN
                UPDATE loans SET status = 'repossessed' WHERE id = v_loan.id;
                IF v_loan.collateral_aircraft_id IS NOT NULL THEN
                    UPDATE fleet_aircraft SET status = 'grounded' WHERE id = v_loan.collateral_aircraft_id;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$function$;


-- 3g. Rewrite repay_loan — remove paid_off_at from UPDATE

CREATE OR REPLACE FUNCTION public.repay_loan(p_loan_id uuid, p_amount numeric DEFAULT NULL::numeric)
 RETURNS TABLE(success boolean, message text, new_cash numeric, paid_off boolean)
 LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog AS $function$
DECLARE
    v_user_id UUID; v_loan RECORD; v_payment NUMERIC; v_cash NUMERIC;
    v_is_paid_off BOOLEAN := false;
BEGIN
    v_user_id := require_current_user_id();
    SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'Loan not found or already paid off.'::TEXT, 0::NUMERIC, false; RETURN; END IF;

    IF p_amount IS NULL THEN v_payment := v_loan.remaining_balance;
    ELSE v_payment := LEAST(p_amount, v_loan.remaining_balance); END IF;

    IF v_payment <= 0 THEN RETURN QUERY SELECT false, 'Payment amount must be positive.'::TEXT, 0::NUMERIC, false; RETURN; END IF;

    v_cash := get_user_balance(v_user_id);
    IF v_cash < v_payment THEN
        RETURN QUERY SELECT false, 'Insufficient cash. Need $' || v_payment::TEXT || ', have $' || v_cash::TEXT || '.'::TEXT, v_cash, false; RETURN;
    END IF;

    PERFORM debit_bank_account(v_user_id, v_payment, 'financing', 'loan_repayment',
        CASE WHEN v_loan.remaining_balance - v_payment <= 0 THEN 'Loan fully repaid' ELSE 'Loan partial repayment' END,
        NOW());

    UPDATE loans
    SET remaining_balance = remaining_balance - v_payment,
        status = CASE WHEN remaining_balance - v_payment <= 0 THEN 'paid_off'::VARCHAR ELSE status END
    WHERE id = p_loan_id;

    v_is_paid_off := (SELECT remaining_balance <= 0 FROM loans WHERE id = p_loan_id);

    v_cash := get_user_balance(v_user_id);
    RETURN QUERY SELECT true,
        CASE WHEN v_is_paid_off THEN 'Loan fully repaid!'
             ELSE 'Payment of $' || v_payment::TEXT || ' applied.' END::TEXT,
        v_cash, v_is_paid_off;
END;
$function$;

REVOKE ALL ON FUNCTION repay_loan(UUID, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION repay_loan(UUID, NUMERIC) TO authenticated;


-- 3h. Drop the columns
ALTER TABLE loans DROP COLUMN IF EXISTS game_date_taken;
ALTER TABLE loans DROP COLUMN IF EXISTS paid_off_at;
ALTER TABLE loans DROP COLUMN IF EXISTS credit_score_at_origination;
ALTER TABLE loans DROP COLUMN IF EXISTS aircraft_model_id;
ALTER TABLE loans DROP COLUMN IF EXISTS fleet_aircraft_id;
ALTER TABLE loans DROP COLUMN IF EXISTS purchase_price;
ALTER TABLE loans DROP COLUMN IF EXISTS down_payment;
ALTER TABLE loans DROP COLUMN IF EXISTS payments_made;


-- ============================================================================
-- Fix 4: Drop dead columns from bank_transactions
-- ============================================================================
-- reference_type, reference_id — legacy FK columns, never used by bank-centric
-- cost_center_type, cost_center_id — added in m128, never read for game logic
-- ============================================================================

-- 4a. Rewrite debit_bank_account — remove cost_center params and columns

CREATE OR REPLACE FUNCTION public.debit_bank_account(
    p_user_id UUID,
    p_amount NUMERIC,
    p_ifrs_category VARCHAR(30),
    p_ifrs_subcategory VARCHAR(50),
    p_description TEXT,
    p_game_date TIMESTAMPTZ
) RETURNS NUMERIC
 LANGUAGE plpgsql SECURITY DEFINER
 AS $$
DECLARE
    v_account_id UUID;
    v_new_balance NUMERIC;
BEGIN
    SELECT id INTO v_account_id
    FROM bank_accounts
    WHERE user_id = p_user_id AND account_type = 'operating'
    LIMIT 1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'No operating bank account for user %', p_user_id;
    END IF;

    UPDATE bank_accounts
    SET balance = balance - p_amount
    WHERE id = v_account_id
    RETURNING balance INTO v_new_balance;

    INSERT INTO bank_transactions (
        account_id, user_id, transaction_type, amount, balance_after,
        description, game_date, ifrs_category, ifrs_subcategory
    ) VALUES (
        v_account_id, p_user_id, 'debit', -p_amount, v_new_balance,
        p_description, p_game_date, p_ifrs_category, p_ifrs_subcategory
    );

    RETURN v_new_balance;
END;
$$;


-- 4b. Rewrite credit_bank_account — remove cost_center params and columns

CREATE OR REPLACE FUNCTION public.credit_bank_account(
    p_user_id UUID,
    p_amount NUMERIC,
    p_ifrs_category VARCHAR(30),
    p_ifrs_subcategory VARCHAR(50),
    p_description TEXT,
    p_game_date TIMESTAMPTZ
) RETURNS NUMERIC
 LANGUAGE plpgsql SECURITY DEFINER
 AS $$
DECLARE
    v_account_id UUID;
    v_new_balance NUMERIC;
BEGIN
    SELECT id INTO v_account_id
    FROM bank_accounts
    WHERE user_id = p_user_id AND account_type = 'operating'
    LIMIT 1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'No operating bank account for user %', p_user_id;
    END IF;

    UPDATE bank_accounts
    SET balance = balance + p_amount
    WHERE id = v_account_id
    RETURNING balance INTO v_new_balance;

    INSERT INTO bank_transactions (
        account_id, user_id, transaction_type, amount, balance_after,
        description, game_date, ifrs_category, ifrs_subcategory
    ) VALUES (
        v_account_id, p_user_id, 'credit', p_amount, v_new_balance,
        p_description, p_game_date, p_ifrs_category, p_ifrs_subcategory
    );

    RETURN v_new_balance;
END;
$$;


-- 4c. Rewrite compact_bank_transactions — remove dropped columns from archive INSERT
--     Also remove created_at from archive INSERT (source column being dropped)

CREATE OR REPLACE FUNCTION public.compact_bank_transactions(p_dry_run BOOLEAN DEFAULT TRUE)
 RETURNS TABLE(action TEXT, detail TEXT, row_count BIGINT)
 LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
DECLARE
    v_retention_days INT;
    v_cutoff_date DATE;
    v_archived BIGINT := 0;
    v_summarized BIGINT := 0;
    v_deleted BIGINT := 0;
BEGIN
    v_retention_days := COALESCE(get_config_int('bank_txn_raw_retention_days'), 30);
    v_cutoff_date := (NOW() - (v_retention_days || ' days')::INTERVAL)::DATE;

    -- Step 1: Archive old raw transactions
    IF NOT p_dry_run THEN
        INSERT INTO bank_transactions_archive (
            id, account_id, user_id, transaction_type, amount, balance_after,
            description, game_date, archived_at,
            ifrs_category, ifrs_subcategory
        )
        SELECT id, account_id, user_id, transaction_type, amount, balance_after,
               description, game_date, NOW(),
               ifrs_category, ifrs_subcategory
        FROM bank_transactions
        WHERE game_date < v_cutoff_date;
        GET DIAGNOSTICS v_archived = ROW_COUNT;
    ELSE
        SELECT COUNT(*) INTO v_archived FROM bank_transactions WHERE game_date < v_cutoff_date;
    END IF;

    action := 'archive'; detail := 'Rows moved to archive'; row_count := v_archived;
    RETURN NEXT;

    -- Step 2: Generate/update daily summaries
    IF NOT p_dry_run THEN
        INSERT INTO bank_transaction_daily_summary (
            user_id, game_date, ifrs_category, ifrs_subcategory, transaction_type,
            transaction_count, total_amount, total_debits, total_credits,
            first_balance, last_balance, first_game_date, last_game_date
        )
        SELECT
            user_id,
            (game_date AT TIME ZONE 'UTC')::DATE,
            COALESCE(ifrs_category, 'uncategorized'),
            COALESCE(ifrs_subcategory, 'uncategorized'),
            transaction_type,
            COUNT(*),
            SUM(amount),
            COALESCE(SUM(amount) FILTER (WHERE amount < 0), 0),
            COALESCE(SUM(amount) FILTER (WHERE amount > 0), 0),
            (ARRAY_AGG(balance_after ORDER BY game_date ASC))[1],
            (ARRAY_AGG(balance_after ORDER BY game_date DESC))[1],
            MIN(game_date),
            MAX(game_date)
        FROM bank_transactions
        WHERE game_date < v_cutoff_date
        GROUP BY user_id, (game_date AT TIME ZONE 'UTC')::DATE,
                 COALESCE(ifrs_category, 'uncategorized'),
                 COALESCE(ifrs_subcategory, 'uncategorized'),
                 transaction_type
        ON CONFLICT (user_id, game_date, ifrs_category, ifrs_subcategory, transaction_type)
        DO UPDATE SET
            transaction_count = bank_transaction_daily_summary.transaction_count + EXCLUDED.transaction_count,
            total_amount = bank_transaction_daily_summary.total_amount + EXCLUDED.total_amount,
            total_debits = bank_transaction_daily_summary.total_debits + EXCLUDED.total_debits,
            total_credits = bank_transaction_daily_summary.total_credits + EXCLUDED.total_credits,
            last_balance = EXCLUDED.last_balance,
            last_game_date = GREATEST(bank_transaction_daily_summary.last_game_date, EXCLUDED.last_game_date),
            compacted_at = NOW();
        GET DIAGNOSTICS v_summarized = ROW_COUNT;
    ELSE
        SELECT COUNT(DISTINCT (user_id, (game_date AT TIME ZONE 'UTC')::DATE,
                      COALESCE(ifrs_category, 'uncategorized'),
                      COALESCE(ifrs_subcategory, 'uncategorized'),
                      transaction_type))
        INTO v_summarized
        FROM bank_transactions WHERE game_date < v_cutoff_date;
    END IF;

    action := 'summarize'; detail := 'Daily summary rows upserted'; row_count := v_summarized;
    RETURN NEXT;

    -- Step 3: Delete archived rows from main table
    IF NOT p_dry_run THEN
        DELETE FROM bank_transactions WHERE game_date < v_cutoff_date;
        GET DIAGNOSTICS v_deleted = ROW_COUNT;
    END IF;

    action := 'delete'; detail := 'Raw rows deleted from main table'; row_count := v_deleted;
    RETURN NEXT;
END;
$$;


-- 4d. Drop the cost_center index
DROP INDEX IF EXISTS idx_bank_txn_cost_center;

-- 4e. Drop the columns
ALTER TABLE bank_transactions DROP COLUMN IF EXISTS reference_type;
ALTER TABLE bank_transactions DROP COLUMN IF EXISTS reference_id;
ALTER TABLE bank_transactions DROP COLUMN IF EXISTS cost_center_type;
ALTER TABLE bank_transactions DROP COLUMN IF EXISTS cost_center_id;


-- ============================================================================
-- Fix 5: Drop dead columns from bank_transactions_archive (same 4 columns)
-- ============================================================================

ALTER TABLE bank_transactions_archive DROP COLUMN IF EXISTS reference_type;
ALTER TABLE bank_transactions_archive DROP COLUMN IF EXISTS reference_id;
ALTER TABLE bank_transactions_archive DROP COLUMN IF EXISTS cost_center_type;
ALTER TABLE bank_transactions_archive DROP COLUMN IF EXISTS cost_center_id;


-- ============================================================================
-- Fix 6: Drop dead *_created_at columns
-- ============================================================================
-- users.created_at — never read for game logic
-- route_assignments.created_at — never read
-- loans.created_at — never read (taken_at is used instead)
-- bank_transactions.created_at — only used in archive INSERT (preserved there)
-- aircraft_models.created_at — never read
-- ============================================================================

ALTER TABLE users DROP COLUMN IF EXISTS created_at;
ALTER TABLE route_assignments DROP COLUMN IF EXISTS created_at;
ALTER TABLE loans DROP COLUMN IF EXISTS created_at;
ALTER TABLE bank_transactions DROP COLUMN IF EXISTS created_at;
ALTER TABLE aircraft_models DROP COLUMN IF EXISTS created_at;


-- ============================================================================
-- Fix 7: Clean up expired game_events
-- ============================================================================

DELETE FROM game_events
WHERE is_active = false
  AND end_game_time < NOW() - INTERVAL '30 days';


COMMIT;


-- ============================================================================
-- Verification (run after commit)
-- ============================================================================

-- SELECT ensure_world_current();
-- SELECT status, COUNT(*) FROM world_tick_log GROUP BY status;
