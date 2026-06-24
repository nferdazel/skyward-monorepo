-- ============================================================================
-- Migration 132: Simplify world_tick_log compaction
-- ============================================================================
-- Problem:
--   world_tick_daily_summary is NEVER read by any function or frontend.
--   The compaction function wastes time aggregating into a table nobody uses.
--
-- Fix:
--   1. Drop world_tick_daily_summary table
--   2. Simplify compact_world_tick_log to just DELETE old rows
--   3. Simplify get_world_tick_log_compaction_report to match
-- ============================================================================

BEGIN;

-- ============================================================================
-- Part 1: Drop unused summary table
-- ============================================================================

DROP TABLE IF EXISTS world_tick_daily_summary CASCADE;

-- ============================================================================
-- Part 2: Simplify compact_world_tick_log — just delete old rows
-- ============================================================================

DROP FUNCTION IF EXISTS public.compact_world_tick_log(BOOLEAN) CASCADE;

CREATE OR REPLACE FUNCTION public.compact_world_tick_log(p_dry_run BOOLEAN DEFAULT TRUE)
RETURNS TABLE(action TEXT, detail TEXT, row_count BIGINT)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
DECLARE
    v_retention_days INT;
    v_cutoff TIMESTAMPTZ;
    v_count BIGINT := 0;
BEGIN
    v_retention_days := COALESCE(get_config_int('world_tick_log_raw_real_days'), 7);
    v_cutoff := NOW() - (v_retention_days || ' days')::INTERVAL;

    SELECT COUNT(*) INTO v_count FROM world_tick_log WHERE started_at < v_cutoff;

    IF NOT p_dry_run AND v_count > 0 THEN
        DELETE FROM world_tick_log WHERE started_at < v_cutoff;
    END IF;

    action := 'delete';
    detail := CASE WHEN p_dry_run THEN 'Rows that would be deleted' ELSE 'Rows deleted' END;
    row_count := v_count;
    RETURN NEXT;
END;
$$;

-- ============================================================================
-- Part 3: Simplify get_world_tick_log_compaction_report
-- ============================================================================

DROP FUNCTION IF EXISTS public.get_world_tick_log_compaction_report() CASCADE;

CREATE OR REPLACE FUNCTION public.get_world_tick_log_compaction_report()
RETURNS TABLE(metric TEXT, value TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
    v_raw_count BIGINT;
    v_retention_days INT;
    v_cutoff TIMESTAMPTZ;
    v_would_delete BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_raw_count FROM world_tick_log;
    v_retention_days := COALESCE(get_config_int('world_tick_log_raw_real_days'), 7);
    v_cutoff := NOW() - (v_retention_days || ' days')::INTERVAL;
    SELECT COUNT(*) INTO v_would_delete FROM world_tick_log WHERE started_at < v_cutoff;

    metric := 'raw_log_count';        value := v_raw_count::TEXT;           RETURN NEXT;
    metric := 'retention_days';        value := v_retention_days::TEXT;      RETURN NEXT;
    metric := 'cutoff_date';           value := v_cutoff::TEXT;             RETURN NEXT;
    metric := 'rows_pending_delete';   value := v_would_delete::TEXT;       RETURN NEXT;
END;
$$;

COMMIT;
