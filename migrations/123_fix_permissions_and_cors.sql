-- Migration 123: Fix permissions, checking→savings in bank_transactions, and repay_loan SECURITY DEFINER
-- ============================================================================
-- Issue 1: Restore SELECT, INSERT, UPDATE grant on users for authenticated
-- Issue 2: All bank_transactions INSERTs still query account_type='checking'
--          but migration 122 converted all accounts to 'savings'
-- Issue 3: repay_loan should be SECURITY DEFINER
-- ============================================================================

BEGIN;

-- ============================================================
-- Fix 1: Restore UPDATE grant on users for authenticated
-- ============================================================

GRANT SELECT, INSERT, UPDATE ON public.users TO authenticated;

-- ============================================================
-- Fix 2: Re-create all functions with 'savings' instead of 'checking'
-- ============================================================

-- ── 2a. process_player_simulation_to_time (latest from migration 120) ─────

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
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found: %', p_user_id; END IF;

    SELECT COALESCE(fuel_price_per_liter, 0.85), COALESCE(crew_cost_per_hour, 350.0)
    INTO v_fuel_price, v_crew_cost FROM global_game_settings LIMIT 1;

    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;

    FOR v_route IN
        SELECT ur.*, am.fuel_burn_per_km, am.speed_kmh, am.turnaround_hours,
               am.capacity, am.lease_price_per_month,
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
        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
        v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
        IF v_flight_hours <= 0 THEN CONTINUE; END IF;

        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price);
        v_seasonal_factor := 1.0;

        v_revenue := v_route.flights_per_week * v_route.ticket_price *
                     LEAST(v_route.capacity,
                           FLOOR(v_route.capacity * 0.95 * v_demand_multiplier * v_seasonal_factor));
        v_ops_cost := v_route.flights_per_week * (
            v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price +
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

    -- Record bank transaction EVERY tick with net movement (not just day boundaries)
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

-- ── 2b. process_loan_payments (latest from migration 119) ─────────────────

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
        WHERE user_id = p_user_id AND status = 'active'
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

-- ── 2c. purchase_aircraft (latest from migration 117) ─────────────────────

CREATE OR REPLACE FUNCTION public.purchase_aircraft(
    p_user_id uuid, p_model_id uuid, p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_cash NUMERIC; v_price NUMERIC; v_model_name VARCHAR; v_capacity INT;
    v_hq_iata VARCHAR(3); v_tail VARCHAR(20); v_economy INT; v_business INT; v_first INT; v_slots_used INT;
    v_game_time TIMESTAMPTZ;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT cash, hq_airport_iata, game_current_time INTO v_cash, v_hq_iata, v_game_time
    FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC; RETURN; END IF;

    SELECT purchase_price, model_name, capacity INTO v_price, v_model_name, v_capacity
    FROM aircraft_models WHERE id = p_model_id;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash; RETURN; END IF;

    v_economy := COALESCE(p_economy_seats, v_capacity);
    v_business := COALESCE(p_business_seats, 0);
    v_first := COALESCE(p_first_class_seats, 0);
    v_slots_used := v_economy + (v_business * 2) + (v_first * 3);

    IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
        RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash; RETURN;
    END IF;
    IF v_cash < v_price THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds to purchase ' || v_model_name || '.')::VARCHAR, v_cash; RETURN;
    END IF;

    LOOP v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
         EXIT WHEN NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_tail);
    END LOOP;

    UPDATE users SET cash = cash - v_price WHERE id = p_user_id RETURNING cash INTO v_cash;

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
    VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'purchase', 100.00, 'active', v_tail, v_economy, v_business, v_first);

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_user_id, 'expense', 'acquisition', v_price,
            'Purchased aircraft ' || v_model_name || ' [' || v_tail || ']', v_game_time);

    PERFORM ensure_checking_account(p_user_id);
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
    SELECT ba.id, p_user_id, 'payment', v_price,
           (SELECT u.cash FROM users u WHERE u.id = p_user_id),
           'Purchased aircraft ' || v_model_name || ' [' || v_tail || ']',
           v_game_time
    FROM bank_accounts ba
    WHERE ba.user_id = p_user_id AND ba.account_type = 'savings'
    LIMIT 1;

    RETURN QUERY SELECT TRUE, 'Successfully purchased ' || v_model_name || ' [' || v_tail || ']'::VARCHAR, v_cash;
END;
$function$;

-- ── 2d. lease_aircraft (latest from migration 117) ────────────────────────

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
    v_lease_deposit := v_lease_price * (v_deposit_pct * 10.0);

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

-- ── 2e. sell_aircraft (latest from migration 117) ─────────────────────────

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
    DELETE FROM fleet_aircraft WHERE id = p_fleet_id;

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

-- ── 2f. repair_aircraft (latest from migration 117) ───────────────────────

CREATE OR REPLACE FUNCTION public.repair_aircraft(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_cash NUMERIC; v_condition NUMERIC; v_purchase_price NUMERIC; v_lease_price NUMERIC;
    v_model_name VARCHAR; v_repair_cost NUMERIC; v_acquisition_type VARCHAR; v_game_time TIMESTAMPTZ;
BEGIN
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

-- ── 2g. terminate_aircraft_lease (latest from migration 117) ──────────────

CREATE OR REPLACE FUNCTION public.terminate_aircraft_lease(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_user RECORD; v_fleet RECORD; v_exit_fee NUMERIC(20,2);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;

    SELECT f.*, m.model_name, m.lease_price_per_month
    INTO v_fleet FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;

    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'lease' THEN
        RETURN QUERY SELECT FALSE, 'Only leased aircraft can be terminated through this action.'::VARCHAR, NULL::NUMERIC; RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC; RETURN;
    END IF;

    v_exit_fee := calculate_lease_termination_fee(v_fleet.lease_price_per_month);
    UPDATE users SET cash = cash - v_exit_fee WHERE id = p_user_id RETURNING cash INTO new_cash;

    IF v_exit_fee > 0 THEN
        INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
        VALUES (p_user_id, 'expense', 'aircraft_lease_exit', v_exit_fee,
                'Terminated leased aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') ||
                ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
                date_trunc('day', v_user.game_current_time));

        PERFORM ensure_checking_account(p_user_id);
        INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
        SELECT ba.id, p_user_id, 'payment', v_exit_fee,
               (SELECT u.cash FROM users u WHERE u.id = p_user_id),
               'Lease termination fee: ' || COALESCE(v_fleet.model_name, 'Unknown'),
               date_trunc('day', v_user.game_current_time)
        FROM bank_accounts ba
        WHERE ba.user_id = p_user_id AND ba.account_type = 'savings'
        LIMIT 1;
    END IF;

    DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;
    RETURN QUERY SELECT TRUE, 'Lease terminated successfully!'::VARCHAR, new_cash;
END;
$function$;

-- ── 2h. finance_aircraft 4-param (latest from migration 121) ──────────────

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

-- ── 2i. process_aircraft_financing_payments (latest from migration 117) ───

CREATE OR REPLACE FUNCTION public.process_aircraft_financing_payments(
    p_user_id uuid,
    p_game_date timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_loan RECORD;
    v_cash NUMERIC;
    v_payment NUMERIC;
    v_late_fee NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;

    FOR v_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id AND loan_type = 'aircraft_financing' AND status = 'active'
    LOOP
        v_payment := v_loan.monthly_payment;

        IF v_cash >= v_payment THEN
            UPDATE users SET cash = cash - v_payment WHERE id = p_user_id;
            v_cash := v_cash - v_payment;
            UPDATE loans SET remaining_balance = remaining_balance - v_payment,
                             payments_made = payments_made + 1 WHERE id = v_loan.id;

            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'aircraft_financing', v_payment, 'Aircraft financing payment', p_game_date);

            PERFORM ensure_checking_account(p_user_id);
            INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
            SELECT ba.id, p_user_id, 'payment', v_payment,
                   (SELECT u.cash FROM users u WHERE u.id = p_user_id),
                   'Aircraft financing payment',
                   p_game_date
            FROM bank_accounts ba
            WHERE ba.user_id = p_user_id AND ba.account_type = 'savings'
            LIMIT 1;

            IF (SELECT remaining_balance FROM loans WHERE id = v_loan.id) <= 0 THEN
                UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0 WHERE id = v_loan.id;
            END IF;
        ELSE
            v_late_fee := v_payment * 0.05;
            UPDATE loans SET remaining_balance = remaining_balance + v_late_fee,
                             missed_payments = missed_payments + 1 WHERE id = v_loan.id;

            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'aircraft_financing_late_fee', v_late_fee, 'Aircraft financing late fee', p_game_date);

            IF (SELECT missed_payments FROM loans WHERE id = v_loan.id) >= 3 THEN
                UPDATE loans SET status = 'repossessed' WHERE id = v_loan.id;
                IF v_loan.fleet_aircraft_id IS NOT NULL THEN
                    UPDATE fleet_aircraft SET status = 'grounded' WHERE id = v_loan.fleet_aircraft_id;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$function$;

-- ── 2j. take_loan (latest from migration 121) ─────────────────────────────

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
        FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'savings' LIMIT 1;
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
    FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'savings' LIMIT 1;

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_user_id, 'revenue', 'loan', p_principal, 'Loan disbursement', v_game_time);

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    RETURN QUERY SELECT true, 'Loan disbursed at ' || ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT, v_cash;
END;
$function$;

-- ── 2k. repay_loan (latest from migration 117, now SECURITY DEFINER) ──────

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
    SELECT ba.id, v_user_id, 'payment', -v_payment, ba.balance,
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
