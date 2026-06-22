-- ============================================================================
-- SKYWARD PHASE 4.1 SCHEDULER HEALTH PERMISSION FIX
-- ============================================================================
-- The Phase 4 scheduler health RPC needs to inspect cron.job. Client roles
-- should not receive direct cron schema access, so expose only the narrow
-- health summary through a SECURITY DEFINER function.
-- ============================================================================

CREATE OR REPLACE FUNCTION get_world_tick_scheduler_health()
RETURNS TABLE (
    season_id UUID,
    season_status VARCHAR,
    current_game_time TIMESTAMP WITH TIME ZONE,
    season_last_tick_at TIMESTAMP WITH TIME ZONE,
    seconds_since_last_tick NUMERIC,
    latest_log_started_at TIMESTAMP WITH TIME ZONE,
    latest_log_status VARCHAR,
    latest_log_message TEXT,
    latest_ticks_processed INT,
    scheduler_job_exists BOOLEAN,
    scheduler_job_active BOOLEAN
) AS $$
DECLARE
    r_season RECORD;
    r_log RECORD;
    r_job RECORD;
BEGIN
    SELECT *
    INTO r_season
    FROM public.season_clock
    WHERE status = 'active'
    ORDER BY created_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT *
    INTO r_log
    FROM public.world_tick_log
    WHERE world_tick_log.season_id = r_season.id
    ORDER BY started_at DESC
    LIMIT 1;

    SELECT *
    INTO r_job
    FROM cron.job
    WHERE jobname = 'skyward_world_tick'
    LIMIT 1;

    RETURN QUERY SELECT
        r_season.id,
        r_season.status::VARCHAR,
        r_season.current_game_time,
        r_season.last_tick_at,
        EXTRACT(EPOCH FROM (NOW() - r_season.last_tick_at))::NUMERIC,
        r_log.started_at,
        r_log.status::VARCHAR,
        r_log.message,
        COALESCE(r_log.ticks_processed, 0),
        (r_job.jobid IS NOT NULL),
        COALESCE(r_job.active, FALSE);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, cron, extensions;

REVOKE ALL ON FUNCTION get_world_tick_scheduler_health() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_world_tick_scheduler_health() TO authenticated, anon, service_role;

COMMENT ON FUNCTION get_world_tick_scheduler_health() IS
'Returns active season clock health and pg_cron job status without granting direct cron schema access.';
