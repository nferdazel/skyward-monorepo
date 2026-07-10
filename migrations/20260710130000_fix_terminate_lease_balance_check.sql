-- ============================================================================
-- Migration: Fix terminate_actor_lease() balance check
-- Goal:
--   Add a balance sufficiency check before debiting the exit fee so that
--   lease termination cannot push the bank balance negative.
-- ============================================================================

BEGIN;

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

    -- Calculate exit fee
    v_exit_fee := calculate_lease_termination_fee(v_fleet.lease_price_per_month);

    -- Check balance sufficiency
    IF v_exit_fee > 0 THEN
        DECLARE v_cash NUMERIC;
        BEGIN
            SELECT get_user_balance(p_user_id) INTO v_cash;
            IF v_cash < v_exit_fee THEN
                RETURN QUERY SELECT FALSE, 'Insufficient funds to pay lease termination fee.'::VARCHAR, NULL::NUMERIC;
                RETURN;
            END IF;
        END;
    END IF;

    -- Debit exit fee
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

COMMIT;
