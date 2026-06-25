-- ============================================================================
-- Migration 10: Finance Phase 4 — credit product consistency
-- Goals:
--   - all credit products read one policy source
--   - refinance works from remaining obligation and remaining term
--   - aircraft financing behaves as an asset-backed product
-- ============================================================================

-- ============================================================================
-- FIX 1: canonical tier policy helper
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_credit_tier_policy(p_tier character varying)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
    v_config JSONB;
    v_policy JSONB;
BEGIN
    SELECT value INTO v_config
    FROM game_config
    WHERE key = 'credit_tier_config';

    IF v_config IS NULL THEN
        RETURN '{}'::JSONB;
    END IF;

    v_policy := v_config -> COALESCE(p_tier, 'Standard');
    IF v_policy IS NULL OR jsonb_typeof(v_policy) <> 'object' THEN
        v_policy := v_config -> 'Standard';
    END IF;

    RETURN COALESCE(v_policy, '{}'::JSONB);
END;
$function$;

-- ============================================================================
-- FIX 2: finance_aircraft — use asset-backed tier policy from shared config
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
    v_actor_type VARCHAR(10);
    v_model RECORD;
    v_credit_score INT;
    v_score_record RECORD;
    v_tier VARCHAR(10);
    v_tier_cfg JSONB;
    v_purchase_price NUMERIC;
    v_down_payment NUMERIC;
    v_principal NUMERIC;
    v_interest_rate NUMERIC;
    v_monthly_payment NUMERIC;
    v_weekly_payment NUMERIC;
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
    SELECT *
    INTO v_model
    FROM aircraft_models
    WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_purchase_price := v_model.purchase_price;

    SELECT u.actor_type, u.game_current_time, u.hq_airport_iata
    INTO v_actor_type, v_game_time, v_hq_iata
    FROM users u
    WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    IF v_actor_type = 'AI' THEN
        SELECT COALESCE(bp.archetype, 'Balanced')
        INTO v_archetype
        FROM bot_profiles bp
        WHERE bp.user_id = p_user_id;
        IF NOT FOUND THEN
            v_archetype := 'Balanced';
        END IF;
    END IF;

    v_cash := get_user_balance(p_user_id);
    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
    v_credit_score := COALESCE(v_credit_score, 500);

    SELECT * INTO v_score_record FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF FOUND THEN
        v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE
        v_tier := resolve_credit_tier(v_credit_score);
    END IF;
    v_tier := COALESCE(v_tier, 'Standard');
    v_tier_cfg := get_credit_tier_policy(v_tier);

    v_max_financing := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
    v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.10);

    IF v_purchase_price > v_max_financing THEN
        RETURN QUERY SELECT false, 'Aircraft price ($' || v_purchase_price::TEXT || ') exceeds your financing limit ($' || v_max_financing::TEXT || ') for tier ' || v_tier || '.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;
    IF p_term_months NOT IN (12, 24, 36, 48, 60) THEN
        RETURN QUERY SELECT false, 'Financing term must be 12, 24, 36, 48, or 60 months.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;
    IF p_down_payment_pct < 0.10 OR p_down_payment_pct > 0.50 THEN
        RETURN QUERY SELECT false, 'Down payment must be between 10% and 50%.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_total_repayable := v_principal * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;
    v_weekly_payment := v_monthly_payment / 4.33;

    IF v_cash < v_down_payment THEN
        RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    PERFORM debit_bank_account(
        p_user_id,
        v_down_payment,
        'investing',
        'aircraft_purchase_deposit',
        'Aircraft financing down payment — ' || v_model.model_name,
        v_game_time
    );

    IF v_actor_type = 'AI' THEN
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
-- FIX 3: take_loan — use shared tier policy helper, root-level config only
-- ============================================================================
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

-- ============================================================================
-- FIX 4: refinance_loan — refinance remaining obligation over remaining term
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refinance_loan(p_loan_id uuid)
RETURNS TABLE(success boolean, message text, new_rate numeric, savings numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id UUID;
    v_loan RECORD;
    v_tier VARCHAR(10);
    v_tier_cfg JSONB;
    v_new_rate NUMERIC;
    v_old_total NUMERIC;
    v_outstanding_principal NUMERIC;
    v_new_total NUMERIC;
    v_savings NUMERIC;
    v_remaining_periods NUMERIC;
    v_weekly_payment NUMERIC;
    v_monthly_payment NUMERIC;
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
    v_tier := COALESCE(v_tier, 'Standard');
    v_tier_cfg := get_credit_tier_policy(v_tier);

    IF v_loan.loan_type IN ('secured', 'aircraft_financing') THEN
        v_new_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
    ELSIF v_loan.loan_type = 'credit_line' THEN
        v_new_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07) + 0.02;
    ELSE
        v_new_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
    END IF;

    IF v_new_rate >= v_loan.interest_rate THEN
        RETURN QUERY SELECT false, 'Current rate is not better than existing rate.'::TEXT, 0::NUMERIC, 0::NUMERIC;
        RETURN;
    END IF;

    v_old_total := COALESCE(v_loan.remaining_balance, 0);
    v_outstanding_principal := v_old_total / (1 + COALESCE(v_loan.interest_rate, 0));

    IF COALESCE(v_loan.term_months, 0) > 0 THEN
        v_remaining_periods := GREATEST(
            1,
            CEIL(
                v_old_total / NULLIF(COALESCE(v_loan.monthly_payment, v_loan.weekly_payment * 4.33), 0)
            )
        );
        v_new_total := v_outstanding_principal * (1 + v_new_rate);
        v_monthly_payment := v_new_total / v_remaining_periods;
        v_weekly_payment := v_monthly_payment / 4.33;
    ELSE
        v_remaining_periods := GREATEST(
            1,
            CEIL(v_old_total / NULLIF(COALESCE(v_loan.weekly_payment, 0), 0))
        );
        v_new_total := v_outstanding_principal * (1 + v_new_rate);
        v_weekly_payment := v_new_total / v_remaining_periods;
        v_monthly_payment := v_weekly_payment * 4.33;
    END IF;

    v_savings := GREATEST(0, v_old_total - v_new_total);

    UPDATE loans
    SET interest_rate = v_new_rate,
        remaining_balance = v_new_total,
        weekly_payment = v_weekly_payment,
        monthly_payment = v_monthly_payment
    WHERE id = p_loan_id;

    RETURN QUERY SELECT true, 'Loan refinanced successfully.'::TEXT, v_new_rate, v_savings;
END;
$function$;

-- ============================================================================
-- FIX 5: get_credit_report — financing capacity comes from the same policy
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_credit_report()
RETURNS TABLE(
    current_score integer,
    fleet_health integer,
    revenue_stability integer,
    debt_ratio integer,
    cash_reserve integer,
    profit_history integer,
    credit_tier character varying,
    max_unsecured_loan numeric,
    max_secured_loan numeric,
    max_financing_amount numeric,
    base_interest_rate numeric,
    suggestions text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id UUID;
    v_score RECORD;
    v_tier_cfg JSONB;
BEGIN
    v_user_id := require_current_user_id();

    SELECT * INTO v_score
    FROM calculate_credit_score(v_user_id)
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
        max_secured_loan := 25000000;
        max_financing_amount := 25000000;
        base_interest_rate := 0.12;
        suggestions := ARRAY['Build your fleet and routes to establish credit history.'];
        RETURN NEXT;
        RETURN;
    END IF;

    current_score := v_score.total_score;
    fleet_health := v_score.fleet_health;
    revenue_stability := v_score.revenue_stability;
    debt_ratio := v_score.debt_ratio;
    cash_reserve := v_score.cash_reserve;
    profit_history := v_score.profit_history;
    credit_tier := resolve_credit_tier(v_score.total_score);
    v_tier_cfg := get_credit_tier_policy(credit_tier);

    max_unsecured_loan := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
    max_secured_loan := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
    max_financing_amount := max_secured_loan;
    base_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);

    suggestions := ARRAY[]::TEXT[];
    IF fleet_health < 80 THEN
        suggestions := array_append(suggestions, 'Improve aircraft condition to strengthen fleet-health scoring.');
    END IF;
    IF revenue_stability < 80 THEN
        suggestions := array_append(suggestions, 'Stabilize route earnings to reduce revenue volatility.');
    END IF;
    IF debt_ratio < 80 THEN
        suggestions := array_append(suggestions, 'Reduce outstanding debt or grow assets to improve debt ratio.');
    END IF;
    IF cash_reserve < 80 THEN
        suggestions := array_append(suggestions, 'Increase cash reserves to improve lender confidence.');
    END IF;
    IF profit_history < 80 THEN
        suggestions := array_append(suggestions, 'Sustain positive operating profits to improve profit history.');
    END IF;
    IF array_length(suggestions, 1) IS NULL THEN
        suggestions := ARRAY['Your credit profile is healthy. Maintain payment discipline and operating profitability.'];
    END IF;

    RETURN NEXT;
END;
$function$;
