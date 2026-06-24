-- Migration 120: Fix remaining database state issues
-- =====================================================
-- Fix 1: Generate nicknames for aircraft with NULL nicknames
-- Fix 2: Set credit_score_at_origination on loans where NULL
-- Fix 3: Fix bank_transactions never written (gated on elapsed_days >= 1.0 but ticks < 1 day)
--         + Restore execute_bot_decisions() call removed in migration 119
-- Fix 4: Fix AI bots with NULL hq_airport_iata (can't create routes)
-- Fix 5: Verify collateral_aircraft_id is expected NULL for unsecured loans

BEGIN;

-- ── Fix 1: Generate nicknames for aircraft with NULL nicknames ────────────

UPDATE fleet_aircraft
SET nickname = CONCAT(
    (SELECT model_name FROM aircraft_models WHERE id = fleet_aircraft.aircraft_model_id),
    ' (',
    tail_number,
    ')'
)
WHERE nickname IS NULL;

-- ── Fix 2: Set credit_score_at_origination on loans where NULL ────────────

UPDATE loans l
SET credit_score_at_origination = (
    SELECT COALESCE(credit_score, 500) FROM users WHERE id = l.user_id
)
WHERE credit_score_at_origination IS NULL;

-- ── Fix 3a: Fix process_player_simulation_to_time — bank_transactions not written ──
-- The bank_transactions INSERT was inside the `IF v_elapsed_days >= 1.0` block,
-- but with tick_interval_seconds=60 and time_scale_multiplier=60, each tick
-- only advances 1 game hour (~0.042 days). The INSERT never fired.
-- Fix: move bank_transactions INSERT outside the day-boundary block so it
-- records every tick with net cash movement.

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
LANGUAGE plpgsql VOLATILE AS $function$
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
    v_buffered_rev_accum NUMERIC(20,2) := 0.00;
    v_buffered_ops_accum NUMERIC(20,2) := 0.00;
    v_buffered_lease_accum NUMERIC(20,2) := 0.00;
    v_buffered_cargo_accum NUMERIC(20,2) := 0.00;
    v_cargo_rev NUMERIC(20,2);
    v_turnaround_hours NUMERIC;
    v_demand_multiplier NUMERIC;
    v_crew_cost NUMERIC;
    v_fuel_price NUMERIC;
    v_seasonal_factor NUMERIC;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found: %', p_user_id; END IF;

    SELECT COALESCE(fuel_price_per_liter, 0.85), COALESCE(crew_cost_per_hour, 350.0)
    INTO v_fuel_price, v_crew_cost FROM global_game_settings LIMIT 1;

    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;

    FOR v_route IN
        SELECT ur.*, am.fuel_burn_per_km, am.speed_kmh, am.turnaround_hours,
               am.capacity, am.lease_price_per_month,
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
        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
        v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
        IF v_flight_hours <= 0 THEN CONTINUE; END IF;

        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price);
        v_seasonal_factor := 1.0;

        v_revenue := v_route.flights_per_week * v_route.ticket_price *
                     LEAST(v_route.capacity,
                           FLOOR(v_route.capacity * 0.95 * v_demand_multiplier * v_seasonal_factor));
        v_ops_cost := v_route.flights_per_week * (
            v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price +
            v_flight_hours * v_crew_cost
        );
        v_lease_cost := CASE
            WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                         WHERE fa2.id = v_route.assigned_aircraft_id
                           AND fa2.acquisition_type = 'lease')
            THEN COALESCE(v_route.lease_price_per_month, 0) / 4.0
            ELSE 0
        END;

        v_cargo_rev := v_revenue * 0.05;
        v_buffered_rev_accum := v_buffered_rev_accum + v_revenue;
        v_buffered_ops_accum := v_buffered_ops_accum + v_ops_cost;
        v_buffered_lease_accum := v_buffered_lease_accum + v_lease_cost;
        v_buffered_cargo_accum := v_buffered_cargo_accum + v_cargo_rev;

        v_wear_per_cycle := 0.50 + (v_route.distance_km * 0.0001);
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week * v_elapsed_days / 7.0;
        v_self_healing_credit := v_gross_damage * 0.10;
        v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

        UPDATE fleet_aircraft
        SET condition = GREATEST(0, condition - v_net_damage),
            total_flights = total_flights + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT
        WHERE id = v_route.assigned_aircraft_id;

        v_flights_run := v_flights_run + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
    END LOOP;

    v_net := v_buffered_rev_accum + v_buffered_cargo_accum
             - v_buffered_ops_accum - v_buffered_lease_accum;

    UPDATE users u
    SET cash = r_user.cash + v_net,
        game_current_time = p_target_game_time,
        last_active_at = NOW()
    WHERE u.id = p_user_id
    RETURNING u.cash INTO v_cash_after;

    -- Record bank transaction EVERY tick with net movement (not just day boundaries)
    IF v_net != 0 THEN
        PERFORM ensure_checking_account(p_user_id);
        INSERT INTO bank_transactions (
            account_id, user_id, transaction_type, amount, balance_after,
            description, game_date
        )
        SELECT ba.id, p_user_id,
            CASE WHEN v_net >= 0 THEN 'deposit' ELSE 'payment' END,
            v_net,
            (SELECT u2.cash FROM users u2 WHERE u2.id = p_user_id),
            'Simulation net cash movement',
            p_target_game_time
        FROM bank_accounts ba
        WHERE ba.user_id = p_user_id AND ba.account_type = 'checking'
        LIMIT 1;
    END IF;

    IF v_elapsed_days >= 1.0 THEN
        PERFORM process_loan_payments(p_user_id, p_target_game_time);
        PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time);
        PERFORM accrue_savings_interest(p_user_id, p_target_game_time);
        PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time);
        PERFORM check_achievements(p_user_id, p_target_game_time);

        IF v_net < 0 THEN
            UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1
            WHERE id = p_user_id;
        ELSE
            UPDATE users SET consecutive_negative_days = 0,
                             recovery_streak_days = recovery_streak_days + 1
            WHERE id = p_user_id;
        END IF;
    END IF;

    game_time := p_target_game_time;
    cash := v_cash_after;
    flights_run := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$function$;

-- ── Fix 3b: Restore execute_bot_decisions() call in process_world_tick ────
-- Migration 119 accidentally removed the execute_bot_decisions() call.
-- Without it, bots never make new decisions (lease aircraft, create routes, etc.)

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
    v_game_time_after TIMESTAMPTZ;
    v_ticks_processed INT := 0;
    v_players_processed INT := 0;
    v_bots_processed INT := 0;
    r_user RECORD;
    r_player_result RECORD;
    v_lock_key BIGINT;
    v_start_time TIMESTAMPTZ;
BEGIN
    IF p_season_id IS NOT NULL THEN
        SELECT * INTO r_season FROM season_clock WHERE id = p_season_id;
    ELSE
        SELECT * INTO r_season FROM season_clock WHERE status = 'active' LIMIT 1;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active season found';
    END IF;

    v_lock_key := hashtext(r_season.id::text);
    IF NOT pg_try_advisory_lock(v_lock_key) THEN
        RAISE EXCEPTION 'World tick already in progress for season %', r_season.id;
    END IF;

    v_start_time := NOW();

    v_game_time_after := r_season.current_game_time +
        (r_season.tick_interval_seconds * r_season.time_scale_multiplier * INTERVAL '1 second');

    PERFORM generate_game_events(v_game_time_after);
    PERFORM deactivate_expired_events(v_game_time_after);

    FOR r_user IN
        SELECT u.id, u.game_current_time
        FROM users u
        WHERE u.season_id = r_season.id
          AND u.actor_type = 'REAL'
          AND u.operational_status != 'Bankrupt'
    LOOP
        SELECT *
        INTO r_player_result
        FROM process_player_simulation_to_time(r_user.id, v_game_time_after)
        LIMIT 1;
        IF COALESCE(r_player_result.elapsed_days, 0.0) > 0.0 THEN
            v_players_processed := v_players_processed + 1;
        END IF;
    END LOOP;

    v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);

    IF date_trunc('day', r_season.current_game_time)::DATE <>
       date_trunc('day', v_game_time_after)::DATE THEN
        PERFORM record_rank_snapshot(date_trunc('day', v_game_time_after)::DATE);
        PERFORM execute_bot_decisions();
    END IF;

    UPDATE season_clock SET
        current_game_time = v_game_time_after,
        last_tick_at = NOW(),
        updated_at = NOW()
    WHERE id = r_season.id;

    INSERT INTO world_tick_log (
        season_id, started_at, finished_at,
        game_time_before, game_time_after,
        ticks_processed, players_processed, bots_processed,
        status,
        real_seconds_processed, game_seconds_processed, message
    ) VALUES (
        r_season.id, v_start_time, NOW(),
        r_season.current_game_time, v_game_time_after,
        1, v_players_processed, v_bots_processed,
        'success',
        EXTRACT(EPOCH FROM (NOW() - v_start_time)),
        EXTRACT(EPOCH FROM (v_game_time_after - r_season.current_game_time)),
        'Tick completed successfully'
    );

    PERFORM pg_advisory_unlock(v_lock_key);

    season_id := r_season.id;
    ticks_processed := 1;
    game_time_after := v_game_time_after;
    players_processed := v_players_processed;
    bots_processed := v_bots_processed;
    RETURN NEXT;
END;
$function$;

-- ── Fix 4: Fix AI bots with NULL hq_airport_iata ──────────────────────────
-- Bots with NULL hq_airport_iata can't create routes because
-- `WHERE iata != NULL` always evaluates to NULL/false.
-- Set a default hub so route creation works.

UPDATE users SET hq_airport_iata = 'CGK'
WHERE actor_type = 'AI' AND hq_airport_iata IS NULL;

COMMIT;

-- ── Verification ───────────────────────────────────────────────────────────

-- Verify aircraft nicknames (should be 0)
SELECT 'null_nicknames' AS check_name, COUNT(*) AS count
FROM fleet_aircraft WHERE nickname IS NULL;

-- Verify credit_score_at_origination (should be 0)
SELECT 'null_credit_score_at_origination' AS check_name, COUNT(*) AS count
FROM loans WHERE credit_score_at_origination IS NULL;

-- Verify AI bot hq_airport_iata (should be 0)
SELECT 'null_hq_airport_iata' AS check_name, COUNT(*) AS count
FROM users WHERE actor_type = 'AI' AND hq_airport_iata IS NULL;

-- Verify bank_transactions has entries
SELECT 'bank_txn_count' AS check_name, COUNT(*) AS count
FROM bank_transactions;

-- Verify collateral distribution (informational)
SELECT loan_type, COUNT(*), COUNT(collateral_aircraft_id) AS with_collateral
FROM loans GROUP BY loan_type;
