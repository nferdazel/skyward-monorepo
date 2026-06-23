-- ============================================================================
-- Migration 106: RPC consolidation and cleanup
-- 1. Merge bot functions into player equivalents (actor_type dispatch)
-- 2. Rewrite process_simulation_delta to delegate to season clock
-- 3. Fix sell_aircraft SECURITY DEFINER pattern
-- 4. Rename trigger functions with trg_ prefix
-- ============================================================================

-- ============================================================================
-- 1a. Consolidate bot_take_loan into take_loan
--     Adds p_user_id overload: if actor_type = 'AI', use simplified bot logic.
--     The original (NUMERIC, INT, VARCHAR, UUID) signature is preserved for
--     player callers; the new (UUID, NUMERIC, INT, VARCHAR, UUID) overload
--     serves bot callers and internal dispatch.
-- ============================================================================

CREATE OR REPLACE FUNCTION take_loan(
    p_user_id   UUID,
    p_principal NUMERIC,
    p_term_weeks INT DEFAULT 52,
    p_loan_type VARCHAR DEFAULT 'unsecured',
    p_collateral_aircraft_id UUID DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT, new_cash NUMERIC) AS $$
DECLARE
    v_actor_type VARCHAR(10);
    v_existing_loans INT;
    v_credit_score INT;
    v_score_record RECORD;
    v_tier VARCHAR(10);
    v_config JSONB;
    v_tier_cfg JSONB;
    v_min_loan NUMERIC;
    v_max_loans INT;
    v_interest_rate NUMERIC;
    v_weekly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_max_principal NUMERIC;
    v_rate_key TEXT;
BEGIN
    SELECT u.actor_type, u.credit_score, u.game_current_time
    INTO v_actor_type, v_credit_score, v_game_time
    FROM users u WHERE u.id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- ── Bot fast path ──
    IF v_actor_type = 'AI' THEN
        SELECT COUNT(*) INTO v_existing_loans
        FROM loans WHERE user_id = p_user_id AND status = 'active';
        IF v_existing_loans >= 3 THEN
            RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        IF p_principal < 100000 OR p_principal > 5000000 THEN
            RETURN QUERY SELECT false, 'Bot loan amount must be between $100K and $5M.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;

        v_interest_rate := 0.05;
        v_total_repayable := p_principal * (1 + v_interest_rate);
        v_weekly_payment := v_total_repayable / p_term_weeks;

        UPDATE users SET cash = cash + p_principal WHERE id = p_user_id;

        INSERT INTO loans (
            user_id, principal, interest_rate, remaining_balance,
            weekly_payment, game_date_taken, status
        ) VALUES (
            p_user_id, p_principal, v_interest_rate, v_total_repayable,
            v_weekly_payment, v_game_time, 'active'
        );

        INSERT INTO financial_ledger (
            user_id, transaction_type, category, amount, description, game_date
        ) VALUES (
            p_user_id, 'revenue', 'loan', p_principal,
            'Bank loan taken — $' || p_principal::TEXT || ' at 5% APR',
            v_game_time
        );

        SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
        RETURN QUERY SELECT true,
            'Loan approved! $' || p_principal::TEXT || ' at 5% APR (bot).',
            v_cash;
        RETURN;
    END IF;

    -- ── Player path ──
    SELECT credit_tier_config INTO v_config
    FROM global_game_settings WHERE id = 1;

    v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
    v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);

    SELECT COUNT(*) INTO v_existing_loans
    FROM loans WHERE user_id = p_user_id AND status = 'active';
    IF v_existing_loans >= v_max_loans THEN
        RETURN QUERY SELECT false,
            'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_credit_score := COALESCE(v_credit_score, 500);

    SELECT * INTO v_score_record
    FROM calculate_credit_score(p_user_id)
    LIMIT 1;

    IF FOUND THEN
        v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE
        v_tier := resolve_credit_tier(v_credit_score);
    END IF;

    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);

    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
        RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    IF p_loan_type = 'unsecured' THEN
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
        v_rate_key := 'rate_unsecured';
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE id = p_collateral_aircraft_id AND user_id = p_user_id) THEN
            RETURN QUERY SELECT false, 'You do not own that aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
        v_rate_key := 'rate_secured';
    ELSE
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_financing')::NUMERIC, 0.07);
        v_rate_key := 'rate_financing';
    END IF;

    IF p_principal < v_min_loan OR p_principal > v_max_principal THEN
        RETURN QUERY SELECT false,
            'Loan amount must be between $' ||
            (v_min_loan / 1000)::TEXT || 'K and $' ||
            CASE WHEN v_max_principal >= 1000000
                 THEN (v_max_principal / 1000000)::TEXT || 'M'
                 ELSE (v_max_principal / 1000)::TEXT || 'K'
            END ||
            ' for your ' || v_tier || ' credit tier.'::TEXT,
            0::NUMERIC;
        RETURN;
    END IF;

    v_total_repayable := p_principal * (1 + v_interest_rate * (p_term_weeks / 52.0));
    v_weekly_payment := v_total_repayable / p_term_weeks;

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id FOR UPDATE;
    IF v_cash < 0 THEN
        RETURN QUERY SELECT false, 'Cannot take loan with negative cash balance.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance,
        weekly_payment, status, game_date_taken,
        loan_type, collateral_aircraft_id, credit_score_at_origination
    ) VALUES (
        p_user_id, p_principal, v_interest_rate, v_total_repayable,
        v_weekly_payment, 'active', v_game_time,
        p_loan_type, p_collateral_aircraft_id, v_credit_score
    );

    UPDATE users SET cash = cash + p_principal WHERE id = p_user_id;
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;

    RETURN QUERY SELECT true,
        'Loan approved! $' || p_principal::TEXT || ' at ' ||
        (v_interest_rate * 100)::TEXT || '% APR (' || v_tier || ' tier).'::TEXT,
        v_cash;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION take_loan(UUID, NUMERIC, INT, VARCHAR, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION take_loan(UUID, NUMERIC, INT, VARCHAR, UUID) TO service_role;

COMMENT ON FUNCTION take_loan(UUID, NUMERIC, INT, VARCHAR, UUID) IS
    'Process a loan for a specific user. Bot (actor_type=AI) uses simplified 5% rate / $5M max. Player uses credit-tier logic.';

DROP FUNCTION IF EXISTS bot_take_loan(UUID, NUMERIC, INT);


-- ============================================================================
-- 1b. Consolidate bot_finance_aircraft into finance_aircraft
--     Adds p_user_id overload for bot callers.
-- ============================================================================

CREATE OR REPLACE FUNCTION finance_aircraft(
    p_user_id UUID,
    p_aircraft_model_id UUID,
    p_down_payment_pct NUMERIC DEFAULT 0.20,
    p_term_months INT DEFAULT 36
)
RETURNS TABLE(success BOOLEAN, message TEXT, new_cash NUMERIC) AS $fn$
DECLARE
    v_actor_type VARCHAR(10);
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
    v_archetype VARCHAR(30);
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_purchase_price := v_model.purchase_price;

    SELECT u.actor_type, u.credit_score, u.game_current_time, u.hq_airport_iata, u.archetype
    INTO v_actor_type, v_credit_score, v_game_time, v_hq_iata, v_archetype
    FROM users u WHERE u.id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- ── Bot fast path ──
    IF v_actor_type = 'AI' THEN
        SELECT cash INTO v_cash FROM users WHERE id = p_user_id;

        v_down_payment := v_purchase_price * p_down_payment_pct;
        v_principal := v_purchase_price - v_down_payment;
        v_interest_rate := 0.05;
        v_total_repayable := v_principal * (1 + v_interest_rate);
        v_monthly_payment := v_total_repayable / p_term_months;

        IF v_cash < v_down_payment THEN
            RETURN QUERY SELECT false,
                'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT,
                0::NUMERIC;
            RETURN;
        END IF;

        UPDATE users SET cash = cash - v_down_payment WHERE id = p_user_id;

        v_economy_seats := CASE
            WHEN v_archetype = 'Regional'   THEN FLOOR(v_model.capacity * 0.80)
            WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)
            ELSE FLOOR(v_model.capacity * 0.50)
        END;
        v_business_seats := CASE
            WHEN v_archetype = 'Regional'   THEN FLOOR(v_model.capacity * 0.15)
            WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)
            ELSE FLOOR(v_model.capacity * 0.30)
        END;
        v_first_seats := v_model.capacity - v_economy_seats - v_business_seats;

        INSERT INTO fleet_aircraft (
            user_id, aircraft_model_id, tail_number,
            acquisition_type, condition, status,
            economy_seats, business_seats, first_class_seats
        ) VALUES (
            p_user_id, p_aircraft_model_id,
            generate_tail_number(COALESCE(v_hq_iata, 'SG')),
            'purchase', 100.00, 'active',
            v_economy_seats, v_business_seats, v_first_seats
        ) RETURNING id INTO v_fleet_id;

        INSERT INTO loans (
            user_id, aircraft_model_id, fleet_aircraft_id,
            purchase_price, down_payment, principal,
            interest_rate, monthly_payment, term_months,
            remaining_balance, weekly_payment, taken_at,
            loan_type, loan_subtype
        ) VALUES (
            p_user_id, p_aircraft_model_id, v_fleet_id,
            v_purchase_price, v_down_payment, v_principal,
            v_interest_rate, v_monthly_payment, p_term_months,
            v_total_repayable, 0, v_game_time,
            'aircraft_financing', 'aircraft_financing'
        );

        INSERT INTO financial_ledger (
            user_id, transaction_type, category, amount, description, game_date
        ) VALUES (
            p_user_id, 'expense', 'aircraft_financing_down', v_down_payment,
            'Aircraft financing down payment',
            v_game_time
        );

        SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
        RETURN QUERY SELECT true,
            'Financed ' || v_model.manufacturer || ' ' || v_model.model_name ||
            '. Down: $' || ROUND(v_down_payment)::TEXT ||
            ', Monthly: $' || ROUND(v_monthly_payment, 2)::TEXT ||
            '/mo for ' || p_term_months::TEXT || ' months (bot).'::TEXT,
            v_cash;
        RETURN;
    END IF;

    -- ── Player path ──
    v_credit_score := COALESCE(v_credit_score, 500);
    SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = p_user_id;
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

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    IF v_cash < v_down_payment THEN
        RETURN QUERY SELECT false,
            'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT,
            0::NUMERIC;
        RETURN;
    END IF;

    UPDATE users SET cash = cash - v_down_payment WHERE id = p_user_id
    RETURNING cash INTO v_cash;

    v_economy_seats := GREATEST(1,
        v_model.capacity
        - (2 * FLOOR(v_model.capacity * 0.18 / 2.0)::INT)
        - (3 * FLOOR(v_model.capacity * 0.06 / 3.0)::INT));
    v_business_seats := FLOOR(v_model.capacity * 0.18 / 2.0)::INT;
    v_first_seats := FLOOR(v_model.capacity * 0.06 / 3.0)::INT;

    INSERT INTO fleet_aircraft (
        user_id, aircraft_model_id, tail_number,
        economy_seats, business_seats, first_class_seats,
        condition, status, acquisition_type
    ) VALUES (
        p_user_id, p_aircraft_model_id,
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
        p_user_id, p_aircraft_model_id, v_fleet_id,
        v_purchase_price, v_down_payment, v_principal,
        v_interest_rate, v_monthly_payment, p_term_months,
        v_total_repayable, 0, v_game_time,
        'aircraft_financing', 'aircraft_financing'
    );

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_user_id, 'expense', 'aircraft_financing_down', v_down_payment,
            'Aircraft financing down payment', v_game_time);

    RETURN QUERY SELECT true,
        'Financed ' || v_model.manufacturer || ' ' || v_model.model_name ||
        '. Down: $' || ROUND(v_down_payment)::TEXT ||
        ', Monthly: $' || ROUND(v_monthly_payment, 2)::TEXT ||
        '/mo for ' || p_term_months::TEXT || ' months.'::TEXT,
        v_cash;
END;
$fn$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION finance_aircraft(UUID, UUID, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION finance_aircraft(UUID, UUID, NUMERIC, INT) TO service_role;

COMMENT ON FUNCTION finance_aircraft(UUID, UUID, NUMERIC, INT) IS
    'Finance an aircraft for a specific user. Bot (actor_type=AI) uses simplified 5% rate. Player uses credit-tier logic.';

DROP FUNCTION IF EXISTS bot_finance_aircraft(UUID, UUID, NUMERIC, INT);


-- ============================================================================
-- 1c. Consolidate process_bot_loan_payments into process_loan_payments
--     Checks actor_type: if AI, use bot penalty logic; if player, use existing.
-- ============================================================================

CREATE OR REPLACE FUNCTION process_loan_payments(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
)
RETURNS VOID AS $$
DECLARE
    v_actor_type VARCHAR(10);
    r_loan RECORD;
    v_cash NUMERIC;
    v_payment NUMERIC;
    v_late_fee NUMERIC;
BEGIN
    SELECT actor_type INTO v_actor_type FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN; END IF;

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;

    FOR r_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id AND status = 'active'
        ORDER BY taken_at ASC
    LOOP
        IF v_actor_type = 'AI' THEN
            -- ── Bot path: simplified penalty ──
            IF v_cash >= r_loan.weekly_payment THEN
                UPDATE users SET cash = cash - r_loan.weekly_payment WHERE id = p_user_id;
                v_cash := v_cash - r_loan.weekly_payment;

                UPDATE loans SET remaining_balance = remaining_balance - r_loan.weekly_payment
                WHERE id = r_loan.id;

                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0
                    WHERE id = r_loan.id;
                END IF;
            ELSE
                UPDATE loans SET
                    remaining_balance = remaining_balance * 1.10,
                    missed_payments = missed_payments + 1
                WHERE id = r_loan.id;

                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
                END IF;
            END IF;
        ELSE
            -- ── Player path: tier-based late fees ──
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
                        UPDATE fleet_aircraft SET status = 'grounded'
                        WHERE id = r_loan.collateral_aircraft_id;
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION process_loan_payments(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_loan_payments(UUID, TIMESTAMPTZ) TO service_role;

COMMENT ON FUNCTION process_loan_payments(UUID, TIMESTAMPTZ) IS
    'Process loan payments. Bot (actor_type=AI) uses simplified 10% penalty. Player uses tier-based late fees with collateral seizure.';

DROP FUNCTION IF EXISTS process_bot_loan_payments(UUID, TIMESTAMPTZ);


-- ============================================================================
-- 1d. Consolidate calculate_bot_credit_score into calculate_credit_score
--     Checks actor_type: if AI, simplified scoring; if player, 5-component.
--     Adds tier to return type for bot compatibility.
-- ============================================================================

DROP FUNCTION IF EXISTS calculate_credit_score(UUID);

CREATE OR REPLACE FUNCTION calculate_credit_score(p_user_id UUID)
RETURNS TABLE (
    total_score INT,
    tier VARCHAR(10),
    fleet_health INT,
    revenue_stability INT,
    debt_ratio INT,
    cash_reserve INT,
    profit_history INT
) AS $fn$
DECLARE
    v_user RECORD;
    v_actor_type VARCHAR(10);
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
    v_tier VARCHAR(10);
BEGIN
    SELECT u.cash, u.net_worth, u.game_current_time, u.actor_type
    INTO v_user
    FROM users u WHERE u.id = p_user_id;

    IF NOT FOUND THEN
        total_score := 500; tier := 'Standard';
        fleet_health := 100; revenue_stability := 100;
        debt_ratio := 100; cash_reserve := 100; profit_history := 100;
        RETURN NEXT;
        RETURN;
    END IF;

    v_actor_type := COALESCE(v_user.actor_type, 'REAL');
    v_cash := COALESCE(v_user.cash, 0.0);
    v_net_worth := COALESCE(v_user.net_worth, 0.0);

    SELECT starting_cash INTO v_starting_cash FROM global_game_settings LIMIT 1;
    v_starting_cash := COALESCE(v_starting_cash, 15000000.0);

    -- Fleet Health (0-200)
    SELECT
        COUNT(*)::INT,
        COALESCE(AVG(condition), 100.0),
        COALESCE(
            COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC /
            NULLIF(COUNT(*), 0), 0.0
        )
    INTO v_fleet_count, v_avg_condition, v_grounded_ratio
    FROM fleet_aircraft WHERE user_id = p_user_id;

    IF v_fleet_count > 0 THEN
        v_fleet_health := (v_avg_condition / 100.0) * 150.0
                        + 50.0 * (1.0 - v_grounded_ratio);
    ELSE
        v_fleet_health := 100.0;
    END IF;
    v_fleet_health := GREATEST(0.0, LEAST(200.0, v_fleet_health));

    -- Revenue Stability (0-200)
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

    -- Debt Ratio (0-200)
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

    -- Cash Reserves (0-200)
    IF v_starting_cash > 0 THEN
        v_cash_reserve := LEAST(200.0, (v_cash / v_starting_cash) * 100.0);
    ELSE
        v_cash_reserve := 100.0;
    END IF;
    IF v_cash < 0 THEN v_cash_reserve := 0.0; END IF;
    v_cash_reserve := GREATEST(0.0, LEAST(200.0, v_cash_reserve));

    -- Profit History (0-200)
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

    v_tier := CASE
        WHEN v_total_score >= 900 THEN 'Platinum'
        WHEN v_total_score >= 750 THEN 'Gold'
        WHEN v_total_score >= 600 THEN 'Silver'
        WHEN v_total_score >= 400 THEN 'Standard'
        ELSE 'Subprime'
    END;

    total_score := v_total_score;
    tier := v_tier;
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
    'Computes a 0-1000 credit score. Bot (actor_type=AI) uses same 5-component scoring. Returns total_score, tier, and component breakdown.';

DROP FUNCTION IF EXISTS calculate_bot_credit_score(UUID);


-- ============================================================================
-- 2. Rewrite process_simulation_delta to delegate to season clock
-- ============================================================================

CREATE OR REPLACE FUNCTION process_simulation_delta(p_user_id UUID)
RETURNS TABLE (
    cash_before NUMERIC(20,2),
    cash_after NUMERIC(20,2),
    elapsed_real_sec DOUBLE PRECISION,
    elapsed_game_days DOUBLE PRECISION,
    flights_run INT
) AS $$
DECLARE
    v_season_time TIMESTAMPTZ;
    v_result RECORD;
BEGIN
    SELECT current_game_time INTO v_season_time
    FROM season_clock WHERE status = 'active' LIMIT 1;

    IF v_season_time IS NULL THEN
        RAISE EXCEPTION 'No active season found';
    END IF;

    SELECT * INTO v_result
    FROM process_player_simulation_to_time(p_user_id, v_season_time);

    cash_before := 0;
    cash_after := v_result.cash;
    elapsed_real_sec := 0;
    elapsed_game_days := v_result.elapsed_days;
    flights_run := v_result.flights_run;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;


-- ============================================================================
-- 3. Fix sell_aircraft SECURITY DEFINER pattern
--    1-param wrapper (auth) = SECURITY DEFINER
--    2-param implementation = NOT SECURITY DEFINER
-- ============================================================================

CREATE OR REPLACE FUNCTION sell_aircraft(
    p_user_id UUID,
    p_fleet_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_user RECORD;
    v_fleet RECORD;
    v_base_value NUMERIC(20,2);
    v_age_years NUMERIC;
    v_depreciation_factor NUMERIC;
    v_sale_value NUMERIC(20,2);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    SELECT f.*, m.model_name, m.purchase_price
    INTO v_fleet
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'purchase' THEN
        RETURN QUERY SELECT FALSE, 'Only owned aircraft can be sold.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM route_assignments
        WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id
    ) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    v_base_value := calculate_owned_aircraft_sale_value(
        v_fleet.purchase_price, v_fleet.condition);

    IF v_fleet.acquired_game_date IS NOT NULL AND v_user.game_current_time IS NOT NULL THEN
        v_age_years := EXTRACT(EPOCH FROM (v_user.game_current_time - v_fleet.acquired_game_date))
                       / (365.25 * 86400.0);
        v_depreciation_factor := GREATEST(0.10, 1.0 - (0.05 * COALESCE(v_age_years, 0)));
        v_sale_value := ROUND(v_base_value * v_depreciation_factor, 2);
    ELSE
        v_sale_value := v_base_value;
    END IF;

    UPDATE users SET cash = cash + v_sale_value WHERE id = p_user_id
    RETURNING cash INTO new_cash;

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_user_id, 'revenue', 'aircraft_sale', v_sale_value,
            'Sold owned aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') ||
            ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
            date_trunc('day', v_user.game_current_time));

    DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Aircraft sold successfully!'::VARCHAR, new_cash;
END;
$$ LANGUAGE plpgsql VOLATILE SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION sell_aircraft(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sell_aircraft(UUID, UUID) TO authenticated, service_role;

COMMENT ON FUNCTION sell_aircraft(UUID, UUID) IS
    'Sells owned aircraft. Sale value depreciated 5% per game-year of age (floor 10% of base value). Not SECURITY DEFINER — called from SD wrapper.';


-- ============================================================================
-- 4. Rename trigger functions with trg_ prefix
--    Triggers auto-update when functions are renamed via ALTER FUNCTION.
-- ============================================================================

ALTER FUNCTION assign_active_season_id() RENAME TO trg_assign_active_season_id;
ALTER FUNCTION set_acquired_game_date() RENAME TO trg_set_acquired_game_date;
ALTER FUNCTION set_default_fare_buckets() RENAME TO trg_set_default_fare_buckets;
ALTER FUNCTION sync_checking_balance() RENAME TO trg_sync_checking_balance;
ALTER FUNCTION create_default_bank_account() RENAME TO trg_create_default_bank_account;


-- ============================================================================
-- 5. Verification
-- ============================================================================

-- Verify dropped functions no longer exist
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'bot_take_loan') THEN
        RAISE EXCEPTION 'bot_take_loan still exists';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'bot_finance_aircraft') THEN
        RAISE EXCEPTION 'bot_finance_aircraft still exists';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'process_bot_loan_payments') THEN
        RAISE EXCEPTION 'process_bot_loan_payments still exists';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'calculate_bot_credit_score') THEN
        RAISE EXCEPTION 'calculate_bot_credit_score still exists';
    END IF;
    RAISE NOTICE 'Migration 106 complete: all bot functions consolidated, triggers renamed.';
END $$;
