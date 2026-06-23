-- 1. Create bank_accounts table
CREATE TABLE IF NOT EXISTS bank_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_type VARCHAR(20) NOT NULL DEFAULT 'checking'
        CHECK (account_type IN ('checking', 'savings')),
    balance NUMERIC(20, 2) NOT NULL DEFAULT 0.00,
    interest_rate NUMERIC(6, 4) DEFAULT 0.00,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, account_type)
);

-- 2. Create bank_transactions table
CREATE TABLE IF NOT EXISTS bank_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES bank_accounts(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    transaction_type VARCHAR(20) NOT NULL
        CHECK (transaction_type IN ('deposit', 'withdrawal', 'transfer', 'interest', 'fee', 'disbursement', 'payment')),
    amount NUMERIC(20, 2) NOT NULL,
    balance_after NUMERIC(20, 2) NOT NULL,
    description TEXT,
    reference_type VARCHAR(30),
    reference_id UUID,
    game_date TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS bank_transactions_user_date_idx ON bank_transactions(user_id, game_date DESC);
CREATE INDEX IF NOT EXISTS bank_transactions_account_idx ON bank_transactions(account_id, created_at DESC);

-- 3. Seed checking accounts for existing users
INSERT INTO bank_accounts (user_id, account_type, balance, interest_rate)
SELECT id, 'checking', cash, 0.00
FROM users
ON CONFLICT (user_id, account_type) DO NOTHING;

-- 4. Create sync trigger — keep bank_accounts.checking.balance in sync with users.cash
CREATE OR REPLACE FUNCTION sync_checking_balance()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE bank_accounts
    SET balance = NEW.cash, updated_at = NOW()
    WHERE user_id = NEW.id AND account_type = 'checking';
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_cash_to_bank ON users;
CREATE TRIGGER trg_sync_cash_to_bank
AFTER UPDATE OF cash ON users
FOR EACH ROW
EXECUTE FUNCTION sync_checking_balance();

-- 5. Create trigger for new users — auto-create checking account
CREATE OR REPLACE FUNCTION create_default_bank_account()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO bank_accounts (user_id, account_type, balance, interest_rate)
    VALUES (NEW.id, 'checking', NEW.cash, 0.00)
    ON CONFLICT (user_id, account_type) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_create_bank_account ON users;
CREATE TRIGGER trg_create_bank_account
AFTER INSERT ON users
FOR EACH ROW
EXECUTE FUNCTION create_default_bank_account();

-- 6. RLS policies
ALTER TABLE bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE bank_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bank_accounts_select_own ON bank_accounts;
CREATE POLICY bank_accounts_select_own ON bank_accounts
    FOR SELECT TO authenticated
    USING (user_id = get_current_user_id());

DROP POLICY IF EXISTS bank_transactions_select_own ON bank_transactions;
CREATE POLICY bank_transactions_select_own ON bank_transactions
    FOR SELECT TO authenticated
    USING (user_id = get_current_user_id());

-- 7. Grants
REVOKE ALL ON bank_accounts FROM PUBLIC;
REVOKE ALL ON bank_transactions FROM PUBLIC;
GRANT SELECT ON bank_accounts TO authenticated;
GRANT SELECT ON bank_transactions TO authenticated;
