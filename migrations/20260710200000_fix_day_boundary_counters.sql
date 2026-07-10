-- ============================================================================
-- Migration: Fix day boundary counter undercounting
-- Fixes:
--   1. consecutive_negative_days increments by 1 instead of p_elapsed_days
--   2. recovery_streak_days increments by 1 instead of p_elapsed_days
-- When a player is offline for N days, the counters should advance by N,
-- not 1 — otherwise the bankruptcy threshold (default 30) is nearly
-- unreachable during catch-up.
-- ============================================================================

BEGIN;

-- ============================================================================
-- FIX 1: consecutive_negative_days should scale with p_elapsed_days
-- ============================================================================
DO $fix_negative_days$
DECLARE v_function_def TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_actor_day_boundary(uuid, timestamptz)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_actor_day_boundary(uuid, timestamptz, numeric)';
    END IF;

    IF position($snip$        SET consecutive_negative_days = consecutive_negative_days + 1,$snip$ IN v_function_def) = 0 THEN
        RAISE NOTICE 'process_actor_day_boundary negative_days already patched or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(
        v_function_def,
        $old$        SET consecutive_negative_days = consecutive_negative_days + 1,$old$,
        $new$        SET consecutive_negative_days = consecutive_negative_days + GREATEST(1, CEIL(p_elapsed_days))::INTEGER,$new$
    );
    EXECUTE v_function_def;
END;
$fix_negative_days$;

-- ============================================================================
-- FIX 2: recovery_streak_days should scale with p_elapsed_days
-- ============================================================================
DO $fix_recovery_streak$
DECLARE v_function_def TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_actor_day_boundary(uuid, timestamptz)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_actor_day_boundary(uuid, timestamptz, numeric)';
    END IF;

    IF position($snip$            recovery_streak_days = recovery_streak_days + 1$snip$ IN v_function_def) = 0 THEN
        RAISE NOTICE 'process_actor_day_boundary recovery_streak already patched or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(
        v_function_def,
        $old$            recovery_streak_days = recovery_streak_days + 1$old$,
        $new$            recovery_streak_days = recovery_streak_days + GREATEST(1, CEIL(p_elapsed_days))::INTEGER$new$
    );
    EXECUTE v_function_def;
END;
$fix_recovery_streak$;

COMMIT;
