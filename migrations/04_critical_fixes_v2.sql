-- ============================================================================
-- Migration 04: Critical Fixes V2
-- ============================================================================
-- Fixes: world tick zero-amount txns, bot 168x inflation, loan tiering,
--        bankrupt route cleanup, credit tier recalculation
-- ============================================================================

-- ============================================================================
-- FIX 1: process_player_simulation_to_time
-- - Add early return when no time elapsed (prevents zero-amount txns)
-- - Add route cleanup on bankruptcy
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_player_simulation_to_time(p_user_id uuid, p_target_game_time timestamp with time zone)
RETURNS TABLE(game_time timestamp with time zone, cash numeric, flights_run integer, elapsed_days numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
v_owned_wear NUMERIC;
v_leased_wear NUMERIC;
v_auto_repair_rate NUMERIC;
v_bankruptcy_threshold NUMERIC;
BEGIN
SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RAISE EXCEPTION 'User not found: %', p_user_id; END IF;

-- FIX: Early return when no time has elapsed (prevents zero-amount transactions)
v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;
IF v_elapsed_days <= 0 THEN
    game_time := r_user.game_current_time;
    cash := get_user_balance(p_user_id);
    flights_run := 0;
    elapsed_days := 0;
    RETURN NEXT;
    RETURN;
END IF;

v_fuel_price := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
v_crew_cost := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
v_owned_wear := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
v_leased_wear := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
v_auto_repair_rate := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);

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

v_time_fraction := LEAST(v_elapsed_days / 7.0, 1.0);
FOR v_route IN
SELECT ur.*, am.fuel_burn_per_km, am.speed_kmh, am.turnaround_hours,
am.capacity, am.lease_price_per_month, am.maintenance_cost_per_hour,
fa.acquisition_type,
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

    -- Only create transactions when amounts are non-zero
    IF v_revenue + v_cargo_rev > 0 THEN
        PERFORM credit_bank_account(p_user_id, v_revenue + v_cargo_rev, 'revenue', 'ticket_revenue',
        'Route ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
    END IF;
    IF v_fuel_cost * v_time_fraction > 0 THEN
        PERFORM debit_bank_account(p_user_id, v_fuel_cost * v_time_fraction, 'cogs', 'fuel',
        'Fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
    END IF;
    IF v_crew_cost_total * v_time_fraction > 0 THEN
        PERFORM debit_bank_account(p_user_id, v_crew_cost_total * v_time_fraction, 'cogs', 'crew',
        'Crew: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
    END IF;
    IF v_maint_cost * v_time_fraction > 0 THEN
        PERFORM debit_bank_account(p_user_id, v_maint_cost * v_time_fraction, 'cogs', 'maintenance',
        'Maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
    END IF;
    IF v_lease_cost * v_time_fraction > 0 THEN
        PERFORM debit_bank_account(p_user_id, v_lease_cost * v_time_fraction, 'opex', 'aircraft_lease',
        'Lease: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
    END IF;

    v_wear_per_cycle := CASE
    WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
    ELSE v_owned_wear
    END + (v_route.distance_km * 0.0001);
    v_gross_damage := v_wear_per_cycle * v_route.flights_per_week * v_elapsed_days / 7.0;
    v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
    v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);
    UPDATE fleet_aircraft
    SET condition = GREATEST(0, condition - v_net_damage)
    WHERE id = v_route.assigned_aircraft_id;
    v_flights_run := v_flights_run + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
END LOOP;

v_cash_after := get_user_balance(p_user_id);
UPDATE users u
SET game_current_time = p_target_game_time,
last_active_at = NOW()
WHERE u.id = p_user_id;

-- Bankruptcy check
IF v_cash_after < v_bankruptcy_threshold THEN
    UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
    UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
    UPDATE route_assignments SET status = 'cancelled' WHERE user_id = p_user_id AND status = 'active';
END IF;

IF v_elapsed_days >= 1.0 THEN
    v_payment_periods := GREATEST(1, FLOOR(v_elapsed_days / 7.0)::INT);
    FOR v_i IN 1..v_payment_periods LOOP
        PERFORM process_loan_payments(p_user_id, p_target_game_time);
        PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time);
    END LOOP;
    PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time);
    PERFORM check_achievements(p_user_id, p_target_game_time);
    v_cash_after := get_user_balance(p_user_id);
    IF v_cash_after < 0 THEN
        UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1
        WHERE id = p_user_id;
        IF (SELECT consecutive_negative_days FROM users WHERE id = p_user_id) >= 30 THEN
            UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
            UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
            UPDATE route_assignments SET status = 'cancelled' WHERE user_id = p_user_id AND status = 'active';
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

-- ============================================================================
-- FIX 2: process_all_bots_simulation_to_time
-- - Add time_fraction scaling (fixes 168x inflation)
-- - Add early return guard
-- - Add route cleanup on bankruptcy
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_all_bots_simulation_to_time(p_target_game_time timestamp with time zone, p_season_id uuid DEFAULT NULL::uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
v_owned_wear NUMERIC;
v_leased_wear NUMERIC;
v_auto_repair_rate NUMERIC;
v_time_fraction NUMERIC;
BEGIN
v_fuel_price := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
v_absolute_minimum_safety_limit := COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00);
v_crew_cost_per_hour := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
v_owned_wear := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
v_leased_wear := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
v_auto_repair_rate := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
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

    -- FIX: Add time_fraction to scale revenue/costs correctly
    v_time_fraction := LEAST(v_game_days / 7.0, 1.0);

    FOR v_route IN
    SELECT ra.*, am.fuel_burn_per_km, am.speed_kmh, am.capacity,
    am.turnaround_hours, am.maintenance_cost_per_hour,
    am.lease_price_per_month, fa.acquisition_type,
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

        -- FIX: Apply time_fraction to all amounts
        IF (v_revenue + v_cargo_rev) * v_time_fraction > 0 THEN
            PERFORM credit_bank_account(r_bot.id, (v_revenue + v_cargo_rev) * v_time_fraction, 'revenue', 'ticket_revenue',
            'Bot route ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
        END IF;
        IF v_fuel_cost * v_time_fraction > 0 THEN
            PERFORM debit_bank_account(r_bot.id, v_fuel_cost * v_time_fraction, 'cogs', 'fuel',
            'Bot fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
        END IF;
        IF v_crew_cost * v_time_fraction > 0 THEN
            PERFORM debit_bank_account(r_bot.id, v_crew_cost * v_time_fraction, 'cogs', 'crew',
            'Bot crew: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
        END IF;
        IF v_maint_cost * v_time_fraction > 0 THEN
            PERFORM debit_bank_account(r_bot.id, v_maint_cost * v_time_fraction, 'cogs', 'maintenance',
            'Bot maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
        END IF;
        IF v_lease_cost * v_time_fraction > 0 THEN
            PERFORM debit_bank_account(r_bot.id, v_lease_cost * v_time_fraction, 'opex', 'aircraft_lease',
            'Bot lease: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
        END IF;

        v_wear_per_cycle := CASE
        WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
        ELSE v_owned_wear
        END + (v_route.distance_km * 0.0001);
        v_gross_damage := v_wear_per_cycle * v_flights * v_game_days / 7.0;
        v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
        v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);
        UPDATE fleet_aircraft
        SET condition = GREATEST(0, condition - v_net_damage)
        WHERE id = v_route.assigned_aircraft_id;
    END LOOP;

    IF date_trunc('day', r_bot.game_current_time)::DATE <>
    date_trunc('day', p_target_game_time)::DATE THEN
        PERFORM check_achievements(r_bot.id, p_target_game_time);
    END IF;
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
            UPDATE route_assignments SET status = 'cancelled' WHERE user_id = r_bot.id AND status = 'active';
        END IF;
    END IF;
    v_processed := v_processed + 1;
END LOOP;
RETURN v_processed;
END;
$function$;

-- ============================================================================
-- FIX 3: take_loan — Read config from correct path
-- ============================================================================
CREATE OR REPLACE FUNCTION public.take_loan(p_user_id uuid, p_principal numeric, p_term_weeks integer DEFAULT 52, p_loan_type character varying DEFAULT 'unsecured'::character varying, p_collateral_aircraft_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type)
    VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', 'unsecured')
    RETURNING id INTO v_loan_id;
    PERFORM credit_bank_account(p_user_id, p_principal, 'financing', 'loan_disbursement',
    'Loan disbursement', v_game_time);
    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Loan disbursed.'::TEXT, v_cash;
    RETURN;
END IF;
SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';
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
-- FIX: Read tier config from correct path (root level, not nested 'tiers')
v_tier_cfg := COALESCE(v_config->v_tier, '{}'::JSONB);
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
INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id)
VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', p_loan_type, p_collateral_aircraft_id)
RETURNING id INTO v_loan_id;
PERFORM credit_bank_account(p_user_id, p_principal, 'financing', 'loan_disbursement',
'Loan disbursement', v_game_time);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT true, 'Loan disbursed at ' || ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT, v_cash;
END;
$function$;

-- ============================================================================
-- FIX 4: get_credit_report — Always recalculate tier
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_credit_report()
RETURNS TABLE(current_score integer, fleet_health integer, revenue_stability integer, debt_ratio integer, cash_reserve integer, profit_history integer, credit_tier character varying, max_unsecured_loan numeric, max_secured_loan numeric, max_financing_amount numeric, base_interest_rate numeric, suggestions text[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_user_id UUID; v_score RECORD; v_tier VARCHAR(20); v_config JSONB; v_tier_cfg JSONB; v_sugg TEXT[] := '{}';
BEGIN
v_user_id := require_current_user_id();
SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';
SELECT * INTO v_score FROM calculate_credit_score(v_user_id) LIMIT 1;
IF NOT FOUND THEN current_score := 500; fleet_health := 100; revenue_stability := 100; debt_ratio := 100; cash_reserve := 100; profit_history := 100; credit_tier := 'Standard'; max_unsecured_loan := 5000000; max_secured_loan := 25000000; max_financing_amount := 20000000; base_interest_rate := 0.07; suggestions := ARRAY['Build your fleet and routes to establish credit history.']; RETURN NEXT; RETURN; END IF;
-- FIX: Always recalculate tier using resolve_credit_tier
v_tier := resolve_credit_tier(v_score.total_score);
INSERT INTO credit_scores (user_id, score, tier, fleet_health_score, revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score, computed_at) VALUES (v_user_id, v_score.total_score, v_tier, v_score.fleet_health, v_score.revenue_stability, v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history, NOW()) ON CONFLICT (user_id) DO UPDATE SET score = EXCLUDED.score, tier = EXCLUDED.tier, fleet_health_score = EXCLUDED.fleet_health_score, revenue_stability_score = EXCLUDED.revenue_stability_score, debt_ratio_score = EXCLUDED.debt_ratio_score, cash_reserves_score = EXCLUDED.cash_reserves_score, profit_history_score = EXCLUDED.profit_history_score, computed_at = EXCLUDED.computed_at;
-- FIX: Read tier config from correct path (root level)
v_tier_cfg := COALESCE(v_config->v_tier, '{}'::JSONB);
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

-- ============================================================================
-- FIX 5: update_credit_score — Use resolve_credit_tier instead of hardcoded
-- ============================================================================
CREATE OR REPLACE FUNCTION public.update_credit_score(p_user_id uuid, p_game_date timestamp with time zone)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_score RECORD; v_tier VARCHAR(10);
BEGIN
SELECT * INTO v_score FROM calculate_credit_score(p_user_id) LIMIT 1;
IF NOT FOUND THEN RETURN; END IF;
-- FIX: Use resolve_credit_tier instead of hardcoded CASE
v_tier := resolve_credit_tier(v_score.total_score);
INSERT INTO credit_scores (user_id, score, tier, fleet_health_score, revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score, computed_at)
VALUES (p_user_id, v_score.total_score, v_tier, v_score.fleet_health, v_score.revenue_stability, v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history, NOW())
ON CONFLICT (user_id) DO UPDATE SET score = EXCLUDED.score, tier = EXCLUDED.tier, fleet_health_score = EXCLUDED.fleet_health_score, revenue_stability_score = EXCLUDED.revenue_stability_score, debt_ratio_score = EXCLUDED.debt_ratio_score, cash_reserves_score = EXCLUDED.cash_reserves_score, profit_history_score = EXCLUDED.profit_history_score, computed_at = EXCLUDED.computed_at;
END;
$function$;

-- ============================================================================
-- FIX 6: Update credit_tier_config with missing keys
-- ============================================================================
UPDATE game_config SET value = '{
  "Platinum": {"min": 800, "max": 1000, "rate": 0.03, "max_unsecured": 10000000, "max_secured": 50000000, "rate_unsecured": 0.03, "rate_secured": 0.02},
  "Gold": {"min": 650, "max": 799, "rate": 0.05, "max_unsecured": 8000000, "max_secured": 40000000, "rate_unsecured": 0.05, "rate_secured": 0.04},
  "Silver": {"min": 500, "max": 649, "rate": 0.08, "max_unsecured": 6000000, "max_secured": 30000000, "rate_unsecured": 0.08, "rate_secured": 0.06},
  "Standard": {"min": 0, "max": 499, "rate": 0.12, "max_unsecured": 5000000, "max_secured": 25000000, "rate_unsecured": 0.12, "rate_secured": 0.10}
}'::jsonb WHERE key = 'credit_tier_config';

-- ============================================================================
-- FIX 7: Recalculate stale credit tiers
-- ============================================================================
UPDATE credit_scores cs
SET tier = resolve_credit_tier(cs.score)
WHERE cs.tier != resolve_credit_tier(cs.score);
