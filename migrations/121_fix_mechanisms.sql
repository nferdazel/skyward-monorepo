-- Migration 121: Fix broken mechanisms (nickname, credit_score, HQ)
BEGIN;

-- ============================================================
-- Fix 1: bot_finance_aircraft — add nickname
-- ============================================================
CREATE OR REPLACE FUNCTION public.bot_finance_aircraft(
    p_bot_id uuid, p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 60
)
RETURNS boolean
LANGUAGE plpgsql VOLATILE AS $function$
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
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN RETURN false; END IF;
    v_purchase_price := v_model.purchase_price;
    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_monthly_payment := (v_principal * (1 + v_interest_rate)) / p_term_months;
    SELECT cash, game_current_time INTO v_cash, v_game_time FROM users WHERE id = p_bot_id;
    IF v_cash < v_down_payment THEN RETURN false; END IF;
    UPDATE users SET cash = cash - v_down_payment WHERE id = p_bot_id;

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
    VALUES (p_bot_id, p_aircraft_model_id, v_model.model_name, 'finance', 100.00, 'active', 'BOT-' || left(p_bot_id::text, 4), FLOOR(v_model.capacity * 0.70)::INT, FLOOR(v_model.capacity * 0.20)::INT, FLOOR(v_model.capacity * 0.10)::INT)
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made)
    VALUES (p_bot_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0);

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_bot_id, 'expense', 'aircraft_financing_down', v_down_payment, 'Aircraft financing down payment — ' || v_model.model_name, v_game_time);
    RETURN true;
END;
$function$;

-- ============================================================
-- Fix 2: finance_aircraft — add nickname to BOTH paths
-- ============================================================
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
        WHERE ba.user_id = p_user_id AND ba.account_type = 'checking'
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
    WHERE ba.user_id = p_user_id AND ba.account_type = 'checking'
    LIMIT 1;

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$function$;

-- ============================================================
-- Fix 3: execute_bot_decisions — add nickname to purchase branch
-- ============================================================
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
            v_deposit_amount := COALESCE(v_lease_price, 0.00) * (v_deposit_pct * 10.0);
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

-- ============================================================
-- Fix 4: take_loan AI branch — add credit_score_at_origination
-- ============================================================
CREATE OR REPLACE FUNCTION public.take_loan(
    p_user_id uuid, p_principal numeric,
    p_term_weeks integer DEFAULT 52,
    p_loan_type character varying DEFAULT 'unsecured',
    p_collateral_aircraft_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_actor_type VARCHAR(10); v_existing_loans INT; v_credit_score INT;
    v_score_record RECORD; v_tier VARCHAR(10); v_config JSONB; v_tier_cfg JSONB;
    v_min_loan NUMERIC; v_max_loans INT; v_interest_rate NUMERIC;
    v_weekly_payment NUMERIC; v_total_repayable NUMERIC; v_cash NUMERIC;
    v_game_time TIMESTAMPTZ; v_max_principal NUMERIC; v_rate_key TEXT; v_loan_id UUID;
BEGIN
    SELECT u.actor_type, u.credit_score, u.game_current_time
    INTO v_actor_type, v_credit_score, v_game_time
    FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;

    IF v_actor_type = 'AI' THEN
        SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active';
        IF v_existing_loans >= 3 THEN RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC; RETURN; END IF;
        IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN QUERY SELECT false, 'Bot loan amount must be between $100K and $5M.'::TEXT, 0::NUMERIC; RETURN; END IF;
        v_interest_rate := 0.05;
        v_total_repayable := p_principal * (1 + v_interest_rate);
        v_weekly_payment := v_total_repayable / p_term_weeks;
        INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, game_date_taken, status, credit_score_at_origination)
        VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, v_game_time, 'active', v_credit_score)
        RETURNING id INTO v_loan_id;
        UPDATE users SET cash = cash + p_principal WHERE id = p_user_id;
        PERFORM ensure_checking_account(p_user_id);
        INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, reference_type, reference_id, game_date)
        SELECT ba.id, p_user_id, 'disbursement', p_principal, ba.balance + p_principal,
               'Loan disbursement', 'loan', v_loan_id, v_game_time
        FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'checking' LIMIT 1;
        INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
        VALUES (p_user_id, 'revenue', 'loan', p_principal, 'Loan disbursement', v_game_time);
        SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
        RETURN QUERY SELECT true, 'Loan disbursed.'::TEXT, v_cash;
        RETURN;
    END IF;

    SELECT credit_tier_config INTO v_config FROM global_game_settings WHERE id = 1;
    v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
    v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);

    SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active';
    IF v_existing_loans >= v_max_loans THEN
        RETURN QUERY SELECT false, 'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    SELECT u.credit_score, u.game_current_time INTO v_credit_score, v_game_time
    FROM users u WHERE u.id = p_user_id;
    v_credit_score := COALESCE(v_credit_score, 500);

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
        v_rate_key := 'rate_unsecured';
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC; RETURN;
        END IF;
        v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
        v_rate_key := 'rate_secured';
    ELSE
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000) * 0.5;
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07) + 0.02;
        v_rate_key := 'rate_credit_line';
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

    UPDATE users SET cash = cash + p_principal WHERE id = p_user_id;

    PERFORM ensure_checking_account(p_user_id);
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, reference_type, reference_id, game_date)
    SELECT ba.id, p_user_id, 'disbursement', p_principal, ba.balance + p_principal,
           'Loan disbursement', 'loan', v_loan_id, v_game_time
    FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'checking' LIMIT 1;

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_user_id, 'revenue', 'loan', p_principal, 'Loan disbursement', v_game_time);

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    RETURN QUERY SELECT true, 'Loan disbursed at ' || ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT, v_cash;
END;
$function$;

-- ============================================================
-- Fix 5: bot_take_loan — add credit_score_at_origination
-- ============================================================
CREATE OR REPLACE FUNCTION public.bot_take_loan(
    p_bot_id uuid, p_principal numeric, p_term_weeks integer DEFAULT 52
)
RETURNS boolean
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_existing_loans INT;
    v_cash NUMERIC;
    v_interest_rate NUMERIC := 0.05;
    v_total_repayable NUMERIC;
    v_weekly_payment NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_credit_score INT;
BEGIN
    SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_bot_id AND status = 'active';
    IF v_existing_loans >= 3 THEN RETURN false; END IF;
    IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN false; END IF;
    SELECT cash, game_current_time, credit_score INTO v_cash, v_game_time, v_credit_score FROM users WHERE id = p_bot_id;
    v_credit_score := COALESCE(v_credit_score, 500);
    v_total_repayable := p_principal * (1 + v_interest_rate * (p_term_weeks / 52.0));
    v_weekly_payment := v_total_repayable / p_term_weeks;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, credit_score_at_origination)
    VALUES (p_bot_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', v_game_time, 'unsecured', v_credit_score);

    UPDATE users SET cash = cash + p_principal WHERE id = p_bot_id;
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_bot_id, 'revenue', 'loan', p_principal, 'Bot loan disbursement', v_game_time);
    RETURN true;
END;
$function$;

-- ============================================================
-- Fix 6: handle_new_auth_user — add default HQ
-- ============================================================
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql VOLATILE AS $function$
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

    SELECT COALESCE((SELECT g.starting_cash::NUMERIC FROM public.global_game_settings g LIMIT 1), 15000000.00)
    INTO v_starting_cash;

    INSERT INTO public.users (
        auth_user_id, username, company_name, ceo_name, cash, net_worth,
        game_current_time, last_active_at, operational_status,
        consecutive_negative_days, recovery_streak_days, auto_grounding_threshold,
        credit_score, credit_tier, actor_type, hq_airport_iata
    ) VALUES (
        NEW.id, v_username, v_company_name, v_ceo_name, v_starting_cash, v_starting_cash,
        '2020-01-01 00:00:00+00', NOW(), 'Active',
        0, 0, 40.00,
        500, 'Standard', 'REAL', 'CGK'
    );

    RETURN NEW;
END;
$function$;

-- ============================================================
-- Fix 7: finance_aircraft (3-param, human-only) — add nickname
-- This is the overload called by the frontend (via require_current_user_id)
-- ============================================================
CREATE OR REPLACE FUNCTION public.finance_aircraft(
    p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20,
    p_term_months integer DEFAULT 36
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $$
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
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC; RETURN; END IF;
    v_purchase_price := v_model.purchase_price;

    SELECT u.credit_score, u.game_current_time, u.hq_airport_iata INTO v_credit_score, v_game_time, v_hq_iata
    FROM users u WHERE u.id = v_user_id;
    v_credit_score := COALESCE(v_credit_score, 500);

    SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = v_user_id;
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

    SELECT cash INTO v_cash FROM users WHERE id = v_user_id;
    IF v_cash < v_down_payment THEN
        RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    UPDATE users SET cash = cash - v_down_payment WHERE id = v_user_id RETURNING cash INTO v_cash;

    v_economy_seats := GREATEST(1, v_model.capacity - (2 * FLOOR(v_model.capacity * 0.18 / 2.0)::INT) - (3 * FLOOR(v_model.capacity * 0.06 / 3.0)::INT));
    v_business_seats := FLOOR(v_model.capacity * 0.18 / 2.0)::INT;
    v_first_seats := FLOOR(v_model.capacity * 0.06 / 3.0)::INT;

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, economy_seats, business_seats, first_class_seats, condition, status, acquisition_type)
    VALUES (v_user_id, p_aircraft_model_id, v_model.model_name, generate_tail_number(COALESCE(v_hq_iata, 'SG')), v_economy_seats, v_business_seats, v_first_seats, 100.0, 'active', 'purchase')
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (user_id, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, principal, interest_rate, monthly_payment, term_months, remaining_balance, weekly_payment, taken_at, loan_type, loan_subtype)
    VALUES (v_user_id, p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, v_principal, v_interest_rate, v_monthly_payment, p_term_months, v_total_repayable, 0, v_game_time, 'aircraft_financing', 'aircraft_financing');

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (v_user_id, 'expense', 'aircraft_financing_down', v_down_payment, 'Aircraft financing down payment', v_game_time);

    RETURN QUERY SELECT true, 'Financed ' || v_model.manufacturer || ' ' || v_model.model_name || '. Down: $' || ROUND(v_down_payment)::TEXT || ', Monthly: $' || ROUND(v_monthly_payment, 2)::TEXT || '/mo for ' || p_term_months::TEXT || ' months.'::TEXT, v_cash;
END;
$$;

COMMIT;
