-- Migration 118: Fix over-granted permissions and financial ledger sign convention
-- Addresses 3 remaining issues from backend re-audit

BEGIN;

-- ============================================================
-- Fix 1: Revoke over-granted table permissions
-- 7 tables have full CRUD for authenticated but RLS only allows SELECT
-- ============================================================

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON public.achievements FROM authenticated;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON public.bank_accounts FROM authenticated;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON public.bank_transactions FROM authenticated;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON public.credit_score_history FROM authenticated;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON public.credit_scores FROM authenticated;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON public.loans FROM authenticated;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON public.rank_history FROM authenticated;

-- ============================================================
-- Fix 2: Revoke bot/admin function access from authenticated
-- These functions should only be callable by service_role
-- ============================================================

REVOKE EXECUTE ON FUNCTION bot_finance_aircraft(UUID, UUID, NUMERIC, INT) FROM authenticated;
REVOKE EXECUTE ON FUNCTION bot_take_loan(UUID, NUMERIC, INT) FROM authenticated;
REVOKE EXECUTE ON FUNCTION execute_bot_decisions() FROM authenticated;
REVOKE EXECUTE ON FUNCTION process_all_bots_simulation_to_time(TIMESTAMPTZ, UUID) FROM authenticated;
REVOKE EXECUTE ON FUNCTION generate_game_events(TIMESTAMPTZ) FROM authenticated;
REVOKE EXECUTE ON FUNCTION compact_financial_ledger(BOOLEAN) FROM authenticated;
REVOKE EXECUTE ON FUNCTION compact_world_tick_log(BOOLEAN) FROM authenticated;
REVOKE EXECUTE ON FUNCTION deactivate_expired_events(TIMESTAMPTZ) FROM authenticated;
REVOKE EXECUTE ON FUNCTION reconcile_all_net_worths() FROM authenticated;
REVOKE EXECUTE ON FUNCTION record_rank_snapshot(DATE) FROM authenticated;

-- ============================================================
-- Fix 4: Standardize financial ledger sign convention
-- All amounts should be POSITIVE. transaction_type indicates direction.
-- revenue = money in (positive)
-- expense = money out (positive, subtracted from cash in reports)
-- ============================================================

UPDATE financial_ledger SET amount = ABS(amount) WHERE amount < 0;

-- ============================================================
-- Verification queries (commented out - run manually if needed)
-- ============================================================

-- Verify no non-SELECT grants remain on restricted tables:
-- SELECT grantee, table_name, privilege_type 
-- FROM information_schema.table_privileges 
-- WHERE table_schema = 'public' AND grantee = 'authenticated' 
-- AND privilege_type NOT IN ('SELECT')
-- AND table_name NOT IN ('users');

-- Verify function grants revoked:
-- SELECT routine_name FROM information_schema.routine_privileges 
-- WHERE routine_schema = 'public' AND grantee = 'authenticated' 
-- AND routine_name IN ('bot_finance_aircraft', 'bot_take_loan', 'execute_bot_decisions');

-- Verify no negative amounts:
-- SELECT COUNT(*) FROM financial_ledger WHERE amount < 0;

COMMIT;
