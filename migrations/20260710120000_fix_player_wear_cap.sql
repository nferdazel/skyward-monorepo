BEGIN;

-- ============================================================================
-- FIX: Player wear formula — use capped v_time_fraction (parity with bots)
-- ============================================================================
-- Player simulation computed gross_damage with uncapped elapsed_days / 7.0
-- while bots used LEAST(game_days / 7.0, 1.0).  When elapsed_days > 7 the
-- player received disproportionate wear compared to bots for the same
-- catch-up period.  The player function already computes v_time_fraction
-- (capped at 1.0) for revenue/costs — wear should use it too.

DO $fix_player_wear_cap$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week * v_elapsed_days / 7.0;
$old$;
    v_new_snippet TEXT := $new$
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week * v_time_fraction;
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
        RAISE NOTICE 'player_wear_cap already migrated or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_player_wear_cap$;

COMMIT;
