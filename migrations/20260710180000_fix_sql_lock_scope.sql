-- ============================================================================
-- Migration: Fix SQL lock scope
-- Fixes:
--   1. repay_loan(): Remove unnecessary FOR UPDATE on users SELECT
--   2. terminate_actor_lease(): Remove unnecessary FOR UPDATE on users SELECT
-- ============================================================================

BEGIN;

-- ============================================================================
-- FIX 1: repay_loan — drop FOR UPDATE from game_current_time read
-- ============================================================================
DO $fix_repay_loan_lock$
DECLARE v_function_def TEXT;
BEGIN
    SELECT pg_get_functiondef('public.repay_loan(uuid, numeric)'::regprocedure)
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for repay_loan(uuid, numeric)';
    END IF;

    IF position($snip$  SELECT game_current_time INTO v_game_time
  FROM users
  WHERE id = v_user_id
  FOR UPDATE;$snip$ IN v_function_def) = 0 THEN
        RAISE NOTICE 'repay_loan FOR UPDATE already removed or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(
        v_function_def,
        $old$  SELECT game_current_time INTO v_game_time
  FROM users
  WHERE id = v_user_id
  FOR UPDATE;$old$,
        $new$  SELECT game_current_time INTO v_game_time
  FROM users
  WHERE id = v_user_id;$new$
    );
    EXECUTE v_function_def;
END;
$fix_repay_loan_lock$;

-- ============================================================================
-- FIX 2: terminate_actor_lease — drop FOR UPDATE from users SELECT
-- ============================================================================
DO $fix_terminate_actor_lease_lock$
DECLARE v_function_def TEXT;
BEGIN
    SELECT pg_get_functiondef('public.terminate_actor_lease(uuid, uuid, timestamptz)'::regprocedure)
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for terminate_actor_lease(uuid, uuid, timestamptz)';
    END IF;

    IF position($snip$PERFORM 1 FROM users WHERE id = p_user_id FOR UPDATE;$snip$ IN v_function_def) = 0 THEN
        RAISE NOTICE 'terminate_actor_lease FOR UPDATE already removed or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(
        v_function_def,
        $old$PERFORM 1 FROM users WHERE id = p_user_id FOR UPDATE;$old$,
        $new$PERFORM 1 FROM users WHERE id = p_user_id;$new$
    );
    EXECUTE v_function_def;
END;
$fix_terminate_actor_lease_lock$;

COMMIT;
