-- ============================================================================
-- Migration 35: Actor parity hardening
-- Goal:
--   1. Fix bankruptcy regression in execute_bot_decisions() (migration 33
--      rewrote the function and reverted migration 22's parity fix)
--   2. Create shared sell_actor_aircraft() helper
--   3. Create shared terminate_actor_lease() helper
--   4. Create shared assign_actor_aircraft_to_route() helper
--   5. Route player-facing RPCs through the new shared helpers
-- ============================================================================

BEGIN;

-- ============================================================================
-- FIX 1: Restore bankruptcy parity in execute_bot_decisions()
-- ============================================================================
-- Migration 33 rewrote execute_bot_decisions() with inline bankruptcy code
-- (4 direct UPDATE statements) instead of calling apply_actor_bankruptcy_state().
-- This reverts migration 22's parity fix. We restore it here.

DO $fix_bankruptcy_regression$
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
        RAISE NOTICE 'execute_bot_decisions bankruptcy block already migrated or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_bankruptcy_regression$;

-- ============================================================================
-- FIX 2: Create shared sell_actor_aircraft() helper
-- ============================================================================
-- Extracts the core sell logic from sell_aircraft() into a shared helper
-- that both player and bot paths can use. The player-facing RPC becomes a
-- thin wrapper that calls process_simulation_delta() then delegates.

CREATE OR REPLACE FUNCTION public.sell_actor_aircraft(
    p_user_id       uuid,
    p_fleet_id      uuid,
    p_game_time     timestamp with time zone
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_fleet RECORD;
    v_base_value NUMERIC(20,2);
    v_age_years NUMERIC;
    v_depreciation_factor NUMERIC;
    v_sale_value NUMERIC(20,2);
BEGIN
    -- Validate user exists
    PERFORM 1 FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Validate aircraft exists and belongs to user
    SELECT f.*, m.model_name, m.purchase_price
    INTO v_fleet
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Must be purchased, not leased
    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'purchase' THEN
        RETURN QUERY SELECT FALSE, 'Only owned aircraft can be sold.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Must not be assigned to a route
    IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Calculate sale value with depreciation
    v_base_value := v_fleet.purchase_price * (v_fleet.condition / 100.00);
    IF v_fleet.acquired_game_date IS NOT NULL AND p_game_time IS NOT NULL THEN
        v_age_years := EXTRACT(EPOCH FROM (p_game_time - v_fleet.acquired_game_date)) / (365.25 * 86400.0);
        v_depreciation_factor := GREATEST(0.10, 1.0 - (0.05 * COALESCE(v_age_years, 0)));
        v_sale_value := ROUND(v_base_value * v_depreciation_factor, 2);
    ELSE
        v_sale_value := v_base_value;
    END IF;

    -- Credit the sale proceeds
    PERFORM credit_bank_account(
        p_user_id, v_sale_value, 'investing', 'aircraft_sale',
        'Sold aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
        p_game_time
    );

    -- Remove the aircraft
    DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;

    new_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT TRUE, ('Aircraft sold for $' || ROUND(v_sale_value, 2)::TEXT || '.')::VARCHAR, new_cash;
END;
$function$;

-- ============================================================================
-- FIX 3: Create shared terminate_actor_lease() helper
-- ============================================================================
-- Extracts the core lease termination logic into a shared helper.

CREATE OR REPLACE FUNCTION public.terminate_actor_lease(
    p_user_id       uuid,
    p_fleet_id      uuid,
    p_game_time     timestamp with time zone
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_fleet RECORD;
    v_exit_fee NUMERIC(20,2);
BEGIN
    -- Validate user exists
    PERFORM 1 FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Validate aircraft exists and belongs to user
    SELECT f.*, m.model_name, m.lease_price_per_month
    INTO v_fleet
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Must be a lease
    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'lease' THEN
        RETURN QUERY SELECT FALSE, 'Only leased aircraft can be terminated through this action.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Must not be assigned to a route
    IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Calculate and charge exit fee
    v_exit_fee := calculate_lease_termination_fee(v_fleet.lease_price_per_month);
    IF v_exit_fee > 0 THEN
        PERFORM debit_bank_account(
            p_user_id, v_exit_fee, 'opex', 'lease_termination',
            'Terminated leased aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
            p_game_time
        );
    END IF;

    -- Remove the aircraft
    DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;

    new_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT TRUE, 'Lease terminated successfully!'::VARCHAR, new_cash;
END;
$function$;

-- ============================================================================
-- FIX 4: Create shared assign_actor_aircraft_to_route() helper
-- ============================================================================
-- Extracts the core assignment logic into a shared helper.

CREATE OR REPLACE FUNCTION public.assign_actor_aircraft_to_route(
    p_user_id       uuid,
    p_route_id      uuid,
    p_aircraft_id   uuid
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_current_aircraft_id UUID;
    v_effective_threshold NUMERIC(5,2);
    v_route_distance_km DOUBLE PRECISION;
    v_route_flights_per_week INT;
    v_aircraft_range_km INT;
    v_aircraft_speed_kmh INT;
    v_max_weekly_flights INT;
BEGIN
    -- Look up the route
    SELECT assigned_aircraft_id, distance_km, flights_per_week
    INTO v_current_aircraft_id, v_route_distance_km, v_route_flights_per_week
    FROM route_assignments
    WHERE id = p_route_id AND user_id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR;
        RETURN;
    END IF;

    -- If assigning an aircraft (not unassigning), validate it
    IF p_aircraft_id IS NOT NULL THEN
        -- Safety threshold
        SELECT GREATEST(
            COALESCE(u.auto_grounding_threshold, 40.00),
            COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00)
        ) INTO v_effective_threshold
        FROM users u WHERE u.id = p_user_id LIMIT 1;

        -- Aircraft existence, condition, and model data
        SELECT m.range_km, m.speed_kmh
        INTO v_aircraft_range_km, v_aircraft_speed_kmh
        FROM fleet_aircraft f
        JOIN aircraft_models m ON m.id = f.aircraft_model_id
        WHERE f.id = p_aircraft_id
          AND f.user_id = p_user_id
          AND f.condition >= COALESCE(v_effective_threshold, 40.00);
        IF NOT FOUND THEN
            RETURN QUERY SELECT FALSE, 'Aircraft is unavailable or below the safety threshold.'::VARCHAR;
            RETURN;
        END IF;

        -- Range check
        IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN
            RETURN QUERY SELECT FALSE, 'Aircraft range is insufficient for this route.'::VARCHAR;
            RETURN;
        END IF;

        -- Capacity check
        v_max_weekly_flights := calculate_route_max_weekly_flights(v_route_distance_km, v_aircraft_speed_kmh);
        IF v_max_weekly_flights > 0 AND COALESCE(v_route_flights_per_week, 0) > v_max_weekly_flights THEN
            RETURN QUERY SELECT FALSE, 'Route frequency exceeds this aircraft''s weekly operating capacity.'::VARCHAR;
            RETURN;
        END IF;

        -- Double-assignment check
        IF EXISTS (
            SELECT 1 FROM route_assignments
            WHERE user_id = p_user_id AND assigned_aircraft_id = p_aircraft_id AND id <> p_route_id
        ) THEN
            RETURN QUERY SELECT FALSE, 'Aircraft is already assigned to another route.'::VARCHAR;
            RETURN;
        END IF;
    END IF;

    -- Perform the assignment
    UPDATE route_assignments
    SET assigned_aircraft_id = p_aircraft_id
    WHERE id = p_route_id AND user_id = p_user_id;

    -- Activate the aircraft if assigning
    IF p_aircraft_id IS NOT NULL THEN
        UPDATE fleet_aircraft SET status = 'active' WHERE id = p_aircraft_id AND user_id = p_user_id;
    END IF;

    RETURN QUERY SELECT TRUE, 'Aircraft assignment updated successfully!'::VARCHAR;
END;
$function$;

-- ============================================================================
-- FIX 5: Route sell_aircraft() through shared helper
-- ============================================================================
DO $fix_sell_aircraft$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
DECLARE
v_user RECORD; v_fleet RECORD;
v_base_value NUMERIC(20,2); v_age_years NUMERIC; v_depreciation_factor NUMERIC;
v_sale_value NUMERIC(20,2);
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
SELECT f.*, m.model_name, m.purchase_price
INTO v_fleet FROM fleet_aircraft f
JOIN aircraft_models m ON m.id = f.aircraft_model_id
WHERE f.id = p_fleet_id AND f.user_id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'purchase' THEN
RETURN QUERY SELECT FALSE, 'Only owned aircraft can be sold.'::VARCHAR, NULL::NUMERIC; RETURN;
END IF;
IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC; RETURN;
END IF;
v_base_value := v_fleet.purchase_price * (v_fleet.condition / 100.00);
IF v_fleet.acquired_game_date IS NOT NULL AND v_user.game_current_time IS NOT NULL THEN
v_age_years := EXTRACT(EPOCH FROM (v_user.game_current_time - v_fleet.acquired_game_date)) / (365.25 * 86400.0);
v_depreciation_factor := GREATEST(0.10, 1.0 - (0.05 * COALESCE(v_age_years, 0)));
v_sale_value := ROUND(v_base_value * v_depreciation_factor, 2);
ELSE
v_sale_value := v_base_value;
END IF;
PERFORM credit_bank_account(p_user_id, v_sale_value, 'investing', 'aircraft_sale',
'Sold aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
v_user.game_current_time);
DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;
new_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, ('Aircraft sold for $' || ROUND(v_sale_value, 2)::TEXT || '.')::VARCHAR, new_cash;
END;
$old$;
    v_new_snippet TEXT := $new$
DECLARE
    v_game_time TIMESTAMPTZ;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
    RETURN QUERY SELECT * FROM sell_actor_aircraft(p_user_id, p_fleet_id, v_game_time);
END;
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.sell_aircraft(uuid, uuid)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for sell_aircraft(uuid, uuid)';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'sell_aircraft already migrated or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_sell_aircraft$;

-- ============================================================================
-- FIX 6: Route terminate_aircraft_lease() through shared helper
-- ============================================================================
DO $fix_terminate_lease$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
DECLARE
v_user RECORD; v_fleet RECORD; v_exit_fee NUMERIC(20,2);
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
SELECT f.*, m.model_name, m.lease_price_per_month
INTO v_fleet FROM fleet_aircraft f
JOIN aircraft_models m ON m.id = f.aircraft_model_id
WHERE f.id = p_fleet_id AND f.user_id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'lease' THEN
RETURN QUERY SELECT FALSE, 'Only leased aircraft can be terminated through this action.'::VARCHAR, NULL::NUMERIC; RETURN;
END IF;
IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC; RETURN;
END IF;
v_exit_fee := calculate_lease_termination_fee(v_fleet.lease_price_per_month);
IF v_exit_fee > 0 THEN
PERFORM debit_bank_account(p_user_id, v_exit_fee, 'opex', 'lease_termination',
'Terminated leased aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
v_user.game_current_time);
END IF;
DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;
new_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, 'Lease terminated successfully!'::VARCHAR, new_cash;
END;
$old$;
    v_new_snippet TEXT := $new$
DECLARE
    v_game_time TIMESTAMPTZ;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
    RETURN QUERY SELECT * FROM terminate_actor_lease(p_user_id, p_fleet_id, v_game_time);
END;
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.terminate_aircraft_lease(uuid, uuid)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for terminate_aircraft_lease(uuid, uuid)';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'terminate_aircraft_lease already migrated or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_terminate_lease$;

-- ============================================================================
-- FIX 7: Route assign_aircraft_to_route() through shared helper
-- ============================================================================
DO $fix_assign_aircraft$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
DECLARE v_current_aircraft_id UUID; v_effective_threshold NUMERIC(5,2); v_route_distance_km DOUBLE PRECISION; v_route_flights_per_week INT; v_aircraft_range_km INT; v_aircraft_speed_kmh INT; v_max_weekly_flights INT;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
SELECT assigned_aircraft_id, distance_km, flights_per_week INTO v_current_aircraft_id, v_route_distance_km, v_route_flights_per_week FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR; RETURN; END IF;
IF p_aircraft_id IS NOT NULL THEN
  SELECT GREATEST(COALESCE(u.auto_grounding_threshold, 40.00), COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00)) INTO v_effective_threshold FROM users u WHERE u.id = p_user_id LIMIT 1;
  SELECT m.range_km, m.speed_kmh INTO v_aircraft_range_km, v_aircraft_speed_kmh FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = p_aircraft_id AND f.user_id = p_user_id AND f.condition >= COALESCE(v_effective_threshold, 40.00);
  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft is unavailable or below the safety threshold.'::VARCHAR; RETURN; END IF;
  IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN RETURN QUERY SELECT FALSE, 'Aircraft range is insufficient for this route.'::VARCHAR; RETURN; END IF;
  v_max_weekly_flights := calculate_route_max_weekly_flights(v_route_distance_km, v_aircraft_speed_kmh);
  IF v_max_weekly_flights > 0 AND COALESCE(v_route_flights_per_week, 0) > v_max_weekly_flights THEN RETURN QUERY SELECT FALSE, 'Route frequency exceeds this aircraft''s weekly operating capacity.'::VARCHAR; RETURN; END IF;
  IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_aircraft_id AND id <> p_route_id) THEN RETURN QUERY SELECT FALSE, 'Aircraft is already assigned to another route.'::VARCHAR; RETURN; END IF;
END IF;
UPDATE route_assignments SET assigned_aircraft_id = p_aircraft_id WHERE id = p_route_id AND user_id = p_user_id;
IF p_aircraft_id IS NOT NULL THEN UPDATE fleet_aircraft SET status = 'active' WHERE id = p_aircraft_id AND user_id = p_user_id; END IF;
RETURN QUERY SELECT TRUE, 'Aircraft assignment updated successfully!'::VARCHAR;
END;
$old$;
    v_new_snippet TEXT := $new$
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    RETURN QUERY SELECT * FROM assign_actor_aircraft_to_route(p_user_id, p_route_id, p_aircraft_id);
END;
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.assign_aircraft_to_route(uuid, uuid, uuid)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for assign_aircraft_to_route(uuid, uuid, uuid)';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'assign_aircraft_to_route already migrated or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_assign_aircraft$;

COMMIT;
