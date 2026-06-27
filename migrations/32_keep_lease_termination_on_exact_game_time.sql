-- ============================================================================
-- Migration 32: Preserve exact game clock for lease termination ledger rows
-- Goal:
--   stop truncating lease-termination transactions to 00:00 and keep the
--   precise shared game clock timestamp for player-facing chronology.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.terminate_aircraft_lease(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;
