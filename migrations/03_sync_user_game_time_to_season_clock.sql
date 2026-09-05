-- Migration 03: Sync user game_current_time to active season_clock.current_game_time
-- Ensures all users operate on the single authoritative world clock (e.g. 2038)
-- and eliminates static 2020-01-01 initial date fallbacks in production.

-- 1. Catch up all existing users whose game_current_time lags behind active season_clock
UPDATE public.users u
SET game_current_time = sc.current_game_time
FROM public.season_clock sc
WHERE sc.status = 'active'
  AND (u.game_current_time IS NULL OR u.game_current_time < sc.current_game_time);

-- 2. Update reset_user_airline to initialize user time from season_clock instead of static 2020-01-01
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
        net_worth = 15000000.00,
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
    VALUES (p_user_id, 'operating', 15000000.00);

    RETURN QUERY SELECT TRUE, 'Airline reset successfully';
END;
$$;

ALTER FUNCTION public.reset_user_airline(p_user_id uuid) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.reset_user_airline(p_user_id uuid) TO anon, authenticated, service_role;
