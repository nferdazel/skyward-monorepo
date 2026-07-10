BEGIN;

-- ============================================================================
-- FIX 1a: Player simulation — declare flight-cap variables (parity with bots)
-- ============================================================================
-- The bot simulation caps flights per week at FLOOR(168 / flight_duration).
-- The player function used raw flights_per_week, allowing over-assignment.
-- ============================================================================

DO $fix_declare_flight_cap_vars$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
    v_total_maint_cost        NUMERIC;
BEGIN
$old$;
    v_new_snippet TEXT := $new$
    v_total_maint_cost        NUMERIC;
    v_max_weekly_flights      INT;
    v_flights                 INT;
BEGIN
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_player_simulation_to_time(uuid, timestamptz)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_player_simulation_to_time()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'flight_cap variables already declared or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_declare_flight_cap_vars$;

-- ============================================================================
-- FIX 1b: Player simulation — cap flights per week at physical maximum
-- ============================================================================
-- Mirror bot logic: v_max_weekly_flights := FLOOR(168.0 / v_flight_duration)
-- Then use LEAST(flights_per_week, v_max_weekly_flights) for all revenue,
-- cost, wear, and flights_run calculations.
-- ============================================================================

DO $fix_flight_cap$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
        IF v_flight_hours <= 0 THEN
            CONTINUE;
        END IF;

        v_airport_demand
$old$;
    v_new_snippet TEXT := $new$
        IF v_flight_hours <= 0 THEN
            CONTINUE;
        END IF;

        v_max_weekly_flights := FLOOR(168.0 / v_flight_hours)::INT;
        v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);

        v_airport_demand
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_player_simulation_to_time(uuid, timestamptz)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_player_simulation_to_time()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'flight_cap logic already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_flight_cap$;

-- ============================================================================
-- FIX 1c: Player simulation — use capped flights in revenue/cost block
-- ============================================================================

DO $fix_flight_cap_revenue$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
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
$old$;
    v_new_snippet TEXT := $new$
        v_revenue := v_flights * v_route.ticket_price
                   * LEAST(
                        v_effective_capacity,
                        FLOOR(
                            v_effective_capacity * 0.95
                            * v_airport_demand
                            * v_demand_multiplier
                            * v_seasonal_factor
                        )
                     );

        v_fuel_cost := v_flights * v_route.distance_km
                     * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
        v_crew_cost_total := v_flights * v_flight_hours * v_crew_cost;
        v_maint_cost := v_flights * v_route.distance_km
                      * COALESCE(v_route.maintenance_cost_per_hour, 0)
                      * COALESCE(v_maintenance_multiplier, 1.0)
                      / NULLIF(v_route.speed_kmh, 0);
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_player_simulation_to_time(uuid, timestamptz)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_player_simulation_to_time()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'flight_cap revenue/cost already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_flight_cap_revenue$;

-- ============================================================================
-- FIX 1d: Player simulation — use capped flights in wear formula
-- ============================================================================

DO $fix_flight_cap_wear$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week * v_time_fraction;
$old$;
    v_new_snippet TEXT := $new$
        v_gross_damage := v_wear_per_cycle * v_flights * v_time_fraction;
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_player_simulation_to_time(uuid, timestamptz)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_player_simulation_to_time()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'flight_cap wear already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_flight_cap_wear$;

-- ============================================================================
-- FIX 1e: Player simulation — use capped flights in flights_run tally
-- ============================================================================

DO $fix_flight_cap_flights_run$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
        v_flights_run := v_flights_run + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
$old$;
    v_new_snippet TEXT := $new$
        v_flights_run := v_flights_run + (v_flights * v_elapsed_days / 7.0)::INT;
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_player_simulation_to_time(uuid, timestamptz)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_player_simulation_to_time()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'flight_cap flights_run already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_flight_cap_flights_run$;

-- ============================================================================
-- FIX 2: Player simulation — respect absolute_minimum_safety_limit
-- ============================================================================
-- The bot simulation uses GREATEST(auto_grounding_threshold,
-- absolute_minimum_safety_limit) but the player function used raw
-- COALESCE(auto_grounding_threshold, 40.00).  Players could set their
-- threshold to 10 and fly aircraft at condition 10.
-- ============================================================================

DO $fix_grounding_floor$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
          AND fa.condition >= COALESCE(r_user.auto_grounding_threshold, 40.00)
$old$;
    v_new_snippet TEXT := $new$
          AND fa.condition >= GREATEST(COALESCE(r_user.auto_grounding_threshold, 40.00), COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00))
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_player_simulation_to_time(uuid, timestamptz)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_player_simulation_to_time()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'absolute_minimum_safety_limit already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_grounding_floor$;

COMMIT;
