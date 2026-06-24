-- ============================================================================
-- Migration 139: Critical Fixes — delete_account, duplicate triggers, dead code
-- ============================================================================
-- Fix 1: delete_account() references dropped tables (financial_ledger_summary,
--         financial_ledger, rank_history). Rewrite without them.
-- Fix 2: Drop duplicate trigger trg_fleet_change on fleet_aircraft
-- Fix 3: Drop duplicate trigger trg_create_bank_account on users
-- Fix 4: trg_create_default_bank_account reads starting_cash from game_config
-- Fix 5: fleet_aircraft.acquisition_type CHECK must include 'finance'
-- Fix 6: Remove dead triggers, functions, and test functions
-- Fix 7: Enable RLS on game_config
-- Fix 8: Add missing CHECK constraints on users
-- Fix 9: Remove dead game_config entries
-- ============================================================================

BEGIN;


-- ============================================================================
-- Fix 1: Rewrite delete_account() — remove references to dropped tables
-- ============================================================================

CREATE OR REPLACE FUNCTION public.delete_account()
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := require_current_user_id();

    -- Delete in dependency order (children before parents)

    -- bank_transactions_archive (has user_id)
    DELETE FROM bank_transactions_archive WHERE user_id = v_user_id;

    -- bank_transaction_daily_summary (has user_id)
    DELETE FROM bank_transaction_daily_summary WHERE user_id = v_user_id;

    -- bank_transactions (FK: account_id → bank_accounts, user_id → users)
    DELETE FROM bank_transactions WHERE user_id = v_user_id;

    -- bank_accounts (FK: user_id → users)
    DELETE FROM bank_accounts WHERE user_id = v_user_id;

    -- achievements (FK: user_id → users)
    DELETE FROM achievements WHERE user_id = v_user_id;

    -- credit_score_history (FK: user_id → users)
    DELETE FROM credit_score_history WHERE user_id = v_user_id;

    -- credit_scores (FK: user_id → users, PK is user_id)
    DELETE FROM credit_scores WHERE user_id = v_user_id;

    -- route_assignments (FK: user_id → users, assigned_aircraft_id → fleet_aircraft)
    DELETE FROM route_assignments WHERE user_id = v_user_id;

    -- loans (FK: user_id → users, collateral_aircraft_id/fleet_aircraft_id → fleet_aircraft)
    DELETE FROM loans WHERE user_id = v_user_id;

    -- fleet_aircraft (FK: user_id → users)
    DELETE FROM fleet_aircraft WHERE user_id = v_user_id;

    -- bot_profiles (FK: user_id → users ON DELETE CASCADE, but explicit is cleaner)
    DELETE FROM bot_profiles WHERE user_id = v_user_id;

    -- Finally, the user row itself
    DELETE FROM users WHERE id = v_user_id;

    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_account() FROM public;
GRANT EXECUTE ON FUNCTION public.delete_account() TO authenticated;


-- ============================================================================
-- Fix 2: Remove duplicate trigger trg_fleet_change on fleet_aircraft
-- ============================================================================
-- This trigger is a duplicate of fleet_reconcile_net_worth (both fire on
-- INSERT/UPDATE/DELETE of fleet_aircraft and reconcile net_worth).
-- Drop the duplicate to avoid double-firing.

DROP TRIGGER IF EXISTS trg_fleet_change ON fleet_aircraft;


-- ============================================================================
-- Fix 3: Remove duplicate trigger trg_create_bank_account on users
-- ============================================================================
-- This trigger duplicates create_default_bank_account (both fire AFTER INSERT
-- on users and create a bank account). Drop the duplicate.

DROP TRIGGER IF EXISTS trg_create_bank_account ON users;


-- ============================================================================
-- Fix 4: Fix trg_create_default_bank_account to read from game_config
-- ============================================================================
-- The current version hardcodes 15000000.00. Should read from game_config.

CREATE OR REPLACE FUNCTION public.trg_create_default_bank_account()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_starting_cash NUMERIC;
BEGIN
    v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
    INSERT INTO bank_accounts (user_id, account_type, balance)
    VALUES (NEW.id, 'operating', v_starting_cash)
    ON CONFLICT (user_id, account_type) DO NOTHING;
    RETURN NEW;
END;
$$;


-- ============================================================================
-- Fix 5: Fix fleet_aircraft.acquisition_type CHECK to include 'finance'
-- ============================================================================
-- The CHECK constraint only allows 'purchase' and 'lease', but finance_aircraft
-- inserts with acquisition_type = 'finance'. This causes constraint violations.

ALTER TABLE fleet_aircraft DROP CONSTRAINT IF EXISTS user_fleet_acquisition_type_check;
ALTER TABLE fleet_aircraft DROP CONSTRAINT IF EXISTS fleet_aircraft_acquisition_type_check;
ALTER TABLE fleet_aircraft ADD CONSTRAINT fleet_aircraft_acquisition_type_check
    CHECK (acquisition_type IN ('purchase', 'lease', 'finance'));


-- ============================================================================
-- Fix 6: Remove dead triggers and functions
-- ============================================================================

-- Drop orphan trigger functions (not attached to any trigger)
DROP FUNCTION IF EXISTS trg_assign_active_season_id() CASCADE;
DROP FUNCTION IF EXISTS trg_set_acquired_game_date() CASCADE;

-- Drop dead functions
DROP FUNCTION IF EXISTS accrue_savings_interest(uuid, timestamptz) CASCADE;
DROP FUNCTION IF EXISTS bot_finance_aircraft(uuid, uuid, numeric, int) CASCADE;
DROP FUNCTION IF EXISTS deposit_to_savings(numeric) CASCADE;
DROP FUNCTION IF EXISTS withdraw_from_savings(numeric) CASCADE;
DROP FUNCTION IF EXISTS reconcile_all_net_worths() CASCADE;

-- Drop test functions
DROP FUNCTION IF EXISTS test_121() CASCADE;
DROP FUNCTION IF EXISTS test_func() CASCADE;
DROP FUNCTION IF EXISTS test_func_125() CASCADE;


-- ============================================================================
-- Fix 7: Enable RLS on game_config
-- ============================================================================
-- game_config has GRANT SELECT to authenticated but no RLS policy.
-- Enable RLS with a permissive SELECT policy.

ALTER TABLE game_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Game config viewable by everyone" ON game_config
    FOR SELECT TO authenticated USING (true);


-- ============================================================================
-- Fix 8: Add missing CHECK constraints on users
-- ============================================================================

-- users.operational_status should only allow 'Active' or 'Bankrupt'
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_operational_status_check;
ALTER TABLE users ADD CONSTRAINT users_operational_status_check
    CHECK (operational_status IN ('Active', 'Bankrupt'));

-- users.actor_type should only allow 'REAL' or 'AI'
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_actor_type_check;
ALTER TABLE users ADD CONSTRAINT users_actor_type_check
    CHECK (actor_type IN ('REAL', 'AI'));


-- ============================================================================
-- Fix 9: Remove dead game_config entries
-- ============================================================================

DELETE FROM game_config WHERE key IN (
    'default_weekly_flights',
    'route_base_load_factor'
);


COMMIT;
