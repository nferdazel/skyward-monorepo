-- ============================================================================
-- Migration 20: Credit sync and zero-amount ledger guardrails
-- Goal:
--   align repo loan origination with live credit-policy reads and prevent
--   bank_transactions from storing zero-amount non-events.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.credit_bank_account(
    p_user_id uuid,
    p_amount numeric,
    p_ifrs_category character varying,
    p_ifrs_subcategory character varying,
    p_description text,
    p_game_date timestamp with time zone
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_account_id UUID;
v_new_balance NUMERIC;
BEGIN
SELECT id INTO v_account_id
FROM bank_accounts
WHERE user_id = p_user_id AND account_type = 'operating'
LIMIT 1;
IF v_account_id IS NULL THEN
RAISE EXCEPTION 'No operating bank account for user %', p_user_id;
END IF;
IF COALESCE(p_amount, 0) = 0 THEN
    SELECT balance INTO v_new_balance
    FROM bank_accounts
    WHERE id = v_account_id;
    RETURN v_new_balance;
END IF;
UPDATE bank_accounts
SET balance = balance + p_amount
WHERE id = v_account_id
RETURNING balance INTO v_new_balance;
INSERT INTO bank_transactions (
account_id, user_id, transaction_type, amount, balance_after,
description, game_date, ifrs_category, ifrs_subcategory
) VALUES (
v_account_id, p_user_id, 'credit', p_amount, v_new_balance,
p_description, p_game_date, p_ifrs_category, p_ifrs_subcategory
);
RETURN v_new_balance;
END;
$function$;

CREATE OR REPLACE FUNCTION public.debit_bank_account(
    p_user_id uuid,
    p_amount numeric,
    p_ifrs_category character varying,
    p_ifrs_subcategory character varying,
    p_description text,
    p_game_date timestamp with time zone
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_account_id UUID;
v_new_balance NUMERIC;
BEGIN
SELECT id INTO v_account_id
FROM bank_accounts
WHERE user_id = p_user_id AND account_type = 'operating'
LIMIT 1;
IF v_account_id IS NULL THEN
RAISE EXCEPTION 'No operating bank account for user %', p_user_id;
END IF;
IF COALESCE(p_amount, 0) = 0 THEN
    SELECT balance INTO v_new_balance
    FROM bank_accounts
    WHERE id = v_account_id;
    RETURN v_new_balance;
END IF;
UPDATE bank_accounts
SET balance = balance - p_amount
WHERE id = v_account_id
RETURNING balance INTO v_new_balance;
INSERT INTO bank_transactions (
account_id, user_id, transaction_type, amount, balance_after,
description, game_date, ifrs_category, ifrs_subcategory
) VALUES (
v_account_id, p_user_id, 'debit', -p_amount, v_new_balance,
p_description, p_game_date, p_ifrs_category, p_ifrs_subcategory
);
RETURN v_new_balance;
END;
$function$;

DELETE FROM public.bank_transactions
WHERE amount = 0
  AND ifrs_subcategory IN ('ticket_revenue', 'fuel', 'crew', 'maintenance');

CREATE OR REPLACE FUNCTION public.take_loan(
    p_user_id uuid,
    p_principal numeric,
    p_term_weeks integer DEFAULT 52,
    p_loan_type character varying DEFAULT 'unsecured'::character varying,
    p_collateral_aircraft_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    v_loan_id UUID;
BEGIN
    SELECT u.actor_type, u.game_current_time
    INTO v_actor_type, v_game_time
    FROM users u
    WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';
    v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
    v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);

    SELECT COUNT(*) INTO v_existing_loans
    FROM loans
    WHERE user_id = p_user_id
      AND status = 'active';
    IF v_existing_loans >= v_max_loans THEN
        RETURN QUERY SELECT false, 'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        v_credit_score := 500;
    END IF;

    SELECT * INTO v_score_record FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF FOUND THEN
        v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE
        v_tier := resolve_credit_tier(v_credit_score);
    END IF;
    v_tier := COALESCE(v_tier, 'Standard');
    v_tier_cfg := get_credit_tier_policy(v_tier);

    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
        RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    IF p_loan_type = 'unsecured' THEN
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
    ELSE
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000) * 0.5;
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07) + 0.02;
    END IF;

    IF p_principal < v_min_loan THEN
        RETURN QUERY SELECT false, 'Minimum loan amount is $' || v_min_loan::TEXT || '.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;
    IF p_principal > v_max_principal THEN
        RETURN QUERY SELECT false, 'Maximum for ' || v_tier || ' tier ' || p_loan_type || ' loan is $' || v_max_principal::TEXT || '.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance, weekly_payment,
        status, loan_type, collateral_aircraft_id
    )
    VALUES (
        p_user_id,
        p_principal,
        v_interest_rate,
        v_total_repayable,
        v_weekly_payment,
        'active',
        p_loan_type,
        p_collateral_aircraft_id
    )
    RETURNING id INTO v_loan_id;

    PERFORM credit_bank_account(
        p_user_id,
        p_principal,
        'financing',
        'loan_disbursement',
        'Loan disbursement',
        v_game_time
    );

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Loan disbursed at ' || ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT, v_cash;
END;
$function$;
