-- ============================================================================
-- 137: delete_account() RPC
-- Permanently deletes the authenticated user and ALL related game data.
-- Auth user deletion is handled by the Edge Function (admin API).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.delete_account()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
BEGIN
    -- Resolve the current authenticated Skyward user
    v_user_id := require_current_user_id();

    -- ── Delete in dependency order (children before parents) ──

    -- 1. bank_transactions (FK: account_id → bank_accounts, user_id → users)
    DELETE FROM bank_transactions WHERE user_id = v_user_id;

    -- 2. bank_transactions_archive (has user_id, no FK constraint but belongs to user)
    DELETE FROM bank_transactions_archive WHERE user_id = v_user_id;

    -- 3. bank_transaction_daily_summary (has user_id)
    DELETE FROM bank_transaction_daily_summary WHERE user_id = v_user_id;

    -- 4. bank_accounts (FK: user_id → users)
    DELETE FROM bank_accounts WHERE user_id = v_user_id;

    -- 5. achievements (FK: user_id → users)
    DELETE FROM achievements WHERE user_id = v_user_id;

    -- 6. credit_score_history (FK: user_id → users)
    DELETE FROM credit_score_history WHERE user_id = v_user_id;

    -- 7. credit_scores (FK: user_id → users, PK is user_id)
    DELETE FROM credit_scores WHERE user_id = v_user_id;

    -- 8. financial_ledger_summary (actor_id maps to user id, no FK)
    DELETE FROM financial_ledger_summary WHERE actor_id = v_user_id;

    -- 9. financial_ledger (FK: user_id → users)
    DELETE FROM financial_ledger WHERE user_id = v_user_id;

    -- 10. rank_history (has user_id, no FK constraint)
    DELETE FROM rank_history WHERE user_id = v_user_id;

    -- 11. route_assignments (FK: user_id → users, assigned_aircraft_id → fleet_aircraft)
    --    Must delete before fleet_aircraft due to FK reference
    DELETE FROM route_assignments WHERE user_id = v_user_id;

    -- 12. loans (FK: user_id → users, collateral_aircraft_id/fleet_aircraft_id → fleet_aircraft)
    --    Must delete before fleet_aircraft due to FK reference
    DELETE FROM loans WHERE user_id = v_user_id;

    -- 13. fleet_aircraft (FK: user_id → users)
    DELETE FROM fleet_aircraft WHERE user_id = v_user_id;

    -- 14. bot_profiles (FK: user_id → users ON DELETE CASCADE, but explicit is cleaner)
    DELETE FROM bot_profiles WHERE user_id = v_user_id;

    -- 15. Finally, the user row itself
    DELETE FROM users WHERE id = v_user_id;

    -- Auth user deletion is handled by the Edge Function after this returns
    RETURN TRUE;
END;
$$;

-- Lock down: only authenticated users can call it
REVOKE ALL ON FUNCTION public.delete_account() FROM public;
GRANT EXECUTE ON FUNCTION public.delete_account() TO authenticated;
