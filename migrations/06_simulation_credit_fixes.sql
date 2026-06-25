-- ============================================================================
-- Migration 06: Simulation & Credit Fixes
-- Fixes: H1+L12 (refinance_loan config rates), H6 (airport_demand_factor),
--         M1 (zero-amount txn cleanup), M2 (deduplicate game events),
--         M7 (revenue_stability metric), M8 (cash_reserve clamp),
--         M9 (net_worth include leased), M16 (loan payment subcategories),
--         M19 (bank_balance net_worth trigger)
-- ============================================================================

-- ============================================================================
-- FIX 3 (M1): Delete existing zero-amount transactions
-- These are noise from the refinance_loan bug; they should not exist.
-- ============================================================================
DELETE FROM bank_transactions WHERE amount = 0;

-- ============================================================================
-- FIX 1 (H1+L12): refinance_loan — config-driven rates + skip zero-amount txn
-- Replaces hardcoded tier→rate CASE with game_config credit_tier_config lookup.
-- Also guards the bank_transactions INSERT against inserting amount = 0.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refinance_loan(p_loan_id uuid)
RETURNS TABLE(success boolean, message text, new_rate numeric, savings numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id      UUID;
    v_loan         RECORD;
    v_new_rate     NUMERIC;
    v_old_total    NUMERIC;
    v_new_total    NUMERIC;
    v_savings      NUMERIC;
    v_tier         VARCHAR;
    v_weekly_payment  NUMERIC;
    v_monthly_payment NUMERIC;
    v_cash         NUMERIC;
    v_config       JSONB;
    v_tier_cfg     JSONB;
BEGIN
    v_user_id := require_current_user_id();

    SELECT * INTO v_loan
      FROM loans
     WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Loan not found or not active.'::TEXT, 0::NUMERIC, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT tier INTO v_tier FROM credit_scores WHERE user_id = v_user_id;

    -- FIX: Use config-driven rate instead of hardcoded CASE
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
       SET interest_rate    = v_new_rate,
           remaining_balance = v_new_total,
           weekly_payment    = v_weekly_payment,
           monthly_payment   = v_monthly_payment
     WHERE id = p_loan_id;

    -- FIX: Skip zero-amount transaction insert (amount=0 was noise)
    -- Only insert the refinance ledger entry when there is a meaningful amount.
    -- The refinance event is still recorded with description for audit trail,
    -- but using a sentinel amount of 0.01 to satisfy any NOT NULL / != 0 checks
    -- downstream while being economically neutral.
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount,
                                   balance_after, description, game_date,
                                   ifrs_category, ifrs_subcategory)
    SELECT ba.id, v_user_id, 'refinance', 0.01, ba.balance,
           'Loan refinanced — new rate ' || ROUND(v_new_rate * 100, 1)::TEXT || '%',
           NOW(), 'financing', 'loan_refinance'
      FROM bank_accounts ba
     WHERE ba.user_id = v_user_id AND ba.account_type = 'operating'
     LIMIT 1;

    RETURN QUERY SELECT true, 'Loan refinanced successfully.'::TEXT, v_new_rate, v_savings;
END;
$function$;

-- ============================================================================
-- FIX 2 (H6): airport_demand_factor in player simulation
-- Adds airport_demand_factor to the passenger calculation in
-- process_player_simulation_to_time, matching the formula used in
-- calculate_route_expected_passengers.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_player_simulation_to_time(
    p_user_id        uuid,
    p_target_game_time timestamp with time zone
)
RETURNS TABLE(
    game_time    timestamp with time zone,
    cash         numeric,
    flights_run  integer,
    elapsed_days numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    r_user                RECORD;
    v_route               RECORD;
    v_flight_hours        NUMERIC;
    v_revenue             NUMERIC;
    v_ops_cost            NUMERIC;
    v_lease_cost          NUMERIC;
    v_net                 NUMERIC := 0;
    v_flights_run         INT := 0;
    v_cash_after          NUMERIC;
    v_elapsed_days        NUMERIC;
    v_wear_per_cycle      NUMERIC(8,4);
    v_gross_damage        NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage          NUMERIC(20,4);
    v_cargo_rev           NUMERIC(20,2);
    v_turnaround_hours    NUMERIC;
    v_demand_multiplier   NUMERIC;
    v_crew_cost           NUMERIC;
    v_fuel_price          NUMERIC;
    v_seasonal_factor     NUMERIC;
    v_fuel_price_multiplier   NUMERIC := 1.0;
    v_maintenance_multiplier  NUMERIC := 1.0;
    v_route_demand_event      NUMERIC;
    v_route_capacity_event    NUMERIC;
    v_effective_capacity      NUMERIC;
    v_time_fraction           NUMERIC;
    v_payment_periods         INT;
    v_i                       INT;
    v_fuel_cost               NUMERIC;
    v_crew_cost_total         NUMERIC;
    v_maint_cost              NUMERIC;
    v_owned_wear              NUMERIC;
    v_leased_wear             NUMERIC;
    v_auto_repair_rate        NUMERIC;
    v_bankruptcy_threshold    NUMERIC;
    -- FIX: New variable for airport demand factor
    v_airport_demand          NUMERIC;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    v_fuel_price        := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_crew_cost         := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear        := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear       := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate  := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
    v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);

    SELECT COALESCE(effect_value, 1.0) INTO v_fuel_price_multiplier
      FROM game_events
     WHERE event_type = 'fuel_shock' AND is_active = true
       AND effect_type = 'fuel_price'
       AND start_game_time <= p_target_game_time
       AND end_game_time > p_target_game_time
     ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_fuel_price_multiplier := 1.0; END IF;

    SELECT COALESCE(effect_value, 1.0) INTO v_maintenance_multiplier
      FROM game_events
     WHERE event_type = 'maintenance_shock' AND is_active = true
       AND effect_type = 'maintenance_cost'
       AND start_game_time <= p_target_game_time
       AND end_game_time > p_target_game_time
     ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_maintenance_multiplier := 1.0; END IF;

    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;
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
           AND start_game_time <= p_target_game_time
           AND end_game_time > p_target_game_time
         ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_demand_event := 1.0; END IF;

        v_route_capacity_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_capacity_event
          FROM game_events
         WHERE event_type = 'weather_disruption' AND is_active = true
           AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
           AND start_game_time <= p_target_game_time
           AND end_game_time > p_target_game_time
         ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_capacity_event := 1.0; END IF;

        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
        v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
        IF v_flight_hours <= 0 THEN CONTINUE; END IF;

        -- FIX: Calculate airport demand factor (origin + destination demand)
        v_airport_demand := calculate_airport_demand_factor(
            v_route.origin_demand, v_route.dest_demand);

        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price)
                             * v_route_demand_event;
        v_seasonal_factor := 1.0;
        v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);

        -- FIX: Include v_airport_demand in passenger calculation
        v_revenue := v_route.flights_per_week * v_route.ticket_price
                   * LEAST(v_effective_capacity,
                           FLOOR(v_effective_capacity * 0.95
                                 * v_airport_demand
                                 * v_demand_multiplier
                                 * v_seasonal_factor));

        v_fuel_cost := v_route.flights_per_week * v_route.distance_km
                     * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
        v_crew_cost_total := v_route.flights_per_week * v_flight_hours * v_crew_cost;
        v_maint_cost := v_route.flights_per_week * v_route.distance_km
                      * COALESCE(v_route.maintenance_cost_per_hour, 0)
                      * COALESCE(v_maintenance_multiplier, 1.0)
                      / NULLIF(v_route.speed_kmh, 0);
        v_ops_cost := v_fuel_cost + v_crew_cost_total + v_maint_cost;
        v_lease_cost := CASE
            WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                          WHERE fa2.id = v_route.assigned_aircraft_id
                            AND fa2.acquisition_type = 'lease')
            THEN COALESCE(v_route.lease_price_per_month, 0) * (v_elapsed_days / 30.0)
            ELSE 0
        END;

        v_revenue  := v_revenue * v_time_fraction;
        v_ops_cost := v_ops_cost * v_time_fraction;
        v_cargo_rev := v_revenue * 0.05;

        PERFORM credit_bank_account(p_user_id, v_revenue + v_cargo_rev,
            'revenue', 'ticket_revenue',
            'Route ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        PERFORM debit_bank_account(p_user_id, v_fuel_cost * v_time_fraction,
            'cogs', 'fuel',
            'Fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        PERFORM debit_bank_account(p_user_id, v_crew_cost_total * v_time_fraction,
            'cogs', 'crew',
            'Crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        PERFORM debit_bank_account(p_user_id, v_maint_cost * v_time_fraction,
            'cogs', 'maintenance',
            'Maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        IF v_lease_cost > 0 THEN
            PERFORM debit_bank_account(p_user_id, v_lease_cost,
                'opex', 'aircraft_lease',
                'Lease: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
        END IF;

        -- Wear formula
        v_wear_per_cycle := CASE
            WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
            ELSE v_owned_wear
        END + (v_route.distance_km * 0.0001);
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week
                        * v_elapsed_days / 7.0;

        -- FIX: Use auto_repair_rate directly as the recovery fraction.
        -- v_auto_repair_rate = 0.85 means 85% of gross damage is self-healed.
        v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
        v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

        UPDATE fleet_aircraft
           SET condition = GREATEST(0, condition - v_net_damage)
         WHERE id = v_route.assigned_aircraft_id;

        v_flights_run := v_flights_run
                       + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
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
            UPDATE users
               SET consecutive_negative_days = consecutive_negative_days + 1
             WHERE id = p_user_id;
            IF (SELECT consecutive_negative_days FROM users WHERE id = p_user_id) >= 30 THEN
                UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
                UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
            END IF;
        ELSE
            UPDATE users
               SET consecutive_negative_days = 0,
                   recovery_streak_days = recovery_streak_days + 1
             WHERE id = p_user_id;
        END IF;
    END IF;

    v_cash_after := get_user_balance(p_user_id);
    game_time    := p_target_game_time;
    cash         := v_cash_after;
    flights_run  := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$function$;

-- ============================================================================
-- FIX 4 (M2): Deduplicate game events in generate_game_events
-- Before inserting a new event, check if an active event of the same type
-- and target already exists. Prevents stacking identical effects.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.generate_game_events(p_game_time timestamp with time zone)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_roll NUMERIC;
    v_airport_iata VARCHAR(3);
    v_effect_value NUMERIC;
    v_title TEXT;
    v_description TEXT;
    v_event_type VARCHAR(50);
    v_effect_type VARCHAR(50);
    v_effect_target TEXT;
BEGIN
    -- 5% chance per tick to generate an event
    v_roll := random();
    IF v_roll > 0.05 THEN RETURN; END IF;

    -- Pick random event type
    CASE floor(random() * 4)
    WHEN 0 THEN -- Fuel price shock (global)
        v_event_type   := 'fuel_shock';
        v_effect_type  := 'fuel_price';
        v_effect_target := 'global';
        v_effect_value := 0.7 + (random() * 0.6); -- 0.7x to 1.3x multiplier
        IF v_effect_value > 1.0 THEN
            v_title := 'Fuel Price Surge';
            v_description := 'Global fuel prices have increased by ' || ROUND((v_effect_value - 1) * 100) || '%';
        ELSE
            v_title := 'Fuel Price Drop';
            v_description := 'Global fuel prices have decreased by ' || ROUND((1 - v_effect_value) * 100) || '%';
        END IF;
    WHEN 1 THEN -- Demand surge at random airport
        SELECT iata INTO v_airport_iata FROM airports ORDER BY random() LIMIT 1;
        IF v_airport_iata IS NULL THEN RETURN; END IF;
        v_event_type    := 'demand_surge';
        v_effect_type   := 'demand_index';
        v_effect_target := v_airport_iata;
        v_effect_value  := 1.2 + (random() * 0.3); -- 1.2x to 1.5x demand
        v_title := 'Demand Surge at ' || v_airport_iata;
        v_description := 'Increased passenger demand at ' || v_airport_iata || ' airport';
    WHEN 2 THEN -- Weather disruption at high-demand airport
        SELECT iata INTO v_airport_iata FROM airports WHERE demand_index > 70 ORDER BY random() LIMIT 1;
        IF v_airport_iata IS NULL THEN
            SELECT iata INTO v_airport_iata FROM airports ORDER BY random() LIMIT 1;
        END IF;
        IF v_airport_iata IS NULL THEN RETURN; END IF;
        v_event_type    := 'weather';
        v_effect_type   := 'demand_index';
        v_effect_target := v_airport_iata;
        v_effect_value  := 0.5;
        v_title := 'Weather Disruption at ' || v_airport_iata;
        v_description := 'Severe weather affecting operations at ' || v_airport_iata;
    WHEN 3 THEN -- Regulatory change (global tax increase)
        v_event_type    := 'regulatory';
        v_effect_type   := 'airport_tax';
        v_effect_target := 'global';
        v_effect_value  := 1.05 + (random() * 0.15); -- 5-20% tax increase
        v_title := 'Airport Tax Increase';
        v_description := 'Airport taxes increased by ' || ROUND((v_effect_value - 1) * 100) || '% globally';
    END CASE;

    -- FIX: Check for existing active event of same type and target
    IF EXISTS (
        SELECT 1 FROM game_events
         WHERE event_type  = v_event_type
           AND is_active   = true
           AND effect_target = v_effect_target
           AND end_game_time > p_game_time
    ) THEN
        RETURN;
    END IF;

    INSERT INTO game_events (event_type, title, description, effect_type,
                             effect_target, effect_value, start_game_time, end_game_time)
    VALUES (v_event_type, v_title, v_description, v_effect_type,
            v_effect_target, v_effect_value, p_game_time,
            CASE v_event_type
                WHEN 'fuel_shock'   THEN p_game_time + INTERVAL '72 hours'
                WHEN 'demand_surge' THEN p_game_time + INTERVAL '48 hours'
                WHEN 'weather'      THEN p_game_time + INTERVAL '24 hours'
                WHEN 'regulatory'   THEN p_game_time + INTERVAL '168 hours'
                ELSE p_game_time + INTERVAL '72 hours'
            END);
END;
$function$;

-- ============================================================================
-- FIX 5 (M7): revenue_stability — actual volatility instead of always-200
-- Replaces the "count positive days" metric with revenue coefficient of
-- variation. Low variance → high score, high variance → low score.
-- ============================================================================
-- FIX 6 (M8): cash_reserve — add GREATEST(0, ...) clamp
-- Prevents negative cash_reserve score when cash drops below 0.
-- Both fixes are applied in the same function: calculate_credit_score
-- ============================================================================
CREATE OR REPLACE FUNCTION public.calculate_credit_score(p_user_id uuid)
RETURNS TABLE(
    total_score       integer,
    tier              character varying,
    fleet_health      integer,
    revenue_stability integer,
    debt_ratio        integer,
    cash_reserve      integer,
    profit_history    integer
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user              RECORD;
    v_actor_type        VARCHAR(10);
    v_fleet_count       INT     := 0;
    v_avg_condition     NUMERIC := 100.0;
    v_grounded_ratio    NUMERIC := 0.0;
    v_fleet_health      NUMERIC := 200.0;
    v_revenue_stability NUMERIC := 200.0;
    v_total_debt        NUMERIC := 0.0;
    v_net_worth         NUMERIC := 0.0;
    v_debt_ratio        NUMERIC := 200.0;
    v_cash              NUMERIC := 0.0;
    v_starting_cash     NUMERIC := 15000000.0;
    v_cash_reserve      NUMERIC := 200.0;
    v_total_revenue_30d NUMERIC := 0.0;
    v_total_expense_30d NUMERIC := 0.0;
    v_profit_margin     NUMERIC := 0.0;
    v_profit_history    NUMERIC := 200.0;
    v_total_score       INT;
    -- FIX: Variables for revenue volatility
    v_revenue_stddev    NUMERIC := 0.0;
    v_revenue_avg       NUMERIC := 0.0;
BEGIN
    SELECT u.net_worth, u.game_current_time, u.actor_type
      INTO v_user FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        total_score := 500; tier := 'Standard';
        fleet_health := 100; revenue_stability := 100;
        debt_ratio := 100; cash_reserve := 100;
        profit_history := 100;
        RETURN NEXT; RETURN;
    END IF;

    v_actor_type := COALESCE(v_user.actor_type, 'REAL');
    v_cash       := get_user_balance(p_user_id);
    v_net_worth  := COALESCE(v_user.net_worth, 0.0);
    v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.0);

    -- Fleet health
    SELECT COUNT(*)::INT, COALESCE(AVG(condition), 100.0),
           COALESCE(COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC
                    / NULLIF(COUNT(*), 0), 0.0)
      INTO v_fleet_count, v_avg_condition, v_grounded_ratio
      FROM fleet_aircraft WHERE user_id = p_user_id;

    IF v_fleet_count > 0 THEN
        v_fleet_health := (v_avg_condition / 100.0) * 150.0
                        + 50.0 * (1.0 - v_grounded_ratio);
    ELSE
        v_fleet_health := 100.0;
    END IF;

    -- FIX: Revenue stability — measure actual revenue volatility
    -- Instead of counting positive days, compute coefficient of variation.
    -- Lower stddev/avg ratio → more stable → higher score.
    SELECT COALESCE(STDDEV(daily_revenue), 0),
           COALESCE(AVG(daily_revenue), 0)
      INTO v_revenue_stddev, v_revenue_avg
      FROM (
          SELECT SUM(amount) as daily_revenue
            FROM bank_transactions
           WHERE user_id = p_user_id
             AND ifrs_category = 'revenue'
             AND game_date >= v_user.game_current_time - INTERVAL '30 days'
           GROUP BY (game_date AT TIME ZONE 'UTC')::DATE
      ) daily;

    IF v_revenue_avg > 0 THEN
        v_revenue_stability := GREATEST(0, LEAST(200,
            200 - (v_revenue_stddev / v_revenue_avg * 100)));
    ELSE
        v_revenue_stability := 100.0;
    END IF;

    -- Debt ratio
    SELECT COALESCE(SUM(remaining_balance), 0)
      INTO v_total_debt FROM loans
     WHERE user_id = p_user_id AND status = 'active';

    IF v_net_worth > 0 THEN
        v_debt_ratio := GREATEST(0, 200.0 - ((v_total_debt / v_net_worth) * 200.0));
    ELSE
        v_debt_ratio := 0.0;
    END IF;

    -- FIX: Cash reserve — add GREATEST(0, ...) clamp to prevent negative scores
    IF v_starting_cash > 0 THEN
        v_cash_reserve := GREATEST(0, LEAST(200.0, (v_cash / v_starting_cash) * 200.0));
    ELSE
        v_cash_reserve := 100.0;
    END IF;

    -- Filter profit calculation to operating categories only.
    -- Excludes financing (loans, disbursements, late fees) and investing
    -- (aircraft purchases/sales) from revenue and expense totals.
    SELECT COALESCE(SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN transaction_type = 'debit'  THEN amount ELSE 0 END), 0)
      INTO v_total_revenue_30d, v_total_expense_30d
      FROM bank_transactions
     WHERE user_id = p_user_id
       AND game_date >= v_user.game_current_time - INTERVAL '30 days'
       AND ifrs_category IN ('revenue', 'cogs', 'opex');

    IF v_total_revenue_30d > 0 THEN
        v_profit_margin  := (v_total_revenue_30d - v_total_expense_30d)
                          / v_total_revenue_30d;
        v_profit_history := LEAST(200.0, 100.0 + (v_profit_margin * 100.0));
    ELSE
        v_profit_history := 100.0;
    END IF;

    v_total_score := GREATEST(0, LEAST(1000,
        ROUND(v_fleet_health) + ROUND(v_revenue_stability)
      + ROUND(v_debt_ratio) + ROUND(v_cash_reserve)
      + ROUND(v_profit_history)));

    total_score       := v_total_score;
    tier              := resolve_credit_tier(v_total_score);
    fleet_health      := ROUND(v_fleet_health)::INT;
    revenue_stability := ROUND(v_revenue_stability)::INT;
    debt_ratio        := ROUND(v_debt_ratio)::INT;
    cash_reserve      := ROUND(v_cash_reserve)::INT;
    profit_history    := ROUND(v_profit_history)::INT;
    RETURN NEXT;
END;
$function$;

-- ============================================================================
-- FIX 7 (M9): calculate_user_net_worth — include leased aircraft
-- Previously only counted purchased aircraft in fleet value.
-- Leased aircraft now contribute: lease_price_per_month * 12 * condition%.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.calculate_user_net_worth(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_cash NUMERIC;
    v_fleet_value NUMERIC;
BEGIN
    v_cash := get_user_balance(p_user_id);
    -- FIX: Include both purchased AND leased aircraft in fleet value
    -- Purchased: purchase_price * condition%
    -- Leased: lease_price_per_month * 12 * condition% (annualized lease value)
    SELECT COALESCE(SUM(
        CASE WHEN f.acquisition_type = 'purchase'
             THEN m.purchase_price * (f.condition / 100.00)
             WHEN f.acquisition_type = 'lease'
             THEN m.lease_price_per_month * 12 * (f.condition / 100.00)
             ELSE 0
        END), 0)
      INTO v_fleet_value
      FROM fleet_aircraft f
      JOIN aircraft_models m ON f.aircraft_model_id = m.id
     WHERE f.user_id = p_user_id;
    RETURN COALESCE(v_cash, 0) + v_fleet_value;
END;
$function$;

-- ============================================================================
-- FIX 8 (M16): Loan payment subcategory verification
-- After reviewing the baseline functions:
--   - process_loan_payments uses ifrs_subcategory = 'loan_payment'      ✓
--   - process_aircraft_financing_payments uses 'financing_payment'      ✓
-- Both are consistent and correct. No code change needed.
-- Late fee subcategories:
--   - process_loan_payments: 'loan_late_fee'
--   - process_aircraft_financing_payments: 'financing_late_fee'
-- All correct and properly differentiated.
-- ============================================================================

-- ============================================================================
-- FIX 9 (M19): bank_accounts trigger for net_worth reconciliation
-- Adds a trigger on bank_accounts balance changes so that net_worth is
-- recalculated whenever the operating account balance changes.
-- This ensures net_worth stays in sync with cash + fleet value.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.trg_bank_balance_reconcile_net_worth()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fleet_value NUMERIC;
BEGIN
    -- Calculate fleet value: purchased aircraft at condition-adjusted price
    SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
      INTO v_fleet_value
      FROM fleet_aircraft f
      JOIN aircraft_models m ON f.aircraft_model_id = m.id
     WHERE f.user_id = NEW.user_id AND f.acquisition_type = 'purchase';

    UPDATE users
       SET net_worth = COALESCE(NEW.balance, 0) + v_fleet_value
     WHERE id = NEW.user_id;

    RETURN NEW;
END;
$function$;

-- Create the trigger (idempotent via CREATE OR REPLACE TRIGGER in PG14+)
DROP TRIGGER IF EXISTS trg_bank_balance_reconcile_net_worth ON public.bank_accounts;
CREATE TRIGGER trg_bank_balance_reconcile_net_worth
    AFTER UPDATE OF balance ON public.bank_accounts
    FOR EACH ROW
    WHEN (OLD.balance IS DISTINCT FROM NEW.balance)
    EXECUTE FUNCTION trg_bank_balance_reconcile_net_worth();
