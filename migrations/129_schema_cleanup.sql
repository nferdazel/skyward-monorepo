-- ============================================================================
-- Migration 129: Schema Cleanup — Drop dead columns, consolidate config,
--               extract bot_profiles, remove redundant credit columns
-- ============================================================================
-- Clean break, no backward compatibility needed.
-- ============================================================================

BEGIN;

-- ============================================================================
-- Part 1: Drop dead columns from users
-- ============================================================================

ALTER TABLE users DROP COLUMN IF EXISTS credit_score_updated_at;
ALTER TABLE users DROP COLUMN IF EXISTS buffered_revenue;
ALTER TABLE users DROP COLUMN IF EXISTS buffered_ops_cost;
ALTER TABLE users DROP COLUMN IF EXISTS buffered_lease_cost;
ALTER TABLE users DROP COLUMN IF EXISTS buffered_cargo_revenue;


-- ============================================================================
-- Part 2: Drop credit_score and credit_tier from users
-- ============================================================================
-- These are redundant with credit_scores table.
-- Rewrite ALL functions that read users.credit_score / users.credit_tier
-- to read from credit_scores instead, then drop the columns.
-- ============================================================================

-- ── 2a. take_loan (5-param internal) — read from credit_scores ──

CREATE OR REPLACE FUNCTION public.take_loan(
    p_user_id uuid, p_principal numeric,
    p_term_weeks integer DEFAULT 52,
    p_loan_type character varying DEFAULT 'unsecured',
    p_collateral_aircraft_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_actor_type VARCHAR(10); v_existing_loans INT; v_credit_score INT;
    v_score_record RECORD; v_tier VARCHAR(10); v_config JSONB; v_tier_cfg JSONB;
    v_min_loan NUMERIC; v_max_loans INT; v_interest_rate NUMERIC;
    v_weekly_payment NUMERIC; v_total_repayable NUMERIC; v_cash NUMERIC;
    v_game_time TIMESTAMPTZ; v_max_principal NUMERIC; v_loan_id UUID;
BEGIN
    SELECT u.actor_type, u.game_current_time
    INTO v_actor_type, v_game_time
    FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;

    IF v_actor_type = 'AI' THEN
        SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active';
        IF v_existing_loans >= 3 THEN RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC; RETURN; END IF;
        IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN QUERY SELECT false, 'Bot loan amount must be between $100K and $5M.'::TEXT, 0::NUMERIC; RETURN; END IF;
        SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
        IF NOT FOUND THEN v_credit_score := 500; END IF;
        v_interest_rate := 0.05;
        v_total_repayable := p_principal * (1 + v_interest_rate);
        v_weekly_payment := v_total_repayable / p_term_weeks;
        INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, game_date_taken, status, loan_type, credit_score_at_origination)
        VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, v_game_time, 'active', 'unsecured', v_credit_score)
        RETURNING id INTO v_loan_id;
        PERFORM credit_bank_account(p_user_id, p_principal, 'financing', 'loan_disbursement',
            'Loan disbursement', v_game_time);
        v_cash := get_user_balance(p_user_id);
        RETURN QUERY SELECT true, 'Loan disbursed.'::TEXT, v_cash;
        RETURN;
    END IF;

    SELECT credit_tier_config INTO v_config FROM game_config WHERE key = 'credit_tier_config';
    v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
    v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);

    SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active';
    IF v_existing_loans >= v_max_loans THEN
        RETURN QUERY SELECT false, 'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
    IF NOT FOUND THEN v_credit_score := 500; END IF;

    SELECT * INTO v_score_record FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF FOUND THEN v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE v_tier := resolve_credit_tier(v_credit_score); END IF;

    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);

    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
        RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    IF p_loan_type = 'unsecured' THEN
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC; RETURN;
        END IF;
        v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
    ELSE
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000) * 0.5;
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07) + 0.02;
    END IF;

    IF p_principal < v_min_loan THEN
        RETURN QUERY SELECT false, 'Minimum loan amount is $' || v_min_loan::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;
    IF p_principal > v_max_principal THEN
        RETURN QUERY SELECT false, 'Maximum for ' || v_tier || ' tier ' || p_loan_type || ' loan is $' || v_max_principal::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, game_date_taken, status, loan_type, collateral_aircraft_id, credit_score_at_origination)
    VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, v_game_time, 'active', p_loan_type, p_collateral_aircraft_id, v_credit_score)
    RETURNING id INTO v_loan_id;

    PERFORM credit_bank_account(p_user_id, p_principal, 'financing', 'loan_disbursement',
        'Loan disbursement', v_game_time);

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Loan disbursed at ' || ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT, v_cash;
END;
$function$;


-- ── 2b. finance_aircraft (4-param internal) — read from credit_scores ──

CREATE OR REPLACE FUNCTION public.finance_aircraft(
    p_user_id uuid, p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20,
    p_term_months integer DEFAULT 36
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_actor_type VARCHAR(10); v_model RECORD; v_credit_score INT; v_tier VARCHAR(10);
    v_purchase_price NUMERIC; v_down_payment NUMERIC; v_principal NUMERIC;
    v_interest_rate NUMERIC; v_monthly_payment NUMERIC; v_total_repayable NUMERIC;
    v_cash NUMERIC; v_game_time TIMESTAMPTZ; v_fleet_id UUID; v_hq_iata VARCHAR(3);
    v_max_financing NUMERIC; v_economy_seats INT; v_business_seats INT; v_first_seats INT;
    v_archetype VARCHAR(30);
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC; RETURN; END IF;
    v_purchase_price := v_model.purchase_price;

    SELECT u.actor_type, u.game_current_time, u.hq_airport_iata
    INTO v_actor_type, v_game_time, v_hq_iata
    FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;

    -- Read archetype from bot_profiles for AI users
    IF v_actor_type = 'AI' THEN
        SELECT COALESCE(bp.archetype, 'Balanced') INTO v_archetype
        FROM bot_profiles bp WHERE bp.user_id = p_user_id;
        IF NOT FOUND THEN v_archetype := 'Balanced'; END IF;
    END IF;

    IF v_actor_type = 'AI' THEN
        v_cash := get_user_balance(p_user_id);
        v_down_payment := v_purchase_price * p_down_payment_pct;
        v_principal := v_purchase_price - v_down_payment;
        v_interest_rate := 0.05;
        v_total_repayable := v_principal * (1 + v_interest_rate);
        v_monthly_payment := v_total_repayable / p_term_months;

        IF v_cash < v_down_payment THEN
            RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
        END IF;

        PERFORM debit_bank_account(p_user_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
            'Aircraft financing down payment — ' || v_model.model_name, v_game_time);

        v_economy_seats := CASE WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.80)::INT
                                WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)::INT
                                ELSE FLOOR(v_model.capacity * 0.50)::INT END;
        v_business_seats := CASE WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.15)::INT
                                 WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)::INT
                                 ELSE FLOOR(v_model.capacity * 0.30)::INT END;
        v_first_seats := v_model.capacity - v_economy_seats - v_business_seats;

        INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
        VALUES (p_user_id, p_aircraft_model_id, v_model.model_name, 'BOT-' || left(p_user_id::text, 4), 'finance', 100.00, 'active', v_economy_seats, v_business_seats, v_first_seats)
        RETURNING id INTO v_fleet_id;

        INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made)
        VALUES (p_user_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0);

        v_cash := get_user_balance(p_user_id);
        RETURN QUERY SELECT true, 'Aircraft financed (bot).'::TEXT, v_cash;
        RETURN;
    END IF;

    -- Human path
    v_cash := get_user_balance(p_user_id);
    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
    v_credit_score := COALESCE(v_credit_score, 500);
    SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = p_user_id;
    v_tier := COALESCE(v_tier, 'Standard');

    v_max_financing := CASE
        WHEN v_tier = 'Platinum' THEN 80000000 WHEN v_tier = 'Gold' THEN 60000000
        WHEN v_tier = 'Silver' THEN 40000000 WHEN v_tier = 'Standard' THEN 20000000
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
        WHEN v_tier = 'Platinum' THEN 0.03 WHEN v_tier = 'Gold' THEN 0.04
        WHEN v_tier = 'Silver' THEN 0.05 WHEN v_tier = 'Standard' THEN 0.07
        ELSE 0.10
    END;
    v_total_repayable := v_principal * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;

    IF v_cash < v_down_payment THEN
        RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    PERFORM debit_bank_account(p_user_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
        'Aircraft financing down payment — ' || v_model.model_name, v_game_time);

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
    VALUES (p_user_id, p_aircraft_model_id, v_model.model_name, generate_tail_number(COALESCE(v_hq_iata, 'CGK')), 'finance', 100.00, 'active', v_model.capacity, 0, 0)
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made)
    VALUES (p_user_id, v_principal, v_interest_rate, v_total_repayable, 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0);

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$function$;


-- ── 2c. bot_take_loan — read from credit_scores ──

CREATE OR REPLACE FUNCTION public.bot_take_loan(
    p_bot_id uuid, p_principal numeric, p_term_weeks integer DEFAULT 52
)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_existing_loans INT;
    v_interest_rate NUMERIC := 0.05;
    v_total_repayable NUMERIC;
    v_weekly_payment NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_credit_score INT;
BEGIN
    SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_bot_id AND status = 'active';
    IF v_existing_loans >= 3 THEN RETURN false; END IF;
    IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN false; END IF;
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_bot_id;
    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_bot_id;
    IF NOT FOUND THEN v_credit_score := 500; END IF;
    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, credit_score_at_origination)
    VALUES (p_bot_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', v_game_time, 'unsecured', v_credit_score);

    PERFORM credit_bank_account(p_bot_id, p_principal, 'financing', 'loan_disbursement',
        'Bot loan disbursement', v_game_time);

    RETURN true;
END;
$function$;


-- ── 2d. bot_finance_aircraft — read from credit_scores ──

CREATE OR REPLACE FUNCTION public.bot_finance_aircraft(
    p_bot_id uuid, p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 60
)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_model RECORD;
    v_purchase_price NUMERIC;
    v_down_payment NUMERIC;
    v_principal NUMERIC;
    v_interest_rate NUMERIC := 0.05;
    v_monthly_payment NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_fleet_id UUID;
    v_credit_score INT;
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN RETURN false; END IF;
    v_purchase_price := v_model.purchase_price;
    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_monthly_payment := (v_principal * (1 + v_interest_rate)) / p_term_months;
    v_cash := get_user_balance(p_bot_id);
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_bot_id;
    IF v_cash < v_down_payment THEN RETURN false; END IF;

    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_bot_id;
    IF NOT FOUND THEN v_credit_score := 500; END IF;

    PERFORM debit_bank_account(p_bot_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
        'Aircraft financing down payment — ' || v_model.model_name, v_game_time);

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
    VALUES (p_bot_id, p_aircraft_model_id, v_model.model_name, 'finance', 100.00, 'active', 'BOT-' || left(p_bot_id::text, 4), FLOOR(v_model.capacity * 0.70)::INT, FLOOR(v_model.capacity * 0.20)::INT, FLOOR(v_model.capacity * 0.10)::INT)
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made, credit_score_at_origination)
    VALUES (p_bot_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0, v_credit_score);

    RETURN true;
END;
$function$;


-- ── 2e. get_credit_report — read credit_tier_config from game_config ──

CREATE OR REPLACE FUNCTION public.get_credit_report()
RETURNS TABLE(current_score integer, fleet_health integer,
    revenue_stability integer, debt_ratio integer, cash_reserve integer,
    profit_history integer, credit_tier character varying,
    max_unsecured_loan numeric, max_secured_loan numeric,
    max_financing_amount numeric, base_interest_rate numeric,
    suggestions text[])
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE v_user_id UUID; v_score RECORD; v_tier VARCHAR(20); v_config JSONB; v_tier_cfg JSONB; v_sugg TEXT[] := '{}';
BEGIN
    v_user_id := require_current_user_id();
    SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';
    SELECT * INTO v_score FROM calculate_credit_score(v_user_id) LIMIT 1;
    IF NOT FOUND THEN current_score := 500; fleet_health := 100; revenue_stability := 100; debt_ratio := 100; cash_reserve := 100; profit_history := 100; credit_tier := 'Standard'; max_unsecured_loan := 5000000; max_secured_loan := 25000000; max_financing_amount := 20000000; base_interest_rate := 0.07; suggestions := ARRAY['Build your fleet and routes to establish credit history.']; RETURN NEXT; RETURN; END IF;
    v_tier := resolve_credit_tier(v_score.total_score);
    INSERT INTO credit_scores (user_id, score, tier, fleet_health_score, revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score, computed_at) VALUES (v_user_id, v_score.total_score, v_tier, v_score.fleet_health, v_score.revenue_stability, v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history, NOW()) ON CONFLICT (user_id) DO UPDATE SET score = EXCLUDED.score, tier = EXCLUDED.tier, fleet_health_score = EXCLUDED.fleet_health_score, revenue_stability_score = EXCLUDED.revenue_stability_score, debt_ratio_score = EXCLUDED.debt_ratio_score, cash_reserves_score = EXCLUDED.cash_reserves_score, profit_history_score = EXCLUDED.profit_history_score, computed_at = EXCLUDED.computed_at;
    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);
    current_score := v_score.total_score; fleet_health := v_score.fleet_health; revenue_stability := v_score.revenue_stability; debt_ratio := v_score.debt_ratio; cash_reserve := v_score.cash_reserve; profit_history := v_score.profit_history; credit_tier := v_tier;
    max_unsecured_loan := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000); max_secured_loan := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000); max_financing_amount := COALESCE((v_tier_cfg->>'max_financing')::NUMERIC, 20000000); base_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
    v_sugg := '{}';
    IF v_score.fleet_health < 100 THEN v_sugg := array_append(v_sugg, 'Repair grounded aircraft to improve fleet health.'); END IF;
    IF v_score.debt_ratio < 100 THEN v_sugg := array_append(v_sugg, 'Reduce outstanding debt to improve your debt ratio.'); END IF;
    IF v_score.cash_reserve < 100 THEN v_sugg := array_append(v_sugg, 'Build cash reserves for financial stability.'); END IF;
    IF v_score.revenue_stability < 100 THEN v_sugg := array_append(v_sugg, 'Establish consistent revenue from routes.'); END IF;
    IF array_length(v_sugg, 1) IS NULL THEN v_sugg := ARRAY['Your credit profile is healthy. Keep it up!']; END IF;
    suggestions := v_sugg; RETURN NEXT;
END;
$function$;


-- ── 2f. update_credit_score — remove users.credit_score/tier write ──

CREATE OR REPLACE FUNCTION public.update_credit_score(p_user_id uuid, p_game_date timestamp with time zone)
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_score RECORD; v_tier VARCHAR(10);
BEGIN
    SELECT * INTO v_score FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF NOT FOUND THEN RETURN; END IF;
    v_tier := CASE WHEN v_score.total_score >= 900 THEN 'Platinum' WHEN v_score.total_score >= 750 THEN 'Gold' WHEN v_score.total_score >= 600 THEN 'Silver' WHEN v_score.total_score >= 400 THEN 'Standard' ELSE 'Subprime' END;
    INSERT INTO credit_scores (user_id, score, tier, fleet_health_score, revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score, computed_at)
    VALUES (p_user_id, v_score.total_score, v_tier, v_score.fleet_health, v_score.revenue_stability, v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history, NOW())
    ON CONFLICT (user_id) DO UPDATE SET score = EXCLUDED.score, tier = EXCLUDED.tier, fleet_health_score = EXCLUDED.fleet_health_score, revenue_stability_score = EXCLUDED.revenue_stability_score, debt_ratio_score = EXCLUDED.debt_ratio_score, cash_reserves_score = EXCLUDED.cash_reserves_score, profit_history_score = EXCLUDED.profit_history_score, computed_at = EXCLUDED.computed_at;
    -- No longer writing to users.credit_score / credit_tier (columns dropped)
END;
$function$;


-- ── 2g. reset_user_airline — remove credit_score/tier, DELETE from credit_scores ──

CREATE OR REPLACE FUNCTION public.reset_user_airline(p_user_id uuid)
RETURNS TABLE(success boolean, message text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RETURN QUERY SELECT FALSE, 'User not found'; RETURN;
    END IF;

    DELETE FROM bank_transactions WHERE user_id = p_user_id;
    DELETE FROM bank_accounts WHERE user_id = p_user_id;
    DELETE FROM loans WHERE user_id = p_user_id;
    DELETE FROM credit_scores WHERE user_id = p_user_id;
    DELETE FROM credit_score_history WHERE user_id = p_user_id;
    DELETE FROM route_assignments WHERE user_id = p_user_id;
    DELETE FROM fleet_aircraft WHERE user_id = p_user_id;
    DELETE FROM achievements WHERE user_id = p_user_id;

    UPDATE users SET
        net_worth = 15000000.00,
        game_current_time = TIMESTAMP WITH TIME ZONE '2020-01-01 00:00:00+00',
        hq_airport_iata = 'SIN',
        auto_grounding_threshold = 40.00,
        operational_status = 'Active',
        consecutive_negative_days = 0,
        recovery_streak_days = 0,
        last_active_at = NOW(),
        onboarding_completed = false
    WHERE id = p_user_id;

    INSERT INTO bank_accounts (user_id, account_type, balance)
    VALUES (p_user_id, 'operating', 15000000.00);

    RETURN QUERY SELECT TRUE, 'Airline reset successfully';
END;
$function$;


-- ── 2h. handle_new_auth_user — remove credit_score/tier from INSERT ──

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_username TEXT;
    v_expected_email TEXT;
    v_company_name TEXT;
    v_ceo_name TEXT;
    v_starting_cash NUMERIC;
BEGIN
    IF EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = NEW.id) THEN
        RETURN NEW;
    END IF;

    v_username := public.normalize_username(NEW.raw_user_meta_data ->> 'username');
    v_company_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'company_name', '')), '');
    v_ceo_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'ceo_name', '')), '');

    IF v_username IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.username';
    END IF;
    IF v_company_name IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.company_name';
    END IF;
    IF v_ceo_name IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.ceo_name';
    END IF;

    v_expected_email := public.build_synthetic_auth_email(v_username);
    IF lower(COALESCE(NEW.email, '')) <> v_expected_email THEN
        RAISE EXCEPTION 'Auth bootstrap email mismatch for username %', v_username;
    END IF;

    IF EXISTS (SELECT 1 FROM public.users u WHERE u.username = v_username) THEN
        RAISE EXCEPTION 'Username % is already registered.', v_username;
    END IF;
    IF EXISTS (SELECT 1 FROM public.users u WHERE u.company_name = v_company_name) THEN
        RAISE EXCEPTION 'Company name % is already registered.', v_company_name;
    END IF;

    SELECT COALESCE(get_config_numeric('starting_cash'), 15000000.00)
    INTO v_starting_cash;

    INSERT INTO public.users (
        auth_user_id, username, company_name, ceo_name, net_worth,
        game_current_time, last_active_at, operational_status,
        consecutive_negative_days, recovery_streak_days, auto_grounding_threshold,
        actor_type, hq_airport_iata
    ) VALUES (
        NEW.id, v_username, v_company_name, v_ceo_name, v_starting_cash,
        '2020-01-01 00:00:00+00', NOW(), 'Active',
        0, 0, 40.00,
        'REAL', 'CGK'
    );
    -- trg_create_default_bank_account trigger handles creating the operating account
    -- credit_scores entry is created by update_credit_score on day boundary

    RETURN NEW;
END;
$function$;


-- ── Now drop the columns ──

ALTER TABLE users DROP COLUMN IF EXISTS credit_score;
ALTER TABLE users DROP COLUMN IF EXISTS credit_tier;


-- ============================================================================
-- Part 3: Create bot_profiles table
-- ============================================================================

CREATE TABLE public.bot_profiles (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    archetype varchar(30) NOT NULL DEFAULT 'Balanced',
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE bot_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Bot profiles viewable by everyone" ON bot_profiles FOR SELECT TO authenticated USING (true);
GRANT SELECT ON bot_profiles TO authenticated;

-- Migrate archetype data from users
INSERT INTO bot_profiles (user_id, archetype)
SELECT id, COALESCE(archetype, 'Balanced')
FROM users WHERE actor_type = 'AI';

-- Drop archetype from users
ALTER TABLE users DROP COLUMN IF EXISTS archetype;


-- ── 3a. execute_bot_decisions — JOIN bot_profiles for archetype ──

CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    r_bot RECORD; v_model_id UUID; v_model_name VARCHAR; v_lease_price NUMERIC; v_purchase_price NUMERIC; v_capacity INT; v_speed_kmh NUMERIC; v_range_km NUMERIC; v_deposit_pct NUMERIC; v_deposit_amount NUMERIC; v_tail VARCHAR(20); v_origin_iata VARCHAR(3); v_dest_iata VARCHAR(3); v_distance DOUBLE PRECISION; v_fleet_count INT; v_route_count INT; v_idle_aircraft_count INT; v_idle_aircraft_id UUID; v_idle_tail VARCHAR(20); v_idle_condition NUMERIC; v_idle_model_name VARCHAR; v_idle_capacity INT; v_idle_speed NUMERIC; v_idle_range NUMERIC; v_grounded_aircraft_id UUID; v_grounded_condition NUMERIC; v_grounded_acquisition_type VARCHAR; v_grounded_model_name VARCHAR; v_grounded_lease_price NUMERIC; v_grounded_purchase_price NUMERIC; v_repair_cost NUMERIC; v_target_fleet_cap INT; v_min_cash_reserve NUMERIC; v_growth_chance NUMERIC; v_target_distance DOUBLE PRECISION; v_target_price_multiplier NUMERIC; v_target_schedule_ratio NUMERIC; v_effective_threshold NUMERIC(5,2); v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00; v_selected_route_id UUID; v_selected_flights INT; v_selected_base_fare NUMERIC; v_max_weekly_flights INT; v_target_flights INT; v_target_price NUMERIC; v_bot_cash NUMERIC; v_starting_cash NUMERIC := 15000000.00; v_attempts INT; v_inserted BOOLEAN; v_economy INT; v_business INT; v_first INT; r_route RECORD; v_human_competitors INT; v_new_price NUMERIC; v_base_fare NUMERIC; v_purchase_capacity INT; v_purchase_model_name VARCHAR; v_active_loans INT; v_game_time TIMESTAMPTZ;
    v_archetype VARCHAR(30);
BEGIN
    SELECT value::numeric INTO v_deposit_pct FROM game_config WHERE key = 'base_lease_deposit_percentage';
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
    FOR r_bot IN
        SELECT u.*, COALESCE(bp.archetype, 'Balanced') as archetype
        FROM users u
        LEFT JOIN bot_profiles bp ON bp.user_id = u.id
        WHERE u.actor_type = 'AI' AND u.operational_status != 'Bankrupt'
    LOOP
        v_archetype := r_bot.archetype;
        v_bot_cash := get_user_balance(r_bot.id);
        v_game_time := r_bot.game_current_time;
        v_origin_iata := r_bot.hq_airport_iata;
        v_effective_threshold := GREATEST(v_absolute_minimum_safety_limit, COALESCE(r_bot.auto_grounding_threshold, 40.00));
        IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < -5000000.00 THEN UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id; UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id; UPDATE loans SET status = 'defaulted', remaining_balance = 0 WHERE user_id = r_bot.id AND status = 'active'; CONTINUE; END IF;
        CASE v_archetype WHEN 'Regional' THEN v_target_fleet_cap := 8; v_min_cash_reserve := 3500000.00; v_growth_chance := 0.20; v_target_distance := 900.0; v_target_price_multiplier := 0.95; v_target_schedule_ratio := 0.72; WHEN 'Aggressive' THEN v_target_fleet_cap := 14; v_min_cash_reserve := 4500000.00; v_growth_chance := 0.26; v_target_distance := 1800.0; v_target_price_multiplier := 1.02; v_target_schedule_ratio := 0.82; ELSE v_target_fleet_cap := 10; v_min_cash_reserve := 7000000.00; v_growth_chance := 0.16; v_target_distance := 4200.0; v_target_price_multiplier := 1.18; v_target_schedule_ratio := 0.58; END CASE;
        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_idle_aircraft_count FROM fleet_aircraft f WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);
        SELECT f.id, f.condition, f.acquisition_type, m.model_name, m.lease_price_per_month, m.purchase_price INTO v_grounded_aircraft_id, v_grounded_condition, v_grounded_acquisition_type, v_grounded_model_name, v_grounded_lease_price, v_grounded_purchase_price FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND (f.status = 'grounded' OR f.condition < v_effective_threshold) ORDER BY f.condition DESC LIMIT 1;
        IF v_grounded_aircraft_id IS NOT NULL THEN v_repair_cost := CASE WHEN v_grounded_acquisition_type = 'lease' THEN (100.00 - v_grounded_condition) * (COALESCE(v_grounded_lease_price, 0.00) * 0.50) ELSE (100.00 - v_grounded_condition) * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005) END; IF v_repair_cost > 0 AND v_bot_cash >= (v_repair_cost + 500000.00) THEN PERFORM debit_bank_account(r_bot.id, v_repair_cost, 'cogs', 'maintenance', 'Bot maintenance recovery: ' || v_grounded_model_name, v_game_time); UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = v_grounded_aircraft_id; v_bot_cash := v_bot_cash - v_repair_cost; END IF; END IF;
        IF v_bot_cash < 3000000.00 OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN SELECT r.id, r.flights_per_week, (50.00 + (r.distance_km * 0.12))::NUMERIC INTO v_selected_route_id, v_selected_flights, v_selected_base_fare FROM route_assignments r WHERE r.user_id = r_bot.id ORDER BY (r.ticket_price / NULLIF((50.00 + (r.distance_km * 0.12)), 0)) DESC, r.flights_per_week DESC LIMIT 1; IF v_selected_route_id IS NOT NULL THEN IF v_selected_flights > 8 THEN UPDATE route_assignments SET flights_per_week = GREATEST(6, flights_per_week - CASE v_archetype WHEN 'Regional' THEN 6 WHEN 'Aggressive' THEN 4 ELSE 2 END), ticket_price = GREATEST(ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2), ROUND((ticket_price * 0.90)::numeric, 2)) WHERE id = v_selected_route_id; ELSE DELETE FROM route_assignments WHERE id = v_selected_route_id; END IF; END IF; END IF;
        IF v_fleet_count < v_target_fleet_cap AND v_bot_cash > v_min_cash_reserve AND COALESCE(r_bot.consecutive_negative_days, 0) = 0 AND v_idle_aircraft_count = 0 AND v_route_count >= v_fleet_count AND random() < v_growth_chance THEN
            v_model_id := NULL; v_model_name := NULL; v_lease_price := NULL; v_purchase_price := NULL; v_capacity := NULL;
            IF v_archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600' LIMIT 1; ELSIF v_archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' AND model_name = 'A320neo' LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' AND model_name = '787-9' LIMIT 1; END IF;
            IF v_model_id IS NULL THEN IF v_archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' ORDER BY capacity DESC LIMIT 1; ELSIF v_archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' ORDER BY capacity DESC LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' ORDER BY capacity DESC LIMIT 1; END IF; END IF;
            v_deposit_amount := COALESCE(v_lease_price, 0.00) * v_deposit_pct;
            IF v_model_id IS NOT NULL AND v_bot_cash >= v_deposit_amount THEN IF v_archetype = 'Regional' THEN v_economy := FLOOR(v_capacity * 0.80); v_business := FLOOR(v_capacity * 0.15); v_first := v_capacity - v_economy - v_business; ELSIF v_archetype = 'Aggressive' THEN v_economy := FLOOR(v_capacity * 0.70); v_business := FLOOR(v_capacity * 0.20); v_first := v_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_capacity * 0.50); v_business := FLOOR(v_capacity * 0.30); v_first := v_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (id, user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats) VALUES (gen_random_uuid(), r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN PERFORM debit_bank_account(r_bot.id, v_deposit_amount, 'investing', 'aircraft_lease_deposit', 'Leased aircraft ' || v_model_name || ' [' || v_tail || '] - deposit', v_game_time); v_bot_cash := v_bot_cash - v_deposit_amount; END IF; END IF;
        END IF;
        IF v_bot_cash > (v_starting_cash * 3) AND v_fleet_count < v_target_fleet_cap THEN SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name FROM aircraft_models WHERE range_km >= v_target_distance ORDER BY purchase_price ASC LIMIT 1; IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN IF v_archetype = 'Regional' THEN v_economy := FLOOR(v_purchase_capacity * 0.80); v_business := FLOOR(v_purchase_capacity * 0.15); v_first := v_purchase_capacity - v_economy - v_business; ELSIF v_archetype = 'Aggressive' THEN v_economy := FLOOR(v_purchase_capacity * 0.70); v_business := FLOOR(v_purchase_capacity * 0.20); v_first := v_purchase_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_purchase_capacity * 0.50); v_business := FLOOR(v_purchase_capacity * 0.30); v_first := v_purchase_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats) VALUES (r_bot.id, v_model_id, v_purchase_model_name, v_tail, 'purchase', 100.00, 'active', v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN PERFORM debit_bank_account(r_bot.id, v_purchase_price, 'investing', 'aircraft_purchase', 'Aircraft purchase: ' || v_tail, v_game_time); v_bot_cash := v_bot_cash - v_purchase_price; END IF; END IF; END IF;
        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
        SELECT f.id, f.tail_number, f.condition, m.model_name, m.capacity, m.speed_kmh, m.range_km INTO v_idle_aircraft_id, v_idle_tail, v_idle_condition, v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id) ORDER BY f.condition DESC LIMIT 1;
        IF v_idle_aircraft_id IS NOT NULL AND v_route_count < v_target_fleet_cap THEN v_attempts := 0; v_inserted := false; WHILE v_attempts < 20 AND NOT v_inserted LOOP SELECT iata INTO v_dest_iata FROM airports WHERE iata != v_origin_iata ORDER BY demand_index DESC, random() LIMIT 1; IF v_dest_iata IS NULL THEN EXIT; END IF; SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude) INTO v_distance FROM airports o, airports d WHERE o.iata = v_origin_iata AND d.iata = v_dest_iata; IF v_distance > 0 AND v_distance <= v_idle_range THEN v_base_fare := 50.00 + (v_distance * 0.12); v_target_price := ROUND(v_base_fare * v_target_price_multiplier, 2); v_max_weekly_flights := calculate_route_max_weekly_flights(v_distance, v_idle_speed::INT); v_target_flights := GREATEST(1, FLOOR(v_max_weekly_flights * v_target_schedule_ratio)); BEGIN INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week) VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, v_target_price, v_idle_aircraft_id, v_target_flights); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; ELSE v_attempts := v_attempts + 1; END IF; END LOOP; END IF;
        FOR r_route IN SELECT ra.*, m.speed_kmh, m.range_km, m.turnaround_hours FROM route_assignments ra JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id JOIN aircraft_models m ON m.id = fa.aircraft_model_id WHERE ra.user_id = r_bot.id AND ra.status = 'active' LOOP SELECT COUNT(*) INTO v_human_competitors FROM route_assignments WHERE origin_iata = r_route.origin_iata AND destination_iata = r_route.destination_iata AND status = 'active' AND user_id != r_bot.id AND user_id IN (SELECT id FROM users WHERE actor_type = 'REAL'); IF v_human_competitors > 0 THEN v_base_fare := 50.00 + (r_route.distance_km * 0.12); v_new_price := ROUND(v_base_fare * v_target_price_multiplier * CASE WHEN r_route.ticket_price > v_base_fare * 1.3 THEN 0.95 ELSE 1.0 END, 2); IF v_new_price != r_route.ticket_price THEN UPDATE route_assignments SET ticket_price = v_new_price WHERE id = r_route.id; END IF; END IF; END LOOP;
        SELECT COUNT(*) INTO v_active_loans FROM loans WHERE user_id = r_bot.id AND status = 'active'; IF v_active_loans = 0 AND v_bot_cash < v_starting_cash * 0.5 AND v_bot_cash > 1000000 THEN PERFORM bot_take_loan(r_bot.id, LEAST(5000000, v_starting_cash - v_bot_cash)); END IF;
        UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;
    END LOOP;
END;
$function$;


-- ── 3b. get_global_leaderboard — JOIN bot_profiles for archetype ──

CREATE OR REPLACE FUNCTION public.get_global_leaderboard()
RETURNS TABLE(id uuid, company_name character varying, ceo_name character varying, is_bot boolean, archetype character varying, cash numeric, net_worth numeric, fleet_size integer, monthly_revenue numeric, status character varying)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
BEGIN
    RETURN QUERY SELECT u.id, u.company_name::VARCHAR, u.ceo_name::VARCHAR,
        (u.actor_type = 'AI')::BOOLEAN, COALESCE(bp.archetype, 'Player')::VARCHAR,
        get_user_balance(u.id), u.net_worth,
        (SELECT COUNT(*)::INT FROM fleet_aircraft f WHERE f.user_id = u.id AND f.status = 'active'),
        COALESCE((SELECT SUM(bt.amount) FROM bank_transactions bt
                  WHERE bt.user_id = u.id AND bt.transaction_type = 'credit'
                    AND bt.game_date >= u.game_current_time - INTERVAL '30 days'), 0.00)::NUMERIC,
        COALESCE(u.operational_status, 'Active')::VARCHAR
    FROM users u
    LEFT JOIN bot_profiles bp ON bp.user_id = u.id;
END;
$function$;


-- ============================================================================
-- Part 4: Create game_config table and migrate data
-- ============================================================================

CREATE TABLE public.game_config (
    key text PRIMARY KEY,
    value jsonb NOT NULL,
    category text NOT NULL DEFAULT 'general',
    unit text,
    description text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_game_config_category ON public.game_config (category);
GRANT SELECT ON public.game_config TO authenticated;

-- Migrate data from global_game_settings
INSERT INTO game_config (key, value, category, description) VALUES
('starting_cash', '15000000.00', 'simulation', 'Initial cash for new players'),
('fuel_price_per_liter', '0.85', 'simulation', 'Base fuel price'),
('absolute_minimum_safety_limit', '30.00', 'simulation', 'Minimum aircraft condition to fly'),
('max_bot_count', '5', 'simulation', 'Maximum AI competitors'),
('base_lease_deposit_percentage', '0.10', 'simulation', 'Lease deposit as fraction of monthly rent'),
('time_scale_multiplier', '60.00', 'simulation', 'Game time acceleration factor'),
('crew_cost_per_hour', '350.0', 'simulation', 'Crew cost per flight hour'),
('tick_interval_seconds', '60', 'simulation', 'Seconds between world ticks'),
('credit_tier_config', '{"Platinum":{"min":800,"max":1000,"rate":0.03},"Gold":{"min":650,"max":799,"rate":0.05},"Silver":{"min":500,"max":649,"rate":0.08},"Standard":{"min":0,"max":499,"rate":0.12}}', 'finance', 'Credit tier thresholds and rates'),
('savings_tiers', '{"tiers":[{"min":0,"max":1000000,"rate":0.01},{"min":1000000,"max":5000000,"rate":0.015},{"min":5000000,"max":10000000,"rate":0.02},{"min":10000000,"max":25000000,"rate":0.025},{"min":25000000,"max":null,"rate":0.03}]}', 'finance', 'Savings interest tiers');

-- Migrate data from data_retention_policy
INSERT INTO game_config (key, value, category, unit, description) VALUES
('database_warn_mb', '350', 'ops', 'megabytes', 'Database size warning threshold'),
('database_critical_mb', '425', 'ops', 'megabytes', 'Database size critical threshold'),
('database_free_quota_mb', '500', 'ops', 'megabytes', 'Database free quota'),
('world_tick_log_raw_real_days', '7', 'ops', 'real_days', 'Retention for raw world tick logs'),
('player_ledger_raw_game_days', '30', 'ops', 'game_days', 'Retention for player ledger entries'),
('bot_ledger_raw_game_days', '7', 'ops', 'game_days', 'Retention for bot ledger entries'),
('inactive_player_archive_real_days', '90', 'ops', 'real_days', 'Archive inactive players after');


-- ============================================================================
-- Part 5: Helper functions for game_config
-- ============================================================================

CREATE OR REPLACE FUNCTION get_config_text(p_key text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT value #>> '{}' FROM game_config WHERE key = p_key;
$$;

CREATE OR REPLACE FUNCTION get_config_numeric(p_key text)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT (value #>> '{}')::numeric FROM game_config WHERE key = p_key;
$$;

CREATE OR REPLACE FUNCTION get_config_int(p_key text)
RETURNS int LANGUAGE sql STABLE AS $$
    SELECT (value #>> '{}')::int FROM game_config WHERE key = p_key;
$$;

CREATE OR REPLACE FUNCTION get_config_jsonb(p_key text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT value FROM game_config WHERE key = p_key;
$$;


-- ============================================================================
-- Part 5b: Rewrite ALL functions that read from old config tables
-- ============================================================================

-- ── resolve_credit_tier — read from game_config ──

CREATE OR REPLACE FUNCTION public.resolve_credit_tier(p_score integer)
RETURNS character varying LANGUAGE plpgsql STABLE AS $function$
DECLARE v_config JSONB; v_tier_name TEXT; v_tier_data JSONB;
BEGIN
    SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';
    IF v_config IS NULL THEN
        RETURN CASE WHEN p_score >= 900 THEN 'Platinum' WHEN p_score >= 750 THEN 'Gold' WHEN p_score >= 600 THEN 'Silver' WHEN p_score >= 400 THEN 'Standard' ELSE 'Subprime' END;
    END IF;
    FOR v_tier_name IN SELECT key FROM jsonb_each(v_config->'tiers') ORDER BY (value->>'min_score')::INT DESC LOOP
        v_tier_data := v_config->'tiers'->v_tier_name;
        IF p_score >= (v_tier_data->>'min_score')::INT THEN RETURN v_tier_name; END IF;
    END LOOP;
    RETURN 'Subprime';
END;
$function$;


-- ── calculate_credit_score — read starting_cash from game_config ──

CREATE OR REPLACE FUNCTION public.calculate_credit_score(p_user_id uuid)
RETURNS TABLE(total_score integer, tier character varying, fleet_health integer, revenue_stability integer, debt_ratio integer, cash_reserve integer, profit_history integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $function$
DECLARE
    v_user RECORD; v_actor_type VARCHAR(10); v_fleet_count INT := 0; v_avg_condition NUMERIC := 100.0; v_grounded_ratio NUMERIC := 0.0; v_fleet_health NUMERIC := 200.0;
    v_revenue_days INT := 0; v_positive_days INT := 0; v_revenue_stability NUMERIC := 200.0;
    v_total_debt NUMERIC := 0.0; v_net_worth NUMERIC := 0.0; v_debt_ratio NUMERIC := 200.0;
    v_cash NUMERIC := 0.0; v_starting_cash NUMERIC := 15000000.0; v_cash_reserve NUMERIC := 200.0;
    v_total_revenue_30d NUMERIC := 0.0; v_total_expense_30d NUMERIC := 0.0; v_profit_margin NUMERIC := 0.0; v_profit_history NUMERIC := 200.0;
    v_total_score INT;
BEGIN
    SELECT u.net_worth, u.game_current_time, u.actor_type INTO v_user FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN total_score := 500; tier := 'Standard'; fleet_health := 100; revenue_stability := 100; debt_ratio := 100; cash_reserve := 100; profit_history := 100; RETURN NEXT; RETURN; END IF;
    v_actor_type := COALESCE(v_user.actor_type, 'REAL');
    v_cash := get_user_balance(p_user_id);
    v_net_worth := COALESCE(v_user.net_worth, 0.0);

    v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.0);

    SELECT COUNT(*)::INT, COALESCE(AVG(condition), 100.0), COALESCE(COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC / NULLIF(COUNT(*), 0), 0.0)
    INTO v_fleet_count, v_avg_condition, v_grounded_ratio FROM fleet_aircraft WHERE user_id = p_user_id;

    IF v_fleet_count > 0 THEN v_fleet_health := (v_avg_condition / 100.0) * 150.0 + 50.0 * (1.0 - v_grounded_ratio); ELSE v_fleet_health := 100.0; END IF;

    SELECT COUNT(*)::INT, COUNT(*) FILTER (WHERE amount > 0)::INT INTO v_revenue_days, v_positive_days
    FROM bank_transactions
    WHERE user_id = p_user_id AND ifrs_category = 'revenue'
      AND game_date >= v_user.game_current_time - INTERVAL '30 days';

    IF v_revenue_days > 0 THEN v_revenue_stability := (v_positive_days::NUMERIC / v_revenue_days::NUMERIC) * 200.0; ELSE v_revenue_stability := 100.0; END IF;

    SELECT COALESCE(SUM(remaining_balance), 0) INTO v_total_debt FROM loans WHERE user_id = p_user_id AND status = 'active';
    IF v_net_worth > 0 THEN v_debt_ratio := GREATEST(0, 200.0 - ((v_total_debt / v_net_worth) * 200.0)); ELSE v_debt_ratio := 0.0; END IF;

    IF v_starting_cash > 0 THEN v_cash_reserve := LEAST(200.0, (v_cash / v_starting_cash) * 200.0); ELSE v_cash_reserve := 100.0; END IF;

    SELECT COALESCE(SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN transaction_type = 'debit' THEN amount ELSE 0 END), 0)
    INTO v_total_revenue_30d, v_total_expense_30d
    FROM bank_transactions
    WHERE user_id = p_user_id AND game_date >= v_user.game_current_time - INTERVAL '30 days';

    IF v_total_revenue_30d > 0 THEN v_profit_margin := (v_total_revenue_30d - v_total_expense_30d) / v_total_revenue_30d; v_profit_history := LEAST(200.0, 100.0 + (v_profit_margin * 100.0)); ELSE v_profit_history := 100.0; END IF;

    v_total_score := GREATEST(0, LEAST(1000, ROUND(v_fleet_health) + ROUND(v_revenue_stability) + ROUND(v_debt_ratio) + ROUND(v_cash_reserve) + ROUND(v_profit_history)));
    total_score := v_total_score; tier := resolve_credit_tier(v_total_score); fleet_health := ROUND(v_fleet_health)::INT; revenue_stability := ROUND(v_revenue_stability)::INT; debt_ratio := ROUND(v_debt_ratio)::INT; cash_reserve := ROUND(v_cash_reserve)::INT; profit_history := ROUND(v_profit_history)::INT; RETURN NEXT;
END;
$function$;


-- ── accrue_savings_interest — no-op (operating accounts don't earn interest) ──
-- Already rewritten in migration 128, no change needed.


-- ── process_player_simulation_to_time — read from game_config ──

CREATE OR REPLACE FUNCTION public.process_player_simulation_to_time(
    p_user_id uuid,
    p_target_game_time timestamp with time zone
)
RETURNS TABLE(
    game_time timestamp with time zone,
    cash numeric,
    flights_run integer,
    elapsed_days numeric
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    r_user RECORD;
    v_route RECORD;
    v_flight_hours NUMERIC;
    v_revenue NUMERIC;
    v_ops_cost NUMERIC;
    v_lease_cost NUMERIC;
    v_net NUMERIC := 0;
    v_flights_run INT := 0;
    v_cash_after NUMERIC;
    v_elapsed_days NUMERIC;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_cargo_rev NUMERIC(20,2);
    v_turnaround_hours NUMERIC;
    v_demand_multiplier NUMERIC;
    v_crew_cost NUMERIC;
    v_fuel_price NUMERIC;
    v_seasonal_factor NUMERIC;
    v_fuel_price_multiplier NUMERIC := 1.0;
    v_maintenance_multiplier NUMERIC := 1.0;
    v_route_demand_event NUMERIC;
    v_route_capacity_event NUMERIC;
    v_effective_capacity NUMERIC;
    v_time_fraction NUMERIC;
    v_payment_periods INT;
    v_i INT;
    v_fuel_cost NUMERIC;
    v_crew_cost_total NUMERIC;
    v_maint_cost NUMERIC;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found: %', p_user_id; END IF;

    v_fuel_price := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_crew_cost := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);

    SELECT COALESCE(effect_value, 1.0) INTO v_fuel_price_multiplier
    FROM game_events
    WHERE event_type = 'fuel_shock' AND is_active = true
      AND effect_type = 'fuel_price'
      AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_fuel_price_multiplier := 1.0; END IF;

    SELECT COALESCE(effect_value, 1.0) INTO v_maintenance_multiplier
    FROM game_events
    WHERE event_type = 'maintenance_shock' AND is_active = true
      AND effect_type = 'maintenance_cost'
      AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_maintenance_multiplier := 1.0; END IF;

    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;
    v_time_fraction := LEAST(v_elapsed_days / 7.0, 1.0);

    FOR v_route IN
        SELECT ur.*, am.fuel_burn_per_km, am.speed_kmh, am.turnaround_hours,
               am.capacity, am.lease_price_per_month, am.maintenance_cost_per_hour,
               a1.demand_index AS origin_demand, a2.demand_index AS dest_demand
        FROM route_assignments ur
        JOIN fleet_aircraft fa ON fa.id = ur.assigned_aircraft_id
        JOIN aircraft_models am ON am.id = fa.aircraft_model_id
        JOIN airports a1 ON a1.iata = ur.origin_iata
        JOIN airports a2 ON a2.iata = ur.destination_iata
        WHERE ur.user_id = p_user_id AND ur.status = 'active'
          AND fa.status = 'active'
          AND fa.condition >= COALESCE(r_user.auto_grounding_threshold, 40.00)
    LOOP
        v_route_demand_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_demand_event
        FROM game_events
        WHERE event_type = 'demand_surge' AND is_active = true
          AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
          AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
        ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_demand_event := 1.0; END IF;

        v_route_capacity_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_capacity_event
        FROM game_events
        WHERE event_type = 'weather_disruption' AND is_active = true
          AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
          AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
        ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_capacity_event := 1.0; END IF;

        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
        v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
        IF v_flight_hours <= 0 THEN CONTINUE; END IF;

        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price) * v_route_demand_event;
        v_seasonal_factor := 1.0;
        v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);

        v_revenue := v_route.flights_per_week * v_route.ticket_price *
                     LEAST(v_effective_capacity,
                           FLOOR(v_effective_capacity * 0.95 * v_demand_multiplier * v_seasonal_factor));

        v_fuel_cost := v_route.flights_per_week * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
        v_crew_cost_total := v_route.flights_per_week * v_flight_hours * v_crew_cost;
        v_maint_cost := v_route.flights_per_week * v_route.distance_km * COALESCE(v_route.maintenance_cost_per_hour, 0) * COALESCE(v_maintenance_multiplier, 1.0) / NULLIF(v_route.speed_kmh, 0);

        v_ops_cost := v_fuel_cost + v_crew_cost_total + v_maint_cost;

        v_lease_cost := CASE
            WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                         WHERE fa2.id = v_route.assigned_aircraft_id
                           AND fa2.acquisition_type = 'lease')
            THEN COALESCE(v_route.lease_price_per_month, 0) * (v_elapsed_days / 30.0)
            ELSE 0
        END;

        v_revenue := v_revenue * v_time_fraction;
        v_ops_cost := v_ops_cost * v_time_fraction;

        v_cargo_rev := v_revenue * 0.05;

        PERFORM credit_bank_account(p_user_id, v_revenue + v_cargo_rev, 'revenue', 'ticket_revenue',
            'Route ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        PERFORM debit_bank_account(p_user_id, v_fuel_cost * v_time_fraction, 'cogs', 'fuel',
            'Fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        PERFORM debit_bank_account(p_user_id, v_crew_cost_total * v_time_fraction, 'cogs', 'crew',
            'Crew: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        PERFORM debit_bank_account(p_user_id, v_maint_cost * v_time_fraction, 'cogs', 'maintenance',
            'Maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        IF v_lease_cost > 0 THEN
            PERFORM debit_bank_account(p_user_id, v_lease_cost, 'opex', 'aircraft_lease',
                'Lease: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
        END IF;

        v_wear_per_cycle := 0.50 + (v_route.distance_km * 0.0001);
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week * v_elapsed_days / 7.0;
        v_self_healing_credit := v_gross_damage * 0.10;
        v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

        UPDATE fleet_aircraft
        SET condition = GREATEST(0, condition - v_net_damage),
            total_flights = total_flights + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT
        WHERE id = v_route.assigned_aircraft_id;

        v_flights_run := v_flights_run + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
    END LOOP;

    v_cash_after := get_user_balance(p_user_id);

    UPDATE users u
    SET game_current_time = p_target_game_time,
        last_active_at = NOW()
    WHERE u.id = p_user_id;

    -- Bankruptcy check for humans
    IF v_cash_after < -5000000.0 THEN
        UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
        UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
    END IF;

    IF v_elapsed_days >= 1.0 THEN
        v_payment_periods := GREATEST(1, FLOOR(v_elapsed_days / 7.0)::INT);
        FOR v_i IN 1..v_payment_periods LOOP
            PERFORM process_loan_payments(p_user_id, p_target_game_time);
            PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time);
        END LOOP;

        PERFORM accrue_savings_interest(p_user_id, p_target_game_time);
        PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time);
        PERFORM check_achievements(p_user_id, p_target_game_time);

        v_cash_after := get_user_balance(p_user_id);
        IF v_cash_after < 0 THEN
            UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1
            WHERE id = p_user_id;
            IF (SELECT consecutive_negative_days FROM users WHERE id = p_user_id) >= 30 THEN
                UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
                UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
            END IF;
        ELSE
            UPDATE users SET consecutive_negative_days = 0,
                             recovery_streak_days = recovery_streak_days + 1
            WHERE id = p_user_id;
        END IF;
    END IF;

    v_cash_after := get_user_balance(p_user_id);
    game_time := p_target_game_time;
    cash := v_cash_after;
    flights_run := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$function$;


-- ── process_all_bots_simulation_to_time — read from game_config ──

CREATE OR REPLACE FUNCTION public.process_all_bots_simulation_to_time(
    p_target_game_time timestamp with time zone,
    p_season_id uuid DEFAULT NULL::uuid
)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    r_bot RECORD;
    v_game_sec DOUBLE PRECISION;
    v_game_days DOUBLE PRECISION;
    v_route RECORD;
    v_flights DOUBLE PRECISION;
    v_revenue NUMERIC(20,2) := 0;
    v_fuel_cost NUMERIC(20,2) := 0;
    v_maint_cost NUMERIC(20,2) := 0;
    v_crew_cost NUMERIC(20,2) := 0;
    v_total_cost NUMERIC(20,2) := 0;
    v_net NUMERIC(20,2) := 0;
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_turnaround_hours NUMERIC;
    v_lease_cost NUMERIC(20,2) := 0;
    v_fuel_price NUMERIC;
    v_fuel_price_multiplier NUMERIC;
    v_crew_cost_per_hour NUMERIC;
    v_absolute_minimum_safety_limit NUMERIC(5,2);
    v_effective_grounding_threshold NUMERIC(5,2);
    v_max_weekly_flights INT;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_cargo_rev NUMERIC(20,2);
    v_processed INT := 0;
    v_demand_multiplier NUMERIC;
    v_seasonal_multiplier NUMERIC;
BEGIN
    v_fuel_price := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_absolute_minimum_safety_limit := COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00);
    v_crew_cost_per_hour := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);

    v_fuel_price_multiplier := 1.0;
    v_seasonal_multiplier := 1.0;

    FOR r_bot IN
        SELECT * FROM users
        WHERE actor_type = 'AI' AND COALESCE(operational_status, 'Active') != 'Bankrupt'
    LOOP
        v_effective_grounding_threshold := GREATEST(
            COALESCE(r_bot.auto_grounding_threshold, 40.00),
            v_absolute_minimum_safety_limit
        );

        v_game_sec := EXTRACT(EPOCH FROM (p_target_game_time - r_bot.game_current_time));
        v_game_days := v_game_sec / 86400.0;
        IF v_game_days <= 0 THEN CONTINUE; END IF;

        FOR v_route IN
            SELECT ra.*, am.fuel_burn_per_km, am.speed_kmh, am.capacity,
                   am.turnaround_hours, am.maintenance_cost_per_hour,
                   am.lease_price_per_month,
                   a1.demand_index AS origin_demand,
                   a2.demand_index AS dest_demand
            FROM route_assignments ra
            JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id
            JOIN aircraft_models am ON am.id = fa.aircraft_model_id
            JOIN airports a1 ON a1.iata = ra.origin_iata
            JOIN airports a2 ON a2.iata = ra.destination_iata
            WHERE ra.user_id = r_bot.id AND ra.status = 'active'
              AND fa.status = 'active'
              AND fa.condition >= v_effective_grounding_threshold
        LOOP
            v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
            v_flight_duration := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
            IF v_flight_duration <= 0 THEN CONTINUE; END IF;

            v_max_weekly_flights := FLOOR(168.0 / v_flight_duration)::INT;
            v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);

            v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price);
            v_passengers := LEAST(v_route.capacity,
                                  FLOOR(v_route.capacity * 0.95 * v_demand_multiplier * v_seasonal_multiplier));

            v_revenue := v_flights * v_route.ticket_price * v_passengers;
            v_fuel_cost := v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
            v_crew_cost := v_flights * v_flight_duration * v_crew_cost_per_hour;
            v_maint_cost := v_flights * v_route.distance_km * v_route.maintenance_cost_per_hour / NULLIF(v_route.speed_kmh, 0);
            v_cargo_rev := v_revenue * 0.05;
            v_lease_cost := CASE
                WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                             WHERE fa2.id = v_route.assigned_aircraft_id
                               AND fa2.acquisition_type = 'lease')
                THEN COALESCE(v_route.lease_price_per_month, 0) / 4.0
                ELSE 0
            END;

            PERFORM credit_bank_account(r_bot.id, v_revenue + v_cargo_rev, 'revenue', 'ticket_revenue',
                'Bot route ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            PERFORM debit_bank_account(r_bot.id, v_fuel_cost, 'cogs', 'fuel',
                'Bot fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            PERFORM debit_bank_account(r_bot.id, v_crew_cost, 'cogs', 'crew',
                'Bot crew: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            PERFORM debit_bank_account(r_bot.id, v_maint_cost, 'cogs', 'maintenance',
                'Bot maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            IF v_lease_cost > 0 THEN
                PERFORM debit_bank_account(r_bot.id, v_lease_cost, 'opex', 'aircraft_lease',
                    'Bot lease: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
            END IF;

            v_wear_per_cycle := 0.50 + (v_route.distance_km * 0.0001);
            v_gross_damage := v_wear_per_cycle * v_flights * v_game_days / 7.0;
            v_self_healing_credit := v_gross_damage * 0.10;
            v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

            UPDATE fleet_aircraft
            SET condition = GREATEST(0, condition - v_net_damage),
                total_flights = total_flights + (v_flights * v_game_days / 7.0)::INT
            WHERE id = v_route.assigned_aircraft_id;
        END LOOP;

        UPDATE users
        SET game_current_time = p_target_game_time,
            last_active_at = NOW()
        WHERE id = r_bot.id;

        IF v_game_days >= 1.0 THEN
            PERFORM process_loan_payments(r_bot.id, p_target_game_time);
            PERFORM process_aircraft_financing_payments(r_bot.id, p_target_game_time);
            PERFORM process_credit_at_day_boundary(r_bot.id, p_target_game_time);

            IF get_user_balance(r_bot.id) < 0 THEN
                UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1
                WHERE id = r_bot.id;
            ELSE
                UPDATE users SET consecutive_negative_days = 0
                WHERE id = r_bot.id;
            END IF;

            IF (SELECT consecutive_negative_days FROM users WHERE id = r_bot.id) >= 30 THEN
                UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
                UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id;
            END IF;
        END IF;

        v_processed := v_processed + 1;
    END LOOP;
    RETURN v_processed;
END;
$function$;


-- ── get_world_tick_log_compaction_report — read from game_config ──

DROP FUNCTION IF EXISTS public.get_world_tick_log_compaction_report() CASCADE;

CREATE OR REPLACE FUNCTION public.get_world_tick_log_compaction_report()
RETURNS TABLE(metric text, value text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_raw_count BIGINT;
    v_summary_count BIGINT;
    v_raw_retention_days INT;
    v_oldest_raw TIMESTAMPTZ;
    v_newest_raw TIMESTAMPTZ;
    v_db_size_mb NUMERIC;
    v_warn_mb NUMERIC;
    v_critical_mb NUMERIC;
BEGIN
    v_raw_retention_days := COALESCE(get_config_int('world_tick_log_raw_real_days'), 7);
    v_warn_mb := COALESCE(get_config_numeric('database_warn_mb'), 350);
    v_critical_mb := COALESCE(get_config_numeric('database_critical_mb'), 425);

    SELECT COUNT(*) INTO v_raw_count FROM world_tick_log;
    SELECT COUNT(*) INTO v_summary_count FROM world_tick_daily_summary;
    SELECT MIN(started_at), MAX(started_at) INTO v_oldest_raw, v_newest_raw FROM world_tick_log;

    SELECT ROUND((pg_database_size(current_database()) / 1024.0 / 1024.0)::NUMERIC, 2) INTO v_db_size_mb;

    metric := 'raw_log_count'; value := v_raw_count::TEXT; RETURN NEXT;
    metric := 'summary_count'; value := v_summary_count::TEXT; RETURN NEXT;
    metric := 'raw_retention_days'; value := v_raw_retention_days::TEXT; RETURN NEXT;
    metric := 'oldest_raw_log'; value := COALESCE(v_oldest_raw::TEXT, 'N/A'); RETURN NEXT;
    metric := 'newest_raw_log'; value := COALESCE(v_newest_raw::TEXT, 'N/A'); RETURN NEXT;
    metric := 'database_size_mb'; value := v_db_size_mb::TEXT; RETURN NEXT;
    metric := 'warn_threshold_mb'; value := v_warn_mb::TEXT; RETURN NEXT;
    metric := 'critical_threshold_mb'; value := v_critical_mb::TEXT; RETURN NEXT;
    metric := 'status'; value := CASE
        WHEN v_db_size_mb >= v_critical_mb THEN 'CRITICAL'
        WHEN v_db_size_mb >= v_warn_mb THEN 'WARNING'
        ELSE 'OK'
    END; RETURN NEXT;
END;
$function$;


-- ── get_database_size_report — read from game_config ──

DROP FUNCTION IF EXISTS public.get_database_size_report() CASCADE;

CREATE OR REPLACE FUNCTION public.get_database_size_report()
RETURNS TABLE(metric text, value text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_db_size_mb NUMERIC;
    v_warn_mb NUMERIC;
    v_critical_mb NUMERIC;
    v_free_quota_mb NUMERIC;
BEGIN
    v_warn_mb := COALESCE(get_config_numeric('database_warn_mb'), 350);
    v_critical_mb := COALESCE(get_config_numeric('database_critical_mb'), 425);
    v_free_quota_mb := COALESCE(get_config_numeric('database_free_quota_mb'), 500);

    SELECT ROUND((pg_database_size(current_database()) / 1024.0 / 1024.0)::NUMERIC, 2) INTO v_db_size_mb;

    metric := 'database_size_mb'; value := v_db_size_mb::TEXT; RETURN NEXT;
    metric := 'free_quota_mb'; value := v_free_quota_mb::TEXT; RETURN NEXT;
    metric := 'usage_pct'; value := ROUND((v_db_size_mb / v_free_quota_mb * 100)::NUMERIC, 1)::TEXT || '%'; RETURN NEXT;
    metric := 'warn_threshold_mb'; value := v_warn_mb::TEXT; RETURN NEXT;
    metric := 'critical_threshold_mb'; value := v_critical_mb::TEXT; RETURN NEXT;
    metric := 'status'; value := CASE
        WHEN v_db_size_mb >= v_critical_mb THEN 'CRITICAL'
        WHEN v_db_size_mb >= v_warn_mb THEN 'WARNING'
        ELSE 'OK'
    END; RETURN NEXT;
END;
$function$;


-- ============================================================================
-- Part 6: Drop old tables
-- ============================================================================

DROP TABLE IF EXISTS global_game_settings CASCADE;
DROP TABLE IF EXISTS data_retention_policy CASCADE;
DROP TABLE IF EXISTS scheduler_config CASCADE;


-- ============================================================================
-- Part 7: Re-add reconcile_all_net_worths
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reconcile_all_net_worths()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE users u SET net_worth = (
        SELECT COALESCE(ba.balance, 0) + COALESCE(
            (SELECT SUM(m.purchase_price * (f.condition / 100.00))
             FROM fleet_aircraft f
             JOIN aircraft_models m ON f.aircraft_model_id = m.id
             WHERE f.user_id = u.id AND f.acquisition_type = 'purchase'), 0)
        FROM bank_accounts ba
        WHERE ba.user_id = u.id AND ba.account_type = 'operating'
        LIMIT 1
    );
END;
$$;


COMMIT;


-- ============================================================================
-- Verification queries (run after commit)
-- ============================================================================

-- Should be 0:
-- SELECT COUNT(*) FROM information_schema.columns
-- WHERE table_name='users' AND column_name IN
--   ('credit_score','credit_tier','archetype','buffered_revenue','credit_score_updated_at',
--    'buffered_ops_cost','buffered_lease_cost','buffered_cargo_revenue');

-- Should be 0:
-- SELECT COUNT(*) FROM information_schema.tables
-- WHERE table_name IN ('global_game_settings','data_retention_policy','scheduler_config');

-- Should be ~17:
-- SELECT COUNT(*) FROM game_config;

-- Should match AI user count:
-- SELECT COUNT(*) FROM bot_profiles;

-- Should work:
-- SELECT * FROM ensure_world_current() LIMIT 1;
