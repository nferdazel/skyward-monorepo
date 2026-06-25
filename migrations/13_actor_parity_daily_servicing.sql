-- ============================================================================
-- Migration 13: Actor parity — daily finance and credit servicing
-- Goal:
--   run daily debt servicing, credit updates, and negative-cash accumulation
--   through the same day-boundary contract for players and bots.
-- ============================================================================

-- ============================================================================
-- FIX 1: shared day-boundary helper for all actors
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_actor_day_boundary(
    p_user_id uuid,
    p_game_date timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_cash_after NUMERIC;
BEGIN
    PERFORM process_loan_payments(p_user_id, p_game_date);
    PERFORM process_aircraft_financing_payments(p_user_id, p_game_date);
    PERFORM process_credit_at_day_boundary(p_user_id, p_game_date);

    v_cash_after := get_user_balance(p_user_id);

    IF v_cash_after < 0 THEN
        UPDATE users
        SET consecutive_negative_days = consecutive_negative_days + 1,
            recovery_streak_days = 0
        WHERE id = p_user_id;

        IF (SELECT consecutive_negative_days FROM users WHERE id = p_user_id) >= 30 THEN
            UPDATE users
            SET operational_status = 'Bankrupt'
            WHERE id = p_user_id;

            UPDATE fleet_aircraft
            SET status = 'grounded'
            WHERE user_id = p_user_id;
        END IF;
    ELSE
        UPDATE users
        SET consecutive_negative_days = 0,
            recovery_streak_days = recovery_streak_days + 1
        WHERE id = p_user_id;
    END IF;
END;
$function$;

-- ============================================================================
-- FIX 2: player simulation — use shared day-boundary helper
-- ============================================================================
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    r_user                RECORD;
    v_route               RECORD;
    v_flight_hours        NUMERIC;
    v_revenue             NUMERIC;
    v_ops_cost            NUMERIC;
    v_lease_cost          NUMERIC;
    v_idle_lease_cost     NUMERIC := 0;
    v_cash_after          NUMERIC;
    v_elapsed_days        NUMERIC;
    v_wear_per_cycle      NUMERIC(8,4);
    v_gross_damage        NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage          NUMERIC(20,4);
    v_cargo_rev           NUMERIC(20,2);
    v_turnaround_hours    NUMERIC;
    v_demand_multiplier   NUMERIC;
    v_crew_cost           NUMERIC;
    v_fuel_price          NUMERIC;
    v_seasonal_factor     NUMERIC;
    v_fuel_price_multiplier   NUMERIC := 1.0;
    v_maintenance_multiplier  NUMERIC := 1.0;
    v_route_demand_event      NUMERIC;
    v_route_capacity_event    NUMERIC;
    v_effective_capacity      NUMERIC;
    v_time_fraction           NUMERIC;
    v_fuel_cost               NUMERIC;
    v_crew_cost_total         NUMERIC;
    v_maint_cost              NUMERIC;
    v_owned_wear              NUMERIC;
    v_leased_wear             NUMERIC;
    v_auto_repair_rate        NUMERIC;
    v_bankruptcy_threshold    NUMERIC;
    v_airport_demand          NUMERIC;
    v_flights_run             INT := 0;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

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
        WHERE ur.user_id = p_user_id
          AND ur.status = 'active'
          AND fa.status = 'active'
          AND fa.condition >= COALESCE(r_user.auto_grounding_threshold, 40.00)
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
        v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
        IF v_flight_hours <= 0 THEN
            CONTINUE;
        END IF;

        v_airport_demand := calculate_airport_demand_factor(
            v_route.origin_demand,
            v_route.dest_demand
        );
        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price)
                             * v_route_demand_event;
        v_seasonal_factor := 1.0;
        v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);

        v_revenue := v_route.flights_per_week * v_route.ticket_price
                   * LEAST(
                        v_effective_capacity,
                        FLOOR(
                            v_effective_capacity * 0.95
                            * v_airport_demand
                            * v_demand_multiplier
                            * v_seasonal_factor
                        )
                     );

        v_fuel_cost := v_route.flights_per_week * v_route.distance_km
                     * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
        v_crew_cost_total := v_route.flights_per_week * v_flight_hours * v_crew_cost;
        v_maint_cost := v_route.flights_per_week * v_route.distance_km
                      * COALESCE(v_route.maintenance_cost_per_hour, 0)
                      * COALESCE(v_maintenance_multiplier, 1.0)
                      / NULLIF(v_route.speed_kmh, 0);
        v_ops_cost := v_fuel_cost + v_crew_cost_total + v_maint_cost;
        v_lease_cost := CASE
            WHEN EXISTS (
                SELECT 1
                FROM fleet_aircraft fa2
                WHERE fa2.id = v_route.assigned_aircraft_id
                  AND fa2.acquisition_type = 'lease'
            ) THEN COALESCE(v_route.lease_price_per_month, 0) * (v_elapsed_days / 30.0)
            ELSE 0
        END;

        v_revenue := v_revenue * v_time_fraction;
        v_ops_cost := v_ops_cost * v_time_fraction;
        v_cargo_rev := v_revenue * 0.05;

        PERFORM credit_bank_account(
            p_user_id,
            v_revenue + v_cargo_rev,
            'revenue',
            'ticket_revenue',
            'Route ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time
        );
        PERFORM debit_bank_account(
            p_user_id,
            v_fuel_cost * v_time_fraction,
            'cogs',
            'fuel',
            'Fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time
        );
        PERFORM debit_bank_account(
            p_user_id,
            v_crew_cost_total * v_time_fraction,
            'cogs',
            'crew',
            'Crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time
        );
        PERFORM debit_bank_account(
            p_user_id,
            v_maint_cost * v_time_fraction,
            'cogs',
            'maintenance',
            'Maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time
        );
        IF v_lease_cost > 0 THEN
            PERFORM debit_bank_account(
                p_user_id,
                v_lease_cost,
                'opex',
                'aircraft_lease',
                'Lease: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
        END IF;

        v_wear_per_cycle := CASE
            WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
            ELSE v_owned_wear
        END + (v_route.distance_km * 0.0001);
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week * v_elapsed_days / 7.0;
        v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
        v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

        UPDATE fleet_aircraft
        SET condition = GREATEST(0, condition - v_net_damage)
        WHERE id = v_route.assigned_aircraft_id;

        v_flights_run := v_flights_run + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
    END LOOP;

    SELECT COALESCE(SUM(am.lease_price_per_month * (v_elapsed_days / 30.0)), 0)
    INTO v_idle_lease_cost
    FROM fleet_aircraft fa
    JOIN aircraft_models am ON am.id = fa.aircraft_model_id
    WHERE fa.user_id = p_user_id
      AND fa.acquisition_type = 'lease'
      AND NOT EXISTS (
          SELECT 1
          FROM route_assignments ra
          WHERE ra.assigned_aircraft_id = fa.id
            AND ra.status = 'active'
      );

    IF v_idle_lease_cost > 0 THEN
        PERFORM debit_bank_account(
            p_user_id,
            v_idle_lease_cost,
            'opex',
            'aircraft_lease_idle',
            'Idle lease carrying cost',
            p_target_game_time
        );
    END IF;

    v_cash_after := get_user_balance(p_user_id);

    UPDATE users u
    SET game_current_time = p_target_game_time,
        last_active_at = NOW()
    WHERE u.id = p_user_id;

    IF v_cash_after <= v_bankruptcy_threshold THEN
        UPDATE users
        SET operational_status = 'Bankrupt'
        WHERE id = p_user_id;

        UPDATE route_assignments
        SET status = 'cancelled'
        WHERE user_id = p_user_id
          AND status = 'active';
    END IF;

    IF date_trunc('day', r_user.game_current_time)::DATE <>
       date_trunc('day', p_target_game_time)::DATE THEN
        PERFORM process_actor_day_boundary(p_user_id, p_target_game_time);
        PERFORM check_achievements(p_user_id, p_target_game_time);
    END IF;

    game_time := p_target_game_time;
    cash := get_user_balance(p_user_id);
    flights_run := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$function$;

-- ============================================================================
-- FIX 3: bot simulation — use the same day-boundary contract as players
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
            v_cargo_rev := v_revenue * 0.05;
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
                v_revenue + v_cargo_rev,
                'revenue',
                'ticket_revenue',
                'Bot route ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_fuel_cost,
                'cogs',
                'fuel',
                'Bot fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_crew_cost,
                'cogs',
                'crew',
                'Bot crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_maint_cost,
                'cogs',
                'maintenance',
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
