-- ============================================================================
-- FIX: Remove overly restrictive amount check constraint on financial_ledger
-- ============================================================================
-- The constraint `amount >= 0` prevented negative amounts for expenses.
-- Bot acquisition expenses use negative amounts which violated this constraint.
-- Revenue vs expense semantics are handled by the transaction_type column.
-- ============================================================================

ALTER TABLE financial_ledger DROP CONSTRAINT IF EXISTS financial_ledger_amount_check;
