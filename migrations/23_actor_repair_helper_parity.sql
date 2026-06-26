-- ============================================================================
-- Migration 23: Actor repair helper parity
-- Goal:
--   route player and bot repair side effects through one helper and keep all
--   bankruptcy entrypoints on the same shared state transition.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.perform_actor_aircraft_repair(
    p_user_id uuid,
    p_fleet_id uuid,
    p_min_cash_reserve numeric DEFAULT 0,
    p_game_time timestamp with time zone DEFAULT NULL,
    p_description text DEFAULT NULL
)
RETURNS TABLE(
    success boolean,
    message character varying,
    new_cash numeric,
    repair_cost numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_cash NUMERIC;
    v_condition NUMERIC;
    v_purchase_price NUMERIC;
    v_lease_price NUMERIC;
    v_model_name VARCHAR;
    v_repair_cost NUMERIC;
    v_acquisition_type VARCHAR;
    v_effective_game_time TIMESTAMPTZ;
    v_required_cash NUMERIC;
    v_description TEXT;
BEGIN
    SELECT game_current_time
      INTO v_effective_game_time
      FROM users
     WHERE id = p_user_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0::NUMERIC, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT f.condition, f.acquisition_type, m.purchase_price, m.lease_price_per_month, m.model_name
      INTO v_condition, v_acquisition_type, v_purchase_price, v_lease_price, v_model_name
      FROM fleet_aircraft f
      JOIN aircraft_models m
        ON m.id = f.aircraft_model_id
     WHERE f.id = p_fleet_id
       AND f.user_id = p_user_id;

    v_cash := get_user_balance(p_user_id);

    IF p_game_time IS NOT NULL THEN
        v_effective_game_time := p_game_time;
    END IF;

    IF v_model_name IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, v_cash, 0::NUMERIC;
        RETURN;
    END IF;

    IF v_condition >= 100.00 THEN
        RETURN QUERY
        SELECT FALSE,
               ('Aircraft ' || v_model_name || ' is already in pristine condition.')::VARCHAR,
               v_cash,
               0::NUMERIC;
        RETURN;
    END IF;

    v_repair_cost := CASE
        WHEN v_acquisition_type = 'lease' THEN (100.00 - v_condition) * (COALESCE(v_lease_price, 0.00) * 0.50)
        ELSE (100.00 - v_condition) * (COALESCE(v_purchase_price, 0.00) * 0.0005)
    END;

    v_required_cash := v_repair_cost + GREATEST(COALESCE(p_min_cash_reserve, 0), 0);

    IF v_cash < v_required_cash THEN
        RETURN QUERY
        SELECT FALSE,
               ('Insufficient funds for repair. Required: $' || ROUND(v_required_cash, 2))::VARCHAR,
               v_cash,
               v_repair_cost;
        RETURN;
    END IF;

    v_description := COALESCE(
        p_description,
        'Maintenance completed for ' || v_model_name || ' - restored from ' || ROUND(v_condition::numeric, 2) || '% to 100%'
    );

    PERFORM debit_bank_account(
        p_user_id,
        v_repair_cost,
        'cogs',
        'maintenance',
        v_description,
        v_effective_game_time
    );

    UPDATE fleet_aircraft
    SET condition = 100.00,
        status = 'active'
    WHERE id = p_fleet_id;

    v_cash := get_user_balance(p_user_id);

    RETURN QUERY
    SELECT TRUE,
           'Aircraft maintenance complete. Health restored to 100%!'::VARCHAR,
           v_cash,
           v_repair_cost;
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.repair_aircraft(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_success BOOLEAN;
    v_message VARCHAR;
    v_new_cash NUMERIC;
    v_repair_cost NUMERIC;
BEGIN
    PERFORM 1
      FROM process_simulation_delta(p_user_id);

    SELECT h.success, h.message, h.new_cash, h.repair_cost
      INTO v_success, v_message, v_new_cash, v_repair_cost
      FROM perform_actor_aircraft_repair(
          p_user_id,
          p_fleet_id
      ) h;

    RETURN QUERY
    SELECT v_success, v_message, v_new_cash;
END;
$function$;

DO $$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
IF v_grounded_aircraft_id IS NOT NULL AND v_repair_allowed THEN
    v_repair_cost := CASE
        WHEN v_grounded_acquisition_type = 'lease' THEN (100.00 - v_grounded_condition) * (COALESCE(v_grounded_lease_price, 0.00) * 0.50)
        ELSE (100.00 - v_grounded_condition) * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005)
    END;

    IF v_repair_cost > 0
       AND v_bot_cash >= (v_repair_cost + 500000.00)
       AND (v_distress_stage IN ('stable', 'cautious') OR (v_distress_stage = 'defensive' AND v_grounded_condition >= 45)) THEN
        PERFORM debit_bank_account(r_bot.id, v_repair_cost, 'cogs', 'maintenance', 'Bot maintenance recovery: ' || v_grounded_model_name, v_game_time);
        UPDATE fleet_aircraft
        SET condition = 100.00,
            status = 'active'
        WHERE id = v_grounded_aircraft_id;
        UPDATE bot_profiles
        SET last_repair_action_at = v_game_time
        WHERE user_id = r_bot.id;
        v_bot_cash := v_bot_cash - v_repair_cost;
    END IF;
END IF;
$old$;
    v_new_snippet TEXT := $new$
IF v_grounded_aircraft_id IS NOT NULL
   AND v_repair_allowed
   AND (v_distress_stage IN ('stable', 'cautious') OR (v_distress_stage = 'defensive' AND v_grounded_condition >= 45)) THEN
    SELECT h.success, h.new_cash, h.repair_cost
      INTO v_inserted, v_bot_cash, v_repair_cost
      FROM perform_actor_aircraft_repair(
          r_bot.id,
          v_grounded_aircraft_id,
          500000.00,
          v_game_time,
          'Bot maintenance recovery: ' || v_grounded_model_name
      ) h;

    IF COALESCE(v_inserted, FALSE) THEN
        UPDATE bot_profiles
        SET last_repair_action_at = v_game_time
        WHERE user_id = r_bot.id;
    END IF;
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
        RAISE EXCEPTION 'Expected bot repair block not found while applying actor repair parity migration';
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$$;
