-- ============================================================================
-- SKYWARD PHASE 4 WORLD TICK SCHEDULER WIRING
-- ============================================================================
-- Wires the Phase 3 world-tick foundation to pg_cron. This schedules the shared
-- season clock to advance automatically while keeping actor simulation on the
-- legacy per-player/per-bot clocks until the deterministic world engine lands.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS world_tick_scheduler_config (
    id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    job_name TEXT NOT NULL DEFAULT 'skyward_world_tick',
    cron_expression TEXT NOT NULL DEFAULT '* * * * *',
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    max_ticks_per_run INT NOT NULL DEFAULT 100 CHECK (max_ticks_per_run > 0),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

INSERT INTO world_tick_scheduler_config (
    id,
    job_name,
    cron_expression,
    enabled,
    max_ticks_per_run
)
VALUES (
    1,
    'skyward_world_tick',
    '* * * * *',
    TRUE,
    100
)
ON CONFLICT (id) DO UPDATE
SET job_name = EXCLUDED.job_name,
    cron_expression = EXCLUDED.cron_expression,
    enabled = EXCLUDED.enabled,
    max_ticks_per_run = EXCLUDED.max_ticks_per_run,
    updated_at = NOW();

DO $$
DECLARE
    r_job RECORD;
BEGIN
    FOR r_job IN
        SELECT jobid
        FROM cron.job
        WHERE jobname = 'skyward_world_tick'
    LOOP
        PERFORM cron.unschedule(r_job.jobid);
    END LOOP;
END;
$$;

SELECT cron.schedule(
    'skyward_world_tick',
    '* * * * *',
    $$SELECT * FROM ensure_world_current(NULL);$$
);

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
    FROM season_clock
    WHERE status = 'active'
    ORDER BY created_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT *
    INTO r_log
    FROM world_tick_log
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
$$ LANGUAGE plpgsql STABLE;

COMMENT ON TABLE world_tick_scheduler_config IS
'Desired scheduler configuration for the shared season clock pg_cron job.';

COMMENT ON FUNCTION get_world_tick_scheduler_health() IS
'Returns the active season clock state, latest tick log entry, and pg_cron job presence.';
