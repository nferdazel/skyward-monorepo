-- ============================================================================
-- Migration 08: Finance Phase 1 — cash movement correctness
-- Fixes:
--   - aircraft financing stores monthly payment but is serviced in weekly loop
--   - non-cash refinance / late-fee events pollute bank_transactions
-- ============================================================================

-- ============================================================================
-- DATA CLEANUP: remove historical non-cash ledger noise
-- refinance and loan late-fee rows did not move bank cash and should not live
-- in the canonical cash ledger.
-- ============================================================================
DELETE FROM bank_transactions
WHERE transaction_type IN ('refinance', 'late_fee')
  AND ifrs_category = 'financing';

-- Backfill weekly payment for existing aircraft financing loans.
UPDATE loans
SET weekly_payment = monthly_payment / 4.33
WHERE loan_type = 'aircraft_financing'
  AND COALESCE(weekly_payment, 0) <= 0
  AND COALESCE(monthly_payment, 0) > 0;

-- ============================================================================
-- FIX 1: bot_finance_aircraft — store weekly payment as the servicing source
-- of truth, while keeping monthly_payment for display.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_finance_aircraft(
    p_bot_id uuid,
    p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20,
    p_term_months integer DEFAULT 60
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_model RECORD;
v_purchase_price NUMERIC;
v_down_payment NUMERIC;
v_principal NUMERIC;
v_interest_rate NUMERIC := 0.05;
v_monthly_payment NUMERIC;
v_weekly_payment NUMERIC;
v_total_repayable NUMERIC;
v_cash NUMERIC;
v_game_time TIMESTAMPTZ;
v_fleet_id UUID;
v_hq_iata VARCHAR(3);
BEGIN
SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
IF NOT FOUND THEN RETURN false; END IF;

v_purchase_price := v_model.purchase_price;
v_down_payment := v_purchase_price * p_down_payment_pct;
v_principal := v_purchase_price - v_down_payment;
v_total_repayable := v_principal * (1 + v_interest_rate);
v_monthly_payment := v_total_repayable / p_term_months;
v_weekly_payment := v_monthly_payment / 4.33;
v_cash := get_user_balance(p_bot_id);

SELECT game_current_time, hq_airport_iata
INTO v_game_time, v_hq_iata
FROM users
WHERE id = p_bot_id;

IF v_cash < v_down_payment THEN RETURN false; END IF;

PERFORM debit_bank_account(
    p_bot_id,
    v_down_payment,
    'investing',
    'aircraft_purchase_deposit',
    'Aircraft financing down payment — ' || v_model.model_name,
    v_game_time
);

INSERT INTO fleet_aircraft (
    user_id, aircraft_model_id, nickname, acquisition_type, condition,
    status, tail_number, economy_seats, business_seats, first_class_seats
)
VALUES (
    p_bot_id,
    p_aircraft_model_id,
    v_model.model_name,
    'finance',
    100.00,
    'active',
    generate_tail_number(COALESCE(v_hq_iata, 'CGK')),
    FLOOR(v_model.capacity * 0.70)::INT,
    FLOOR(v_model.capacity * 0.20)::INT,
    FLOOR(v_model.capacity * 0.10)::INT
)
RETURNING id INTO v_fleet_id;

INSERT INTO loans (
    user_id, principal, interest_rate, remaining_balance, weekly_payment,
    status, loan_type, collateral_aircraft_id, term_months, monthly_payment
)
VALUES (
    p_bot_id,
    v_principal,
    v_interest_rate,
    v_total_repayable,
    v_weekly_payment,
    'active',
    'aircraft_financing',
    v_fleet_id,
    p_term_months,
    v_monthly_payment
);

RETURN true;
END;
$function$;

-- ============================================================================
-- FIX 2: finance_aircraft — same cadence correction for AI and human paths.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.finance_aircraft(
    p_user_id uuid,
    p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20,
    p_term_months integer DEFAULT 36
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_actor_type VARCHAR(10); v_model RECORD; v_credit_score INT; v_tier VARCHAR(10);
v_purchase_price NUMERIC; v_down_payment NUMERIC; v_principal NUMERIC;
v_interest_rate NUMERIC; v_monthly_payment NUMERIC; v_weekly_payment NUMERIC;
v_total_repayable NUMERIC;
v_cash NUMERIC; v_game_time TIMESTAMPTZ; v_fleet_id UUID; v_hq_iata VARCHAR(3);
v_max_financing NUMERIC; v_economy_seats INT; v_business_seats INT; v_first_seats INT;
v_archetype VARCHAR(30);
BEGIN
SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
IF NOT FOUND THEN RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC; RETURN; END IF;

v_purchase_price := v_model.purchase_price;

SELECT u.actor_type, u.game_current_time, u.hq_airport_iata
INTO v_actor_type, v_game_time, v_hq_iata
FROM users u
WHERE u.id = p_user_id;
IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;

IF v_actor_type = 'AI' THEN
    SELECT COALESCE(bp.archetype, 'Balanced') INTO v_archetype
    FROM bot_profiles bp
    WHERE bp.user_id = p_user_id;
    IF NOT FOUND THEN v_archetype := 'Balanced'; END IF;
END IF;

IF v_actor_type = 'AI' THEN
    v_cash := get_user_balance(p_user_id);
    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_interest_rate := 0.05;
    v_total_repayable := v_principal * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;
    v_weekly_payment := v_monthly_payment / 4.33;
    IF v_cash < v_down_payment THEN
        RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    PERFORM debit_bank_account(
        p_user_id,
        v_down_payment,
        'investing',
        'aircraft_purchase_deposit',
        'Aircraft financing down payment — ' || v_model.model_name,
        v_game_time
    );

    v_economy_seats := CASE
        WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.80)::INT
        WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)::INT
        ELSE FLOOR(v_model.capacity * 0.50)::INT
    END;
    v_business_seats := CASE
        WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.15)::INT
        WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)::INT
        ELSE FLOOR(v_model.capacity * 0.30)::INT
    END;
    v_first_seats := v_model.capacity - v_economy_seats - v_business_seats;

    INSERT INTO fleet_aircraft (
        user_id, aircraft_model_id, nickname, tail_number, acquisition_type,
        condition, status, economy_seats, business_seats, first_class_seats
    )
    VALUES (
        p_user_id,
        p_aircraft_model_id,
        v_model.model_name,
        generate_tail_number(COALESCE(v_hq_iata, 'CGK')),
        'finance',
        100.00,
        'active',
        v_economy_seats,
        v_business_seats,
        v_first_seats
    )
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance, weekly_payment,
        status, loan_type, collateral_aircraft_id, term_months, monthly_payment
    )
    VALUES (
        p_user_id,
        v_principal,
        v_interest_rate,
        v_total_repayable,
        v_weekly_payment,
        'active',
        'aircraft_financing',
        v_fleet_id,
        p_term_months,
        v_monthly_payment
    );

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Aircraft financed (bot).'::TEXT, v_cash;
    RETURN;
END IF;

v_cash := get_user_balance(p_user_id);
SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
v_credit_score := COALESCE(v_credit_score, 500);
SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = p_user_id;
v_tier := COALESCE(v_tier, 'Standard');

v_max_financing := CASE
    WHEN v_tier = 'Platinum' THEN 80000000
    WHEN v_tier = 'Gold' THEN 60000000
    WHEN v_tier = 'Silver' THEN 40000000
    WHEN v_tier = 'Standard' THEN 20000000
    ELSE 5000000
END;

IF v_purchase_price > v_max_financing THEN
    RETURN QUERY SELECT false, 'Aircraft price ($' || v_purchase_price::TEXT || ') exceeds your financing limit ($' || v_max_financing::TEXT || ') for tier ' || v_tier || '.'::TEXT, 0::NUMERIC; RETURN;
END IF;
IF p_term_months NOT IN (12, 24, 36, 48, 60) THEN
    RETURN QUERY SELECT false, 'Financing term must be 12, 24, 36, 48, or 60 months.'::TEXT, 0::NUMERIC; RETURN;
END IF;
IF p_down_payment_pct < 0.10 OR p_down_payment_pct > 0.50 THEN
    RETURN QUERY SELECT false, 'Down payment must be between 10% and 50%.'::TEXT, 0::NUMERIC; RETURN;
END IF;

v_down_payment := v_purchase_price * p_down_payment_pct;
v_principal := v_purchase_price - v_down_payment;
v_interest_rate := CASE
    WHEN v_tier = 'Platinum' THEN 0.03
    WHEN v_tier = 'Gold' THEN 0.04
    WHEN v_tier = 'Silver' THEN 0.05
    WHEN v_tier = 'Standard' THEN 0.07
    ELSE 0.10
END;
v_total_repayable := v_principal * (1 + v_interest_rate);
v_monthly_payment := v_total_repayable / p_term_months;
v_weekly_payment := v_monthly_payment / 4.33;

IF v_cash < v_down_payment THEN
    RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
END IF;

PERFORM debit_bank_account(
    p_user_id,
    v_down_payment,
    'investing',
    'aircraft_purchase_deposit',
    'Aircraft financing down payment — ' || v_model.model_name,
    v_game_time
);

INSERT INTO fleet_aircraft (
    user_id, aircraft_model_id, nickname, tail_number, acquisition_type,
    condition, status, economy_seats, business_seats, first_class_seats
)
VALUES (
    p_user_id,
    p_aircraft_model_id,
    v_model.model_name,
    generate_tail_number(COALESCE(v_hq_iata, 'CGK')),
    'finance',
    100.00,
    'active',
    v_model.capacity,
    0,
    0
)
RETURNING id INTO v_fleet_id;

INSERT INTO loans (
    user_id, principal, interest_rate, remaining_balance, weekly_payment,
    status, loan_type, collateral_aircraft_id, term_months, monthly_payment
)
VALUES (
    p_user_id,
    v_principal,
    v_interest_rate,
    v_total_repayable,
    v_weekly_payment,
    'active',
    'aircraft_financing',
    v_fleet_id,
    p_term_months,
    v_monthly_payment
);

v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$function$;

-- ============================================================================
-- FIX 3: process_aircraft_financing_payments — charge weekly obligation and
-- keep missed-payment penalties out of the cash ledger until cash actually moves.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_aircraft_financing_payments(
    p_user_id uuid,
    p_game_date timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_loan RECORD;
v_cash NUMERIC;
v_payment NUMERIC;
v_late_fee NUMERIC;
BEGIN
v_cash := get_user_balance(p_user_id);

FOR v_loan IN
    SELECT *
    FROM loans
    WHERE user_id = p_user_id
      AND loan_type = 'aircraft_financing'
      AND status = 'active'
LOOP
    IF COALESCE(v_loan.weekly_payment, 0) > 0 THEN
        v_payment := v_loan.weekly_payment;
    ELSIF COALESCE(v_loan.monthly_payment, 0) > 0 THEN
        v_payment := v_loan.monthly_payment / 4.33;
    ELSE
        CONTINUE;
    END IF;

    IF v_cash >= v_payment THEN
        PERFORM debit_bank_account(
            p_user_id,
            v_payment,
            'financing',
            'financing_payment',
            'Aircraft financing payment',
            p_game_date
        );
        v_cash := v_cash - v_payment;

        UPDATE loans
        SET remaining_balance = remaining_balance - v_payment
        WHERE id = v_loan.id;

        IF (SELECT remaining_balance FROM loans WHERE id = v_loan.id) <= 0 THEN
            UPDATE loans
            SET status = 'paid_off',
                remaining_balance = 0
            WHERE id = v_loan.id;
        END IF;
    ELSE
        v_late_fee := v_payment * 0.05;

        UPDATE loans
        SET remaining_balance = remaining_balance + v_late_fee,
            missed_payments = missed_payments + 1
        WHERE id = v_loan.id;

        IF (SELECT missed_payments FROM loans WHERE id = v_loan.id) >= 3 THEN
            UPDATE loans
            SET status = 'repossessed'
            WHERE id = v_loan.id;

            IF v_loan.collateral_aircraft_id IS NOT NULL THEN
                UPDATE fleet_aircraft
                SET status = 'grounded'
                WHERE id = v_loan.collateral_aircraft_id;
            END IF;
        END IF;
    END IF;
END LOOP;
END;
$function$;

-- ============================================================================
-- FIX 4: process_loan_payments — missed-payment penalties affect debt state
-- only; they do not create bank ledger rows until cash is actually paid.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_loan_payments(
    p_user_id uuid,
    p_game_date timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_actor_type       VARCHAR(10);
    r_loan             RECORD;
    v_cash             NUMERIC;
    v_payment          NUMERIC;
    v_late_fee         NUMERIC;
    v_effective_weekly NUMERIC;
BEGIN
    SELECT actor_type INTO v_actor_type FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN; END IF;

    v_cash := get_user_balance(p_user_id);

    FOR r_loan IN
        SELECT *
        FROM loans
        WHERE user_id = p_user_id
          AND status = 'active'
          AND loan_type != 'aircraft_financing'
        ORDER BY taken_at ASC
    LOOP
        IF COALESCE(r_loan.weekly_payment, 0) > 0 THEN
            v_effective_weekly := r_loan.weekly_payment;
        ELSIF COALESCE(r_loan.monthly_payment, 0) > 0 THEN
            v_effective_weekly := r_loan.monthly_payment / 4.33;
        ELSE
            CONTINUE;
        END IF;

        IF v_actor_type = 'AI' THEN
            IF v_cash >= v_effective_weekly THEN
                PERFORM debit_bank_account(
                    p_user_id,
                    v_effective_weekly,
                    'financing',
                    'loan_payment',
                    'Weekly loan payment',
                    p_game_date
                );
                v_cash := v_cash - v_effective_weekly;

                UPDATE loans
                SET remaining_balance = remaining_balance - v_effective_weekly
                WHERE id = r_loan.id;

                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans
                    SET status = 'paid_off',
                        remaining_balance = 0
                    WHERE id = r_loan.id;
                END IF;
            ELSE
                v_late_fee := v_effective_weekly * 0.10;

                UPDATE loans
                SET remaining_balance = remaining_balance + v_late_fee,
                    missed_payments = missed_payments + 1
                WHERE id = r_loan.id;

                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans
                    SET status = 'defaulted'
                    WHERE id = r_loan.id;
                END IF;
            END IF;
        ELSE
            v_payment := v_effective_weekly;

            IF v_cash >= v_payment THEN
                PERFORM debit_bank_account(
                    p_user_id,
                    v_payment,
                    'financing',
                    'loan_payment',
                    'Weekly loan payment',
                    p_game_date
                );
                v_cash := v_cash - v_payment;

                UPDATE loans
                SET remaining_balance = remaining_balance - v_payment
                WHERE id = r_loan.id;

                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans
                    SET status = 'paid_off',
                        remaining_balance = 0
                    WHERE id = r_loan.id;
                END IF;
            ELSE
                v_late_fee := v_payment * 0.10;

                UPDATE loans
                SET remaining_balance = remaining_balance + v_late_fee,
                    missed_payments = missed_payments + 1
                WHERE id = r_loan.id;

                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans
                    SET status = 'defaulted'
                    WHERE id = r_loan.id;

                    IF r_loan.collateral_aircraft_id IS NOT NULL THEN
                        UPDATE fleet_aircraft
                        SET status = 'grounded'
                        WHERE id = r_loan.collateral_aircraft_id;
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$function$;

-- ============================================================================
-- FIX 5: refinance_loan — refinancing changes debt terms, not live cash.
-- Keep it out of bank_transactions.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refinance_loan(p_loan_id uuid)
RETURNS TABLE(success boolean, message text, new_rate numeric, savings numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id         UUID;
    v_loan            RECORD;
    v_new_rate        NUMERIC;
    v_old_total       NUMERIC;
    v_new_total       NUMERIC;
    v_savings         NUMERIC;
    v_tier            VARCHAR;
    v_weekly_payment  NUMERIC;
    v_monthly_payment NUMERIC;
    v_config          JSONB;
    v_tier_cfg        JSONB;
BEGIN
    v_user_id := require_current_user_id();

    SELECT *
    INTO v_loan
    FROM loans
    WHERE id = p_loan_id
      AND user_id = v_user_id
      AND status = 'active';
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Loan not found or not active.'::TEXT, 0::NUMERIC, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT tier INTO v_tier FROM credit_scores WHERE user_id = v_user_id;
    SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';

    v_tier := COALESCE(v_tier, 'Standard');
    v_tier_cfg := COALESCE(v_config->v_tier, '{}'::JSONB);
    v_new_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);

    IF v_new_rate >= v_loan.interest_rate THEN
        RETURN QUERY SELECT false, 'Current rate is not better than existing rate.'::TEXT, 0::NUMERIC, 0::NUMERIC;
        RETURN;
    END IF;

    v_old_total := v_loan.remaining_balance;
    v_new_total := v_loan.principal * (1 + v_new_rate);
    v_savings := GREATEST(0, v_old_total - v_new_total);

    IF v_loan.term_months IS NOT NULL AND v_loan.term_months > 0 THEN
        v_monthly_payment := v_new_total / v_loan.term_months;
        v_weekly_payment := v_monthly_payment / 4.33;
    ELSE
        v_weekly_payment := v_new_total / 52;
        v_monthly_payment := v_weekly_payment * 4.33;
    END IF;

    UPDATE loans
    SET interest_rate = v_new_rate,
        remaining_balance = v_new_total,
        weekly_payment = v_weekly_payment,
        monthly_payment = v_monthly_payment
    WHERE id = p_loan_id;

    RETURN QUERY SELECT true, 'Loan refinanced successfully.'::TEXT, v_new_rate, v_savings;
END;
$function$;
