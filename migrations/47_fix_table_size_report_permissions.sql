-- ============================================================================
-- SKYWARD PHASE 12.1 TABLE SIZE REPORT PERMISSION FIX
-- ============================================================================
-- Restricts table-size reporting to public tables and exposes it through a
-- security-definer audit function so client roles do not need access to
-- extension schemas such as cron.
-- ============================================================================

CREATE OR REPLACE FUNCTION get_table_size_report()
RETURNS TABLE (
    schema_name TEXT,
    table_name TEXT,
    row_estimate BIGINT,
    total_size_bytes BIGINT,
    total_size_pretty TEXT,
    table_size_pretty TEXT,
    index_size_pretty TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        stat.schemaname::TEXT,
        stat.relname::TEXT,
        stat.n_live_tup::BIGINT,
        pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)::BIGINT,
        pg_size_pretty(pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)),
        pg_size_pretty(pg_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)),
        pg_size_pretty(pg_indexes_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS))
    FROM pg_stat_user_tables stat
    WHERE stat.schemaname = 'public'
    ORDER BY pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS) DESC;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION get_table_size_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_table_size_report() TO authenticated, anon, service_role;

COMMENT ON FUNCTION get_table_size_report() IS
'Returns approximate row counts and relation/index sizes for public user tables without requiring extension schema access.';
