-- ============================================================================
-- Migration 41: Fix get_competitor_insights net worth source
-- Goal:
--   get_competitor_insights reads u.net_worth (stale denormalized column)
--   while get_global_leaderboard uses calculate_user_net_worth() (canonical).
--   This causes net worth to disagree between leaderboard and insights panels.
--
--   Fix: patch get_competitor_insights to use calculate_user_net_worth(),
--   matching the pattern from migration 09.
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_competitor_insights(uuid, boolean);

CREATE OR REPLACE FUNCTION public.get_competitor_insights(p_id uuid, p_is_bot boolean DEFAULT false)
RETURNS TABLE(
    company_name character varying,
    ceo_name character varying,
    net_worth numeric,
    fleet_size integer,
    route_count integer,
    monthly_revenue numeric,
    operational_status character varying,
    hq_airport_iata character varying,
    distress_stage character varying,
    consecutive_negative_days integer,
    recovery_streak_days integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        u.company_name,
        u.ceo_name,
        calculate_user_net_worth(u.id) AS net_worth,
        (SELECT COUNT(*)::INT FROM fleet_aircraft f WHERE f.user_id = u.id) AS fleet_size,
        (SELECT COUNT(*)::INT FROM route_assignments r WHERE r.user_id = u.id AND r.status = 'active') AS route_count,
        0::NUMERIC AS monthly_revenue,
        u.operational_status,
        u.hq_airport_iata,
        COALESCE(bp.distress_stage, 'stable')::VARCHAR AS distress_stage,
        COALESCE(u.consecutive_negative_days, 0) AS consecutive_negative_days,
        COALESCE(u.recovery_streak_days, 0) AS recovery_streak_days
    FROM users u
    LEFT JOIN bot_profiles bp ON bp.user_id = u.id
    WHERE u.id = p_id;
END;
$function$;

COMMIT;
