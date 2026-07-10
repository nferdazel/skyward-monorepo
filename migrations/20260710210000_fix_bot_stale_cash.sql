-- ============================================================================
-- Migration: Fix stale cash value in execute_bot_decisions()
-- Goal:
--   v_bot_cash is read once at the top of the per-bot loop (line 744) and
--   never refreshed after sub-functions that mutate the balance.
--   bot_handle_repair spends cash on repairs, bot_handle_fleet_growth may
--   lease/purchase aircraft, and bot_handle_route_creation may assign
--   aircraft to routes (which can incur costs).  Downstream functions like
--   bot_handle_financial still see the pre-mutation cash value.
--
--   Fix: re-read v_bot_cash via get_user_balance() after each mutating
--   sub-function call.
-- ============================================================================

BEGIN;

-- ============================================================================
-- FIX 1: Refresh v_bot_cash after bot_handle_repair
-- ============================================================================
DO $fix1$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
        PERFORM bot_handle_repair(r_bot.id, r_bot.game_current_time, v_distress, v_effective_threshold, v_bot_repair_cash_reserve);

        -- Route lifecycle (audit + trim + optimization)
$old$;
    v_new_snippet TEXT := $new$
        PERFORM bot_handle_repair(r_bot.id, r_bot.game_current_time, v_distress, v_effective_threshold, v_bot_repair_cash_reserve);
        v_bot_cash := get_user_balance(r_bot.id);

        -- Route lifecycle (audit + trim + optimization)
$new$;
BEGIN
    SELECT pg_get_functiondef('public.execute_bot_decisions()'::regprocedure)
      INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for execute_bot_decisions()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'execute_bot_decisions stale-cash fix1 already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix1$;

-- ============================================================================
-- FIX 2: Refresh v_bot_cash after bot_handle_fleet_growth
-- ============================================================================
DO $fix2$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
        PERFORM bot_handle_fleet_growth(r_bot.id, r_bot.game_current_time, r_bot.archetype, v_distress,
            v_bot_cash, v_starting_cash, v_target_fleet_cap, v_min_cash_reserve, v_growth_chance,
            v_target_distance, v_purchase_cash_multiplier, v_fleet_diversity_chance);

        -- Route creation (kept inline due to secondary hub complexity)
$old$;
    v_new_snippet TEXT := $new$
        PERFORM bot_handle_fleet_growth(r_bot.id, r_bot.game_current_time, r_bot.archetype, v_distress,
            v_bot_cash, v_starting_cash, v_target_fleet_cap, v_min_cash_reserve, v_growth_chance,
            v_target_distance, v_purchase_cash_multiplier, v_fleet_diversity_chance);
        v_bot_cash := get_user_balance(r_bot.id);

        -- Route creation (kept inline due to secondary hub complexity)
$new$;
BEGIN
    SELECT pg_get_functiondef('public.execute_bot_decisions()'::regprocedure)
      INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for execute_bot_decisions()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'execute_bot_decisions stale-cash fix2 already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix2$;

-- ============================================================================
-- FIX 3: Refresh v_bot_cash after bot_handle_route_creation
-- ============================================================================
DO $fix3$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
        PERFORM bot_handle_route_creation(r_bot.id, r_bot.game_current_time, r_bot.archetype, v_distress,
            r_bot.hq_airport_iata, v_target_fleet_cap, v_target_price_mult, v_target_sched_ratio,
            v_target_distance, v_effective_threshold, v_secondary_hub_chance);

        -- Pricing review
$old$;
    v_new_snippet TEXT := $new$
        PERFORM bot_handle_route_creation(r_bot.id, r_bot.game_current_time, r_bot.archetype, v_distress,
            r_bot.hq_airport_iata, v_target_fleet_cap, v_target_price_mult, v_target_sched_ratio,
            v_target_distance, v_effective_threshold, v_secondary_hub_chance);
        v_bot_cash := get_user_balance(r_bot.id);

        -- Pricing review
$new$;
BEGIN
    SELECT pg_get_functiondef('public.execute_bot_decisions()'::regprocedure)
      INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for execute_bot_decisions()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'execute_bot_decisions stale-cash fix3 already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix3$;

COMMIT;
