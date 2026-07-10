-- ============================================================================
-- Migration 37: Fix world_tick_log compaction
-- Goal:
--   The existing compact_world_tick_log() function works correctly when called
--   manually, but pg_cron fails to execute the DELETE. The issue is likely
--   pg_cron's handling of boolean parameters in RETURNS TABLE functions.
--
--   Fix: create a simpler prune_world_tick_log() wrapper with no parameters
--   that always deletes. Update the cron job to use it.
-- ============================================================================

BEGIN;

-- New simple wrapper — no parameters, always deletes
CREATE OR REPLACE FUNCTION public.prune_world_tick_log()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_retention_days INT;
    v_cutoff TIMESTAMPTZ;
BEGIN
    v_retention_days := COALESCE(get_config_int('world_tick_log_raw_real_days'), 7);
    v_cutoff := NOW() - (v_retention_days || ' days')::INTERVAL;
    DELETE FROM world_tick_log WHERE started_at < v_cutoff;
END;
$function$;

COMMIT;
