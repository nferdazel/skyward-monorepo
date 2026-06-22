-- ============================================================================
-- SKYWARD PHASE 15 FINANCIAL LEDGER COMPACTION DRY-RUN FOUNDATION
-- ============================================================================
-- Adds a summarized ledger table plus:
--   1. a read-only dry-run report RPC
--   2. a compaction RPC that defaults to dry-run mode
--
-- This phase uses actor-relative game-time retention:
--   - players keep raw ledger rows for 90 game days
--   - bots keep raw ledger rows for 30 game days
--
-- This migration does not schedule compaction. Destructive behavior only runs
-- when compact_financial_ledger(FALSE) is called intentionally.
-- ============================================================================

CREATE TABLE IF NOT EXISTS financial_ledger_summary (
    actor_id UUID NOT NULL,
    is_bot BOOLEAN NOT NULL,
    summary_game_date DATE NOT NULL,
    summary_month DATE NOT NULL,
    transaction_type VARCHAR(20) NOT NULL CHECK (transaction_type IN ('revenue', 'expense')),
    category VARCHAR(50) NOT NULL,
    source_row_count BIGINT NOT NULL CHECK (source_row_count > 0),
    total_amount NUMERIC(20,2) NOT NULL CHECK (total_amount >= 0),
    first_game_date TIMESTAMP WITH TIME ZONE NOT NULL,
    last_game_date TIMESTAMP WITH TIME ZONE NOT NULL,
    first_created_at TIMESTAMP WITH TIME ZONE,
    last_created_at TIMESTAMP WITH TIME ZONE,
    compacted_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    PRIMARY KEY (actor_id, is_bot, summary_game_date, transaction_type, category)
);

CREATE INDEX IF NOT EXISTS financial_ledger_summary_month_idx
ON financial_ledger_summary(summary_month DESC, is_bot, category, transaction_type);

CREATE INDEX IF NOT EXISTS financial_ledger_summary_date_idx
ON financial_ledger_summary(summary_game_date DESC, is_bot, actor_id);


CREATE OR REPLACE FUNCTION get_financial_ledger_compaction_report()
RETURNS TABLE (
    actor_id UUID,
    is_bot BOOLEAN,
    company_name VARCHAR,
    summary_game_date DATE,
    summary_month DATE,
    transaction_type VARCHAR,
    category VARCHAR,
    source_row_count BIGINT,
    total_amount NUMERIC,
    first_game_date TIMESTAMP WITH TIME ZONE,
    last_game_date TIMESTAMP WITH TIME ZONE,
    first_created_at TIMESTAMP WITH TIME ZONE,
    last_created_at TIMESTAMP WITH TIME ZONE,
    retention_game_days INT,
    actor_game_current_time TIMESTAMP WITH TIME ZONE,
    cutoff_game_time TIMESTAMP WITH TIME ZONE
) AS $$
BEGIN
    RETURN QUERY
    WITH actor_cutoffs AS (
        SELECT
            u.id AS actor_id,
            FALSE AS is_bot,
            u.company_name,
            u.game_current_time AS actor_game_current_time,
            COALESCE(policy.value_int, 90) AS retention_game_days,
            u.game_current_time - make_interval(days => COALESCE(policy.value_int, 90)) AS cutoff_game_time
        FROM users u
        LEFT JOIN data_retention_policy policy
            ON policy.key = 'player_ledger_raw_game_days'

        UNION ALL

        SELECT
            ai.id AS actor_id,
            TRUE AS is_bot,
            ai.company_name,
            ai.game_current_time AS actor_game_current_time,
            COALESCE(policy.value_int, 30) AS retention_game_days,
            ai.game_current_time - make_interval(days => COALESCE(policy.value_int, 30)) AS cutoff_game_time
        FROM ai_competitors ai
        LEFT JOIN data_retention_policy policy
            ON policy.key = 'bot_ledger_raw_game_days'
    ),
    eligible AS (
        SELECT
            ac.actor_id,
            ac.is_bot,
            ac.company_name,
            ac.retention_game_days,
            ac.actor_game_current_time,
            ac.cutoff_game_time,
            fl.transaction_type,
            fl.category,
            fl.amount,
            fl.game_date,
            fl.created_at
        FROM financial_ledger fl
        JOIN actor_cutoffs ac
            ON (
                (NOT ac.is_bot AND fl.user_id = ac.actor_id)
                OR
                (ac.is_bot AND fl.ai_competitor_id = ac.actor_id)
            )
        WHERE fl.game_date < ac.cutoff_game_time
    )
    SELECT
        eligible.actor_id,
        eligible.is_bot,
        eligible.company_name,
        (eligible.game_date AT TIME ZONE 'UTC')::DATE AS summary_game_date,
        date_trunc('month', eligible.game_date AT TIME ZONE 'UTC')::DATE AS summary_month,
        eligible.transaction_type,
        eligible.category,
        COUNT(*)::BIGINT AS source_row_count,
        COALESCE(SUM(eligible.amount), 0.00)::NUMERIC AS total_amount,
        MIN(eligible.game_date) AS first_game_date,
        MAX(eligible.game_date) AS last_game_date,
        MIN(eligible.created_at) AS first_created_at,
        MAX(eligible.created_at) AS last_created_at,
        eligible.retention_game_days,
        eligible.actor_game_current_time,
        eligible.cutoff_game_time
    FROM eligible
    GROUP BY
        eligible.actor_id,
        eligible.is_bot,
        eligible.company_name,
        (eligible.game_date AT TIME ZONE 'UTC')::DATE,
        date_trunc('month', eligible.game_date AT TIME ZONE 'UTC')::DATE,
        eligible.transaction_type,
        eligible.category,
        eligible.retention_game_days,
        eligible.actor_game_current_time,
        eligible.cutoff_game_time
    ORDER BY
        summary_game_date ASC,
        eligible.is_bot ASC,
        eligible.actor_id ASC,
        eligible.transaction_type ASC,
        eligible.category ASC;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;


CREATE OR REPLACE FUNCTION compact_financial_ledger(
    p_dry_run BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    action TEXT,
    actor_id UUID,
    is_bot BOOLEAN,
    company_name VARCHAR,
    summary_game_date DATE,
    summary_month DATE,
    transaction_type VARCHAR,
    category VARCHAR,
    source_row_count BIGINT,
    total_amount NUMERIC,
    first_game_date TIMESTAMP WITH TIME ZONE,
    last_game_date TIMESTAMP WITH TIME ZONE,
    first_created_at TIMESTAMP WITH TIME ZONE,
    last_created_at TIMESTAMP WITH TIME ZONE,
    retention_game_days INT,
    actor_game_current_time TIMESTAMP WITH TIME ZONE,
    cutoff_game_time TIMESTAMP WITH TIME ZONE,
    raw_rows_deleted BIGINT
) AS $$
DECLARE
    v_deleted_rows BIGINT := 0;
BEGIN
    CREATE TEMP TABLE tmp_financial_ledger_compaction_report
    ON COMMIT DROP AS
    SELECT *
    FROM get_financial_ledger_compaction_report();

    IF p_dry_run THEN
        RETURN QUERY
        SELECT
            'dry_run'::TEXT,
            report.actor_id,
            report.is_bot,
            report.company_name,
            report.summary_game_date,
            report.summary_month,
            report.transaction_type,
            report.category,
            report.source_row_count,
            report.total_amount,
            report.first_game_date,
            report.last_game_date,
            report.first_created_at,
            report.last_created_at,
            report.retention_game_days,
            report.actor_game_current_time,
            report.cutoff_game_time,
            0::BIGINT
        FROM tmp_financial_ledger_compaction_report report
        ORDER BY
            report.summary_game_date ASC,
            report.is_bot ASC,
            report.actor_id ASC,
            report.transaction_type ASC,
            report.category ASC;
        RETURN;
    END IF;

    INSERT INTO financial_ledger_summary (
        actor_id,
        is_bot,
        summary_game_date,
        summary_month,
        transaction_type,
        category,
        source_row_count,
        total_amount,
        first_game_date,
        last_game_date,
        first_created_at,
        last_created_at,
        compacted_at
    )
    SELECT
        report.actor_id,
        report.is_bot,
        report.summary_game_date,
        report.summary_month,
        report.transaction_type,
        report.category,
        report.source_row_count,
        report.total_amount,
        report.first_game_date,
        report.last_game_date,
        report.first_created_at,
        report.last_created_at,
        NOW()
    FROM tmp_financial_ledger_compaction_report report
    ON CONFLICT ON CONSTRAINT financial_ledger_summary_pkey DO UPDATE
    SET summary_month = EXCLUDED.summary_month,
        source_row_count = EXCLUDED.source_row_count,
        total_amount = EXCLUDED.total_amount,
        first_game_date = EXCLUDED.first_game_date,
        last_game_date = EXCLUDED.last_game_date,
        first_created_at = EXCLUDED.first_created_at,
        last_created_at = EXCLUDED.last_created_at,
        compacted_at = EXCLUDED.compacted_at;

    DELETE FROM financial_ledger raw
    USING (
        SELECT DISTINCT
            report.actor_id,
            report.is_bot,
            report.cutoff_game_time
        FROM tmp_financial_ledger_compaction_report report
    ) cutoff
    WHERE (
        (NOT cutoff.is_bot AND raw.user_id = cutoff.actor_id)
        OR
        (cutoff.is_bot AND raw.ai_competitor_id = cutoff.actor_id)
    )
    AND raw.game_date < cutoff.cutoff_game_time;
    GET DIAGNOSTICS v_deleted_rows = ROW_COUNT;

    RETURN QUERY
    SELECT
        'compacted'::TEXT,
        report.actor_id,
        report.is_bot,
        report.company_name,
        report.summary_game_date,
        report.summary_month,
        report.transaction_type,
        report.category,
        report.source_row_count,
        report.total_amount,
        report.first_game_date,
        report.last_game_date,
        report.first_created_at,
        report.last_created_at,
        report.retention_game_days,
        report.actor_game_current_time,
        report.cutoff_game_time,
        v_deleted_rows
    FROM tmp_financial_ledger_compaction_report report
    ORDER BY
        report.summary_game_date ASC,
        report.is_bot ASC,
        report.actor_id ASC,
        report.transaction_type ASC,
        report.category ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;


GRANT SELECT ON financial_ledger_summary TO authenticated, anon, service_role;

REVOKE ALL ON FUNCTION get_financial_ledger_compaction_report() FROM PUBLIC;
REVOKE ALL ON FUNCTION compact_financial_ledger(BOOLEAN) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION get_financial_ledger_compaction_report() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION compact_financial_ledger(BOOLEAN) TO service_role;

COMMENT ON TABLE financial_ledger_summary IS
'Daily actor-level summary buckets for compacted financial_ledger history. Phase 15 foundation keeps raw ledger retention actor-relative in game days.';

COMMENT ON FUNCTION get_financial_ledger_compaction_report() IS
'Dry-run report for Phase 15 ledger compaction. Groups eligible historical financial_ledger rows by actor, game date, transaction type, and category using actor-relative game-day retention.';

COMMENT ON FUNCTION compact_financial_ledger(BOOLEAN) IS
'Compacts financial_ledger into financial_ledger_summary. Defaults to dry-run mode; destructive deletion only occurs when called with FALSE.';
