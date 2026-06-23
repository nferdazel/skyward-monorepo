-- Migration 103: Drop dead database objects and run compaction

-- Part 1: Drop dead table
DROP TABLE IF EXISTS financial_snapshots CASCADE;

-- Part 2: Drop dead columns from users
ALTER TABLE users DROP COLUMN IF EXISTS password_hash;
ALTER TABLE users DROP COLUMN IF EXISTS credit_score_updated_at;

-- Part 3: Drop 11 dead functions
DROP FUNCTION IF EXISTS calculate_casm_rasm(UUID, INT);
DROP FUNCTION IF EXISTS calculate_distance(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION);
DROP FUNCTION IF EXISTS check_debt_covenants(UUID);
DROP FUNCTION IF EXISTS ensure_world_current(UUID);
DROP FUNCTION IF EXISTS process_all_bots_simulation();
DROP FUNCTION IF EXISTS process_all_bots_simulation_segment(TIMESTAMPTZ, UUID);
DROP FUNCTION IF EXISTS process_bot_simulation(UUID);
DROP FUNCTION IF EXISTS process_player_simulation_segment(UUID, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS register_company(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS trg_ai_competitor_bankruptcy();
DROP FUNCTION IF EXISTS trg_ai_competitor_respawn();

-- Part 4: Drop orphaned triggers
DROP TRIGGER IF EXISTS trg_ai_cash_change ON users;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'ai_competitors') THEN
    DROP TRIGGER IF EXISTS trg_ai_competitors_assign_active_season_id ON ai_competitors;
    DROP TRIGGER IF EXISTS trg_ai_competitor_bankruptcy ON ai_competitors;
    DROP TRIGGER IF EXISTS trg_ai_competitor_respawn ON ai_competitors;
  END IF;
END $$;

-- Part 5: Rename world_tick_scheduler_config → scheduler_config
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'world_tick_scheduler_config') THEN
    ALTER TABLE world_tick_scheduler_config RENAME TO scheduler_config;
  END IF;
END $$;

-- Part 6: Fix check constraint on financial_ledger_summary (expenses are negative)
ALTER TABLE financial_ledger_summary
  DROP CONSTRAINT IF EXISTS financial_ledger_summary_total_amount_check;

-- Part 7: Fix compaction functions (ai_competitors no longer exists)
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
            ON fl.user_id = ac.actor_id
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
            report.cutoff_game_time
        FROM tmp_financial_ledger_compaction_report report
    ) cutoff
    WHERE raw.user_id = cutoff.actor_id
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

GRANT EXECUTE ON FUNCTION get_financial_ledger_compaction_report() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION compact_financial_ledger(BOOLEAN) TO service_role;

-- Part 7: Run compaction on world_tick_log
SELECT * FROM compact_world_tick_log(false);

-- Part 8: Run compaction on financial_ledger
SELECT * FROM compact_financial_ledger(false);

-- Part 9: Schedule pg_cron jobs for future compaction
SELECT cron.schedule('skyward_tick_compaction', '0 3 * * *', 'SELECT * FROM compact_world_tick_log(false)');
SELECT cron.schedule('skyward_ledger_compaction', '0 4 * * 0', 'SELECT * FROM compact_financial_ledger(false)');
