BEGIN;

-- ============================================================================
-- Migration: Consolidate process_all_bots_simulation_to_time()
-- ============================================================================
-- Replaces the baseline function + DO-block patches from:
--   • 34_tick_configurability_and_fixes.sql   (elapsed_days → process_actor_day_boundary)
--   • 20260710150000_fix_ifrs_subcategories.sql
--       – cargo revenue percentage from game_config
--       – IFRS subcategories use _cost suffix (fuel_cost, crew_cost, maintenance_cost)
--       – cargo revenue split into separate credit transaction
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_all_bots_simulation_to_time(
    p_target_game_time timestamp with time zone,
    p_season_id uuid DEFAULT NULL::uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    r_bot                           RECORD;
    v_route                         RECORD;
    v_flights                       DOUBLE PRECISION;
    v_revenue                       NUMERIC(20,2) := 0;
    v_fuel_cost                     NUMERIC(20,2) := 0;
    v_maint_cost                    NUMERIC(20,2) := 0;
    v_crew_cost                     NUMERIC(20,2) := 0;
    v_passengers                    INT;
    v_flight_duration               DOUBLE PRECISION;
    v_turnaround_hours              NUMERIC;
    v_lease_cost                    NUMERIC(20,2) := 0;
    v_idle_lease_cost               NUMERIC(20,2) := 0;
    v_fuel_price                    NUMERIC;
    v_fuel_price_multiplier         NUMERIC;
    v_crew_cost_per_hour            NUMERIC;
    v_absolute_minimum_safety_limit NUMERIC(5,2);
    v_effective_grounding_threshold NUMERIC(5,2);
    v_max_weekly_flights            INT;
    v_wear_per_cycle                NUMERIC(8,4);
    v_gross_damage                  NUMERIC(20,4);
    v_self_healing_credit           NUMERIC(20,4);
    v_net_damage                    NUMERIC(20,4);
    v_cargo_rev                     NUMERIC(20,2);
    v_processed                     INT := 0;
    v_demand_multiplier             NUMERIC;
    v_airport_demand                NUMERIC;
    v_seasonal_multiplier           NUMERIC;
    v_owned_wear                    NUMERIC;
    v_leased_wear                   NUMERIC;
    v_auto_repair_rate              NUMERIC;
    v_maintenance_multiplier        NUMERIC;
    v_route_demand_event            NUMERIC;
    v_route_capacity_event          NUMERIC;
    v_effective_capacity            NUMERIC;
    v_game_days                     DOUBLE PRECISION;
    v_time_fraction                 NUMERIC;
    v_effective_season_id           UUID;
BEGIN
    v_fuel_price := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_absolute_minimum_safety_limit := COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00);
    v_crew_cost_per_hour := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
    v_effective_season_id := resolve_active_season_id(p_season_id);

    SELECT COALESCE(effect_value, 1.0) INTO v_fuel_price_multiplier
    FROM game_events
    WHERE event_type = 'fuel_shock' AND is_active = true
      AND effect_type = 'fuel_price'
      AND start_game_time <= p_target_game_time
      AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC
    LIMIT 1;
    IF NOT FOUND THEN
        v_fuel_price_multiplier := 1.0;
    END IF;

    SELECT COALESCE(effect_value, 1.0) INTO v_maintenance_multiplier
    FROM game_events
    WHERE event_type = 'maintenance_shock' AND is_active = true
      AND effect_type = 'maintenance_cost'
      AND start_game_time <= p_target_game_time
      AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC
    LIMIT 1;
    IF NOT FOUND THEN
        v_maintenance_multiplier := 1.0;
    END IF;

    v_seasonal_multiplier := 1.0;

    FOR r_bot IN
        SELECT *
        FROM users
        WHERE actor_type = 'AI'
          AND COALESCE(operational_status, 'Active') != 'Bankrupt'
          AND (v_effective_season_id IS NULL OR season_id = v_effective_season_id)
    LOOP
        v_effective_grounding_threshold := GREATEST(
            COALESCE(r_bot.auto_grounding_threshold, 40.00),
            v_absolute_minimum_safety_limit
        );

        v_game_days := EXTRACT(EPOCH FROM (p_target_game_time - r_bot.game_current_time)) / 86400.0;
        v_time_fraction := LEAST(v_game_days / 7.0, 1.0);
        IF v_game_days <= 0 THEN
            CONTINUE;
        END IF;

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
            WHERE ra.user_id = r_bot.id
              AND ra.status = 'active'
              AND fa.status = 'active'
              AND fa.condition >= v_effective_grounding_threshold
        LOOP
            v_route_demand_event := 1.0;
            SELECT COALESCE(effect_value, 1.0) INTO v_route_demand_event
            FROM game_events
            WHERE event_type = 'demand_surge' AND is_active = true
              AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
              AND start_game_time <= p_target_game_time
              AND end_game_time > p_target_game_time
            ORDER BY start_game_time DESC
            LIMIT 1;
            IF NOT FOUND THEN
                v_route_demand_event := 1.0;
            END IF;

            v_route_capacity_event := 1.0;
            SELECT COALESCE(effect_value, 1.0) INTO v_route_capacity_event
            FROM game_events
            WHERE event_type = 'weather_disruption' AND is_active = true
              AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
              AND start_game_time <= p_target_game_time
              AND end_game_time > p_target_game_time
            ORDER BY start_game_time DESC
            LIMIT 1;
            IF NOT FOUND THEN
                v_route_capacity_event := 1.0;
            END IF;

            v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
            v_flight_duration := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0))
                               + v_turnaround_hours;
            IF v_flight_duration <= 0 THEN
                CONTINUE;
            END IF;

            v_max_weekly_flights := FLOOR(168.0 / v_flight_duration)::INT;
            v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);
            v_airport_demand := calculate_airport_demand_factor(
                v_route.origin_demand,
                v_route.dest_demand
            );
            v_demand_multiplier := calculate_route_demand_multiplier(
                v_route.distance_km,
                v_route.ticket_price
            ) * v_route_demand_event;
            v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);
            v_passengers := LEAST(
                v_effective_capacity,
                FLOOR(
                    v_effective_capacity * 0.95
                    * v_airport_demand
                    * v_demand_multiplier
                    * v_seasonal_multiplier
                )
            );

            v_revenue := v_flights * v_route.ticket_price * v_passengers * v_time_fraction;
            v_fuel_cost := v_flights * v_route.distance_km
                         * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier
                         * v_time_fraction;
            v_crew_cost := v_flights * v_flight_duration * v_crew_cost_per_hour * v_time_fraction;
            v_maint_cost := v_flights * v_route.distance_km
                          * v_route.maintenance_cost_per_hour
                          * COALESCE(v_maintenance_multiplier, 1.0)
                          / NULLIF(v_route.speed_kmh, 0)
                          * v_time_fraction;
            v_cargo_rev := v_revenue * COALESCE(get_config_numeric('cargo_revenue_percentage'), 0.05);
            v_lease_cost := CASE
                WHEN EXISTS (
                    SELECT 1
                    FROM fleet_aircraft fa2
                    WHERE fa2.id = v_route.assigned_aircraft_id
                      AND fa2.acquisition_type = 'lease'
                ) THEN COALESCE(v_route.lease_price_per_month, 0) * (v_game_days / 30.0)
                ELSE 0
            END;

            PERFORM credit_bank_account(
                r_bot.id,
                v_revenue,
                'revenue',
                'ticket_revenue',
                'Bot route ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM credit_bank_account(
                r_bot.id,
                v_cargo_rev,
                'revenue',
                'cargo_revenue',
                'Bot cargo: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_fuel_cost,
                'cogs',
                'fuel_cost',
                'Bot fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_crew_cost,
                'cogs',
                'crew_cost',
                'Bot crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_maint_cost,
                'cogs',
                'maintenance_cost',
                'Bot maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            IF v_lease_cost > 0 THEN
                PERFORM debit_bank_account(
                    r_bot.id,
                    v_lease_cost,
                    'opex',
                    'aircraft_lease',
                    'Bot lease: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                    p_target_game_time
                );
            END IF;

            v_wear_per_cycle := CASE
                WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
                ELSE v_owned_wear
            END + (v_route.distance_km * 0.0001);
            v_gross_damage := v_wear_per_cycle * v_flights * v_time_fraction;
            v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
            v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

            UPDATE fleet_aircraft
            SET condition = GREATEST(0, condition - v_net_damage)
            WHERE id = v_route.assigned_aircraft_id;
        END LOOP;

        SELECT COALESCE(SUM(am.lease_price_per_month * (v_game_days / 30.0)), 0)
        INTO v_idle_lease_cost
        FROM fleet_aircraft fa
        JOIN aircraft_models am ON am.id = fa.aircraft_model_id
        WHERE fa.user_id = r_bot.id
          AND fa.acquisition_type = 'lease'
          AND NOT EXISTS (
              SELECT 1
              FROM route_assignments ra
              WHERE ra.assigned_aircraft_id = fa.id
                AND ra.status = 'active'
          );

        IF v_idle_lease_cost > 0 THEN
            PERFORM debit_bank_account(
                r_bot.id,
                v_idle_lease_cost,
                'opex',
                'aircraft_lease_idle',
                'Bot idle lease carrying cost',
                p_target_game_time
            );
        END IF;

        IF date_trunc('day', r_bot.game_current_time)::DATE <>
           date_trunc('day', p_target_game_time)::DATE THEN
            PERFORM process_actor_day_boundary(r_bot.id, p_target_game_time);
            PERFORM check_achievements(r_bot.id, p_target_game_time);
        END IF;

        UPDATE users
        SET game_current_time = p_target_game_time,
            last_active_at = NOW()
        WHERE id = r_bot.id;

        v_processed := v_processed + 1;
    END LOOP;

    RETURN v_processed;
END;
$function$;

COMMIT;
