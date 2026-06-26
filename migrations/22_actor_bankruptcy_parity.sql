-- ============================================================================
-- Migration 22: Actor bankruptcy parity
-- Goal:
--   route shared bankruptcy side effects through one helper so player and bot
--   paths ground fleet, default loans, and cancel routes consistently.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.apply_actor_bankruptcy_state(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    UPDATE users
    SET operational_status = 'Bankrupt'
    WHERE id = p_user_id;

    UPDATE fleet_aircraft
    SET status = 'grounded'
    WHERE user_id = p_user_id;

    UPDATE loans
    SET status = 'defaulted',
        remaining_balance = 0
    WHERE user_id = p_user_id
      AND status = 'active';

    UPDATE route_assignments
    SET status = 'cancelled'
    WHERE user_id = p_user_id
      AND status = 'active';
END;
$function$;

DO $$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
    IF v_cash_after <= v_bankruptcy_threshold THEN
        UPDATE users
        SET operational_status = 'Bankrupt'
        WHERE id = p_user_id;

        UPDATE route_assignments
        SET status = 'cancelled'
        WHERE user_id = p_user_id
          AND status = 'active';
    END IF;
$old$;
    v_new_snippet TEXT := $new$
    IF v_cash_after <= v_bankruptcy_threshold THEN
        PERFORM apply_actor_bankruptcy_state(p_user_id);
    END IF;
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_player_simulation_to_time(uuid,timestamp with time zone)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_player_simulation_to_time(uuid, timestamptz)';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE EXCEPTION 'Expected player bankruptcy block not found while applying actor bankruptcy parity migration';
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$$;

DO $$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < v_bankruptcy_threshold THEN
  UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
  UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id;
  UPDATE loans SET status = 'defaulted', remaining_balance = 0 WHERE user_id = r_bot.id AND status = 'active';
  UPDATE route_assignments SET status = 'cancelled' WHERE user_id = r_bot.id AND status = 'active';
  UPDATE bot_profiles SET distress_stage = 'desperate' WHERE user_id = r_bot.id;
  CONTINUE;
END IF;
$old$;
    v_new_snippet TEXT := $new$
IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < v_bankruptcy_threshold THEN
  PERFORM apply_actor_bankruptcy_state(r_bot.id);
  UPDATE bot_profiles SET distress_stage = 'desperate' WHERE user_id = r_bot.id;
  CONTINUE;
END IF;
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.execute_bot_decisions()'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for execute_bot_decisions()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE EXCEPTION 'Expected bot bankruptcy block not found while applying actor bankruptcy parity migration';
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$$;
