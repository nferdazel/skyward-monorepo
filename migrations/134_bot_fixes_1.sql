-- ============================================================================
-- Migration 134: Bot Fixes (Part 1)
-- ============================================================================
-- Fix 1: Restore max_bot_count to game_config (deleted in m130)
-- Fix 2: Verify execute_bot_decisions uses config (already fixed in m130)
-- Fix 3: Add check_achievements to bot simulation day boundary
-- ============================================================================

BEGIN;


-- ============================================================================
-- Fix 1: Restore max_bot_count to game_config
-- ============================================================================

INSERT INTO game_config (key, value, category, description)
VALUES ('max_bot_count', '5', 'simulation', 'Maximum AI competitors')
ON CONFLICT (key) DO NOTHING;


-- ============================================================================
-- Fix 2: execute_bot_decisions already uses config (verified in m130)
-- ============================================================================
-- The current execute_bot_decisions function (from m130) already uses:
--   v_ticket_base_fare  := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
--   v_ticket_per_km_rate := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);
--   v_starting_cash      := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
--   v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);
-- No rewrite needed. Hardcoded values are only used as COALESCE fallbacks.


-- ============================================================================
-- Fix 3: Add check_achievements to process_all_bots_simulation_to_time
-- ============================================================================
-- At the day boundary (when bot's game time day differs from target time day),
-- call check_achievements so bots can earn achievement milestones.

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

            -- Wear formula: use acquisition-type-specific base wear from config
            v_wear_per_cycle := CASE
                WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
                ELSE v_owned_wear
            END + (v_route.distance_km * 0.0001);
            v_gross_damage := v_wear_per_cycle * v_flights * v_game_days / 7.0;
            v_self_healing_credit := v_gross_damage * (1.0 - v_auto_repair_rate);
            v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

            UPDATE fleet_aircraft
            SET condition = GREATEST(0, condition - v_net_damage),
                total_flights = total_flights + (v_flights * v_game_days / 7.0)::INT
            WHERE id = v_route.assigned_aircraft_id;
        END LOOP;

        -- Fix 3: Check achievements at day boundary
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


COMMIT;


-- ============================================================================
-- Verification queries
-- ============================================================================

-- Fix 1: max_bot_count should exist in game_config
-- SELECT key, value, category, description FROM game_config WHERE key = 'max_bot_count';

-- Fix 2: execute_bot_decisions should use config (no hardcoded 15000000/50.00/0.12)
-- SELECT prosrc FROM pg_proc WHERE proname = 'execute_bot_decisions' AND prosrc LIKE '%15000000%';
-- SELECT prosrc FROM pg_proc WHERE proname = 'execute_bot_decisions' AND prosrc LIKE '%= 50.00%';
-- SELECT prosrc FROM pg_proc WHERE proname = 'execute_bot_decisions' AND prosrc LIKE '%= 0.12%';
-- All three should return 0 rows.

-- Fix 3: process_all_bots_simulation_to_time should call check_achievements
-- SELECT prosrc FROM pg_proc WHERE proname = 'process_all_bots_simulation_to_time' AND prosrc LIKE '%check_achievements%';
-- Should return 1 row.

-- Full integration test:
-- SELECT ensure_world_current();
