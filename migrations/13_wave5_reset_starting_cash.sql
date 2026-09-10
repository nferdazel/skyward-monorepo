-- WAVE 5 corrective — reset_user_airline starting cash
--
-- Migration 03 redefined reset_user_airline with a hardcoded $15M, overriding
-- the config-driven baseline and contradicting GAME-08 (starting cash $25M).
-- 03 has been fixed for fresh applies; this reconciles the live DB. The Go
-- reset path (Settings.Reset) is authoritative for the API, but the SQL RPC
-- remains callable, so keep it consistent.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

CREATE OR REPLACE FUNCTION public.reset_user_airline(p_user_id uuid)
RETURNS TABLE(success boolean, message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_season_time TIMESTAMPTZ;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id) THEN
        RETURN QUERY SELECT FALSE, 'User not found'; RETURN;
    END IF;

    SELECT current_game_time INTO v_season_time
    FROM public.season_clock WHERE status = 'active' LIMIT 1;
    v_season_time := COALESCE(v_season_time, NOW());

    DELETE FROM public.bank_transactions WHERE user_id = p_user_id;
    DELETE FROM public.bank_accounts WHERE user_id = p_user_id;
    DELETE FROM public.loans WHERE user_id = p_user_id;
    DELETE FROM public.credit_scores WHERE user_id = p_user_id;
    DELETE FROM public.credit_score_history WHERE user_id = p_user_id;
    DELETE FROM public.route_assignments WHERE user_id = p_user_id;
    DELETE FROM public.fleet_aircraft WHERE user_id = p_user_id;
    DELETE FROM public.achievements WHERE user_id = p_user_id;

    UPDATE public.users SET
        net_worth = COALESCE(public.get_config_numeric('starting_cash'), 25000000.00),
        game_current_time = v_season_time,
        hq_airport_iata = 'SIN',
        auto_grounding_threshold = 40.00,
        operational_status = 'Active',
        consecutive_negative_days = 0,
        recovery_streak_days = 0,
        last_active_at = NOW(),
        onboarding_completed = false
    WHERE id = p_user_id;

    INSERT INTO public.bank_accounts (user_id, account_type, balance)
    VALUES (p_user_id, 'operating', COALESCE(public.get_config_numeric('starting_cash'), 25000000.00));

    RETURN QUERY SELECT TRUE, 'Airline reset successfully';
END;
$$;

ALTER FUNCTION public.reset_user_airline(p_user_id uuid) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.reset_user_airline(p_user_id uuid) TO anon, authenticated, service_role;

COMMIT;
