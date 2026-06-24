-- Migration 122: Savings by default — all money in savings account
BEGIN;

-- ============================================================
-- 1. Change default account creation from checking to savings
-- ============================================================
CREATE OR REPLACE FUNCTION public.trg_create_default_bank_account()
RETURNS trigger
LANGUAGE plpgsql VOLATILE AS $function$
BEGIN
    INSERT INTO bank_accounts (user_id, account_type, balance, interest_rate)
    VALUES (NEW.id, 'savings', NEW.cash, 0.01)
    ON CONFLICT (user_id, account_type) DO UPDATE SET balance = NEW.cash;
    RETURN NEW;
END;
$function$;

-- ============================================================
-- 2. Sync trigger now targets savings instead of checking
-- ============================================================
CREATE OR REPLACE FUNCTION public.trg_sync_checking_balance()
RETURNS trigger
LANGUAGE plpgsql VOLATILE AS $function$
BEGIN
    UPDATE bank_accounts SET balance = NEW.cash, updated_at = NOW()
    WHERE user_id = NEW.id AND account_type = 'savings';
    RETURN NEW;
END;
$function$;

-- ============================================================
-- 3. Rename ensure_checking_account → ensure_savings_account
--    (keep old name as alias for backward compat)
-- ============================================================
CREATE OR REPLACE FUNCTION public.ensure_checking_account(p_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE v_account_id UUID;
BEGIN
    INSERT INTO bank_accounts (user_id, account_type, balance, interest_rate)
    VALUES (p_user_id, 'savings', (SELECT cash FROM users WHERE id = p_user_id), 0.01)
    ON CONFLICT (user_id, account_type) DO NOTHING;
    SELECT id INTO v_account_id FROM bank_accounts
    WHERE user_id = p_user_id AND account_type = 'savings';
    RETURN v_account_id;
END;
$function$;

-- ============================================================
-- 4. Migrate existing checking accounts to savings
-- ============================================================
-- First, delete orphan savings accounts for users who have both checking AND savings
DELETE FROM bank_transactions WHERE account_id IN (
    SELECT ba2.id FROM bank_accounts ba2
    WHERE ba2.account_type = 'savings'
    AND EXISTS (
        SELECT 1 FROM bank_accounts ba1
        WHERE ba1.user_id = ba2.user_id AND ba1.account_type = 'checking'
    )
);
DELETE FROM bank_accounts ba2
WHERE ba2.account_type = 'savings'
AND EXISTS (
    SELECT 1 FROM bank_accounts ba1
    WHERE ba1.user_id = ba2.user_id AND ba1.account_type = 'checking'
);

-- Now convert all remaining checking to savings
UPDATE bank_accounts SET account_type = 'savings', interest_rate = 0.01
WHERE account_type = 'checking';

COMMIT;
