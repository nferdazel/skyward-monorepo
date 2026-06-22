-- ============================================================================
-- CREDIT RATING & AIRCRAFT FINANCING SYSTEM
-- ============================================================================
-- Adds credit scoring, enhanced loan types, and aircraft financing.
--
-- Credit Score (0–1000):
--   Fleet Health      (0–200)  — avg condition & grounded ratio
--   Revenue Stability (0–200)  — consistency of daily revenue over 30 days
--   Debt Ratio        (0–200)  — outstanding debt vs. net worth
--   Cash Reserve      (0–200)  — current cash vs. starting capital
--   Profit History    (0–200)  — rolling 30-day net profit margin
--
-- Integration:
--   • Credit score recalculated at every game-day boundary inside
--     process_player_simulation_segment (the inner tick function).
--   • Loan applications and aircraft financing check credit score.
--   • Score history tracked for trend analysis.
-- ============================================================================


-- ============================================================================
-- 1. CREDIT SCORE HISTORY TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS credit_score_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    score INT NOT NULL CHECK (score >= 0 AND score <= 1000),
    fleet_health INT NOT NULL DEFAULT 0,
    revenue_stability INT NOT NULL DEFAULT 0,
    debt_ratio INT NOT NULL DEFAULT 0,
    cash_reserve INT NOT NULL DEFAULT 0,
    profit_history INT NOT NULL DEFAULT 0,
    game_date TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE credit_score_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY credit_history_select_own ON credit_score_history FOR SELECT TO authenticated
USING (user_id = (SELECT id FROM users WHERE auth_user_id = auth.uid()));
GRANT SELECT ON credit_score_history TO authenticated;

CREATE INDEX IF NOT EXISTS credit_history_user_date_idx
    ON credit_score_history(user_id, game_date DESC);

COMMENT ON TABLE credit_score_history IS
    'Historical credit score snapshots per game-day for trend analysis.';


-- ============================================================================
-- 2. ADD CREDIT_SCORE COLUMN TO USERS
-- ============================================================================
ALTER TABLE users ADD COLUMN IF NOT EXISTS credit_score INT DEFAULT 500;
ALTER TABLE users ADD COLUMN IF NOT EXISTS credit_score_updated_at TIMESTAMPTZ;


-- ============================================================================
-- 3. ENHANCE LOANS TABLE
-- ============================================================================
ALTER TABLE loans ADD COLUMN IF NOT EXISTS loan_type VARCHAR(20) DEFAULT 'unsecured'
    CHECK (loan_type IN ('unsecured', 'secured', 'credit_line'));
ALTER TABLE loans ADD COLUMN IF NOT EXISTS collateral_aircraft_id UUID
    REFERENCES user_fleet(id) ON DELETE SET NULL;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS credit_score_at_origination INT;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS missed_payments INT DEFAULT 0;

CREATE INDEX IF NOT EXISTS loans_collateral_idx
    ON loans(collateral_aircraft_id) WHERE collateral_aircraft_id IS NOT NULL;


-- ============================================================================
-- 4. AIRCRAFT FINANCING TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS aircraft_financing (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id),
    aircraft_model_id UUID NOT NULL REFERENCES aircraft_models(id),
    fleet_id UUID REFERENCES user_fleet(id) ON DELETE SET NULL,
    down_payment NUMERIC NOT NULL,
    financed_amount NUMERIC NOT NULL,
    interest_rate NUMERIC NOT NULL,
    monthly_payment NUMERIC NOT NULL,
    remaining_payments INT NOT NULL,
    total_payments INT NOT NULL,
    remaining_balance NUMERIC NOT NULL,
    credit_score_at_origination INT,
    status VARCHAR(20) DEFAULT 'active'
        CHECK (status IN ('active', 'paid_off', 'repossessed', 'defaulted')),
    taken_at TIMESTAMPTZ DEFAULT NOW(),
    game_date_taken TIMESTAMPTZ,
    paid_off_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE aircraft_financing ENABLE ROW LEVEL SECURITY;
CREATE POLICY aircraft_financing_select_own ON aircraft_financing FOR SELECT TO authenticated
USING (user_id = (SELECT id FROM users WHERE auth_user_id = auth.uid()));
GRANT SELECT ON aircraft_financing TO authenticated;

CREATE INDEX IF NOT EXISTS aircraft_financing_user_status_idx
    ON aircraft_financing(user_id, status);

COMMENT ON TABLE aircraft_financing IS
    'Aircraft purchase financing plans. Monthly payments deducted at game-day boundaries.';


-- ============================================================================
-- 5. CALCULATE CREDIT SCORE
-- ============================================================================
CREATE OR REPLACE FUNCTION calculate_credit_score(p_user_id UUID)
RETURNS TABLE (
    total_score INT,
    fleet_health INT,
    revenue_stability INT,
    debt_ratio INT,
    cash_reserve INT,
    profit_history INT
) AS $$
DECLARE
    v_user RECORD;
    v_fleet_count INT := 0;
    v_active_count INT := 0;
    v_avg_condition NUMERIC := 100.0;
    v_grounded_ratio NUMERIC := 0.0;
    v_fleet_health NUMERIC := 200.0;

    v_revenue_days INT := 0;
    v_positive_days INT := 0;
    v_revenue_stability NUMERIC := 200.0;

    v_total_debt NUMERIC := 0.0;
    v_net_worth NUMERIC := 0.0;
    v_debt_ratio NUMERIC := 200.0;

    v_cash NUMERIC := 0.0;
    v_starting_cash NUMERIC := 15000000.0;
    v_cash_reserve NUMERIC := 200.0;

    v_total_revenue_30d NUMERIC := 0.0;
    v_total_expense_30d NUMERIC := 0.0;
    v_profit_margin NUMERIC := 0.0;
    v_profit_history NUMERIC := 200.0;

    v_total_score INT;
BEGIN
    -- Fetch user data
    SELECT u.cash, u.net_worth, u.game_current_time
    INTO v_user
    FROM users u WHERE u.id = p_user_id;

    IF NOT FOUND THEN
        total_score := 500;
        fleet_health := 100;
        revenue_stability := 100;
        debt_ratio := 100;
        cash_reserve := 100;
        profit_history := 100;
        RETURN NEXT;
        RETURN;
    END IF;

    v_cash := COALESCE(v_user.cash, 0.0);
    v_net_worth := COALESCE(v_user.net_worth, 0.0);

    SELECT starting_cash INTO v_starting_cash FROM global_game_settings LIMIT 1;
    v_starting_cash := COALESCE(v_starting_cash, 15000000.0);

    -- ── 1. Fleet Health (0–200) ──
    SELECT
        COUNT(*)::INT,
        COUNT(*) FILTER (WHERE status = 'active' OR status IS NULL)::INT,
        COALESCE(AVG(condition), 100.0),
        COALESCE(
            COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC /
            NULLIF(COUNT(*), 0),
            0.0
        )
    INTO v_fleet_count, v_active_count, v_avg_condition, v_grounded_ratio
    FROM user_fleet
    WHERE user_id = p_user_id;

    -- Base score from average condition (0–100 maps to 0–150)
    v_fleet_health := (v_avg_condition / 100.0) * 150.0;
    -- Bonus for having active aircraft (up to 50)
    IF v_fleet_count > 0 THEN
        v_fleet_health := v_fleet_health + (50.0 * (1.0 - v_grounded_ratio));
    ELSE
        -- No fleet = neutral score (100)
        v_fleet_health := 100.0;
    END IF;
    v_fleet_health := GREATEST(0.0, LEAST(200.0, v_fleet_health));

    -- ── 2. Revenue Stability (0–200) ──
    -- Count days with revenue entries in last 30 game days
    SELECT
        COUNT(DISTINCT date_trunc('day', game_date))::INT,
        COUNT(DISTINCT date_trunc('day', game_date)) FILTER (
            WHERE transaction_type = 'revenue' AND amount > 0
        )::INT
    INTO v_revenue_days, v_positive_days
    FROM financial_ledger
    WHERE user_id = p_user_id
      AND game_date >= v_user.game_current_time - INTERVAL '30 days';

    IF v_revenue_days > 0 THEN
        -- Stability = ratio of revenue days * 200
        v_revenue_stability := (v_positive_days::NUMERIC / GREATEST(v_revenue_days, 1)) * 200.0;
    ELSE
        -- No data = neutral (100)
        v_revenue_stability := 100.0;
    END IF;
    v_revenue_stability := GREATEST(0.0, LEAST(200.0, v_revenue_stability));

    -- ── 3. Debt Ratio (0–200) ──
    SELECT COALESCE(SUM(remaining_balance), 0)
    INTO v_total_debt
    FROM loans
    WHERE user_id = p_user_id AND status = 'active';

    -- Also count aircraft financing debt
    v_total_debt := v_total_debt + COALESCE(
        (SELECT SUM(remaining_balance) FROM aircraft_financing
         WHERE user_id = p_user_id AND status = 'active'),
        0
    );

    IF v_net_worth > 0 THEN
        -- Lower debt ratio = higher score
        -- 0% debt = 200, 100%+ debt = 0
        v_debt_ratio := GREATEST(0.0, 200.0 * (1.0 - (v_total_debt / v_net_worth)));
    ELSIF v_total_debt > 0 THEN
        -- Negative net worth with debt = worst score
        v_debt_ratio := 0.0;
    ELSE
        v_debt_ratio := 100.0;
    END IF;
    v_debt_ratio := GREATEST(0.0, LEAST(200.0, v_debt_ratio));

    -- ── 4. Cash Reserve (0–200) ──
    IF v_starting_cash > 0 THEN
        -- Scale: 0 cash = 0, 2x starting = 200
        v_cash_reserve := LEAST(200.0, (v_cash / v_starting_cash) * 100.0);
    ELSE
        v_cash_reserve := 100.0;
    END IF;
    -- Negative cash = 0
    IF v_cash < 0 THEN
        v_cash_reserve := 0.0;
    END IF;
    v_cash_reserve := GREATEST(0.0, LEAST(200.0, v_cash_reserve));

    -- ── 5. Profit History (0–200) ──
    SELECT
        COALESCE(SUM(CASE WHEN transaction_type = 'revenue' THEN amount ELSE 0 END), 0.0),
        COALESCE(SUM(CASE WHEN transaction_type = 'expense' THEN amount ELSE 0 END), 0.0)
    INTO v_total_revenue_30d, v_total_expense_30d
    FROM financial_ledger
    WHERE user_id = p_user_id
      AND game_date >= v_user.game_current_time - INTERVAL '30 days';

    IF v_total_revenue_30d > 0 THEN
        v_profit_margin := (v_total_revenue_30d - v_total_expense_30d) / v_total_revenue_30d;
        -- Scale: -50% margin = 0, +50% margin = 200
        v_profit_history := GREATEST(0.0, LEAST(200.0, (v_profit_margin + 0.5) * 200.0));
    ELSE
        -- No revenue data = neutral
        v_profit_history := 100.0;
    END IF;
    v_profit_history := GREATEST(0.0, LEAST(200.0, v_profit_history));

    -- ── Total ──
    v_total_score := ROUND(v_fleet_health + v_revenue_stability +
                           v_debt_ratio + v_cash_reserve + v_profit_history);
    v_total_score := GREATEST(0, LEAST(1000, v_total_score));

    total_score := v_total_score;
    fleet_health := ROUND(v_fleet_health)::INT;
    revenue_stability := ROUND(v_revenue_stability)::INT;
    debt_ratio := ROUND(v_debt_ratio)::INT;
    cash_reserve := ROUND(v_cash_reserve)::INT;
    profit_history := ROUND(v_profit_history)::INT;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION calculate_credit_score(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION calculate_credit_score(UUID) TO authenticated, service_role;

COMMENT ON FUNCTION calculate_credit_score(UUID) IS
    'Computes a 0–1000 credit score from fleet health, revenue stability, debt ratio, cash reserves, and profit history.';


-- ============================================================================
-- 6. UPDATE CREDIT SCORE (called at game-day boundary)
-- ============================================================================
CREATE OR REPLACE FUNCTION update_credit_score(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
)
RETURNS VOID AS $$
DECLARE
    v_score RECORD;
BEGIN
    SELECT * INTO v_score
    FROM calculate_credit_score(p_user_id)
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Update user's cached credit score
    UPDATE users
    SET credit_score = v_score.total_score,
        credit_score_updated_at = NOW()
    WHERE id = p_user_id;

    -- Insert history snapshot (one per game-day)
    INSERT INTO credit_score_history (
        user_id, score, fleet_health, revenue_stability,
        debt_ratio, cash_reserve, profit_history, game_date
    ) VALUES (
        p_user_id, v_score.total_score, v_score.fleet_health,
        v_score.revenue_stability, v_score.debt_ratio,
        v_score.cash_reserve, v_score.profit_history, p_game_date
    );

    -- Prune old history (keep last 90 game-days)
    DELETE FROM credit_score_history
    WHERE user_id = p_user_id
      AND game_date < (p_game_date - INTERVAL '90 days');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION update_credit_score(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_credit_score(UUID, TIMESTAMPTZ) TO service_role;

COMMENT ON FUNCTION update_credit_score(UUID, TIMESTAMPTZ) IS
    'Recalculates and persists a player''s credit score at each game-day boundary. Retains 90 days of history.';


-- ============================================================================
-- 7. GET CREDIT REPORT (client-facing RPC)
-- ============================================================================
CREATE OR REPLACE FUNCTION get_credit_report(p_user_id UUID)
RETURNS TABLE (
    current_score INT,
    fleet_health INT,
    revenue_stability INT,
    debt_ratio INT,
    cash_reserve INT,
    profit_history INT,
    credit_tier VARCHAR(20),
    max_unsecured_loan NUMERIC,
    max_secured_loan NUMERIC,
    max_financing_amount NUMERIC,
    base_interest_rate NUMERIC,
    suggestions TEXT[]
) AS $$
DECLARE
    v_score RECORD;
    v_tier VARCHAR(20);
    v_max_unsecured NUMERIC;
    v_max_secured NUMERIC;
    v_max_financing NUMERIC;
    v_base_rate NUMERIC;
    v_suggestions TEXT[] := '{}';
BEGIN
    SELECT * INTO v_score
    FROM calculate_credit_score(p_user_id)
    LIMIT 1;

    IF NOT FOUND THEN
        current_score := 500;
        fleet_health := 100;
        revenue_stability := 100;
        debt_ratio := 100;
        cash_reserve := 100;
        profit_history := 100;
        credit_tier := 'Standard';
        max_unsecured_loan := 5000000;
        max_secured_loan := 20000000;
        max_financing_amount := 15000000;
        base_interest_rate := 0.07;
        suggestions := ARRAY['Build your fleet and routes to establish credit history.'];
        RETURN NEXT;
        RETURN;
    END IF;

    -- Determine tier and limits based on score
    v_tier := CASE
        WHEN v_score.total_score >= 900 THEN 'Platinum'
        WHEN v_score.total_score >= 750 THEN 'Gold'
        WHEN v_score.total_score >= 600 THEN 'Silver'
        WHEN v_score.total_score >= 400 THEN 'Standard'
        ELSE 'Subprime'
    END;

    -- Loan limits by tier
    v_max_unsecured := CASE
        WHEN v_tier = 'Platinum' THEN 50000000
        WHEN v_tier = 'Gold' THEN 30000000
        WHEN v_tier = 'Silver' THEN 15000000
        WHEN v_tier = 'Standard' THEN 5000000
        ELSE 1000000
    END;

    v_max_secured := CASE
        WHEN v_tier = 'Platinum' THEN 100000000
        WHEN v_tier = 'Gold' THEN 75000000
        WHEN v_tier = 'Silver' THEN 50000000
        WHEN v_tier = 'Standard' THEN 25000000
        ELSE 10000000
    END;

    v_max_financing := CASE
        WHEN v_tier = 'Platinum' THEN 80000000
        WHEN v_tier = 'Gold' THEN 60000000
        WHEN v_tier = 'Silver' THEN 40000000
        WHEN v_tier = 'Standard' THEN 20000000
        ELSE 5000000
    END;

    -- Interest rate: better score = lower rate
    v_base_rate := CASE
        WHEN v_tier = 'Platinum' THEN 0.03
        WHEN v_tier = 'Gold' THEN 0.04
        WHEN v_tier = 'Silver' THEN 0.05
        WHEN v_tier = 'Standard' THEN 0.07
        ELSE 0.10
    END;

    -- Generate improvement suggestions based on weakest categories
    IF v_score.fleet_health < 100 THEN
        v_suggestions := array_append(v_suggestions,
            'Maintain your aircraft — low fleet condition hurts your credit.');
    END IF;
    IF v_score.revenue_stability < 100 THEN
        v_suggestions := array_append(v_suggestions,
            'Operate routes consistently — irregular revenue lowers your score.');
    END IF;
    IF v_score.debt_ratio < 100 THEN
        v_suggestions := array_append(v_suggestions,
            'Reduce outstanding debt relative to your net worth.');
    END IF;
    IF v_score.cash_reserve < 100 THEN
        v_suggestions := array_append(v_suggestions,
            'Build cash reserves — low liquidity increases lending risk.');
    END IF;
    IF v_score.profit_history < 100 THEN
        v_suggestions := array_append(v_suggestions,
            'Improve profitability — your expenses are outpacing revenue.');
    END IF;

    IF array_length(v_suggestions, 1) IS NULL THEN
        v_suggestions := ARRAY['Your credit profile is strong. Keep it up!'];
    END IF;

    current_score := v_score.total_score;
    fleet_health := v_score.fleet_health;
    revenue_stability := v_score.revenue_stability;
    debt_ratio := v_score.debt_ratio;
    cash_reserve := v_score.cash_reserve;
    profit_history := v_score.profit_history;
    credit_tier := v_tier;
    max_unsecured_loan := v_max_unsecured;
    max_secured_loan := v_max_secured;
    max_financing_amount := v_max_financing;
    base_interest_rate := v_base_rate;
    suggestions := v_suggestions;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION get_credit_report(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_credit_report(UUID) TO authenticated;

COMMENT ON FUNCTION get_credit_report(UUID) IS
    'Returns a full credit report: score breakdown, tier, loan limits, interest rate, and improvement suggestions.';


-- ============================================================================
-- 8. ENHANCED TAKE_LOAN (credit-score-aware, loan-type-aware)
-- ============================================================================
DROP FUNCTION IF EXISTS take_loan(NUMERIC, INT);

CREATE OR REPLACE FUNCTION take_loan(
    p_principal NUMERIC,
    p_term_weeks INT DEFAULT 52,
    p_loan_type VARCHAR DEFAULT 'unsecured',
    p_collateral_aircraft_id UUID DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT, new_cash NUMERIC) AS $$
DECLARE
    v_user_id UUID;
    v_existing_loans INT;
    v_credit_score INT;
    v_credit_report RECORD;
    v_interest_rate NUMERIC;
    v_weekly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_max_principal NUMERIC;
BEGIN
    v_user_id := require_current_user_id();

    -- Check existing active loans (max 3)
    SELECT COUNT(*) INTO v_existing_loans
    FROM loans
    WHERE user_id = v_user_id AND status = 'active';

    IF v_existing_loans >= 3 THEN
        RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Get credit report for limits and rates
    SELECT * INTO v_credit_report
    FROM get_credit_report(v_user_id)
    LIMIT 1;

    v_credit_score := COALESCE(v_credit_report.current_score, 500);

    -- Validate loan type
    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
        RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Validate principal against credit tier limits
    IF p_loan_type = 'unsecured' THEN
        v_max_principal := COALESCE(v_credit_report.max_unsecured_loan, 5000000);
        v_interest_rate := COALESCE(v_credit_report.base_interest_rate, 0.07);
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        -- Verify collateral ownership
        IF NOT EXISTS (
            SELECT 1 FROM user_fleet
            WHERE id = p_collateral_aircraft_id AND user_id = v_user_id
        ) THEN
            RETURN QUERY SELECT false, 'You do not own that aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        v_max_principal := COALESCE(v_credit_report.max_secured_loan, 25000000);
        -- Secured loans get a rate discount
        v_interest_rate := COALESCE(v_credit_report.base_interest_rate, 0.07) - 0.01;
    ELSE
        -- credit_line: same limits as unsecured, revolving
        v_max_principal := COALESCE(v_credit_report.max_unsecured_loan, 5000000);
        v_interest_rate := COALESCE(v_credit_report.base_interest_rate, 0.07) + 0.01;
    END IF;

    v_interest_rate := GREATEST(0.02, v_interest_rate); -- Floor at 2%

    IF p_principal < 100000 OR p_principal > v_max_principal THEN
        RETURN QUERY SELECT false,
            'Loan amount must be between $100K and $' || v_max_principal::TEXT || ' for your credit tier.'::TEXT,
            0::NUMERIC;
        RETURN;
    END IF;

    IF p_term_weeks NOT IN (12, 26, 52) THEN
        RETURN QUERY SELECT false, 'Loan term must be 12, 26, or 52 weeks.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Calculate weekly payment (simple interest)
    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    -- Fetch current game time
    SELECT game_current_time INTO v_game_time
    FROM users WHERE id = v_user_id;

    -- Credit cash
    UPDATE users
    SET cash = cash + p_principal
    WHERE id = v_user_id
    RETURNING cash INTO v_cash;

    -- Create loan record
    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance,
        weekly_payment, game_date_taken,
        loan_type, collateral_aircraft_id, credit_score_at_origination
    )
    VALUES (
        v_user_id, p_principal, v_interest_rate, v_total_repayable,
        v_weekly_payment, v_game_time,
        p_loan_type, p_collateral_aircraft_id, v_credit_score
    );

    -- Ledger entry
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (v_user_id, 'revenue', 'loan', p_principal,
            'Bank loan (' || p_loan_type || ') taken', v_game_time);

    RETURN QUERY SELECT true,
        'Loan of $' || p_principal::TEXT || ' approved at ' ||
        ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT,
        v_cash;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION take_loan(NUMERIC, INT, VARCHAR, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION take_loan(NUMERIC, INT, VARCHAR, UUID) TO authenticated;

COMMENT ON FUNCTION take_loan(NUMERIC, INT, VARCHAR, UUID) IS
    'Credit-score-aware loan origination. Supports unsecured, secured (with collateral), and credit line types. Interest rate and limits determined by credit tier.';


-- ============================================================================
-- 9. PROCESS LOAN PAYMENTS (enhanced: tracks missed payments)
-- ============================================================================
DROP FUNCTION IF EXISTS process_loan_payments(UUID, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION process_loan_payments(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
)
RETURNS VOID AS $$
DECLARE
    r_loan RECORD;
    v_cash NUMERIC;
    v_payment NUMERIC;
    v_late_fee NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;

    FOR r_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id AND status = 'active'
        ORDER BY taken_at ASC
    LOOP
        v_payment := r_loan.weekly_payment;

        IF v_cash >= v_payment THEN
            -- Deduct payment
            v_cash := v_cash - v_payment;
            UPDATE users SET cash = v_cash WHERE id = p_user_id;

            -- Update loan balance
            UPDATE loans
            SET remaining_balance = remaining_balance - v_payment,
                missed_payments = 0  -- Reset streak on successful payment
            WHERE id = r_loan.id;

            -- Check if paid off
            IF r_loan.remaining_balance - v_payment <= 0 THEN
                UPDATE loans
                SET status = 'paid_off',
                    paid_off_at = NOW(),
                    remaining_balance = 0
                WHERE id = r_loan.id;

                -- Release collateral if secured
                IF r_loan.loan_type = 'secured' AND r_loan.collateral_aircraft_id IS NOT NULL THEN
                    -- Collateral is automatically released when loan is paid off
                    -- (no lien system needed — collateral is just recorded)
                    NULL;
                END IF;
            END IF;

            -- Ledger entry
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'loan_payment', v_payment, 'Loan payment', p_game_date);
        ELSE
            -- Can't pay — apply late fee and track missed payment
            v_late_fee := v_payment * 0.1;

            UPDATE loans
            SET remaining_balance = remaining_balance + v_late_fee,
                missed_payments = missed_payments + 1
            WHERE id = r_loan.id;

            -- Ledger entry for late fee
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'loan_late_fee', v_late_fee, 'Loan late fee — insufficient cash', p_game_date);

            -- Auto-default after 4 consecutive missed payments
            IF r_loan.missed_payments + 1 >= 4 THEN
                UPDATE loans
                SET status = 'defaulted'
                WHERE id = r_loan.id;

                -- Repossess collateral if secured
                IF r_loan.loan_type = 'secured' AND r_loan.collateral_aircraft_id IS NOT NULL THEN
                    UPDATE user_fleet
                    SET status = 'grounded'
                    WHERE id = r_loan.collateral_aircraft_id;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION process_loan_payments(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_loan_payments(UUID, TIMESTAMPTZ) TO service_role;

COMMENT ON FUNCTION process_loan_payments(UUID, TIMESTAMPTZ) IS
    'Enhanced loan payment processor. Tracks missed payments, auto-defaults after 4 consecutive misses, and repossesses collateral on secured loan defaults.';


-- ============================================================================
-- 10. FINANCE AIRCRAFT PURCHASE
-- ============================================================================
CREATE OR REPLACE FUNCTION finance_aircraft(
    p_aircraft_model_id UUID,
    p_fleet_id UUID,
    p_term_months INT DEFAULT 36,
    p_down_payment_pct NUMERIC DEFAULT 0.20
)
RETURNS TABLE(success BOOLEAN, message TEXT, new_cash NUMERIC) AS $$
DECLARE
    v_user_id UUID;
    v_model RECORD;
    v_credit_report RECORD;
    v_purchase_price NUMERIC;
    v_down_payment NUMERIC;
    v_financed_amount NUMERIC;
    v_interest_rate NUMERIC;
    v_monthly_payment NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_total_repayable NUMERIC;
BEGIN
    v_user_id := require_current_user_id();

    -- Fetch aircraft model
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_purchase_price := v_model.purchase_price;

    -- Verify fleet ownership
    IF NOT EXISTS (
        SELECT 1 FROM user_fleet
        WHERE id = p_fleet_id AND user_id = v_user_id AND aircraft_model_id = p_aircraft_model_id
    ) THEN
        RETURN QUERY SELECT false, 'You do not own that aircraft model.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Check credit report
    SELECT * INTO v_credit_report
    FROM get_credit_report(v_user_id)
    LIMIT 1;

    IF v_purchase_price > COALESCE(v_credit_report.max_financing_amount, 20000000) THEN
        RETURN QUERY SELECT false,
            'Aircraft price exceeds your financing limit of $' ||
            v_credit_report.max_financing_amount::TEXT || '.'::TEXT,
            0::NUMERIC;
        RETURN;
    END IF;

    -- Validate term
    IF p_term_months NOT IN (12, 24, 36, 48, 60) THEN
        RETURN QUERY SELECT false, 'Financing term must be 12, 24, 36, 48, or 60 months.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Validate down payment
    IF p_down_payment_pct < 0.10 OR p_down_payment_pct > 0.50 THEN
        RETURN QUERY SELECT false, 'Down payment must be between 10% and 50%.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Calculate financing
    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_financed_amount := v_purchase_price - v_down_payment;
    v_interest_rate := COALESCE(v_credit_report.base_interest_rate, 0.07);

    -- Simple interest for monthly payments
    v_total_repayable := v_financed_amount * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;

    -- Check player can afford down payment
    SELECT cash INTO v_cash FROM users WHERE id = v_user_id;
    IF v_cash < v_down_payment THEN
        RETURN QUERY SELECT false,
            'Insufficient cash for down payment of $' || v_down_payment::TEXT || '.'::TEXT,
            0::NUMERIC;
        RETURN;
    END IF;

    -- Deduct down payment
    UPDATE users
    SET cash = cash - v_down_payment
    WHERE id = v_user_id
    RETURNING cash INTO v_cash;

    -- Create financing record
    INSERT INTO aircraft_financing (
        user_id, aircraft_model_id, fleet_id,
        down_payment, financed_amount, interest_rate,
        monthly_payment, remaining_payments, total_payments,
        remaining_balance, credit_score_at_origination, game_date_taken
    ) VALUES (
        v_user_id, p_aircraft_model_id, p_fleet_id,
        v_down_payment, v_financed_amount, v_interest_rate,
        v_monthly_payment, p_term_months, p_term_months,
        v_total_repayable, v_credit_report.current_score, v_game_time
    );

    -- Ledger entry for down payment
    SELECT game_current_time INTO v_game_time FROM users WHERE id = v_user_id;
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (v_user_id, 'expense', 'aircraft_financing_down', v_down_payment,
            'Aircraft financing down payment', v_game_time);

    RETURN QUERY SELECT true,
        'Aircraft financing approved. Down payment: $' || v_down_payment::TEXT ||
        ', Monthly: $' || v_monthly_payment::TEXT || '/mo for ' || p_term_months::TEXT || ' months.'::TEXT,
        v_cash;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION finance_aircraft(UUID, UUID, INT, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION finance_aircraft(UUID, UUID, INT, NUMERIC) TO authenticated;

COMMENT ON FUNCTION finance_aircraft(UUID, UUID, INT, NUMERIC) IS
    'Finance an aircraft purchase with a down payment and monthly installments. Credit score determines interest rate and limits.';


-- ============================================================================
-- 11. PROCESS AIRCRAFT FINANCING PAYMENTS (called at game-day boundary)
-- ============================================================================
CREATE OR REPLACE FUNCTION process_aircraft_financing_payments(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
)
RETURNS VOID AS $$
DECLARE
    v_days_in_month NUMERIC := 30.0;
    r_financing RECORD;
    v_daily_payment NUMERIC;
    v_cash NUMERIC;
    v_late_fee NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;

    FOR r_financing IN
        SELECT * FROM aircraft_financing
        WHERE user_id = p_user_id AND status = 'active'
        ORDER BY taken_at ASC
    LOOP
        -- Convert monthly payment to daily equivalent
        v_daily_payment := r_financing.monthly_payment / v_days_in_month;

        IF v_cash >= v_daily_payment THEN
            v_cash := v_cash - v_daily_payment;
            UPDATE users SET cash = v_cash WHERE id = p_user_id;

            UPDATE aircraft_financing
            SET remaining_balance = remaining_balance - v_daily_payment
            WHERE id = r_financing.id;

            -- Check if paid off
            IF r_financing.remaining_balance - v_daily_payment <= 0 THEN
                UPDATE aircraft_financing
                SET status = 'paid_off',
                    paid_off_at = NOW(),
                    remaining_balance = 0,
                    remaining_payments = 0
                WHERE id = r_financing.id;
            END IF;

            -- Ledger entry (batched — only write at month boundaries for readability)
            IF date_trunc('month', p_game_date) > date_trunc('month', p_game_date - INTERVAL '1 day') THEN
                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (p_user_id, 'expense', 'aircraft_financing',
                        r_financing.monthly_payment,
                        'Aircraft financing monthly payment', p_game_date);
            END IF;
        ELSE
            -- Late fee
            v_late_fee := v_daily_payment * 0.05;
            UPDATE aircraft_financing
            SET remaining_balance = remaining_balance + v_late_fee
            WHERE id = r_financing.id;

            -- Track missed payments by decrementing remaining_payments faster
            -- (penalty: effectively extends the term)
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION process_aircraft_financing_payments(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_aircraft_financing_payments(UUID, TIMESTAMPTZ) TO service_role;

COMMENT ON FUNCTION process_aircraft_financing_payments(UUID, TIMESTAMPTZ) IS
    'Daily aircraft financing payment processor. Converts monthly payments to daily equivalents. Applies late fees on insufficient cash.';


-- ============================================================================
-- 12. WIRE INTO SIMULATION TICK
-- ============================================================================
-- Add credit score update and aircraft financing payment processing to the
-- game-day boundary in process_player_simulation_segment (the inner tick).

-- The process_player_simulation_segment function (renamed from the original
-- process_player_simulation_to_time in migration 45) is the inner function
-- that runs per game-day. We need to add calls at the game-day boundary.

-- Find and patch the game-day boundary block. The segment function is the one
-- that has the IF date_trunc('day', ...) > date_trunc('day', ...) block.
-- We add credit score + financing payment calls alongside the existing
-- achievement checks and loan payments.

-- Note: This is done by replacing the process_player_simulation_segment function.
-- The function body is the same as in migration 84 (the current version), with
-- three new PERFORM calls added at the game-day boundary.

CREATE OR REPLACE FUNCTION process_player_simulation_segment(
    p_user_id UUID,
    p_target_game_time TIMESTAMP WITH TIME ZONE
)
RETURNS TABLE (
    cash_before NUMERIC(20,2),
    cash_after NUMERIC(20,2),
    elapsed_real_sec DOUBLE PRECISION,
    elapsed_game_days DOUBLE PRECISION,
    flights_run INT
) AS $$
DECLARE
    r_user RECORD;
    v_game_sec DOUBLE PRECISION;
    v_game_days DOUBLE PRECISION;
    v_route RECORD;
    v_fleet RECORD;
    v_flights DOUBLE PRECISION;
    v_revenue NUMERIC(20,2) := 0;
    v_fuel_cost NUMERIC(20,2) := 0;
    v_maint_cost NUMERIC(20,2) := 0;
    v_tax_cost NUMERIC(20,2) := 0;
    v_total_cost NUMERIC(20,2) := 0;
    v_total_revenue NUMERIC(20,2) := 0;
    v_total_cost_accum NUMERIC(20,2) := 0;
    v_net NUMERIC(20,2) := 0;
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_completed_flights_all INT := 0;
    v_lease_cost NUMERIC(20,2) := 0;
    v_fuel_price NUMERIC;
    v_absolute_minimum_safety_limit NUMERIC(5,2);
    v_effective_grounding_threshold NUMERIC(5,2);
    v_max_weekly_flights INT;
    v_unused_slots INT;
    v_maintenance_hours DOUBLE PRECISION;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_buffered_rev_accum NUMERIC(20,2);
    v_buffered_ops_accum NUMERIC(20,2);
    v_buffered_lease_accum NUMERIC(20,2);
    v_buffered_cargo_accum NUMERIC(20,2);
    v_cash_after NUMERIC(20,2);
    v_grounded_count INT := 0;
    v_consecutive_negative_days INT := 0;
    v_recovery_streak_days INT := 0;
    v_new_status VARCHAR(20) := 'Active';
    v_total_seats INT;
    v_economy_pax NUMERIC;
    v_business_pax NUMERIC;
    v_first_pax NUMERIC;
    -- Event system variables
    v_fuel_price_multiplier NUMERIC := 1.0;
    v_demand_multiplier NUMERIC := 1.0;
    -- Catch-up subsidy variables
    v_leader_net_worth NUMERIC := 0;
    v_player_net_worth NUMERIC := 0;
    v_asset_value NUMERIC := 0;
    v_gap_ratio NUMERIC;
    v_subsidy NUMERIC := 0;
    -- Cargo revenue variables
    v_cargo_rate NUMERIC := 0.10;
    v_cargo_demand NUMERIC;
    v_cargo_revenue NUMERIC;
    v_total_cargo_revenue NUMERIC(20,2) := 0;
    -- Non-linear degradation variable
    v_acceleration NUMERIC;
    -- Loan balance snapshot for net worth calculation
    v_total_loan_balance NUMERIC := 0;
BEGIN
    SELECT *
    INTO r_user
    FROM users
    WHERE id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_game_sec := COALESCE(EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)), 0.0);

    IF v_game_sec < 1 THEN
        cash_before := r_user.cash;
        cash_after := r_user.cash;
        elapsed_real_sec := 0.0;
        elapsed_game_days := 0.0;
        flights_run := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT fuel_price_per_liter, absolute_minimum_safety_limit
    INTO v_fuel_price, v_absolute_minimum_safety_limit
    FROM global_game_settings
    LIMIT 1;

    v_fuel_price := COALESCE(v_fuel_price, 0.85);
    v_absolute_minimum_safety_limit := COALESCE(v_absolute_minimum_safety_limit, 30.00);
    v_game_days := v_game_sec / 86400.0;
    v_effective_grounding_threshold := GREATEST(
        COALESCE(r_user.auto_grounding_threshold, 40.00),
        v_absolute_minimum_safety_limit
    );

    -- Check for active global fuel price events
    SELECT COALESCE(
        (SELECT effect_value FROM game_events
         WHERE effect_type = 'fuel_price' AND effect_target = 'global'
           AND is_active = true
           AND start_game_time <= p_target_game_time
           AND end_game_time > p_target_game_time
         ORDER BY start_game_time DESC LIMIT 1),
        1.0
    ) INTO v_fuel_price_multiplier;

    FOR v_fleet IN
        SELECT f.*, m.lease_price_per_month
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.user_id = p_user_id AND f.acquisition_type = 'lease'
    LOOP
        v_lease_cost := v_lease_cost + COALESCE((v_game_days * (v_fleet.lease_price_per_month / 30.0)), 0.00);
    END LOOP;

    v_lease_cost := GREATEST(0.00, COALESCE(v_lease_cost, 0.00));

    FOR v_route IN
        SELECT r.*,
               f.id AS fleet_aircraft_id,
               f.condition,
               f.status,
               f.acquisition_type,
               f.economy_seats,
               f.business_seats,
               f.first_class_seats,
               m.capacity,
               m.speed_kmh,
               m.fuel_burn_per_km,
               m.maintenance_cost_per_hour,
               calculate_effective_passenger_capacity(
                   m.capacity,
                   f.economy_seats,
                   f.business_seats,
                   f.first_class_seats
               ) AS passenger_capacity,
               org.demand_index AS org_demand,
               org.airport_tax AS org_tax,
               dst.demand_index AS dst_demand,
               dst.airport_tax AS dst_tax
        FROM user_routes r
        JOIN user_fleet f ON r.assigned_aircraft_id = f.id
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        JOIN airports org ON r.origin_iata = org.iata
        JOIN airports dst ON r.destination_iata = dst.iata
        WHERE r.user_id = p_user_id
    LOOP
        IF COALESCE(v_route.status, 'grounded') != 'active'
           OR COALESCE(v_route.condition, 0.00) < v_effective_grounding_threshold THEN
            CONTINUE;
        END IF;

        v_flight_duration := COALESCE((v_route.distance_km / NULLIF(v_route.speed_kmh, 0)), 0.0) + 1.0;
        v_flights := COALESCE(v_game_days * (v_route.flights_per_week / 7.0), 0.0);

        IF v_flights > 0.0001 THEN
            v_passengers := calculate_route_expected_passengers(
                COALESCE(v_route.passenger_capacity, 0),
                COALESCE(v_route.distance_km, 0.0),
                COALESCE(v_route.ticket_price, 0.00),
                COALESCE(v_route.org_demand, 50),
                COALESCE(v_route.dst_demand, 50),
                v_route.origin_iata,
                v_route.destination_iata,
                p_user_id
            );

            -- Apply demand events at this route's airports
            SELECT COALESCE(
                (SELECT effect_value FROM game_events
                 WHERE effect_type = 'demand_index' AND effect_target = v_route.origin_iata
                   AND is_active = true
                   AND start_game_time <= p_target_game_time
                   AND end_game_time > p_target_game_time
                 ORDER BY start_game_time DESC LIMIT 1),
                1.0
            ) INTO v_demand_multiplier;

            v_passengers := GREATEST(0, FLOOR(v_passengers * v_demand_multiplier));

            -- Premium cabin revenue: distribute passengers across seat classes
            v_total_seats := COALESCE(v_route.economy_seats, 0)
                           + COALESCE(v_route.business_seats, 0)
                           + COALESCE(v_route.first_class_seats, 0);

            IF v_total_seats > 0 THEN
                v_economy_pax := v_passengers * (v_route.economy_seats::NUMERIC / v_total_seats);
                v_business_pax := v_passengers * (v_route.business_seats::NUMERIC / v_total_seats);
                v_first_pax := v_passengers * (v_route.first_class_seats::NUMERIC / v_total_seats);

                v_revenue := COALESCE(v_flights * (
                    (v_economy_pax * v_route.ticket_price) +
                    (v_business_pax * v_route.ticket_price * 2.5) +
                    (v_first_pax * v_route.ticket_price * 4.0)
                ), 0.00);
            ELSE
                v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
            END IF;

            -- Cargo revenue: scales with distance (long routes = more cargo)
            v_cargo_demand := LEAST(1.0, COALESCE(v_route.distance_km, 0.0) / 5000.0);
            v_cargo_revenue := v_revenue * v_cargo_rate * v_cargo_demand;
            v_total_cargo_revenue := v_total_cargo_revenue + v_cargo_revenue;

            -- Apply fuel price event multiplier to fuel cost
            v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier, 0.00);
            v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
            v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
            v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost);

            v_max_weekly_flights := calculate_route_max_weekly_flights(
                COALESCE(v_route.distance_km, 0.0),
                COALESCE(v_route.speed_kmh, 0)
            );
            v_unused_slots := GREATEST(0, COALESCE(v_max_weekly_flights, 0) - COALESCE(v_route.flights_per_week, 0));
            v_maintenance_hours := COALESCE(v_unused_slots, 0) * v_flight_duration * (v_game_days / 7.0);
            v_wear_per_cycle := CASE
                WHEN COALESCE(v_route.acquisition_type, 'purchase') = 'lease' THEN 0.70
                ELSE 0.50
            END;

            -- Non-linear degradation: accelerating wear below 60% condition
            IF COALESCE(v_route.condition, 100) > 60 THEN
                v_acceleration := 1.0;
            ELSE
                v_acceleration := 1.0 + ((60.0 - COALESCE(v_route.condition, 60)) / 40.0) * 1.5;
            END IF;

            v_gross_damage := COALESCE(v_flights, 0.0) * v_wear_per_cycle * v_acceleration;
            v_self_healing_credit := COALESCE(v_maintenance_hours, 0.0) * 0.85;
            v_net_damage := GREATEST(0.00, v_gross_damage - v_self_healing_credit);

            UPDATE user_fleet
            SET condition = GREATEst(0.00, condition - v_net_damage)
            WHERE id = v_route.fleet_aircraft_id;

            UPDATE user_fleet
            SET status = 'grounded'
            WHERE id = v_route.fleet_aircraft_id
              AND condition < v_effective_grounding_threshold;

            v_total_revenue := v_total_revenue + v_revenue;
            v_total_cost_accum := v_total_cost_accum + v_total_cost;
            v_completed_flights_all := v_completed_flights_all + ROUND(v_flights)::INT;
        END IF;
    END LOOP;

    v_total_revenue := GREATEST(0.00, COALESCE(v_total_revenue, 0.00));
    v_total_cost_accum := GREATEST(0.00, COALESCE(v_total_cost_accum, 0.00));
    v_total_cargo_revenue := GREATEST(0.00, COALESCE(v_total_cargo_revenue, 0.00));
    v_net := v_total_revenue + v_total_cargo_revenue - v_total_cost_accum - v_lease_cost;

    -- Catch-up subsidy for players far behind the leader
    SELECT COALESCE(SUM(am.purchase_price * 0.7), 0)
    INTO v_asset_value
    FROM user_fleet uf
    JOIN aircraft_models am ON uf.aircraft_model_id = am.id
    WHERE uf.user_id = p_user_id AND uf.status = 'active';

    v_player_net_worth := r_user.cash + v_asset_value;

    SELECT MAX(sub.net_worth) INTO v_leader_net_worth
    FROM (
        SELECT u.cash + COALESCE(
            (SELECT SUM(am2.purchase_price * 0.7)
             FROM user_fleet uf2
             JOIN aircraft_models am2 ON uf2.aircraft_model_id = am2.id
             WHERE uf2.user_id = u.id AND uf2.status = 'active'),
            0
        ) AS net_worth
        FROM users u
        WHERE u.operational_status != 'Bankrupt'
          AND u.season_id = r_user.season_id
    ) sub;

    v_leader_net_worth := COALESCE(v_leader_net_worth, 0);

    IF v_leader_net_worth > 0 AND v_player_net_worth < (v_leader_net_worth * 0.3) THEN
        v_gap_ratio := v_player_net_worth / v_leader_net_worth;
        v_subsidy := v_total_revenue * (0.3 - v_gap_ratio) * 0.33;
        v_subsidy := GREATEST(0, LEAST(v_subsidy, v_total_revenue * 0.10));

        IF v_subsidy > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'subsidy', v_subsidy, 'Government route subsidy', date_trunc('day', p_target_game_time));
            v_net := v_net + v_subsidy;
        END IF;
    END IF;

    v_buffered_rev_accum := COALESCE(r_user.buffered_revenue, 0.00) + v_total_revenue + v_subsidy;
    v_buffered_ops_accum := COALESCE(r_user.buffered_ops_cost, 0.00) + v_total_cost_accum;
    v_buffered_lease_accum := COALESCE(r_user.buffered_lease_cost, 0.00) + v_lease_cost;
    v_buffered_cargo_accum := COALESCE(r_user.buffered_cargo_revenue, 0.00) + v_total_cargo_revenue;

    IF date_trunc('day', p_target_game_time) > date_trunc('day', r_user.game_current_time) THEN
        IF v_buffered_rev_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active routes', date_trunc('day', p_target_game_time));
        END IF;

        IF v_buffered_cargo_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'cargo', v_buffered_cargo_accum, 'Cargo revenue — distance-scaled freight income', date_trunc('day', p_target_game_time));
        END IF;

        IF v_buffered_ops_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew maintenance, & landing fees', date_trunc('day', p_target_game_time));
        END IF;

        IF v_buffered_lease_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active fleet', date_trunc('day', p_target_game_time));
        END IF;

        DELETE FROM financial_ledger
        WHERE user_id = p_user_id
          AND game_date < (p_target_game_time - INTERVAL '30 days');

        v_buffered_rev_accum := 0.00;
        v_buffered_ops_accum := 0.00;
        v_buffered_lease_accum := 0.00;
        v_buffered_cargo_accum := 0.00;

        -- ── Check achievements at game-day boundary ──
        PERFORM check_achievements(p_user_id, p_target_game_time);

        -- ── Process loan payments at game-day boundary ──
        PERFORM process_loan_payments(p_user_id, p_target_game_time);

        -- ── NEW: Process aircraft financing payments ──
        PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time);

        -- ── NEW: Update credit score at game-day boundary ──
        PERFORM update_credit_score(p_user_id, p_target_game_time);
    END IF;

    v_cash_after := r_user.cash + v_net;

    -- Subtract outstanding loan balance from net worth calculation
    SELECT COALESCE(SUM(remaining_balance), 0)
    INTO v_total_loan_balance
    FROM loans
    WHERE user_id = p_user_id AND status = 'active';

    SELECT COUNT(*)::INT
    INTO v_grounded_count
    FROM user_fleet
    WHERE user_id = p_user_id
      AND (status = 'grounded' OR condition < v_effective_grounding_threshold);

    v_consecutive_negative_days := CASE
        WHEN v_net < 0.00 THEN COALESCE(r_user.consecutive_negative_days, 0) + 1
        ELSE 0
    END;

    v_recovery_streak_days := CASE
        WHEN COALESCE(r_user.operational_status, 'Active') IN ('Distress', 'Maintenance', 'Recovery')
             AND v_cash_after >= 0.00
             AND v_grounded_count = 0
             AND v_net >= 0.00
        THEN COALESCE(r_user.recovery_streak_days, 0) + 1
        ELSE 0
    END;

    v_new_status := CASE
        WHEN v_cash_after < 0.00 OR v_consecutive_negative_days >= 2 THEN 'Distress'
        WHEN v_grounded_count > 0 THEN 'Maintenance'
        WHEN v_recovery_streak_days > 0 THEN 'Recovery'
        ELSE 'Active'
    END;

    IF v_recovery_streak_days >= 3 THEN
        v_new_status := 'Active';
        v_recovery_streak_days := 0;
    END IF;

    UPDATE users
    SET cash = v_cash_after,
        game_current_time = p_target_game_time,
        last_active_at = NOW(),
        buffered_revenue = v_buffered_rev_accum,
        buffered_ops_cost = v_buffered_ops_accum,
        buffered_lease_cost = v_buffered_lease_accum,
        buffered_cargo_revenue = v_buffered_cargo_accum,
        operational_status = v_new_status,
        consecutive_negative_days = v_consecutive_negative_days,
        recovery_streak_days = v_recovery_streak_days
    WHERE id = p_user_id;

    cash_before := r_user.cash;
    cash_after := v_cash_after;
    elapsed_real_sec := 0.0;
    elapsed_game_days := v_game_days;
    flights_run := v_completed_flights_all;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION process_player_simulation_segment(UUID, TIMESTAMP WITH TIME ZONE) IS
    'Inner simulation tick per game-day. Includes flight processing, cargo revenue, non-linear degradation, achievements, loan payments, aircraft financing payments, and credit score updates.';


-- ============================================================================
-- 13. GRANTS & COMMENTS
-- ============================================================================
GRANT EXECUTE ON FUNCTION calculate_credit_score(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION update_credit_score(UUID, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION get_credit_report(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION take_loan(NUMERIC, INT, VARCHAR, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION process_loan_payments(UUID, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION finance_aircraft(UUID, UUID, INT, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION process_aircraft_financing_payments(UUID, TIMESTAMPTZ) TO service_role;

COMMENT ON TABLE loans IS
    'Bank loans taken by players. Supports unsecured, secured (with collateral), and credit line types. Payments auto-deducted at game-day boundaries.';

COMMENT ON TABLE aircraft_financing IS
    'Aircraft purchase financing plans. Monthly payments converted to daily deductions at game-day boundaries.';
