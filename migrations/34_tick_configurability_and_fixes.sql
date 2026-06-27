-- ============================================================================
-- Migration 34: Tick configurability and backend fixes
-- Fixes:
--   1. Tick interval and max catchup ticks configurable via game_config
--   2. Day boundary payment loop for multi-week catch-ups
--   3. Human finance_aircraft gets reasonable default seats
-- ============================================================================

BEGIN;

-- ============================================================================
-- FIX 1: Config entries for tick behaviour
-- ============================================================================
INSERT INTO game_config (key, value, category, unit, description) VALUES
  ('tick_interval_seconds', '60'::jsonb, 'simulation', 'seconds',
   'Interval between world ticks in real seconds'),
  ('max_catchup_ticks', '100'::jsonb, 'simulation', 'ticks',
   'Maximum ticks processed per ensure_world_current call')
ON CONFLICT (key) DO NOTHING;

-- ============================================================================
-- FIX 1: Update ensure_world_current to read max_catchup_ticks from config
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ensure_world_current(p_season_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(
    season_id        uuid,
    ticks_processed  integer,
    game_time_after  timestamp with time zone,
    players_processed integer,
    bots_processed   integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_season_id UUID;
    v_ticks INT := 0;
    v_max_catchup_ticks INT;
    r_result RECORD;
    v_current_game_time TIMESTAMPTZ;
BEGIN
    v_max_catchup_ticks := COALESCE(get_config_numeric('max_catchup_ticks')::INT, 100);

    IF p_season_id IS NOT NULL THEN
        v_season_id := p_season_id;
    ELSE
        SELECT id INTO v_season_id
        FROM season_clock
        WHERE status = 'active'
        ORDER BY created_at ASC
        LIMIT 1;
    END IF;

    IF v_season_id IS NULL THEN RETURN; END IF;

    LOOP
        SELECT * INTO r_result
        FROM process_world_tick(v_season_id, 1)
        LIMIT 1;

        v_ticks := v_ticks + 1;
        IF v_ticks >= v_max_catchup_ticks THEN EXIT; END IF;

        SELECT current_game_time
        INTO v_current_game_time
        FROM season_clock
        WHERE id = v_season_id;

        EXIT WHEN v_current_game_time >= now();
    END LOOP;

    IF r_result IS NOT NULL THEN
        season_id       := r_result.season_id;
        ticks_processed := r_result.ticks_processed;
        game_time_after := r_result.game_time_after;
        players_processed := r_result.players_processed;
        bots_processed  := r_result.bots_processed;
        RETURN NEXT;
    END IF;
END;
$function$;

-- ============================================================================
-- FIX 2: process_actor_day_boundary — payment loop for multi-week catch-ups
-- ============================================================================
-- Drop the old two-argument signature before replacing with three-argument one.
DROP FUNCTION IF EXISTS public.process_actor_day_boundary(uuid, timestamptz);

CREATE OR REPLACE FUNCTION public.process_actor_day_boundary(
    p_user_id      uuid,
    p_game_date    timestamp with time zone,
    p_elapsed_days numeric DEFAULT 1.0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_cash_after               NUMERIC;
    v_bankruptcy_days_threshold INTEGER;
    v_payment_periods          INTEGER;
    v_i                        INTEGER;
BEGIN
    v_payment_periods := GREATEST(1, FLOOR(p_elapsed_days / 7.0))::INTEGER;

    -- Credit score update (once per day boundary, not per payment period)
    PERFORM process_credit_at_day_boundary(p_user_id, p_game_date);

    -- Loop loan and financing payments for each elapsed payment period
    FOR v_i IN 1..v_payment_periods LOOP
        PERFORM process_loan_payments(p_user_id, p_game_date);
        PERFORM process_aircraft_financing_payments(p_user_id, p_game_date);
    END LOOP;

    v_cash_after := get_user_balance(p_user_id);
    v_bankruptcy_days_threshold := COALESCE(
        get_config_numeric('bankruptcy_negative_days_threshold'), 30
    )::INTEGER;

    IF v_cash_after < 0 THEN
        UPDATE users
        SET consecutive_negative_days = consecutive_negative_days + 1,
            recovery_streak_days = 0
        WHERE id = p_user_id;

        IF (SELECT consecutive_negative_days FROM users WHERE id = p_user_id)
           >= v_bankruptcy_days_threshold THEN
            PERFORM apply_actor_bankruptcy_state(p_user_id);
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
-- FIX 2a: Update process_player_simulation_to_time to pass elapsed_days
-- ============================================================================
DO $fix_player_boundary_call$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
        PERFORM process_actor_day_boundary(p_user_id, p_target_game_time);
$old$;
    v_new_snippet TEXT := $new$
        PERFORM process_actor_day_boundary(p_user_id, p_target_game_time, v_elapsed_days);
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
        RAISE NOTICE 'process_player_simulation_to_time already migrated or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_player_boundary_call$;

-- ============================================================================
-- FIX 2b: Update process_all_bots_simulation_to_time to pass elapsed days
-- ============================================================================
DO $fix_bot_boundary_call$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
            PERFORM process_actor_day_boundary(r_bot.id, p_target_game_time);
$old$;
    v_new_snippet TEXT := $new$
            PERFORM process_actor_day_boundary(r_bot.id, p_target_game_time, v_game_days);
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_all_bots_simulation_to_time(timestamptz, uuid)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_all_bots_simulation_to_time()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'process_all_bots_simulation_to_time already migrated or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_bot_boundary_call$;

-- ============================================================================
-- FIX 3: finance_aircraft — human path gets Regional-archetype default seats
-- ============================================================================
DO $fix_finance_seats$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
        'finance',
        100.00,
        'active',
        v_model.capacity,
        0,
        0
    )
$old$;
    v_new_snippet TEXT := $new$
        'finance',
        100.00,
        'active',
        FLOOR(v_model.capacity * 0.80)::INT,
        FLOOR(v_model.capacity * 0.15)::INT,
        (v_model.capacity - FLOOR(v_model.capacity * 0.80)::INT - FLOOR(v_model.capacity * 0.15)::INT)
    )
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.finance_aircraft(uuid, uuid, numeric, integer)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for finance_aircraft()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'finance_aircraft human seats already migrated or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_finance_seats$;

COMMIT;
