-- ============================================================================
-- Migration 131: Compaction System — Fix world_tick_log, add bank_transactions
-- ============================================================================
-- Problem:
--   1. compact_world_tick_log is broken — it calls get_world_tick_log_compaction_report()
--      which was rewritten in m129 to return (metric text, value text) instead of
--      the rich compaction schema the function depends on.
--   2. No compaction exists for bank_transactions (growing indefinitely).
--   3. Broken cron jobs: skyward_ledger_compaction (function dropped in m128),
--      skyward_tick_compaction (redundant duplicate).
--
-- Fix:
--   1. Remove broken/duplicate cron jobs
--   2. Rewrite compact_world_tick_log to work independently
--   3. Create bank_transaction_daily_summary + bank_transactions_archive tables
--   4. Create compact_bank_transactions function
--   5. Add config entry for bank txn retention
--   6. Schedule new cron job
-- ============================================================================

BEGIN;

-- ============================================================================
-- Part 1: Remove Broken/Duplicate Cron Jobs
-- ============================================================================

-- Remove broken financial_ledger compaction (function was dropped in m128)
DO $$ BEGIN PERFORM cron.unschedule('skyward_ledger_compaction'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- Remove duplicate world_tick_log compaction (skyward_tick_compaction is
-- redundant with skyward_compact_world_tick_log)
DO $$ BEGIN PERFORM cron.unschedule('skyward_tick_compaction'); EXCEPTION WHEN OTHERS THEN NULL; END $$;


-- ============================================================================
-- Part 2: Fix compact_world_tick_log
-- ============================================================================
-- The current function is broken because it calls
-- get_world_tick_log_compaction_report() which now returns (metric text, value text)
-- instead of the rich compaction schema the function depends on. Rewrite to work independently.

DROP FUNCTION IF EXISTS public.compact_world_tick_log(BOOLEAN) CASCADE;

CREATE OR REPLACE FUNCTION public.compact_world_tick_log(p_dry_run BOOLEAN DEFAULT TRUE)
RETURNS TABLE(action TEXT, detail TEXT, row_count BIGINT)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
DECLARE
    v_retention_days INT;
    v_cutoff TIMESTAMPTZ;
    v_summarized BIGINT := 0;
    v_deleted BIGINT := 0;
BEGIN
    v_retention_days := COALESCE(get_config_int('world_tick_log_raw_real_days'), 7);
    v_cutoff := NOW() - (v_retention_days || ' days')::INTERVAL;

    -- Step 1: Upsert daily summaries from old raw rows
    IF NOT p_dry_run THEN
        INSERT INTO world_tick_daily_summary (
            season_id, summary_date, status, source_row_count,
            first_started_at, last_finished_at,
            first_game_time_before, last_game_time_after,
            total_ticks_processed, total_real_seconds_processed,
            total_game_seconds_processed, total_players_processed,
            total_bots_processed, latest_message
        )
        SELECT
            season_id,
            (started_at AT TIME ZONE 'UTC')::DATE AS summary_date,
            status,
            COUNT(*),
            MIN(started_at),
            MAX(finished_at),
            MIN(game_time_before),
            MAX(game_time_after),
            SUM(ticks_processed),
            SUM(real_seconds_processed),
            SUM(game_seconds_processed),
            SUM(players_processed),
            SUM(bots_processed),
            (ARRAY_AGG(message ORDER BY started_at DESC))[1]
        FROM world_tick_log
        WHERE started_at < v_cutoff
        GROUP BY season_id, (started_at AT TIME ZONE 'UTC')::DATE, status
        ON CONFLICT (season_id, summary_date, status)
        DO UPDATE SET
            source_row_count = world_tick_daily_summary.source_row_count + EXCLUDED.source_row_count,
            last_finished_at = GREATEST(world_tick_daily_summary.last_finished_at, EXCLUDED.last_finished_at),
            last_game_time_after = GREATEST(world_tick_daily_summary.last_game_time_after, EXCLUDED.last_game_time_after),
            total_ticks_processed = world_tick_daily_summary.total_ticks_processed + EXCLUDED.total_ticks_processed,
            total_real_seconds_processed = world_tick_daily_summary.total_real_seconds_processed + EXCLUDED.total_real_seconds_processed,
            total_game_seconds_processed = world_tick_daily_summary.total_game_seconds_processed + EXCLUDED.total_game_seconds_processed,
            total_players_processed = world_tick_daily_summary.total_players_processed + EXCLUDED.total_players_processed,
            total_bots_processed = world_tick_daily_summary.total_bots_processed + EXCLUDED.total_bots_processed,
            latest_message = EXCLUDED.latest_message,
            compacted_at = NOW();
    END IF;

    SELECT COUNT(*) INTO v_summarized FROM world_tick_log WHERE started_at < v_cutoff;
    action := 'summarize'; detail := 'Daily summary rows upserted'; row_count := v_summarized;
    RETURN NEXT;

    -- Step 2: Delete old raw rows
    IF NOT p_dry_run THEN
        DELETE FROM world_tick_log WHERE started_at < v_cutoff;
        GET DIAGNOSTICS v_deleted = ROW_COUNT;
    END IF;

    action := 'delete'; detail := 'Raw rows deleted'; row_count := v_deleted;
    RETURN NEXT;
END;
$$;


-- ============================================================================
-- Part 3a: bank_transaction_daily_summary table
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.bank_transaction_daily_summary (
    user_id           UUID NOT NULL,
    game_date         DATE NOT NULL,
    ifrs_category     VARCHAR(30) NOT NULL,
    ifrs_subcategory  VARCHAR(50) NOT NULL,
    transaction_type  VARCHAR(20) NOT NULL,
    transaction_count BIGINT NOT NULL DEFAULT 0,
    total_amount      NUMERIC(20,2) NOT NULL DEFAULT 0.00,
    total_debits      NUMERIC(20,2) NOT NULL DEFAULT 0.00,
    total_credits     NUMERIC(20,2) NOT NULL DEFAULT 0.00,
    first_balance     NUMERIC(20,2),
    last_balance      NUMERIC(20,2),
    first_game_date   TIMESTAMPTZ,
    last_game_date    TIMESTAMPTZ,
    compacted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, game_date, ifrs_category, ifrs_subcategory, transaction_type)
);

CREATE INDEX IF NOT EXISTS idx_bt_daily_summary_date ON bank_transaction_daily_summary(game_date);
CREATE INDEX IF NOT EXISTS idx_bt_daily_summary_user ON bank_transaction_daily_summary(user_id, game_date);

ALTER TABLE bank_transaction_daily_summary ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Bank txn daily summary viewable by owner" ON bank_transaction_daily_summary
    FOR SELECT TO authenticated USING (user_id = public.get_current_user_id());
GRANT SELECT ON bank_transaction_daily_summary TO authenticated;


-- ============================================================================
-- Part 3b: bank_transactions_archive table
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.bank_transactions_archive (
    id                UUID NOT NULL,
    account_id        UUID,
    user_id           UUID NOT NULL,
    transaction_type  VARCHAR(20) NOT NULL,
    amount            NUMERIC(20,2) NOT NULL,
    balance_after     NUMERIC(20,2) NOT NULL,
    description       TEXT,
    reference_type    VARCHAR(30),
    reference_id      UUID,
    game_date         TIMESTAMPTZ,
    created_at        TIMESTAMPTZ,
    ifrs_category     VARCHAR(30),
    ifrs_subcategory  VARCHAR(50),
    cost_center_type  VARCHAR(20),
    cost_center_id    UUID,
    archived_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_bt_archive_user_date ON bank_transactions_archive(user_id, game_date);
CREATE INDEX IF NOT EXISTS idx_bt_archive_ifrs ON bank_transactions_archive(user_id, ifrs_category, game_date);

ALTER TABLE bank_transactions_archive ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Bank txn archive viewable by owner" ON bank_transactions_archive
    FOR SELECT TO authenticated USING (user_id = public.get_current_user_id());
GRANT SELECT ON bank_transactions_archive TO authenticated;


-- ============================================================================
-- Part 3c: compact_bank_transactions function
-- ============================================================================

CREATE OR REPLACE FUNCTION public.compact_bank_transactions(p_dry_run BOOLEAN DEFAULT TRUE)
RETURNS TABLE(action TEXT, detail TEXT, row_count BIGINT)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
DECLARE
    v_retention_days INT;
    v_cutoff_date DATE;
    v_archived BIGINT := 0;
    v_summarized BIGINT := 0;
    v_deleted BIGINT := 0;
BEGIN
    v_retention_days := COALESCE(get_config_int('bank_txn_raw_retention_days'), 30);
    v_cutoff_date := (NOW() - (v_retention_days || ' days')::INTERVAL)::DATE;

    -- Step 1: Archive old raw transactions
    IF NOT p_dry_run THEN
        INSERT INTO bank_transactions_archive (
            id, account_id, user_id, transaction_type, amount, balance_after,
            description, reference_type, reference_id, game_date, created_at,
            ifrs_category, ifrs_subcategory, cost_center_type, cost_center_id
        )
        SELECT id, account_id, user_id, transaction_type, amount, balance_after,
               description, reference_type, reference_id, game_date, created_at,
               ifrs_category, ifrs_subcategory, cost_center_type, cost_center_id
        FROM bank_transactions
        WHERE game_date < v_cutoff_date;
        GET DIAGNOSTICS v_archived = ROW_COUNT;
    ELSE
        SELECT COUNT(*) INTO v_archived FROM bank_transactions WHERE game_date < v_cutoff_date;
    END IF;

    action := 'archive'; detail := 'Rows moved to archive'; row_count := v_archived;
    RETURN NEXT;

    -- Step 2: Generate/update daily summaries
    IF NOT p_dry_run THEN
        INSERT INTO bank_transaction_daily_summary (
            user_id, game_date, ifrs_category, ifrs_subcategory, transaction_type,
            transaction_count, total_amount, total_debits, total_credits,
            first_balance, last_balance, first_game_date, last_game_date
        )
        SELECT
            user_id,
            (game_date AT TIME ZONE 'UTC')::DATE,
            COALESCE(ifrs_category, 'uncategorized'),
            COALESCE(ifrs_subcategory, 'uncategorized'),
            transaction_type,
            COUNT(*),
            SUM(amount),
            COALESCE(SUM(amount) FILTER (WHERE amount < 0), 0),
            COALESCE(SUM(amount) FILTER (WHERE amount > 0), 0),
            (ARRAY_AGG(balance_after ORDER BY game_date ASC))[1],
            (ARRAY_AGG(balance_after ORDER BY game_date DESC))[1],
            MIN(game_date),
            MAX(game_date)
        FROM bank_transactions
        WHERE game_date < v_cutoff_date
        GROUP BY user_id, (game_date AT TIME ZONE 'UTC')::DATE,
                 COALESCE(ifrs_category, 'uncategorized'),
                 COALESCE(ifrs_subcategory, 'uncategorized'),
                 transaction_type
        ON CONFLICT (user_id, game_date, ifrs_category, ifrs_subcategory, transaction_type)
        DO UPDATE SET
            transaction_count = bank_transaction_daily_summary.transaction_count + EXCLUDED.transaction_count,
            total_amount = bank_transaction_daily_summary.total_amount + EXCLUDED.total_amount,
            total_debits = bank_transaction_daily_summary.total_debits + EXCLUDED.total_debits,
            total_credits = bank_transaction_daily_summary.total_credits + EXCLUDED.total_credits,
            last_balance = EXCLUDED.last_balance,
            last_game_date = GREATEST(bank_transaction_daily_summary.last_game_date, EXCLUDED.last_game_date),
            compacted_at = NOW();
        GET DIAGNOSTICS v_summarized = ROW_COUNT;
    ELSE
        SELECT COUNT(DISTINCT (user_id, (game_date AT TIME ZONE 'UTC')::DATE,
                      COALESCE(ifrs_category, 'uncategorized'),
                      COALESCE(ifrs_subcategory, 'uncategorized'),
                      transaction_type))
        INTO v_summarized
        FROM bank_transactions WHERE game_date < v_cutoff_date;
    END IF;

    action := 'summarize'; detail := 'Daily summary rows upserted'; row_count := v_summarized;
    RETURN NEXT;

    -- Step 3: Delete archived rows from main table
    IF NOT p_dry_run THEN
        DELETE FROM bank_transactions WHERE game_date < v_cutoff_date;
        GET DIAGNOSTICS v_deleted = ROW_COUNT;
    END IF;

    action := 'delete'; detail := 'Raw rows deleted from main table'; row_count := v_deleted;
    RETURN NEXT;
END;
$$;


-- ============================================================================
-- Part 4: Add Config Entry
-- ============================================================================

INSERT INTO game_config (key, value, category, unit, description)
VALUES ('bank_txn_raw_retention_days', '30', 'ops', 'game_days',
        'Retention for raw bank transactions before compaction')
ON CONFLICT (key) DO NOTHING;


-- ============================================================================
-- Part 5: Schedule Cron Jobs
-- ============================================================================

-- Bank transactions compaction: daily at 03:30 UTC
SELECT cron.schedule(
    'skyward_compact_bank_transactions',
    '30 3 * * *',
    $$SELECT compact_bank_transactions(false)$$
);

-- World tick log compaction: daily at 03:00 UTC
-- The existing skyward_compact_world_tick_log job calls the now-fixed function
-- Verify it exists, re-create if needed
DO $outer$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'skyward_compact_world_tick_log') THEN
        PERFORM cron.schedule(
            'skyward_compact_world_tick_log',
            '0 3 * * *',
            'SELECT compact_world_tick_log(false)'
        );
    END IF;
END;
$outer$;


-- ============================================================================
-- Part 6: Run Compaction (backfill existing data)
-- ============================================================================

-- Compact world_tick_log backlog
SELECT * FROM compact_world_tick_log(false);


COMMIT;


-- ============================================================================
-- Verification queries (run after commit)
-- ============================================================================

-- Verify broken cron jobs removed:
-- SELECT jobname FROM cron.job WHERE jobname IN ('skyward_ledger_compaction', 'skyward_tick_compaction');
-- Should return 0 rows

-- Verify new tables exist:
-- SELECT table_name FROM information_schema.tables
-- WHERE table_name IN ('bank_transaction_daily_summary', 'bank_transactions_archive');

-- Verify compact_bank_transactions dry run works:
-- SELECT * FROM compact_bank_transactions(true);

-- Verify compact_world_tick_log works:
-- SELECT * FROM compact_world_tick_log(true);

-- Verify cron jobs:
-- SELECT jobname, schedule, command FROM cron.job
-- WHERE jobname IN ('skyward_compact_bank_transactions', 'skyward_compact_world_tick_log');

-- Check row counts:
-- SELECT 'world_tick_log' AS tbl, COUNT(*) FROM world_tick_log
-- UNION ALL SELECT 'world_tick_daily_summary', COUNT(*) FROM world_tick_daily_summary
-- UNION ALL SELECT 'bank_transactions', COUNT(*) FROM bank_transactions
-- UNION ALL SELECT 'bank_transactions_archive', COUNT(*) FROM bank_transactions_archive;
