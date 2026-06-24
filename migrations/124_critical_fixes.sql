-- Migration 124: Critical fixes — stale overloads, deposit calc, game events, error isolation, cron jobs
-- ============================================================================
-- Fix 1: Re-create all stale frontend overloads
-- Fix 2: Fix lease_aircraft & execute_bot_decisions deposit calculation
-- Fix 3: Fix deposit_to_savings & withdraw_from_savings (checking→savings)
-- Fix 4: Fix finance_aircraft 4-param internal (ensure 'finance' acquisition_type)
-- Fix 5: Create pg_cron jobs
-- Fix 6: Fix process_world_tick — error isolation + lock safety
-- Fix 7: Fix trigger update_user_net_worth uses stale cash
-- Fix 8: Fix double loan payment (exclude aircraft_financing)
-- Fix 9: Consume game events in simulation
-- Fix 10: (refinance_loan already included in Fix 1)
-- Fix 11: Fix sell_aircraft ownership check
-- Fix 12: Fix repair_aircraft — add process_simulation_delta call
-- Fix 13: Fix reset_user_airline — cleanup bank data
-- Fix 14: Fix ensure_world_current — add catch-up loop
-- Fix 15: Rename ensure_checking_account → ensure_savings_account
-- Fix 16: Fix repay_loan sign convention
-- ============================================================================

BEGIN;

-- ── Fix 1a: purchase_aircraft (5-param frontend) ──

CREATE OR REPLACE FUNCTION public.purchase_aircraft(
    p_model_id uuid, p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM purchase_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;

-- ── Fix 1b: lease_aircraft (5-param frontend) ──

CREATE OR REPLACE FUNCTION public.lease_aircraft(
    p_model_id uuid, p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM lease_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;

-- ── Fix 1c: sell_aircraft (1-param frontend) ──

CREATE OR REPLACE FUNCTION public.sell_aircraft(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM sell_aircraft(v_user_id, p_fleet_id);
END;
$function$;

-- ── Fix 1d: repair_aircraft (1-param frontend) ──

CREATE OR REPLACE FUNCTION public.repair_aircraft(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM repair_aircraft(v_user_id, p_fleet_id);
END;
$function$;

-- ── Fix 1e: terminate_aircraft_lease (1-param frontend) ──

CREATE OR REPLACE FUNCTION public.terminate_aircraft_lease(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM terminate_aircraft_lease(v_user_id, p_fleet_id);
END;
$function$;

-- ── Fix 1f: configure_aircraft_seats (4-param frontend) ──

CREATE OR REPLACE FUNCTION public.configure_aircraft_seats(
    p_fleet_id uuid, p_economy_seats integer,
    p_business_seats integer, p_first_class_seats integer
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM configure_aircraft_seats(v_user_id, p_fleet_id, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;

-- ── Fix 1g: create_route (5-param frontend) ──

CREATE OR REPLACE FUNCTION public.create_route(
    p_origin_iata character varying, p_destination_iata character varying,
    p_distance_km numeric, p_ticket_price numeric, p_flights_per_week integer
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM create_route(v_user_id, p_origin_iata, p_destination_iata, p_distance_km, p_ticket_price, p_flights_per_week);
END;
$function$;

-- ── Fix 1h: delete_route (1-param frontend) ──

CREATE OR REPLACE FUNCTION public.delete_route(p_route_id uuid)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM delete_route(v_user_id, p_route_id);
END;
$function$;

-- ── Fix 1i: assign_aircraft_to_route (2-param frontend) ──

CREATE OR REPLACE FUNCTION public.assign_aircraft_to_route(p_route_id uuid, p_aircraft_id uuid)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM assign_aircraft_to_route(v_user_id, p_route_id, p_aircraft_id);
END;
$function$;

-- ── Fix 1j: update_route_frequency_and_price (3-param frontend) ──

CREATE OR REPLACE FUNCTION public.update_route_frequency_and_price(
    p_route_id uuid, p_ticket_price numeric, p_flights_per_week integer
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM update_route_frequency_and_price(v_user_id, p_route_id, p_ticket_price, p_flights_per_week);
END;
$function$;

-- ── Fix 1k: take_loan (4-param frontend) ──

CREATE OR REPLACE FUNCTION public.take_loan(
    p_principal numeric, p_term_weeks integer DEFAULT 52,
    p_loan_type character varying DEFAULT 'unsecured',
    p_collateral_aircraft_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := require_current_user_id();
    RETURN QUERY SELECT * FROM take_loan(v_user_id, p_principal, p_term_weeks, p_loan_type, p_collateral_aircraft_id);
END;
$function$;

-- ── Fix 1l: save_airline_settings (3-param frontend) ──

CREATE OR REPLACE FUNCTION public.save_airline_settings(
    p_company_name character varying, p_auto_grounding_threshold numeric,
    p_hq_airport_iata character varying
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM save_airline_settings(v_user_id, p_company_name, p_auto_grounding_threshold, p_hq_airport_iata);
END;
$function$;

-- ── Fix 1m: reset_user_airline (0-param frontend) ──

CREATE OR REPLACE FUNCTION public.reset_user_airline()
RETURNS TABLE(success boolean, message text)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM reset_user_airline(v_user_id);
END;
$function$;

-- ── Fix 1n: get_finance_snapshot (0-param frontend) ──

CREATE OR REPLACE FUNCTION public.get_finance_snapshot()
RETURNS TABLE(actor_id uuid, is_bot boolean, company_name character varying,
    cash numeric, net_worth numeric, owned_aircraft_asset_value numeric,
    leased_aircraft_monthly_exposure numeric, fleet_count integer,
    owned_fleet_count integer, leased_fleet_count integer,
    active_route_count integer, rolling_revenue_30d numeric,
    rolling_expense_30d numeric, rolling_net_30d numeric,
    ledger_window_days integer)
LANGUAGE plpgsql STABLE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM get_finance_snapshot(v_user_id, FALSE);
END;
$function$;

-- ── Fix 1o: get_credit_report (0-param frontend) ──

CREATE OR REPLACE FUNCTION public.get_credit_report()
RETURNS TABLE(current_score integer, fleet_health integer,
    revenue_stability integer, debt_ratio integer, cash_reserve integer,
    profit_history integer, credit_tier character varying,
    max_unsecured_loan numeric, max_secured_loan numeric,
    max_financing_amount numeric, base_interest_rate numeric,
    suggestions text[])
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID; v_score RECORD; v_tier VARCHAR(20); v_config JSONB; v_tier_cfg JSONB; v_sugg TEXT[] := '{}';
BEGIN
    v_user_id := require_current_user_id();
    SELECT credit_tier_config INTO v_config FROM global_game_settings WHERE id = 1;
    SELECT * INTO v_score FROM calculate_credit_score(v_user_id) LIMIT 1;
    IF NOT FOUND THEN current_score := 500; fleet_health := 100; revenue_stability := 100; debt_ratio := 100; cash_reserve := 100; profit_history := 100; credit_tier := 'Standard'; max_unsecured_loan := 5000000; max_secured_loan := 25000000; max_financing_amount := 20000000; base_interest_rate := 0.07; suggestions := ARRAY['Build your fleet and routes to establish credit history.']; RETURN NEXT; RETURN; END IF;
    v_tier := resolve_credit_tier(v_score.total_score);
    UPDATE users SET credit_score = v_score.total_score, credit_tier = v_tier WHERE id = v_user_id;
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

-- ── Fix 1p: finance_aircraft (3-param frontend) ──

CREATE OR REPLACE FUNCTION public.finance_aircraft(
    p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20,
    p_term_months integer DEFAULT 36
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := require_current_user_id();
    RETURN QUERY SELECT * FROM finance_aircraft(v_user_id, p_aircraft_model_id, p_down_payment_pct, p_term_months);
END;
$function$;

-- ── Fix 1q: refinance_loan (1-param frontend) ──

CREATE OR REPLACE FUNCTION public.refinance_loan(p_loan_id uuid)
RETURNS TABLE(success boolean, message text, new_rate numeric, savings numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID; v_loan RECORD; v_new_rate NUMERIC; v_old_total NUMERIC; v_new_total NUMERIC; v_savings NUMERIC; v_tier VARCHAR; v_weekly_payment NUMERIC; v_monthly_payment NUMERIC;
BEGIN
    v_user_id := require_current_user_id();
    SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'Loan not found or not active.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF;
    SELECT tier INTO v_tier FROM credit_scores WHERE user_id = v_user_id;
    v_new_rate := CASE COALESCE(v_tier, 'Standard')
        WHEN 'Platinum' THEN 0.03 WHEN 'Gold' THEN 0.04
        WHEN 'Silver' THEN 0.05 WHEN 'Standard' THEN 0.07
        ELSE 0.10
    END;
    IF v_new_rate >= v_loan.interest_rate THEN
        RETURN QUERY SELECT false, 'Current rate is not better than existing rate.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN;
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
    UPDATE loans SET interest_rate = v_new_rate, remaining_balance = v_new_total,
        weekly_payment = v_weekly_payment, monthly_payment = v_monthly_payment
    WHERE id = p_loan_id;
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (v_user_id, 'expense', 'loan_refinance', 0,
            'Loan refinanced from ' || ROUND(v_loan.interest_rate * 100, 1)::TEXT || '% to ' || ROUND(v_new_rate * 100, 1)::TEXT || '% APR',
            NOW());
    PERFORM ensure_checking_account(v_user_id);
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
    SELECT ba.id, v_user_id, 'refinance', 0,
           (SELECT u.cash FROM users u WHERE u.id = v_user_id),
           'Loan refinanced — new rate ' || ROUND(v_new_rate * 100, 1)::TEXT || '%',
           NOW()
    FROM bank_accounts ba WHERE ba.user_id = v_user_id AND ba.account_type = 'savings' LIMIT 1;
    RETURN QUERY SELECT true, 'Loan refinanced successfully.'::TEXT, v_new_rate, v_savings;
END;
$function$;


-- ── Fix 2: Fix lease_aircraft deposit calculation ──

CREATE OR REPLACE FUNCTION public.lease_aircraft(
    p_user_id uuid, p_model_id uuid, p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_cash NUMERIC; v_lease_price NUMERIC; v_model_name VARCHAR; v_capacity INT;
    v_hq_iata VARCHAR(3); v_tail VARCHAR(20); v_deposit_pct NUMERIC; v_lease_deposit NUMERIC;
    v_economy INT; v_business INT; v_first INT; v_slots_used INT; v_game_time TIMESTAMPTZ;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT cash, hq_airport_iata, game_current_time INTO v_cash, v_hq_iata, v_game_time
    FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC; RETURN; END IF;

    SELECT lease_price_per_month, model_name, capacity INTO v_lease_price, v_model_name, v_capacity
    FROM aircraft_models WHERE id = p_model_id;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash; RETURN; END IF;

    SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1;
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
    v_lease_deposit := v_lease_price * v_deposit_pct;

    v_economy := COALESCE(p_economy_seats, v_capacity);
    v_business := COALESCE(p_business_seats, 0);
    v_first := COALESCE(p_first_class_seats, 0);
    v_slots_used := v_economy + (v_business * 2) + (v_first * 3);

    IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
        RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash; RETURN;
    END IF;
    IF v_cash < v_lease_deposit THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds for lease down payment of ' || v_model_name || '. Required: $' || ROUND(v_lease_deposit, 2))::VARCHAR, v_cash; RETURN;
    END IF;

    LOOP v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
         EXIT WHEN NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_tail);
    END LOOP;

    UPDATE users SET cash = cash - v_lease_deposit WHERE id = p_user_id RETURNING cash INTO v_cash;

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
    VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first);

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_user_id, 'expense', 'aircraft_lease', v_lease_deposit,
            'Leased aircraft ' || v_model_name || ' with Call Sign: ' || v_tail || ' - Downpayment deposit',
            v_game_time);

    PERFORM ensure_checking_account(p_user_id);
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
    SELECT ba.id, p_user_id, 'payment', v_lease_deposit,
           (SELECT u.cash FROM users u WHERE u.id = p_user_id),
           'Leased aircraft ' || v_model_name || ' deposit [' || v_tail || ']',
           v_game_time
    FROM bank_accounts ba
    WHERE ba.user_id = p_user_id AND ba.account_type = 'savings'
    LIMIT 1;

    RETURN QUERY SELECT TRUE, 'Successfully leased ' || v_model_name || ' [' || v_tail || ']'::VARCHAR, v_cash;
END;
$function$;

CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    r_bot RECORD; v_model_id UUID; v_model_name VARCHAR; v_lease_price NUMERIC; v_purchase_price NUMERIC; v_capacity INT; v_speed_kmh NUMERIC; v_range_km NUMERIC; v_deposit_pct NUMERIC; v_deposit_amount NUMERIC; v_tail VARCHAR(20); v_new_aircraft_id UUID; v_origin_iata VARCHAR(3); v_dest_iata VARCHAR(3); v_distance DOUBLE PRECISION; v_fleet_count INT; v_route_count INT; v_idle_aircraft_count INT; v_idle_aircraft_id UUID; v_idle_tail VARCHAR(20); v_idle_condition NUMERIC; v_idle_model_name VARCHAR; v_idle_capacity INT; v_idle_speed NUMERIC; v_idle_range NUMERIC; v_grounded_aircraft_id UUID; v_grounded_condition NUMERIC; v_grounded_acquisition_type VARCHAR; v_grounded_model_name VARCHAR; v_grounded_lease_price NUMERIC; v_grounded_purchase_price NUMERIC; v_repair_cost NUMERIC; v_target_fleet_cap INT; v_min_cash_reserve NUMERIC; v_growth_chance NUMERIC; v_target_distance DOUBLE PRECISION; v_target_price_multiplier NUMERIC; v_target_schedule_ratio NUMERIC; v_effective_threshold NUMERIC(5,2); v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00; v_selected_route_id UUID; v_selected_flights INT; v_selected_base_fare NUMERIC; v_max_weekly_flights INT; v_target_flights INT; v_target_price NUMERIC; v_bot_cash NUMERIC; v_grounded_count INT; v_negative_days INT; v_starting_cash NUMERIC := 15000000.00; v_attempts INT; v_inserted BOOLEAN; v_economy INT; v_business INT; v_first INT; r_route RECORD; v_human_competitors INT; v_new_price NUMERIC; v_base_fare NUMERIC; v_purchase_capacity INT; v_purchase_model_name VARCHAR; v_active_loans INT; v_loan_record RECORD; v_fin_model_id UUID; v_fin_model_price NUMERIC; v_credit_score INT; v_credit_tier VARCHAR(10);
BEGIN
    SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1; v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
    FOR r_bot IN SELECT * FROM users WHERE actor_type = 'AI' LOOP
        v_bot_cash := COALESCE(r_bot.cash, 0.00); v_origin_iata := r_bot.hq_airport_iata;
        v_effective_threshold := GREATEST(v_absolute_minimum_safety_limit, COALESCE(r_bot.auto_grounding_threshold, 40.00));
        IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < -5000000.00 THEN UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id; UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id; UPDATE loans SET status = 'defaulted', remaining_balance = 0 WHERE user_id = r_bot.id AND status = 'active'; CONTINUE; END IF;
        CASE r_bot.archetype WHEN 'Regional' THEN v_target_fleet_cap := 8; v_min_cash_reserve := 3500000.00; v_growth_chance := 0.20; v_target_distance := 900.0; v_target_price_multiplier := 0.95; v_target_schedule_ratio := 0.72; WHEN 'Aggressive' THEN v_target_fleet_cap := 14; v_min_cash_reserve := 4500000.00; v_growth_chance := 0.26; v_target_distance := 1800.0; v_target_price_multiplier := 1.02; v_target_schedule_ratio := 0.82; ELSE v_target_fleet_cap := 10; v_min_cash_reserve := 7000000.00; v_growth_chance := 0.16; v_target_distance := 4200.0; v_target_price_multiplier := 1.18; v_target_schedule_ratio := 0.58; END CASE;
        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_idle_aircraft_count FROM fleet_aircraft f WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);
        SELECT f.id, f.condition, f.acquisition_type, m.model_name, m.lease_price_per_month, m.purchase_price INTO v_grounded_aircraft_id, v_grounded_condition, v_grounded_acquisition_type, v_grounded_model_name, v_grounded_lease_price, v_grounded_purchase_price FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND (f.status = 'grounded' OR f.condition < v_effective_threshold) ORDER BY f.condition DESC LIMIT 1;
        IF v_grounded_aircraft_id IS NOT NULL THEN v_repair_cost := CASE WHEN v_grounded_acquisition_type = 'lease' THEN (100.00 - v_grounded_condition) * (COALESCE(v_grounded_lease_price, 0.00) * 0.50) ELSE (100.00 - v_grounded_condition) * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005) END; IF v_repair_cost > 0 AND v_bot_cash >= (v_repair_cost + 500000.00) THEN UPDATE users SET cash = cash - v_repair_cost WHERE id = r_bot.id; UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = v_grounded_aircraft_id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (r_bot.id, 'expense', 'aircraft_repair', v_repair_cost, 'Bot maintenance recovery completed for ' || v_grounded_model_name, r_bot.game_current_time); v_bot_cash := v_bot_cash - v_repair_cost; END IF; END IF;
        IF v_bot_cash < 3000000.00 OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN SELECT r.id, r.flights_per_week, (50.00 + (r.distance_km * 0.12))::NUMERIC INTO v_selected_route_id, v_selected_flights, v_selected_base_fare FROM route_assignments r WHERE r.user_id = r_bot.id ORDER BY (r.ticket_price / NULLIF((50.00 + (r.distance_km * 0.12)), 0)) DESC, r.flights_per_week DESC LIMIT 1; IF v_selected_route_id IS NOT NULL THEN IF v_selected_flights > 8 THEN UPDATE route_assignments SET flights_per_week = GREATEST(6, flights_per_week - CASE r_bot.archetype WHEN 'Regional' THEN 6 WHEN 'Aggressive' THEN 4 ELSE 2 END), ticket_price = GREATEST(ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2), ROUND((ticket_price * 0.90)::numeric, 2)) WHERE id = v_selected_route_id; ELSE DELETE FROM route_assignments WHERE id = v_selected_route_id; END IF; END IF; END IF;
        IF v_fleet_count < v_target_fleet_cap AND v_bot_cash > v_min_cash_reserve AND COALESCE(r_bot.consecutive_negative_days, 0) = 0 AND v_idle_aircraft_count = 0 AND v_route_count >= v_fleet_count AND random() < v_growth_chance THEN
            v_model_id := NULL; v_model_name := NULL; v_lease_price := NULL; v_purchase_price := NULL; v_capacity := NULL;
            IF r_bot.archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600' LIMIT 1; ELSIF r_bot.archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' AND model_name = 'A320neo' LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' AND model_name = '787-9' LIMIT 1; END IF;
            IF v_model_id IS NULL THEN IF r_bot.archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' ORDER BY capacity DESC LIMIT 1; ELSIF r_bot.archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' ORDER BY capacity DESC LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' ORDER BY capacity DESC LIMIT 1; END IF; END IF;
            v_deposit_amount := COALESCE(v_lease_price, 0.00) * v_deposit_pct;
            IF v_model_id IS NOT NULL AND v_bot_cash >= v_deposit_amount THEN v_tail := generate_tail_number(r_bot.hq_airport_iata); v_new_aircraft_id := gen_random_uuid(); IF r_bot.archetype = 'Regional' THEN v_economy := FLOOR(v_capacity * 0.80); v_business := FLOOR(v_capacity * 0.15); v_first := v_capacity - v_economy - v_business; ELSIF r_bot.archetype = 'Aggressive' THEN v_economy := FLOOR(v_capacity * 0.70); v_business := FLOOR(v_capacity * 0.20); v_first := v_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_capacity * 0.50); v_business := FLOOR(v_capacity * 0.30); v_first := v_capacity - v_economy - v_business; END IF; INSERT INTO fleet_aircraft (id, user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats) VALUES (v_new_aircraft_id, r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first); UPDATE users SET cash = cash - v_deposit_amount WHERE id = r_bot.id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (r_bot.id, 'expense', 'aircraft_lease', v_deposit_amount, 'Leased aircraft ' || v_model_name || ' with Call Sign: ' || v_tail || ' - Downpayment deposit', r_bot.game_current_time); v_bot_cash := v_bot_cash - v_deposit_amount; END IF;
        END IF;
        IF v_bot_cash > (v_starting_cash * 3) AND v_fleet_count < v_target_fleet_cap THEN SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name FROM aircraft_models WHERE range_km >= v_target_distance ORDER BY purchase_price ASC LIMIT 1; IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN IF r_bot.archetype = 'Regional' THEN v_economy := FLOOR(v_purchase_capacity * 0.80); v_business := FLOOR(v_purchase_capacity * 0.15); v_first := v_purchase_capacity - v_economy - v_business; ELSIF r_bot.archetype = 'Aggressive' THEN v_economy := FLOOR(v_purchase_capacity * 0.70); v_business := FLOOR(v_purchase_capacity * 0.20); v_first := v_purchase_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_purchase_capacity * 0.50); v_business := FLOOR(v_purchase_capacity * 0.30); v_first := v_purchase_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats) VALUES (r_bot.id, v_model_id, v_purchase_model_name, v_tail, 'purchase', 100.00, 'active', v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN UPDATE users SET cash = cash - v_purchase_price WHERE id = r_bot.id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (r_bot.id, 'expense', 'acquisition', v_purchase_price, 'Aircraft purchase: ' || v_tail, r_bot.game_current_time); v_bot_cash := v_bot_cash - v_purchase_price; END IF; END IF; END IF;
        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
        SELECT f.id, f.tail_number, f.condition, m.model_name, m.capacity, m.speed_kmh, m.range_km INTO v_idle_aircraft_id, v_idle_tail, v_idle_condition, v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id) ORDER BY f.condition DESC LIMIT 1;
        IF v_idle_aircraft_id IS NOT NULL AND v_route_count < v_target_fleet_cap THEN v_attempts := 0; v_inserted := false; WHILE v_attempts < 20 AND NOT v_inserted LOOP SELECT iata INTO v_dest_iata FROM airports WHERE iata != v_origin_iata ORDER BY demand_index DESC, random() LIMIT 1; IF v_dest_iata IS NULL THEN EXIT; END IF; SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude) INTO v_distance FROM airports o, airports d WHERE o.iata = v_origin_iata AND d.iata = v_dest_iata; IF v_distance > 0 AND v_distance <= v_idle_range THEN v_base_fare := 50.00 + (v_distance * 0.12); v_target_price := ROUND(v_base_fare * v_target_price_multiplier, 2); v_max_weekly_flights := calculate_route_max_weekly_flights(v_distance, v_idle_speed); v_target_flights := GREATEST(1, FLOOR(v_max_weekly_flights * v_target_schedule_ratio)); BEGIN INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week) VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, v_target_price, v_idle_aircraft_id, v_target_flights); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; ELSE v_attempts := v_attempts + 1; END IF; END LOOP; END IF;
        FOR r_route IN SELECT ra.*, m.speed_kmh, m.range_km, m.turnaround_hours FROM route_assignments ra JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id JOIN aircraft_models m ON m.id = fa.aircraft_model_id WHERE ra.user_id = r_bot.id AND ra.status = 'active' LOOP SELECT COUNT(*) INTO v_human_competitors FROM route_assignments WHERE origin_iata = r_route.origin_iata AND destination_iata = r_route.destination_iata AND status = 'active' AND user_id != r_bot.id AND user_id IN (SELECT id FROM users WHERE actor_type = 'REAL'); IF v_human_competitors > 0 THEN v_base_fare := 50.00 + (r_route.distance_km * 0.12); v_new_price := ROUND(v_base_fare * v_target_price_multiplier * CASE WHEN r_route.ticket_price > v_base_fare * 1.3 THEN 0.95 ELSE 1.0 END, 2); IF v_new_price != r_route.ticket_price THEN UPDATE route_assignments SET ticket_price = v_new_price WHERE id = r_route.id; END IF; END IF; END LOOP;
        SELECT COUNT(*) INTO v_active_loans FROM loans WHERE user_id = r_bot.id AND status = 'active'; IF v_active_loans = 0 AND v_bot_cash < v_starting_cash * 0.5 AND v_bot_cash > 1000000 THEN PERFORM bot_take_loan(r_bot.id, LEAST(5000000, v_starting_cash - v_bot_cash)); END IF;
        UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;
    END LOOP;
END;
$function$;


-- ── Fix 3: Fix deposit_to_savings AND withdraw_from_savings ──
-- Return types changed (removed new_checking_balance), must DROP first

DROP FUNCTION IF EXISTS public.deposit_to_savings(numeric);
DROP FUNCTION IF EXISTS public.withdraw_from_savings(numeric);

CREATE OR REPLACE FUNCTION public.deposit_to_savings(p_amount numeric)
RETURNS TABLE(success boolean, message text, new_savings_balance numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID; v_savings_id UUID; v_savings_balance NUMERIC; v_cash NUMERIC;
BEGIN
    v_user_id := require_current_user_id();
    IF p_amount <= 0 THEN RETURN QUERY SELECT false, 'Amount must be positive.'::TEXT, 0::NUMERIC; RETURN; END IF;
    SELECT cash INTO v_cash FROM users WHERE id = v_user_id;
    IF v_cash < p_amount THEN RETURN QUERY SELECT false, 'Insufficient cash balance.'::TEXT, COALESCE(v_cash, 0)::NUMERIC; RETURN; END IF;
    PERFORM ensure_checking_account(v_user_id);
    SELECT id, balance INTO v_savings_id, v_savings_balance FROM bank_accounts WHERE user_id = v_user_id AND account_type = 'savings';
    IF v_savings_id IS NULL THEN RETURN QUERY SELECT false, 'No savings account found.'::TEXT, 0::NUMERIC; RETURN; END IF;
    UPDATE users SET cash = cash - p_amount WHERE id = v_user_id;
    UPDATE bank_accounts SET balance = balance + p_amount, updated_at = NOW() WHERE id = v_savings_id;
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
    VALUES (v_savings_id, v_user_id, 'deposit', p_amount, v_savings_balance + p_amount, 'Cash deposit to savings', NOW());
    SELECT balance INTO v_savings_balance FROM bank_accounts WHERE id = v_savings_id;
    RETURN QUERY SELECT true, 'Deposited $' || p_amount::TEXT || ' to savings.'::TEXT, v_savings_balance;
END;
$function$;

CREATE OR REPLACE FUNCTION public.withdraw_from_savings(p_amount numeric)
RETURNS TABLE(success boolean, message text, new_savings_balance numeric, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID; v_savings_id UUID; v_savings_balance NUMERIC;
BEGIN
    v_user_id := require_current_user_id();
    IF p_amount <= 0 THEN RETURN QUERY SELECT false, 'Amount must be positive.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF;
    SELECT id, balance INTO v_savings_id, v_savings_balance FROM bank_accounts WHERE user_id = v_user_id AND account_type = 'savings';
    IF v_savings_id IS NULL OR v_savings_balance < p_amount THEN
        RETURN QUERY SELECT false, 'Insufficient savings balance.'::TEXT, COALESCE(v_savings_balance, 0)::NUMERIC, (SELECT cash FROM users WHERE id = v_user_id); RETURN;
    END IF;
    UPDATE bank_accounts SET balance = balance - p_amount, updated_at = NOW() WHERE id = v_savings_id;
    UPDATE users SET cash = cash + p_amount WHERE id = v_user_id;
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
    VALUES (v_savings_id, v_user_id, 'withdrawal', p_amount, v_savings_balance - p_amount, 'Withdrawal from savings to cash', NOW());
    SELECT balance INTO v_savings_balance FROM bank_accounts WHERE id = v_savings_id;
    RETURN QUERY SELECT true, 'Withdrew $' || p_amount::TEXT || ' from savings.'::TEXT, v_savings_balance, (SELECT cash FROM users WHERE id = v_user_id);
END;
$function$;


-- ── Fix 4: Fix finance_aircraft 4-param internal (ensure 'finance' acquisition_type) ──

CREATE OR REPLACE FUNCTION public.finance_aircraft(
    p_user_id uuid, p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20,
    p_term_months integer DEFAULT 36
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
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

    SELECT u.actor_type, u.credit_score, u.game_current_time, u.hq_airport_iata, u.archetype
    INTO v_actor_type, v_credit_score, v_game_time, v_hq_iata, v_archetype
    FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;

    IF v_actor_type = 'AI' THEN
        SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
        v_down_payment := v_purchase_price * p_down_payment_pct;
        v_principal := v_purchase_price - v_down_payment;
        v_interest_rate := 0.05;
        v_total_repayable := v_principal * (1 + v_interest_rate);
        v_monthly_payment := v_total_repayable / p_term_months;

        IF v_cash < v_down_payment THEN
            RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
        END IF;

        UPDATE users SET cash = cash - v_down_payment WHERE id = p_user_id;

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

        INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
        VALUES (p_user_id, 'expense', 'aircraft_financing_down', v_down_payment,
                'Aircraft financing down payment — ' || v_model.model_name, v_game_time);

        PERFORM ensure_checking_account(p_user_id);
        INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
        SELECT ba.id, p_user_id, 'payment', v_down_payment,
               (SELECT u.cash FROM users u WHERE u.id = p_user_id),
               'Aircraft financing down payment — ' || v_model.model_name,
               v_game_time
        FROM bank_accounts ba
        WHERE ba.user_id = p_user_id AND ba.account_type = 'savings'
        LIMIT 1;

        SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
        RETURN QUERY SELECT true, 'Aircraft financed (bot).'::TEXT, v_cash;
        RETURN;
    END IF;

    SELECT cash, game_current_time, hq_airport_iata INTO v_cash, v_game_time, v_hq_iata
    FROM users u WHERE u.id = p_user_id;
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

    UPDATE users SET cash = cash - v_down_payment WHERE id = p_user_id;

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
    VALUES (p_user_id, p_aircraft_model_id, v_model.model_name, generate_tail_number(COALESCE(v_hq_iata, 'CGK')), 'finance', 100.00, 'active', v_model.capacity, 0, 0)
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made)
    VALUES (p_user_id, v_principal, v_interest_rate, v_total_repayable, 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0);

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_user_id, 'expense', 'aircraft_financing_down', v_down_payment,
            'Aircraft financing down payment — ' || v_model.model_name, v_game_time);

    PERFORM ensure_checking_account(p_user_id);
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
    SELECT ba.id, p_user_id, 'payment', v_down_payment,
           (SELECT u.cash FROM users u WHERE u.id = p_user_id),
           'Aircraft financing down payment — ' || v_model.model_name,
           v_game_time
    FROM bank_accounts ba
    WHERE ba.user_id = p_user_id AND ba.account_type = 'savings'
    LIMIT 1;

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$function$;


-- ── Fix 5: Create pg_cron jobs ──

DO $$
BEGIN
    PERFORM cron.unschedule('skyward_world_tick');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

DO $$
BEGIN
    PERFORM cron.unschedule('skyward_compact_financial_ledger');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

DO $$
BEGIN
    PERFORM cron.unschedule('skyward_compact_world_tick_log');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

SELECT cron.schedule(
    'skyward_world_tick',
    '* * * * *',
    $$SELECT ensure_world_current()$$
);

SELECT cron.schedule(
    'skyward_compact_financial_ledger',
    '0 3 * * *',
    $$SELECT compact_financial_ledger(false)$$
);

SELECT cron.schedule(
    'skyward_compact_world_tick_log',
    '30 3 * * *',
    $$SELECT compact_world_tick_log(false)$$
);


-- ── Fix 6: Fix process_world_tick — error isolation + lock safety ──

CREATE OR REPLACE FUNCTION public.process_world_tick(p_season_id uuid DEFAULT NULL::uuid, p_max_ticks integer DEFAULT 10)
RETURNS TABLE(season_id uuid, ticks_processed integer, game_time_after timestamp with time zone, players_processed integer, bots_processed integer)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    r_season RECORD;
    v_game_time_after TIMESTAMPTZ;
    v_ticks_processed INT := 0;
    v_players_processed INT := 0;
    v_bots_processed INT := 0;
    r_user RECORD;
    r_player_result RECORD;
    v_lock_key BIGINT;
    v_error_msg TEXT;
BEGIN
    IF p_season_id IS NOT NULL THEN
        SELECT * INTO r_season FROM season_clock WHERE id = p_season_id;
    ELSE
        SELECT * INTO r_season FROM season_clock WHERE status = 'active' LIMIT 1;
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'No active season found'; END IF;

    v_lock_key := hashtext(r_season.id::text);
    IF NOT pg_try_advisory_xact_lock(v_lock_key) THEN
        RAISE EXCEPTION 'World tick already in progress for season %', r_season.id;
    END IF;

    v_game_time_after := r_season.current_game_time
        + (r_season.tick_interval_seconds * r_season.time_scale_multiplier * INTERVAL '1 second');

    PERFORM generate_game_events(v_game_time_after);
    PERFORM deactivate_expired_events(v_game_time_after);

    FOR r_user IN
        SELECT u.id, u.game_current_time
        FROM users u
        WHERE u.season_id = r_season.id
          AND u.actor_type = 'REAL'
          AND COALESCE(u.operational_status, 'Active') != 'Bankrupt'
    LOOP
        BEGIN
            SELECT * INTO r_player_result
            FROM process_player_simulation_to_time(r_user.id, v_game_time_after) LIMIT 1;
            IF COALESCE(r_player_result.elapsed_days, 0.0) > 0.0 THEN
                v_players_processed := v_players_processed + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_error_msg = MESSAGE_TEXT;
            INSERT INTO world_tick_log (season_id, status, message, started_at, finished_at)
            VALUES (r_season.id, 'player_error',
                    'Player ' || r_user.id || ': ' || v_error_msg, NOW(), NOW());
        END;
    END LOOP;

    v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);

    IF date_trunc('day', r_season.current_game_time)::DATE <> date_trunc('day', v_game_time_after)::DATE THEN
        PERFORM record_rank_snapshot((v_game_time_after AT TIME ZONE 'UTC')::DATE);
        PERFORM execute_bot_decisions();
    END IF;

    UPDATE season_clock
    SET current_game_time = v_game_time_after, last_tick_at = NOW(), updated_at = NOW()
    WHERE id = r_season.id;

    v_ticks_processed := 1;

    season_id := r_season.id;
    ticks_processed := v_ticks_processed;
    game_time_after := v_game_time_after;
    players_processed := v_players_processed;
    bots_processed := v_bots_processed;
    RETURN NEXT;
END;
$function$;


-- ── Fix 7: Fix trigger update_user_net_worth uses stale cash ──

CREATE OR REPLACE FUNCTION public.trg_update_user_net_worth()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_fleet_value NUMERIC;
BEGIN
    SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
    INTO v_fleet_value
    FROM fleet_aircraft f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.user_id = NEW.id AND f.acquisition_type = 'purchase';
    NEW.net_worth := COALESCE(NEW.cash, 0) + v_fleet_value;
    RETURN NEW;
END;
$$;


-- ── Fix 8: Fix double loan payment (exclude aircraft_financing) ──

CREATE OR REPLACE FUNCTION public.process_loan_payments(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
DECLARE
    v_actor_type VARCHAR(10);
    r_loan RECORD;
    v_cash NUMERIC;
    v_payment NUMERIC;
    v_late_fee NUMERIC;
    v_effective_weekly NUMERIC;
BEGIN
    SELECT actor_type, cash INTO v_actor_type, v_cash FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN; END IF;

    FOR r_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id AND status = 'active' AND loan_type != 'aircraft_financing'
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
                UPDATE users SET cash = cash - v_effective_weekly WHERE id = p_user_id;
                v_cash := v_cash - v_effective_weekly;
                UPDATE loans SET remaining_balance = remaining_balance - v_effective_weekly WHERE id = r_loan.id;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0 WHERE id = r_loan.id;
                END IF;
            ELSE
                UPDATE loans SET remaining_balance = remaining_balance * 1.10,
                                 missed_payments = missed_payments + 1 WHERE id = r_loan.id;
                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
                END IF;
            END IF;
        ELSE
            v_payment := v_effective_weekly;
            IF v_cash >= v_payment THEN
                v_cash := v_cash - v_payment;
                UPDATE users SET cash = v_cash WHERE id = p_user_id;
                UPDATE loans SET remaining_balance = remaining_balance - v_payment WHERE id = r_loan.id;
                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (p_user_id, 'expense', 'loan_payment', v_payment, 'Weekly loan payment', p_game_date);
                PERFORM ensure_checking_account(p_user_id);
                INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
                SELECT ba.id, p_user_id, 'payment', v_payment,
                       (SELECT u.cash FROM users u WHERE u.id = p_user_id),
                       'Weekly loan payment',
                       p_game_date
                FROM bank_accounts ba
                WHERE ba.user_id = p_user_id AND ba.account_type = 'savings'
                LIMIT 1;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0 WHERE id = r_loan.id;
                END IF;
            ELSE
                v_late_fee := v_payment * 0.10;
                UPDATE loans SET remaining_balance = remaining_balance + v_late_fee,
                                 missed_payments = missed_payments + 1 WHERE id = r_loan.id;
                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (p_user_id, 'expense', 'loan_late_fee', v_late_fee, 'Loan payment late fee', p_game_date);
                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
                    IF r_loan.collateral_aircraft_id IS NOT NULL THEN
                        UPDATE fleet_aircraft SET status = 'grounded' WHERE id = r_loan.collateral_aircraft_id;
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$function$;


-- ── Fix 9: Consume game events in simulation ──

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
LANGUAGE plpgsql VOLATILE AS $function$
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
    v_buffered_rev_accum NUMERIC(20,2) := 0.00;
    v_buffered_ops_accum NUMERIC(20,2) := 0.00;
    v_buffered_lease_accum NUMERIC(20,2) := 0.00;
    v_buffered_cargo_accum NUMERIC(20,2) := 0.00;
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
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found: %', p_user_id; END IF;

    SELECT COALESCE(fuel_price_per_liter, 0.85), COALESCE(crew_cost_per_hour, 350.0)
    INTO v_fuel_price, v_crew_cost FROM global_game_settings LIMIT 1;

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
        v_ops_cost := v_route.flights_per_week * (
            v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier +
            v_flight_hours * v_crew_cost
        );
        v_lease_cost := CASE
            WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                         WHERE fa2.id = v_route.assigned_aircraft_id
                           AND fa2.acquisition_type = 'lease')
            THEN COALESCE(v_route.lease_price_per_month, 0) / 4.0
            ELSE 0
        END;

        v_cargo_rev := v_revenue * 0.05;
        v_buffered_rev_accum := v_buffered_rev_accum + v_revenue;
        v_buffered_ops_accum := v_buffered_ops_accum + v_ops_cost;
        v_buffered_lease_accum := v_buffered_lease_accum + v_lease_cost;
        v_buffered_cargo_accum := v_buffered_cargo_accum + v_cargo_rev;

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

    v_net := v_buffered_rev_accum + v_buffered_cargo_accum
             - v_buffered_ops_accum - v_buffered_lease_accum;

    UPDATE users u
    SET cash = r_user.cash + v_net,
        game_current_time = p_target_game_time,
        last_active_at = NOW()
    WHERE u.id = p_user_id
    RETURNING u.cash INTO v_cash_after;

    IF v_net != 0 THEN
        PERFORM ensure_checking_account(p_user_id);
        INSERT INTO bank_transactions (
            account_id, user_id, transaction_type, amount, balance_after,
            description, game_date
        )
        SELECT ba.id, p_user_id,
            CASE WHEN v_net >= 0 THEN 'deposit' ELSE 'payment' END,
            v_net,
            (SELECT u2.cash FROM users u2 WHERE u2.id = p_user_id),
            'Simulation net cash movement',
            p_target_game_time
        FROM bank_accounts ba
        WHERE ba.user_id = p_user_id AND ba.account_type = 'savings'
        LIMIT 1;
    END IF;

    IF v_elapsed_days >= 1.0 THEN
        PERFORM process_loan_payments(p_user_id, p_target_game_time);
        PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time);
        PERFORM accrue_savings_interest(p_user_id, p_target_game_time);
        PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time);
        PERFORM check_achievements(p_user_id, p_target_game_time);

        IF v_net < 0 THEN
            UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1
            WHERE id = p_user_id;
        ELSE
            UPDATE users SET consecutive_negative_days = 0,
                             recovery_streak_days = recovery_streak_days + 1
            WHERE id = p_user_id;
        END IF;
    END IF;

    game_time := p_target_game_time;
    cash := v_cash_after;
    flights_run := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$function$;


-- ── Fix 10: (refinance_loan already included in Fix 1q above) ──


-- ── Fix 11: Fix sell_aircraft ownership check ──

CREATE OR REPLACE FUNCTION public.sell_aircraft(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_user RECORD; v_fleet RECORD;
    v_base_value NUMERIC(20,2); v_age_years NUMERIC; v_depreciation_factor NUMERIC;
    v_sale_value NUMERIC(20,2);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;

    SELECT f.*, m.model_name, m.purchase_price
    INTO v_fleet FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;

    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'purchase' THEN
        RETURN QUERY SELECT FALSE, 'Only owned aircraft can be sold.'::VARCHAR, NULL::NUMERIC; RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC; RETURN;
    END IF;

    v_base_value := v_fleet.purchase_price * (v_fleet.condition / 100.00);
    IF v_fleet.acquired_game_date IS NOT NULL AND v_user.game_current_time IS NOT NULL THEN
        v_age_years := EXTRACT(EPOCH FROM (v_user.game_current_time - v_fleet.acquired_game_date)) / (365.25 * 86400.0);
        v_depreciation_factor := GREATEST(0.10, 1.0 - (0.05 * COALESCE(v_age_years, 0)));
        v_sale_value := ROUND(v_base_value * v_depreciation_factor, 2);
    ELSE
        v_sale_value := v_base_value;
    END IF;

    UPDATE users SET cash = cash + v_sale_value WHERE id = p_user_id RETURNING cash INTO new_cash;
    DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_user_id, 'revenue', 'aircraft_sale', v_sale_value,
            'Sold aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
            v_user.game_current_time);

    PERFORM ensure_checking_account(p_user_id);
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
    SELECT ba.id, p_user_id, 'deposit', v_sale_value,
           (SELECT u.cash FROM users u WHERE u.id = p_user_id),
           'Sold aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
           v_user.game_current_time
    FROM bank_accounts ba
    WHERE ba.user_id = p_user_id AND ba.account_type = 'savings'
    LIMIT 1;

    RETURN QUERY SELECT TRUE, 'Aircraft sold for $' || ROUND(v_sale_value, 2)::TEXT || '.'::VARCHAR, new_cash;
END;
$function$;


-- ── Fix 12: Fix repair_aircraft — add process_simulation_delta call ──

CREATE OR REPLACE FUNCTION public.repair_aircraft(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_cash NUMERIC; v_condition NUMERIC; v_purchase_price NUMERIC; v_lease_price NUMERIC;
    v_model_name VARCHAR; v_repair_cost NUMERIC; v_acquisition_type VARCHAR; v_game_time TIMESTAMPTZ;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT f.condition, f.acquisition_type, m.purchase_price, m.lease_price_per_month, m.model_name
    INTO v_condition, v_acquisition_type, v_purchase_price, v_lease_price, v_model_name
    FROM fleet_aircraft f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id;

    SELECT cash, game_current_time INTO v_cash, v_game_time FROM users WHERE id = p_user_id FOR UPDATE;

    IF v_model_name IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, v_cash; RETURN;
    END IF;
    IF v_condition >= 100.00 THEN
        RETURN QUERY SELECT FALSE, ('Aircraft ' || v_model_name || ' is already in pristine condition.')::VARCHAR, v_cash; RETURN;
    END IF;

    v_repair_cost := CASE
        WHEN v_acquisition_type = 'lease' THEN (100.00 - v_condition) * (COALESCE(v_lease_price, 0.00) * 0.50)
        ELSE (100.00 - v_condition) * (COALESCE(v_purchase_price, 0.00) * 0.0005)
    END;

    IF v_cash < v_repair_cost THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds for repair. Required: $' || ROUND(v_repair_cost, 2))::VARCHAR, v_cash; RETURN;
    END IF;

    UPDATE users SET cash = cash - v_repair_cost WHERE id = p_user_id RETURNING cash INTO v_cash;
    UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = p_fleet_id;

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_user_id, 'expense', 'aircraft_repair', v_repair_cost,
            'Maintenance check completed for ' || v_model_name ||
            ' - restored condition from ' || ROUND(v_condition::numeric, 2) || '% to 100%',
            v_game_time);

    PERFORM ensure_checking_account(p_user_id);
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
    SELECT ba.id, p_user_id, 'payment', v_repair_cost,
           (SELECT u.cash FROM users u WHERE u.id = p_user_id),
           'Maintenance repair: ' || v_model_name,
           v_game_time
    FROM bank_accounts ba
    WHERE ba.user_id = p_user_id AND ba.account_type = 'savings'
    LIMIT 1;

    RETURN QUERY SELECT TRUE, 'Aircraft maintenance complete. Health restored to 100%!'::VARCHAR, v_cash;
END;
$function$;


-- ── Fix 13: Fix reset_user_airline — cleanup bank data ──

CREATE OR REPLACE FUNCTION public.reset_user_airline(p_user_id uuid)
RETURNS TABLE(success boolean, message text)
LANGUAGE plpgsql VOLATILE AS $function$
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
    DELETE FROM financial_ledger WHERE user_id = p_user_id;
    DELETE FROM achievements WHERE user_id = p_user_id;

    UPDATE users SET
        cash = 15000000.00,
        net_worth = 15000000.00,
        game_current_time = TIMESTAMP WITH TIME ZONE '2020-01-01 00:00:00+00',
        hq_airport_iata = 'SIN',
        auto_grounding_threshold = 40.00,
        buffered_revenue = 0.00,
        buffered_ops_cost = 0.00,
        buffered_lease_cost = 0.00,
        operational_status = 'Active',
        consecutive_negative_days = 0,
        recovery_streak_days = 0,
        last_active_at = NOW(),
        onboarding_completed = false,
        credit_score = 500,
        credit_tier = 'Standard'
    WHERE id = p_user_id;

    INSERT INTO bank_accounts (user_id, account_type, balance, interest_rate)
    VALUES (p_user_id, 'savings', 15000000.00, 0.01);

    RETURN QUERY SELECT TRUE, 'Airline reset successfully';
END;
$function$;


-- ── Fix 14: Fix ensure_world_current — add catch-up loop ──

CREATE OR REPLACE FUNCTION public.ensure_world_current(p_season_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(season_id uuid, ticks_processed integer, game_time_after timestamp with time zone, players_processed integer, bots_processed integer)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_season_id UUID;
    v_ticks INT := 0;
    r_result RECORD;
    v_current_game_time TIMESTAMPTZ;
BEGIN
    IF p_season_id IS NOT NULL THEN v_season_id := p_season_id;
    ELSE SELECT id INTO v_season_id FROM season_clock WHERE status = 'active' ORDER BY created_at ASC LIMIT 1;
    END IF;
    IF v_season_id IS NULL THEN RETURN; END IF;

    LOOP
        SELECT * INTO r_result FROM process_world_tick(v_season_id, 1) LIMIT 1;
        v_ticks := v_ticks + 1;
        IF v_ticks >= 100 THEN EXIT; END IF;
        SELECT current_game_time INTO v_current_game_time FROM season_clock WHERE id = v_season_id;
        EXIT WHEN v_current_game_time >= now();
    END LOOP;

    IF r_result IS NOT NULL THEN
        season_id := r_result.season_id;
        ticks_processed := r_result.ticks_processed;
        game_time_after := r_result.game_time_after;
        players_processed := r_result.players_processed;
        bots_processed := r_result.bots_processed;
        RETURN NEXT;
    END IF;
END;
$function$;


-- ── Fix 15: Rename ensure_checking_account → ensure_savings_account ──

CREATE OR REPLACE FUNCTION public.ensure_savings_account(p_user_id uuid)
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

CREATE OR REPLACE FUNCTION public.ensure_checking_account(p_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
    RETURN ensure_savings_account(p_user_id);
END;
$function$;


-- ── Fix 16: Fix repay_loan sign convention ──

CREATE OR REPLACE FUNCTION public.repay_loan(p_loan_id uuid, p_amount numeric DEFAULT NULL::numeric)
RETURNS TABLE(success boolean, message text, new_cash numeric, paid_off boolean)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog AS $function$
DECLARE
    v_user_id UUID; v_loan RECORD; v_payment NUMERIC; v_cash NUMERIC;
    v_is_paid_off BOOLEAN := false;
BEGIN
    v_user_id := require_current_user_id();
    SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'Loan not found or already paid off.'::TEXT, 0::NUMERIC, false; RETURN; END IF;

    IF p_amount IS NULL THEN v_payment := v_loan.remaining_balance;
    ELSE v_payment := LEAST(p_amount, v_loan.remaining_balance); END IF;

    IF v_payment <= 0 THEN RETURN QUERY SELECT false, 'Payment amount must be positive.'::TEXT, 0::NUMERIC, false; RETURN; END IF;

    SELECT cash INTO v_cash FROM users WHERE id = v_user_id FOR UPDATE;
    IF v_cash < v_payment THEN
        RETURN QUERY SELECT false, 'Insufficient cash. Need $' || v_payment::TEXT || ', have $' || v_cash::TEXT || '.'::TEXT, v_cash, false; RETURN;
    END IF;

    UPDATE users SET cash = cash - v_payment WHERE id = v_user_id;
    UPDATE loans
    SET remaining_balance = remaining_balance - v_payment,
        status = CASE WHEN remaining_balance - v_payment <= 0 THEN 'paid_off'::VARCHAR ELSE status END,
        paid_off_at = CASE WHEN remaining_balance - v_payment <= 0 THEN NOW() ELSE paid_off_at END
    WHERE id = p_loan_id;

    v_is_paid_off := (SELECT remaining_balance <= 0 FROM loans WHERE id = p_loan_id);

    PERFORM ensure_checking_account(v_user_id);
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, reference_type, reference_id, game_date)
    SELECT ba.id, v_user_id, 'payment', v_payment, ba.balance,
           CASE WHEN v_is_paid_off THEN 'Loan fully repaid' ELSE 'Loan partial repayment' END,
           'loan', p_loan_id, NOW()
    FROM bank_accounts ba WHERE ba.user_id = v_user_id AND ba.account_type = 'savings' LIMIT 1;

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (v_user_id, 'expense', 'loan_repayment', v_payment,
            CASE WHEN v_is_paid_off THEN 'Loan fully repaid' ELSE 'Loan partial repayment' END,
            NOW());

    SELECT cash INTO v_cash FROM users WHERE id = v_user_id;
    RETURN QUERY SELECT true,
        CASE WHEN v_is_paid_off THEN 'Loan fully repaid!'
             ELSE 'Payment of $' || v_payment::TEXT || ' applied.' END::TEXT,
        v_cash, v_is_paid_off;
END;
$function$;

REVOKE ALL ON FUNCTION repay_loan(UUID, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION repay_loan(UUID, NUMERIC) TO authenticated;


COMMIT;
