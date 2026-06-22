-- ============================================================================
-- CREDIT SYSTEM & AIRCRAFT FINANCING
-- ============================================================================
-- Implements credit scoring (0–1000), aircraft financing, and enhanced loans.
--
-- Credit Score Components (0–200 each):
--   Fleet Health      — avg aircraft condition & grounded ratio
--   Revenue Stability — consistency of 30-day revenue
--   Debt Ratio        — total debt vs. net worth
--   Cash Reserves     — current cash vs. starting capital
--   Profit History    — rolling 30-day net profit margin
--
-- Credit Tiers:
--   Platinum (900+), Gold (750+), Silver (600+), Standard (400+), Subprime (<400)
--
-- Aircraft Financing:
--   Players finance aircraft with 10–50% down over 12–60 months.
--   Interest rate and max amount determined by credit tier.
--   Monthly payments tracked; repossession after 3 consecutive misses.
--
-- Enhanced Loans:
--   Unsecured, secured (with collateral), and credit line types.
--   Interest rate and max amount determined by credit tier.
--   Auto-default after 4 consecutive missed weekly payments.
--
-- Integration:
--   process_aircraft_financing_payments and update_credit_score are called
--   at every game-day boundary inside process_player_simulation_segment.
-- ============================================================================


-- ============================================================================
-- 1. CREDIT SCORES TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS credit_scores (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    score INT NOT NULL DEFAULT 500 CHECK (score BETWEEN 0 AND 1000),
    tier VARCHAR(10) NOT NULL DEFAULT 'Standard',
    fleet_health_score INT DEFAULT 0,
    revenue_stability_score INT DEFAULT 0,
    debt_ratio_score INT DEFAULT 0,
    cash_reserves_score INT DEFAULT 0,
    profit_history_score INT DEFAULT 0,
    computed_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE credit_scores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS credit_scores_select_own ON credit_scores;
CREATE POLICY credit_scores_select_own ON credit_scores FOR SELECT TO authenticated
USING (user_id = (SELECT id FROM users WHERE auth_user_id = auth.uid()));

GRANT SELECT ON credit_scores TO authenticated;

CREATE INDEX IF NOT EXISTS credit_scores_tier_idx ON credit_scores(tier);

COMMENT ON TABLE credit_scores IS
    'Current credit score snapshot per player. Updated at each game-day boundary.';


-- ============================================================================
-- 2. ADD CREDIT COLUMNS TO USERS
-- ============================================================================
ALTER TABLE users ADD COLUMN IF NOT EXISTS credit_score INT DEFAULT 500;
ALTER TABLE users ADD COLUMN IF NOT EXISTS credit_score_updated_at TIMESTAMPTZ;


-- ============================================================================
-- 3. AIRCRAFT FINANCING TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS aircraft_financing (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    aircraft_model_id UUID NOT NULL REFERENCES aircraft_models(id),
    fleet_aircraft_id UUID REFERENCES user_fleet(id) ON DELETE SET NULL,
    purchase_price NUMERIC NOT NULL,
    down_payment NUMERIC NOT NULL,
    principal NUMERIC NOT NULL,
    interest_rate NUMERIC NOT NULL,
    monthly_payment NUMERIC NOT NULL,
    term_months INT NOT NULL,
    remaining_balance NUMERIC NOT NULL,
    payments_made INT DEFAULT 0,
    missed_payments INT DEFAULT 0,
    status VARCHAR(20) DEFAULT 'active'
        CHECK (status IN ('active', 'paid_off', 'repossessed', 'defaulted')),
    taken_at TIMESTAMPTZ DEFAULT NOW(),
    paid_off_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE aircraft_financing ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS aircraft_financing_select_own ON aircraft_financing;
CREATE POLICY aircraft_financing_select_own ON aircraft_financing FOR SELECT TO authenticated
USING (user_id = (SELECT id FROM users WHERE auth_user_id = auth.uid()));

GRANT SELECT ON aircraft_financing TO authenticated;

CREATE INDEX IF NOT EXISTS aircraft_financing_user_status_idx
    ON aircraft_financing(user_id, status);

COMMENT ON TABLE aircraft_financing IS
    'Aircraft purchase financing plans. Monthly payments deducted at game-day boundaries.';


-- ============================================================================
-- 4. ADD COLUMNS TO LOANS TABLE
-- ============================================================================
ALTER TABLE loans ADD COLUMN IF NOT EXISTS loan_type VARCHAR(20) DEFAULT 'unsecured'
    CHECK (loan_type IN ('unsecured', 'secured', 'credit_line'));
ALTER TABLE loans ADD COLUMN IF NOT EXISTS collateral_aircraft_id UUID
    REFERENCES user_fleet(id) ON DELETE SET NULL;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS missed_payments INT DEFAULT 0;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS credit_score_at_origination INT;

CREATE INDEX IF NOT EXISTS loans_collateral_idx
    ON loans(collateral_aircraft_id) WHERE collateral_aircraft_id IS NOT NULL;


-- ============================================================================
-- 5. CALCULATE CREDIT SCORE
-- ============================================================================
-- Returns a 0–1000 credit score from five components (0–200 each).
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
    SELECT u.cash, u.net_worth, u.game_current_time
    INTO v_user
    FROM users u WHERE u.id = p_user_id;

    IF NOT FOUND THEN
        total_score := 500; fleet_health := 100; revenue_stability := 100;
        debt_ratio := 100; cash_reserve := 100; profit_history := 100;
        RETURN NEXT;
        RETURN;
    END IF;

    v_cash := COALESCE(v_user.cash, 0.0);
    v_net_worth := COALESCE(v_user.net_worth, 0.0);

    SELECT starting_cash INTO v_starting_cash FROM global_game_settings LIMIT 1;
    v_starting_cash := COALESCE(v_starting_cash, 15000000.0);

    -- ── Fleet Health (0–200) ──
    SELECT
        COUNT(*)::INT,
        COALESCE(AVG(condition), 100.0),
        COALESCE(
            COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC /
            NULLIF(COUNT(*), 0), 0.0
        )
    INTO v_fleet_count, v_avg_condition, v_grounded_ratio
    FROM user_fleet WHERE user_id = p_user_id;

    IF v_fleet_count > 0 THEN
        v_fleet_health := (v_avg_condition / 100.0) * 150.0
                        + 50.0 * (1.0 - v_grounded_ratio);
    ELSE
        v_fleet_health := 100.0;
    END IF;
    v_fleet_health := GREATEST(0.0, LEAST(200.0, v_fleet_health));

    -- ── Revenue Stability (0–200) ──
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
        v_revenue_stability := (v_positive_days::NUMERIC / GREATEST(v_revenue_days, 1)) * 200.0;
    ELSE
        v_revenue_stability := 100.0;
    END IF;
    v_revenue_stability := GREATEST(0.0, LEAST(200.0, v_revenue_stability));

    -- ── Debt Ratio (0–200) ──
    SELECT COALESCE(SUM(remaining_balance), 0) INTO v_total_debt
    FROM loans WHERE user_id = p_user_id AND status = 'active';

    v_total_debt := v_total_debt + COALESCE(
        (SELECT SUM(remaining_balance) FROM aircraft_financing
         WHERE user_id = p_user_id AND status = 'active'), 0);

    IF v_net_worth > 0 THEN
        v_debt_ratio := GREATEST(0.0, 200.0 * (1.0 - (v_total_debt / v_net_worth)));
    ELSIF v_total_debt > 0 THEN
        v_debt_ratio := 0.0;
    ELSE
        v_debt_ratio := 100.0;
    END IF;
    v_debt_ratio := GREATEST(0.0, LEAST(200.0, v_debt_ratio));

    -- ── Cash Reserves (0–200) ──
    IF v_starting_cash > 0 THEN
        v_cash_reserve := LEAST(200.0, (v_cash / v_starting_cash) * 100.0);
    ELSE
        v_cash_reserve := 100.0;
    END IF;
    IF v_cash < 0 THEN v_cash_reserve := 0.0; END IF;
    v_cash_reserve := GREATEST(0.0, LEAST(200.0, v_cash_reserve));

    -- ── Profit History (0–200) ──
    SELECT
        COALESCE(SUM(CASE WHEN transaction_type = 'revenue' THEN amount ELSE 0 END), 0.0),
        COALESCE(SUM(CASE WHEN transaction_type = 'expense' THEN amount ELSE 0 END), 0.0)
    INTO v_total_revenue_30d, v_total_expense_30d
    FROM financial_ledger
    WHERE user_id = p_user_id
      AND game_date >= v_user.game_current_time - INTERVAL '30 days';

    IF v_total_revenue_30d > 0 THEN
        v_profit_margin := (v_total_revenue_30d - v_total_expense_30d) / v_total_revenue_30d;
        v_profit_history := GREATEST(0.0, LEAST(200.0, (v_profit_margin + 0.5) * 200.0));
    ELSE
        v_profit_history := 100.0;
    END IF;
    v_profit_history := GREATEST(0.0, LEAST(200.0, v_profit_history));

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
    'Computes a 0-1000 credit score from fleet health, revenue stability, debt ratio, cash reserves, and profit history.';


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
    v_tier VARCHAR(10);
BEGIN
    SELECT * INTO v_score FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF NOT FOUND THEN RETURN; END IF;

    v_tier := CASE
        WHEN v_score.total_score >= 900 THEN 'Platinum'
        WHEN v_score.total_score >= 750 THEN 'Gold'
        WHEN v_score.total_score >= 600 THEN 'Silver'
        WHEN v_score.total_score >= 400 THEN 'Standard'
        ELSE 'Subprime'
    END;

    INSERT INTO credit_scores (
        user_id, score, tier,
        fleet_health_score, revenue_stability_score,
        debt_ratio_score, cash_reserves_score, profit_history_score,
        computed_at
    ) VALUES (
        p_user_id, v_score.total_score, v_tier,
        v_score.fleet_health, v_score.revenue_stability,
        v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history,
        NOW()
    )
    ON CONFLICT (user_id) DO UPDATE SET
        score = EXCLUDED.score,
        tier = EXCLUDED.tier,
        fleet_health_score = EXCLUDED.fleet_health_score,
        revenue_stability_score = EXCLUDED.revenue_stability_score,
        debt_ratio_score = EXCLUDED.debt_ratio_score,
        cash_reserves_score = EXCLUDED.cash_reserves_score,
        profit_history_score = EXCLUDED.profit_history_score,
        computed_at = EXCLUDED.computed_at;

    UPDATE users
    SET credit_score = v_score.total_score,
        credit_score_updated_at = NOW()
    WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION update_credit_score(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_credit_score(UUID, TIMESTAMPTZ) TO service_role;

COMMENT ON FUNCTION update_credit_score(UUID, TIMESTAMPTZ) IS
    'Recalculates and persists a player''s credit score at each game-day boundary.';


-- ============================================================================
-- 7. FINANCE AIRCRAFT PURCHASE
-- ============================================================================
-- Takes aircraft_model_id, down_payment_pct, term_months.
-- Validates credit tier, deducts down payment, creates fleet entry,
-- and creates the financing record.
CREATE OR REPLACE FUNCTION finance_aircraft(
    p_aircraft_model_id UUID,
    p_down_payment_pct NUMERIC DEFAULT 0.20,
    p_term_months INT DEFAULT 36
)
RETURNS TABLE(success BOOLEAN, message TEXT, new_cash NUMERIC) AS $$
DECLARE
    v_user_id UUID;
    v_model RECORD;
    v_credit_score INT;
    v_tier VARCHAR(10);
    v_purchase_price NUMERIC;
    v_down_payment NUMERIC;
    v_principal NUMERIC;
    v_interest_rate NUMERIC;
    v_monthly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_fleet_id UUID;
    v_hq_iata VARCHAR(3);
    v_max_financing NUMERIC;
    v_economy_seats INT;
    v_business_seats INT;
    v_first_seats INT;
BEGIN
    v_user_id := require_current_user_id();

    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_purchase_price := v_model.purchase_price;

    SELECT u.credit_score, u.game_current_time, u.hq_airport_iata
    INTO v_credit_score, v_game_time, v_hq_iata
    FROM users u WHERE u.id = v_user_id;

    v_credit_score := COALESCE(v_credit_score, 500);

    SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = v_user_id;
    v_tier := COALESCE(v_tier, 'Standard');

    v_max_financing := CASE
        WHEN v_tier = 'Platinum' THEN 80000000
        WHEN v_tier = 'Gold'     THEN 60000000
        WHEN v_tier = 'Silver'   THEN 40000000
        WHEN v_tier = 'Standard' THEN 20000000
        ELSE 5000000
    END;

    IF v_purchase_price > v_max_financing THEN
        RETURN QUERY SELECT false,
            'Aircraft price ($' || v_purchase_price::TEXT ||
            ') exceeds your financing limit ($' || v_max_financing::TEXT ||
            ') for tier ' || v_tier || '.'::TEXT,
            0::NUMERIC;
        RETURN;
    END IF;

    IF p_term_months NOT IN (12, 24, 36, 48, 60) THEN
        RETURN QUERY SELECT false,
            'Financing term must be 12, 24, 36, 48, or 60 months.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    IF p_down_payment_pct < 0.10 OR p_down_payment_pct > 0.50 THEN
        RETURN QUERY SELECT false,
            'Down payment must be between 10% and 50%.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_interest_rate := CASE
        WHEN v_tier = 'Platinum' THEN 0.03
        WHEN v_tier = 'Gold'     THEN 0.04
        WHEN v_tier = 'Silver'   THEN 0.05
        WHEN v_tier = 'Standard' THEN 0.07
        ELSE 0.10
    END;
    v_total_repayable := v_principal * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;

    SELECT cash INTO v_cash FROM users WHERE id = v_user_id;
    IF v_cash < v_down_payment THEN
        RETURN QUERY SELECT false,
            'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT,
            0::NUMERIC;
        RETURN;
    END IF;

    UPDATE users SET cash = cash - v_down_payment WHERE id = v_user_id
    RETURNING cash INTO v_cash;

    v_economy_seats := GREATEST(1,
        v_model.capacity
        - (2 * FLOOR(v_model.capacity * 0.18 / 2.0)::INT)
        - (3 * FLOOR(v_model.capacity * 0.06 / 3.0)::INT));
    v_business_seats := FLOOR(v_model.capacity * 0.18 / 2.0)::INT;
    v_first_seats := FLOOR(v_model.capacity * 0.06 / 3.0)::INT;

    INSERT INTO user_fleet (
        user_id, aircraft_model_id, tail_number,
        economy_seats, business_seats, first_class_seats,
        condition, status, acquisition_type
    ) VALUES (
        v_user_id, p_aircraft_model_id,
        generate_tail_number(COALESCE(v_hq_iata, 'SG')),
        v_economy_seats, v_business_seats, v_first_seats,
        100.0, 'active', 'purchase'
    ) RETURNING id INTO v_fleet_id;

    INSERT INTO aircraft_financing (
        user_id, aircraft_model_id, fleet_aircraft_id,
        purchase_price, down_payment, principal,
        interest_rate, monthly_payment, term_months,
        remaining_balance, taken_at
    ) VALUES (
        v_user_id, p_aircraft_model_id, v_fleet_id,
        v_purchase_price, v_down_payment, v_principal,
        v_interest_rate, v_monthly_payment, p_term_months,
        v_total_repayable, v_game_time
    );

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (v_user_id, 'expense', 'aircraft_financing_down', v_down_payment,
            'Aircraft financing down payment', v_game_time);

    RETURN QUERY SELECT true,
        'Financed ' || v_model.manufacturer || ' ' || v_model.model_name ||
        '. Down: $' || ROUND(v_down_payment)::TEXT ||
        ', Monthly: $' || ROUND(v_monthly_payment, 2)::TEXT ||
        '/mo for ' || p_term_months::TEXT || ' months.'::TEXT,
        v_cash;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION finance_aircraft(UUID, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION finance_aircraft(UUID, NUMERIC, INT) TO authenticated;

COMMENT ON FUNCTION finance_aircraft(UUID, NUMERIC, INT) IS
    'Finance an aircraft purchase with a down payment and monthly installments. Creates fleet entry and financing record. Credit tier determines rate and limits.';


-- ============================================================================
-- 8. PROCESS AIRCRAFT FINANCING PAYMENTS (called at game-day boundary)
-- ============================================================================
-- Deducts monthly payments when due, tracks missed payments, and repossesses
-- the aircraft after 3 consecutive missed monthly payments.
CREATE OR REPLACE FUNCTION process_aircraft_financing_payments(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
)
RETURNS VOID AS $$
DECLARE
    r_fin RECORD;
    v_cash NUMERIC;
    v_days_since NUMERIC;
    v_expected_payments INT;
    v_late_fee NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;

    FOR r_fin IN
        SELECT * FROM aircraft_financing
        WHERE user_id = p_user_id AND status = 'active'
        ORDER BY taken_at ASC
    LOOP
        v_days_since := EXTRACT(EPOCH FROM (p_game_date - r_fin.taken_at)) / 86400.0;
        v_expected_payments := FLOOR(v_days_since / 30)::INT;

        IF v_expected_payments > (r_fin.payments_made + r_fin.missed_payments) THEN
            IF v_cash >= r_fin.monthly_payment THEN
                v_cash := v_cash - r_fin.monthly_payment;
                UPDATE users SET cash = v_cash WHERE id = p_user_id;

                UPDATE aircraft_financing
                SET remaining_balance = remaining_balance - r_fin.monthly_payment,
                    payments_made = payments_made + 1,
                    missed_payments = 0
                WHERE id = r_fin.id;

                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (p_user_id, 'expense', 'aircraft_financing',
                        r_fin.monthly_payment, 'Aircraft financing monthly payment', p_game_date);

                IF r_fin.remaining_balance - r_fin.monthly_payment <= 0 THEN
                    UPDATE aircraft_financing
                    SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0
                    WHERE id = r_fin.id;
                END IF;
            ELSE
                v_late_fee := r_fin.monthly_payment * 0.05;

                UPDATE aircraft_financing
                SET remaining_balance = remaining_balance + v_late_fee,
                    missed_payments = missed_payments + 1
                WHERE id = r_fin.id;

                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (p_user_id, 'expense', 'aircraft_financing_late_fee',
                        v_late_fee, 'Aircraft financing late fee — insufficient cash', p_game_date);

                IF r_fin.missed_payments + 1 >= 3 THEN
                    UPDATE aircraft_financing SET status = 'repossessed' WHERE id = r_fin.id;

                    IF r_fin.fleet_aircraft_id IS NOT NULL THEN
                        UPDATE user_fleet SET status = 'grounded'
                        WHERE id = r_fin.fleet_aircraft_id;
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION process_aircraft_financing_payments(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_aircraft_financing_payments(UUID, TIMESTAMPTZ) TO service_role;

COMMENT ON FUNCTION process_aircraft_financing_payments(UUID, TIMESTAMPTZ) IS
    'Monthly aircraft financing payment processor. Tracks missed payments; repossesses aircraft after 3 consecutive misses.';


-- ============================================================================
-- 9. ENHANCED TAKE_LOAN (credit-score-aware, loan-type-aware)
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
    v_tier VARCHAR(10);
    v_interest_rate NUMERIC;
    v_weekly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_max_principal NUMERIC;
BEGIN
    v_user_id := require_current_user_id();

    SELECT COUNT(*) INTO v_existing_loans
    FROM loans WHERE user_id = v_user_id AND status = 'active';
    IF v_existing_loans >= 3 THEN
        RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT u.credit_score, u.game_current_time INTO v_credit_score, v_game_time
    FROM users u WHERE u.id = v_user_id;
    v_credit_score := COALESCE(v_credit_score, 500);

    SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = v_user_id;
    v_tier := COALESCE(v_tier, 'Standard');

    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
        RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    IF p_loan_type = 'unsecured' THEN
        v_max_principal := CASE
            WHEN v_tier = 'Platinum' THEN 50000000 WHEN v_tier = 'Gold' THEN 30000000
            WHEN v_tier = 'Silver' THEN 15000000 WHEN v_tier = 'Standard' THEN 5000000 ELSE 1000000
        END;
        v_interest_rate := CASE
            WHEN v_tier = 'Platinum' THEN 0.03 WHEN v_tier = 'Gold' THEN 0.04
            WHEN v_tier = 'Silver' THEN 0.05 WHEN v_tier = 'Standard' THEN 0.07 ELSE 0.10
        END;
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM user_fleet WHERE id = p_collateral_aircraft_id AND user_id = v_user_id) THEN
            RETURN QUERY SELECT false, 'You do not own that aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        v_max_principal := CASE
            WHEN v_tier = 'Platinum' THEN 100000000 WHEN v_tier = 'Gold' THEN 75000000
            WHEN v_tier = 'Silver' THEN 50000000 WHEN v_tier = 'Standard' THEN 25000000 ELSE 10000000
        END;
        v_interest_rate := CASE
            WHEN v_tier = 'Platinum' THEN 0.02 WHEN v_tier = 'Gold' THEN 0.03
            WHEN v_tier = 'Silver' THEN 0.04 WHEN v_tier = 'Standard' THEN 0.06 ELSE 0.09
        END;
    ELSE
        v_max_principal := CASE
            WHEN v_tier = 'Platinum' THEN 50000000 WHEN v_tier = 'Gold' THEN 30000000
            WHEN v_tier = 'Silver' THEN 15000000 WHEN v_tier = 'Standard' THEN 5000000 ELSE 1000000
        END;
        v_interest_rate := CASE
            WHEN v_tier = 'Platinum' THEN 0.04 WHEN v_tier = 'Gold' THEN 0.05
            WHEN v_tier = 'Silver' THEN 0.06 WHEN v_tier = 'Standard' THEN 0.08 ELSE 0.11
        END;
    END IF;

    v_interest_rate := GREATEST(0.02, v_interest_rate);

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

    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    UPDATE users SET cash = cash + p_principal WHERE id = v_user_id
    RETURNING cash INTO v_cash;

    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance,
        weekly_payment, game_date_taken,
        loan_type, collateral_aircraft_id, credit_score_at_origination
    ) VALUES (
        v_user_id, p_principal, v_interest_rate, v_total_repayable,
        v_weekly_payment, v_game_time,
        p_loan_type, p_collateral_aircraft_id, v_credit_score
    );

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
    'Credit-score-aware loan origination. Supports unsecured, secured, and credit line types.';


-- ============================================================================
-- 10. ENHANCED PROCESS LOAN PAYMENTS
-- ============================================================================
-- Tracks missed_payments, defaults after 4 consecutive misses.
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
            v_cash := v_cash - v_payment;
            UPDATE users SET cash = v_cash WHERE id = p_user_id;

            UPDATE loans
            SET remaining_balance = remaining_balance - v_payment,
                missed_payments = 0
            WHERE id = r_loan.id;

            IF r_loan.remaining_balance - v_payment <= 0 THEN
                UPDATE loans
                SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0
                WHERE id = r_loan.id;
            END IF;

            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'loan_payment', v_payment, 'Loan payment', p_game_date);
        ELSE
            v_late_fee := v_payment * 0.1;

            UPDATE loans
            SET remaining_balance = remaining_balance + v_late_fee,
                missed_payments = missed_payments + 1
            WHERE id = r_loan.id;

            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'loan_late_fee', v_late_fee,
                    'Loan late fee — insufficient cash', p_game_date);

            IF r_loan.missed_payments + 1 >= 4 THEN
                UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;

                IF r_loan.loan_type = 'secured' AND r_loan.collateral_aircraft_id IS NOT NULL THEN
                    UPDATE user_fleet SET status = 'grounded'
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
    'Enhanced loan payment processor. Tracks missed payments; auto-defaults after 4 consecutive misses.';
