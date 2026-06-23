-- ============================================================================
-- MERGE AIRCRAFT_FINANCING INTO LOANS TABLE
-- ============================================================================
-- Consolidates the aircraft_financing table into the loans table by adding
-- aircraft-financing-specific columns and migrating existing data.
-- The aircraft_financing table is kept for reference during Phase 4/5.
-- ============================================================================


-- ============================================================================
-- 1. ADD NEW COLUMNS TO LOANS TABLE
-- ============================================================================
ALTER TABLE loans ADD COLUMN IF NOT EXISTS loan_subtype VARCHAR(30) DEFAULT 'cash'
    CHECK (loan_subtype IN ('cash', 'aircraft_financing'));

ALTER TABLE loans ADD COLUMN IF NOT EXISTS aircraft_model_id UUID REFERENCES aircraft_models(id);
ALTER TABLE loans ADD COLUMN IF NOT EXISTS fleet_aircraft_id UUID;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS purchase_price NUMERIC;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS down_payment NUMERIC;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS term_months INT;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS monthly_payment NUMERIC;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS payments_made INT DEFAULT 0;


-- ============================================================================
-- 2. UPDATE CHECK CONSTRAINTS
-- ============================================================================
ALTER TABLE loans DROP CONSTRAINT IF EXISTS loans_status_check;
ALTER TABLE loans ADD CONSTRAINT loans_status_check
    CHECK (status IN ('active', 'paid_off', 'defaulted', 'repossessed'));

ALTER TABLE loans DROP CONSTRAINT IF EXISTS loans_loan_type_check;
ALTER TABLE loans ADD CONSTRAINT loans_loan_type_check
    CHECK (loan_type IN ('unsecured', 'secured', 'credit_line', 'aircraft_financing'));


-- ============================================================================
-- 3. MIGRATE DATA FROM AIRCRAFT_FINANCING TO LOANS
-- ============================================================================
INSERT INTO loans (
    id, user_id, ai_competitor_id, principal, interest_rate, remaining_balance,
    weekly_payment, status, taken_at, paid_off_at, created_at,
    loan_type, loan_subtype, aircraft_model_id, fleet_aircraft_id,
    purchase_price, down_payment, term_months, monthly_payment,
    payments_made, missed_payments, credit_score_at_origination
)
SELECT
    af.id,
    af.user_id,
    af.ai_competitor_id,
    af.principal,
    af.interest_rate,
    af.remaining_balance,
    0,  -- aircraft financing uses monthly_payment, not weekly_payment
    af.status,
    af.taken_at,
    af.paid_off_at,
    af.created_at,
    'aircraft_financing',
    'aircraft_financing',
    af.aircraft_model_id,
    af.fleet_aircraft_id,
    af.purchase_price,
    af.down_payment,
    af.term_months,
    af.monthly_payment,
    af.payments_made,
    af.missed_payments,
    NULL
FROM aircraft_financing af
ON CONFLICT (id) DO NOTHING;


-- ============================================================================
-- 4. UPDATE process_aircraft_financing_payments TO USE LOANS TABLE
-- ============================================================================
CREATE OR REPLACE FUNCTION process_aircraft_financing_payments(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
) RETURNS VOID AS $fn$
DECLARE
    v_loan RECORD;
    v_cash NUMERIC;
    v_payment NUMERIC;
    v_late_fee NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    FOR v_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id
          AND loan_type = 'aircraft_financing'
          AND status = 'active'
    LOOP
        v_payment := v_loan.monthly_payment;
        IF v_cash >= v_payment THEN
            UPDATE users SET cash = cash - v_payment WHERE id = p_user_id;
            v_cash := v_cash - v_payment;
            UPDATE loans SET
                remaining_balance = remaining_balance - v_payment,
                payments_made = payments_made + 1
            WHERE id = v_loan.id;
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'aircraft_financing', v_payment,
                    'Aircraft financing payment', p_game_date);
            IF (SELECT remaining_balance FROM loans WHERE id = v_loan.id) <= 0 THEN
                UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0
                WHERE id = v_loan.id;
            END IF;
        ELSE
            v_late_fee := v_payment * 0.05;
            UPDATE loans SET
                remaining_balance = remaining_balance + v_late_fee,
                missed_payments = missed_payments + 1
            WHERE id = v_loan.id;
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'aircraft_financing_late_fee', v_late_fee,
                    'Aircraft financing late fee', p_game_date);
            IF (SELECT missed_payments FROM loans WHERE id = v_loan.id) >= 3 THEN
                UPDATE loans SET status = 'repossessed' WHERE id = v_loan.id;
                IF v_loan.fleet_aircraft_id IS NOT NULL THEN
                    UPDATE user_fleet SET status = 'grounded' WHERE id = v_loan.fleet_aircraft_id;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$fn$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION process_aircraft_financing_payments(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_aircraft_financing_payments(UUID, TIMESTAMPTZ) TO service_role, authenticated;


-- ============================================================================
-- 5. UPDATE finance_aircraft TO INSERT INTO LOANS
-- ============================================================================
CREATE OR REPLACE FUNCTION finance_aircraft(
    p_aircraft_model_id UUID,
    p_down_payment_pct NUMERIC DEFAULT 0.20,
    p_term_months INT DEFAULT 36
)
RETURNS TABLE(success BOOLEAN, message TEXT, new_cash NUMERIC) AS $fn$
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
    INSERT INTO loans (
        user_id, aircraft_model_id, fleet_aircraft_id,
        purchase_price, down_payment, principal,
        interest_rate, monthly_payment, term_months,
        remaining_balance, weekly_payment, taken_at,
        loan_type, loan_subtype
    ) VALUES (
        v_user_id, p_aircraft_model_id, v_fleet_id,
        v_purchase_price, v_down_payment, v_principal,
        v_interest_rate, v_monthly_payment, p_term_months,
        v_total_repayable, 0, v_game_time,
        'aircraft_financing', 'aircraft_financing'
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
$fn$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION finance_aircraft(UUID, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION finance_aircraft(UUID, NUMERIC, INT) TO authenticated;

COMMENT ON FUNCTION finance_aircraft(UUID, NUMERIC, INT) IS
    'Finance an aircraft purchase with a down payment and monthly installments. Creates fleet entry and financing record. Credit tier determines rate and limits.';


-- ============================================================================
-- 6. UPDATE bot_finance_aircraft TO INSERT INTO LOANS
-- ============================================================================
CREATE OR REPLACE FUNCTION bot_finance_aircraft(
    p_bot_id UUID,
    p_aircraft_model_id UUID,
    p_down_payment_pct NUMERIC DEFAULT 0.20,
    p_term_months INT DEFAULT 60
)
RETURNS BOOLEAN AS $fn$
DECLARE
    v_model RECORD;
    v_purchase_price NUMERIC;
    v_down_payment NUMERIC;
    v_principal NUMERIC;
    v_interest_rate NUMERIC := 0.05;
    v_monthly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_bot_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_hq_iata VARCHAR(3);
    v_fleet_id UUID;
    v_tail VARCHAR(20);
    v_economy INT;
    v_business INT;
    v_first INT;
    v_archetype VARCHAR;
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN RETURN false; END IF;

    SELECT cash, game_current_time, hq_airport_iata, archetype
    INTO v_bot_cash, v_game_time, v_hq_iata, v_archetype
    FROM ai_competitors WHERE id = p_bot_id;

    IF NOT FOUND THEN RETURN false; END IF;

    v_purchase_price := v_model.purchase_price;
    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_total_repayable := v_principal * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;

    -- Guard: must have cash for down payment
    IF v_bot_cash < v_down_payment THEN
        RETURN false;
    END IF;

    -- Deduct down payment
    UPDATE ai_competitors SET cash = cash - v_down_payment WHERE id = p_bot_id;

    -- Archetype-based cabin layout
    v_economy := CASE
        WHEN v_archetype = 'Regional'  THEN FLOOR(v_model.capacity * 0.80)
        WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)
        ELSE FLOOR(v_model.capacity * 0.50)
    END;
    v_business := CASE
        WHEN v_archetype = 'Regional'  THEN FLOOR(v_model.capacity * 0.15)
        WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)
        ELSE FLOOR(v_model.capacity * 0.30)
    END;
    v_first := v_model.capacity - v_economy - v_business;

    v_tail := generate_tail_number(COALESCE(v_hq_iata, 'SG'));

    INSERT INTO user_fleet (
        ai_competitor_id, aircraft_model_id, tail_number,
        acquisition_type, condition, status,
        economy_seats, business_seats, first_class_seats
    ) VALUES (
        p_bot_id, p_aircraft_model_id, v_tail,
        'purchase', 100.00, 'active',
        v_economy, v_business, v_first
    ) RETURNING id INTO v_fleet_id;

    INSERT INTO loans (
        ai_competitor_id, aircraft_model_id, fleet_aircraft_id,
        purchase_price, down_payment, principal,
        interest_rate, monthly_payment, term_months,
        remaining_balance, weekly_payment, taken_at,
        loan_type, loan_subtype
    ) VALUES (
        p_bot_id, p_aircraft_model_id, v_fleet_id,
        v_purchase_price, v_down_payment, v_principal,
        v_interest_rate, v_monthly_payment, p_term_months,
        v_total_repayable, 0, v_game_time,
        'aircraft_financing', 'aircraft_financing'
    );

    -- Ledger: down payment expense
    INSERT INTO financial_ledger (
        ai_competitor_id, transaction_type, category, amount, description, game_date
    ) VALUES (
        p_bot_id, 'expense', 'aircraft_financing_down', v_down_payment,
        'Aircraft financing down payment — ' || v_model.model_name,
        v_game_time
    );

    RETURN true;
END;
$fn$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION bot_finance_aircraft(UUID, UUID, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bot_finance_aircraft(UUID, UUID, NUMERIC, INT) TO service_role;

COMMENT ON FUNCTION bot_finance_aircraft(UUID, UUID, NUMERIC, INT) IS
    'Finance an aircraft purchase for a bot with a down payment and monthly installments at 5% APR.';


-- ============================================================================
-- 7. UPDATE calculate_credit_score TO QUERY LOANS INSTEAD OF AIRCRAFT_FINANCING
-- ============================================================================
CREATE OR REPLACE FUNCTION calculate_credit_score(p_user_id UUID)
RETURNS TABLE (
    total_score INT,
    fleet_health INT,
    revenue_stability INT,
    debt_ratio INT,
    cash_reserve INT,
    profit_history INT
) AS $fn$
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
    -- After merge: all debt (including aircraft financing) is in the loans table
    SELECT COALESCE(SUM(remaining_balance), 0) INTO v_total_debt
    FROM loans WHERE user_id = p_user_id AND status = 'active';

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
$fn$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION calculate_credit_score(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION calculate_credit_score(UUID) TO authenticated, service_role;

COMMENT ON FUNCTION calculate_credit_score(UUID) IS
    'Computes a 0-1000 credit score from fleet health, revenue stability, debt ratio, cash reserves, and profit history.';


-- ============================================================================
-- 8. DO NOT DROP AIRCRAFT_FINANCING — KEEP FOR REFERENCE DURING PHASE 4/5
-- ============================================================================
