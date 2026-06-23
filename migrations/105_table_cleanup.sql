-- Migration 105: Table audit and cleanup
-- Renames stale RLS policies, adds constraints, fixes FK ON DELETE behavior.
--
-- AUDIT FINDINGS (not fixed here, require code changes):
--   • take_loan() and repay_loan() do NOT write to bank_transactions.
--     deposit_to_savings() and withdraw_from_savings() DO write.
--   • process_aircraft_financing_payments() is defined but NOT called from
--     process_world_tick or process_player_simulation_to_time. Loan
--     financing payments are never processed during simulation.
--   • credit_score_history and rank_history both have 0 rows, but their
--     write paths (process_credit_at_day_boundary, record_rank_snapshot)
--     ARE wired correctly into the simulation loop.

-- ============================================================
-- 1. Rename stale RLS policies (left over from table renames)
-- ============================================================

ALTER POLICY user_fleet_select_own ON fleet_aircraft
    RENAME TO fleet_aircraft_select_own;

ALTER POLICY user_routes_select_own ON route_assignments
    RENAME TO route_assignments_select_own;

-- ============================================================
-- 2. Make financial_ledger.user_id NOT NULL
--    (verified: 0 rows have NULL user_id)
-- ============================================================

ALTER TABLE financial_ledger ALTER COLUMN user_id SET NOT NULL;

-- ============================================================
-- 3. Add CHECK constraint on financial_ledger.transaction_type
-- ============================================================

ALTER TABLE financial_ledger
    DROP CONSTRAINT IF EXISTS financial_ledger_transaction_type_check;

ALTER TABLE financial_ledger
    ADD CONSTRAINT financial_ledger_transaction_type_check
    CHECK (transaction_type IN ('revenue', 'expense'));

-- ============================================================
-- 4. Fix FK ON DELETE behavior
--    Pattern: user_id FKs → CASCADE (user-owned data deleted with user)
--    Pattern: season_id FKs on tick tables → CASCADE
-- ============================================================

-- achievements.user_id → users: CASCADE
ALTER TABLE achievements
    DROP CONSTRAINT achievements_user_id_fkey,
    ADD CONSTRAINT achievements_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- credit_score_history.user_id → users: CASCADE
ALTER TABLE credit_score_history
    DROP CONSTRAINT credit_score_history_user_id_fkey,
    ADD CONSTRAINT credit_score_history_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- loans.user_id → users: CASCADE
ALTER TABLE loans
    DROP CONSTRAINT loans_user_id_fkey,
    ADD CONSTRAINT loans_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- world_tick_daily_summary.season_id → season_clock: CASCADE
ALTER TABLE world_tick_daily_summary
    DROP CONSTRAINT world_tick_daily_summary_season_id_fkey,
    ADD CONSTRAINT world_tick_daily_summary_season_id_fkey
    FOREIGN KEY (season_id) REFERENCES season_clock(id) ON DELETE CASCADE;

-- world_tick_log.season_id → season_clock: CASCADE
ALTER TABLE world_tick_log
    DROP CONSTRAINT world_tick_log_season_id_fkey,
    ADD CONSTRAINT world_tick_log_season_id_fkey
    FOREIGN KEY (season_id) REFERENCES season_clock(id) ON DELETE CASCADE;

-- ============================================================
-- 5. Rename stale FK constraint names (left over from table renames)
--    These still carry the old "user_fleet"/"user_routes" prefix.
-- ============================================================

-- fleet_aircraft FKs
ALTER TABLE fleet_aircraft
    RENAME CONSTRAINT user_fleet_aircraft_model_id_fkey
    TO fleet_aircraft_aircraft_model_id_fkey;

ALTER TABLE fleet_aircraft
    RENAME CONSTRAINT user_fleet_user_id_fkey
    TO fleet_aircraft_user_id_fkey;

-- route_assignments FKs
ALTER TABLE route_assignments
    RENAME CONSTRAINT user_routes_assigned_aircraft_id_fkey
    TO route_assignments_assigned_aircraft_id_fkey;

ALTER TABLE route_assignments
    RENAME CONSTRAINT user_routes_destination_iata_fkey
    TO route_assignments_destination_iata_fkey;

ALTER TABLE route_assignments
    RENAME CONSTRAINT user_routes_origin_iata_fkey
    TO route_assignments_origin_iata_fkey;

ALTER TABLE route_assignments
    RENAME CONSTRAINT user_routes_user_id_fkey
    TO route_assignments_user_id_fkey;
