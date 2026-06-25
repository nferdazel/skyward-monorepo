-- ============================================================================
-- Migration 15: Acquisition progression rebalance
-- Goal:
--   restore a coherent growth ladder across lease, financing, and credit.
-- ============================================================================

-- ============================================================================
-- FIX 1: rebalance credit-tier policy against the live aircraft catalog
-- ============================================================================
UPDATE game_config
SET value = jsonb_build_object(
    'Standard', jsonb_build_object(
        'min', 0,
        'max', 519,
        'max_unsecured', 5000000,
        'max_secured', 25000000,
        'rate', 0.12,
        'rate_unsecured', 0.12,
        'rate_secured', 0.10
    ),
    'Silver', jsonb_build_object(
        'min', 520,
        'max', 659,
        'max_unsecured', 7000000,
        'max_secured', 45000000,
        'rate', 0.08,
        'rate_unsecured', 0.08,
        'rate_secured', 0.06
    ),
    'Gold', jsonb_build_object(
        'min', 660,
        'max', 819,
        'max_unsecured', 10000000,
        'max_secured', 75000000,
        'rate', 0.05,
        'rate_unsecured', 0.05,
        'rate_secured', 0.04
    ),
    'Platinum', jsonb_build_object(
        'min', 820,
        'max', 1000,
        'max_unsecured', 15000000,
        'max_secured', 120000000,
        'rate', 0.03,
        'rate_unsecured', 0.03,
        'rate_secured', 0.02
    ),
    'min_loan', 100000,
    'max_active_loans', 3
)
WHERE key = 'credit_tier_config';

-- ============================================================================
-- FIX 2: canonical lease-deposit helper
-- Lease should remain flexible, but premium aircraft must require meaningful
-- upfront cash. Deposit now scales with asset value, not just monthly rent.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.calculate_required_lease_deposit(
    p_purchase_price numeric,
    p_lease_price_per_month numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
    v_base_pct NUMERIC := COALESCE(get_config_numeric('base_lease_deposit_percentage'), 0.10);
    v_monthly_floor NUMERIC;
    v_asset_pct NUMERIC;
BEGIN
    v_monthly_floor := COALESCE(p_lease_price_per_month, 0) * GREATEST(2.0, v_base_pct * 20.0);

    v_asset_pct := CASE
        WHEN COALESCE(p_purchase_price, 0) < 25000000 THEN 0.02
        WHEN COALESCE(p_purchase_price, 0) < 60000000 THEN 0.03
        WHEN COALESCE(p_purchase_price, 0) < 120000000 THEN 0.05
        ELSE 0.08
    END;

    RETURN ROUND(
        GREATEST(
            v_monthly_floor,
            COALESCE(p_purchase_price, 0) * v_asset_pct
        ),
        2
    );
END;
$function$;

-- ============================================================================
-- FIX 3: lease_aircraft — use value-sensitive deposit gating
-- ============================================================================
CREATE OR REPLACE FUNCTION public.lease_aircraft(
    p_user_id uuid,
    p_model_id uuid,
    p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_cash NUMERIC; v_lease_price NUMERIC; v_model_name VARCHAR; v_capacity INT;
v_purchase_price NUMERIC;
v_hq_iata VARCHAR(3); v_tail VARCHAR(20); v_lease_deposit NUMERIC;
v_economy INT; v_business INT; v_first INT; v_slots_used INT; v_game_time TIMESTAMPTZ;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
v_cash := get_user_balance(p_user_id);
SELECT hq_airport_iata, game_current_time INTO v_hq_iata, v_game_time
FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC; RETURN; END IF;
SELECT lease_price_per_month, purchase_price, model_name, capacity
INTO v_lease_price, v_purchase_price, v_model_name, v_capacity
FROM aircraft_models WHERE id = p_model_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash; RETURN; END IF;
v_lease_deposit := calculate_required_lease_deposit(v_purchase_price, v_lease_price);
v_economy := COALESCE(p_economy_seats, v_capacity);
v_business := COALESCE(p_business_seats, 0);
v_first := COALESCE(p_first_class_seats, 0);
v_slots_used := v_economy + (v_business * 2) + (v_first * 3);
IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash; RETURN;
END IF;
IF v_cash < v_lease_deposit THEN
RETURN QUERY SELECT FALSE, ('Insufficient funds for lease deposit of ' || v_model_name || '. Required: $' || ROUND(v_lease_deposit, 2))::VARCHAR, v_cash; RETURN;
END IF;
LOOP v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
EXIT WHEN NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_tail);
END LOOP;
PERFORM debit_bank_account(p_user_id, v_lease_deposit, 'investing', 'aircraft_lease_deposit',
'Leased aircraft ' || v_model_name || ' deposit [' || v_tail || ']', v_game_time);
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, ('Successfully leased ' || v_model_name || ' [' || v_tail || ']')::VARCHAR, v_cash;
END;
$function$;

-- ============================================================================
-- FIX 4: calculate_credit_score — lower the starting baseline and reward
-- operating history more than untouched starting cash.
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
    v_fleet_count       INT     := 0;
    v_avg_condition     NUMERIC := 100.0;
    v_grounded_ratio    NUMERIC := 0.0;
    v_fleet_health      NUMERIC := 140.0;
    v_revenue_stability NUMERIC := 140.0;
    v_total_debt        NUMERIC := 0.0;
    v_net_worth         NUMERIC := 0.0;
    v_debt_ratio        NUMERIC := 140.0;
    v_cash              NUMERIC := 0.0;
    v_starting_cash     NUMERIC := 15000000.0;
    v_cash_reserve      NUMERIC := 140.0;
    v_total_revenue_30d NUMERIC := 0.0;
    v_total_expense_30d NUMERIC := 0.0;
    v_profit_margin     NUMERIC := 0.0;
    v_profit_history    NUMERIC := 140.0;
    v_total_score       INT;
    v_revenue_stddev    NUMERIC := 0.0;
    v_revenue_avg       NUMERIC := 0.0;
BEGIN
    SELECT u.net_worth, u.game_current_time
      INTO v_user FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        total_score := 500; tier := 'Standard';
        fleet_health := 100; revenue_stability := 100;
        debt_ratio := 100; cash_reserve := 100;
        profit_history := 100;
        RETURN NEXT; RETURN;
    END IF;

    v_cash := get_user_balance(p_user_id);
    v_net_worth := COALESCE(v_user.net_worth, 0.0);
    v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.0);

    SELECT COUNT(*)::INT, COALESCE(AVG(condition), 100.0),
           COALESCE(COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC / NULLIF(COUNT(*), 0), 0.0)
      INTO v_fleet_count, v_avg_condition, v_grounded_ratio
      FROM fleet_aircraft
     WHERE user_id = p_user_id;

    IF v_fleet_count > 0 THEN
        v_fleet_health := LEAST(
            200.0,
            (v_avg_condition / 100.0) * 130.0
            + 50.0 * (1.0 - v_grounded_ratio)
            + LEAST(20.0, v_fleet_count * 2.0)
        );
    ELSE
        v_fleet_health := 70.0;
    END IF;

    SELECT COALESCE(STDDEV(daily_revenue), 0),
           COALESCE(AVG(daily_revenue), 0)
      INTO v_revenue_stddev, v_revenue_avg
      FROM (
          SELECT SUM(amount) AS daily_revenue
          FROM bank_transactions
          WHERE user_id = p_user_id
            AND ifrs_category = 'revenue'
            AND game_date >= v_user.game_current_time - INTERVAL '30 days'
          GROUP BY (game_date AT TIME ZONE 'UTC')::DATE
      ) daily;

    SELECT COALESCE(SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END), 0),
           ABS(COALESCE(SUM(CASE WHEN transaction_type = 'debit' THEN amount ELSE 0 END), 0))
      INTO v_total_revenue_30d, v_total_expense_30d
      FROM bank_transactions
     WHERE user_id = p_user_id
       AND game_date >= v_user.game_current_time - INTERVAL '30 days'
       AND ifrs_category IN ('revenue', 'cogs', 'opex');

    IF v_revenue_avg > 0 THEN
        v_revenue_stability := GREATEST(
            0,
            LEAST(200.0, 170.0 - (v_revenue_stddev / v_revenue_avg * 100.0))
        );
    ELSE
        v_revenue_stability := 60.0;
    END IF;

    SELECT COALESCE(SUM(remaining_balance), 0)
      INTO v_total_debt
      FROM loans
     WHERE user_id = p_user_id
       AND status = 'active';

    IF v_total_debt <= 0 THEN
        IF v_total_revenue_30d > 0 OR v_fleet_count > 0 THEN
            v_debt_ratio := 180.0;
        ELSE
            v_debt_ratio := 130.0;
        END IF;
    ELSIF v_net_worth > 0 THEN
        v_debt_ratio := GREATEST(0, 180.0 - ((v_total_debt / v_net_worth) * 180.0));
    ELSE
        v_debt_ratio := 0.0;
    END IF;

    IF v_starting_cash > 0 THEN
        v_cash_reserve := GREATEST(
            0,
            LEAST(180.0, 60.0 + ((v_cash / v_starting_cash) * 60.0))
        );
    ELSE
        v_cash_reserve := 80.0;
    END IF;
    IF v_total_revenue_30d <= 0 THEN
        v_cash_reserve := LEAST(v_cash_reserve, 130.0);
    END IF;

    IF v_total_revenue_30d > 0 THEN
        v_profit_margin := (v_total_revenue_30d - v_total_expense_30d)
                         / NULLIF(v_total_revenue_30d, 0);
        v_profit_history := LEAST(200.0, GREATEST(20.0, 90.0 + (v_profit_margin * 140.0)));
    ELSE
        v_profit_history := 60.0;
    END IF;

    v_total_score := GREATEST(0, LEAST(1000,
        ROUND(v_fleet_health)
      + ROUND(v_revenue_stability)
      + ROUND(v_debt_ratio)
      + ROUND(v_cash_reserve)
      + ROUND(v_profit_history)
    ));

    total_score := v_total_score;
    tier := resolve_credit_tier(v_total_score);
    fleet_health := ROUND(v_fleet_health)::INT;
    revenue_stability := ROUND(v_revenue_stability)::INT;
    debt_ratio := ROUND(v_debt_ratio)::INT;
    cash_reserve := ROUND(v_cash_reserve)::INT;
    profit_history := ROUND(v_profit_history)::INT;
    RETURN NEXT;
END;
$function$;

-- ============================================================================
-- FIX 5: update_credit_score — use resolve_credit_tier, not stale hardcoding
-- ============================================================================
CREATE OR REPLACE FUNCTION public.update_credit_score(
    p_user_id uuid,
    p_game_date timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_score RECORD;
    v_tier VARCHAR(10);
BEGIN
    SELECT * INTO v_score
    FROM calculate_credit_score(p_user_id)
    LIMIT 1;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_tier := resolve_credit_tier(v_score.total_score);

    INSERT INTO credit_scores (
        user_id, score, tier, fleet_health_score, revenue_stability_score,
        debt_ratio_score, cash_reserves_score, profit_history_score, computed_at
    )
    VALUES (
        p_user_id,
        v_score.total_score,
        v_tier,
        v_score.fleet_health,
        v_score.revenue_stability,
        v_score.debt_ratio,
        v_score.cash_reserve,
        v_score.profit_history,
        NOW()
    )
    ON CONFLICT (user_id) DO UPDATE
    SET score = EXCLUDED.score,
        tier = EXCLUDED.tier,
        fleet_health_score = EXCLUDED.fleet_health_score,
        revenue_stability_score = EXCLUDED.revenue_stability_score,
        debt_ratio_score = EXCLUDED.debt_ratio_score,
        cash_reserves_score = EXCLUDED.cash_reserves_score,
        profit_history_score = EXCLUDED.profit_history_score,
        computed_at = EXCLUDED.computed_at;
END;
$function$;

-- ============================================================================
-- FIX 6: execute_bot_decisions — use the same lease deposit helper
-- ============================================================================
CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
r_bot RECORD; v_model_id UUID; v_model_name VARCHAR; v_lease_price NUMERIC; v_purchase_price NUMERIC; v_capacity INT; v_speed_kmh NUMERIC; v_range_km NUMERIC; v_deposit_amount NUMERIC; v_tail VARCHAR(20); v_origin_iata VARCHAR(3); v_dest_iata VARCHAR(3); v_distance DOUBLE PRECISION; v_fleet_count INT; v_route_count INT; v_idle_aircraft_count INT; v_idle_aircraft_id UUID; v_idle_tail VARCHAR(20); v_idle_condition NUMERIC; v_idle_model_name VARCHAR; v_idle_capacity INT; v_idle_speed NUMERIC; v_idle_range NUMERIC; v_grounded_aircraft_id UUID; v_grounded_condition NUMERIC; v_grounded_acquisition_type VARCHAR; v_grounded_model_name VARCHAR; v_grounded_lease_price NUMERIC; v_grounded_purchase_price NUMERIC; v_repair_cost NUMERIC; v_target_fleet_cap INT; v_min_cash_reserve NUMERIC; v_growth_chance NUMERIC; v_target_distance DOUBLE PRECISION; v_target_price_multiplier NUMERIC; v_target_schedule_ratio NUMERIC; v_effective_threshold NUMERIC(5,2); v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00; v_selected_route_id UUID; v_selected_flights INT; v_selected_base_fare NUMERIC; v_max_weekly_flights INT; v_target_flights INT; v_target_price NUMERIC; v_bot_cash NUMERIC; v_starting_cash NUMERIC; v_attempts INT; v_inserted BOOLEAN; v_economy INT; v_business INT; v_first INT; r_route RECORD; v_human_competitors INT; v_new_price NUMERIC; v_base_fare NUMERIC; v_purchase_capacity INT; v_purchase_model_name VARCHAR; v_active_loans INT; v_game_time TIMESTAMPTZ;
v_archetype VARCHAR(30);
v_ticket_base_fare NUMERIC;
v_ticket_per_km_rate NUMERIC;
v_bankruptcy_threshold NUMERIC;
v_spawned_id UUID;
v_requested_loan NUMERIC;
BEGIN
v_ticket_base_fare := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
v_ticket_per_km_rate := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);
v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);
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
IF v_bot_cash < v_bankruptcy_threshold THEN
  UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
  UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id;
  UPDATE loans SET status = 'defaulted', remaining_balance = 0 WHERE user_id = r_bot.id AND status = 'active';
  UPDATE route_assignments SET status = 'cancelled' WHERE user_id = r_bot.id AND status = 'active';
  CONTINUE;
END IF;
CASE v_archetype WHEN 'Regional' THEN v_target_fleet_cap := 8; v_min_cash_reserve := 3500000.00; v_growth_chance := 0.20; v_target_distance := 900.0; v_target_price_multiplier := 0.95; v_target_schedule_ratio := 0.72; WHEN 'Aggressive' THEN v_target_fleet_cap := 14; v_min_cash_reserve := 4500000.00; v_growth_chance := 0.26; v_target_distance := 1800.0; v_target_price_multiplier := 1.02; v_target_schedule_ratio := 0.82; ELSE v_target_fleet_cap := 10; v_min_cash_reserve := 7000000.00; v_growth_chance := 0.16; v_target_distance := 4200.0; v_target_price_multiplier := 1.18; v_target_schedule_ratio := 0.58; END CASE;
SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
SELECT COUNT(*)::INT INTO v_idle_aircraft_count FROM fleet_aircraft f WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);
SELECT f.id, f.condition, f.acquisition_type, m.model_name, m.lease_price_per_month, m.purchase_price INTO v_grounded_aircraft_id, v_grounded_condition, v_grounded_acquisition_type, v_grounded_model_name, v_grounded_lease_price, v_grounded_purchase_price FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND (f.status = 'grounded' OR f.condition < v_effective_threshold) ORDER BY f.condition DESC LIMIT 1;
IF v_grounded_aircraft_id IS NOT NULL THEN v_repair_cost := CASE WHEN v_grounded_acquisition_type = 'lease' THEN (100.00 - v_grounded_condition) * (COALESCE(v_grounded_lease_price, 0.00) * 0.50) ELSE (100.00 - v_grounded_condition) * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005) END; IF v_repair_cost > 0 AND v_bot_cash >= (v_repair_cost + 500000.00) THEN PERFORM debit_bank_account(r_bot.id, v_repair_cost, 'cogs', 'maintenance', 'Bot maintenance recovery: ' || v_grounded_model_name, v_game_time); UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = v_grounded_aircraft_id; v_bot_cash := v_bot_cash - v_repair_cost; END IF; END IF;
IF v_bot_cash < 3000000.00 OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN SELECT r.id, r.flights_per_week, (v_ticket_base_fare + (r.distance_km * v_ticket_per_km_rate))::NUMERIC INTO v_selected_route_id, v_selected_flights, v_selected_base_fare FROM route_assignments r WHERE r.user_id = r_bot.id ORDER BY (r.ticket_price / NULLIF((v_ticket_base_fare + (r.distance_km * v_ticket_per_km_rate)), 0)) DESC, r.flights_per_week DESC LIMIT 1; IF v_selected_route_id IS NOT NULL THEN IF v_selected_flights > 8 THEN UPDATE route_assignments SET flights_per_week = GREATEST(6, flights_per_week - CASE v_archetype WHEN 'Regional' THEN 6 WHEN 'Aggressive' THEN 4 ELSE 2 END), ticket_price = LEAST(ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2), ROUND((ticket_price * 0.90)::numeric, 2)) WHERE id = v_selected_route_id; ELSE DELETE FROM route_assignments WHERE id = v_selected_route_id; END IF; END IF; END IF;
IF v_fleet_count < v_target_fleet_cap AND v_bot_cash > v_min_cash_reserve AND COALESCE(r_bot.consecutive_negative_days, 0) = 0 AND v_idle_aircraft_count = 0 AND v_route_count >= v_fleet_count AND random() < v_growth_chance THEN
v_model_id := NULL; v_model_name := NULL; v_lease_price := NULL; v_purchase_price := NULL; v_capacity := NULL;
IF v_archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600' LIMIT 1; ELSIF v_archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' AND model_name = 'A320neo' LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' AND model_name = '787-9' LIMIT 1; END IF;
IF v_model_id IS NULL THEN IF v_archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' ORDER BY capacity DESC LIMIT 1; ELSIF v_archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' ORDER BY capacity DESC LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' ORDER BY capacity DESC LIMIT 1; END IF; END IF;
v_deposit_amount := calculate_required_lease_deposit(v_purchase_price, v_lease_price);
IF v_model_id IS NOT NULL AND v_bot_cash >= v_deposit_amount THEN IF v_archetype = 'Regional' THEN v_economy := FLOOR(v_capacity * 0.80); v_business := FLOOR(v_capacity * 0.15); v_first := v_capacity - v_economy - v_business; ELSIF v_archetype = 'Aggressive' THEN v_economy := FLOOR(v_capacity * 0.70); v_business := FLOOR(v_capacity * 0.20); v_first := v_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_capacity * 0.50); v_business := FLOOR(v_capacity * 0.30); v_first := v_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (id, user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats) VALUES (gen_random_uuid(), r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN PERFORM debit_bank_account(r_bot.id, v_deposit_amount, 'investing', 'aircraft_lease_deposit', 'Leased aircraft ' || v_model_name || ' [' || v_tail || '] - deposit', v_game_time); v_bot_cash := v_bot_cash - v_deposit_amount; END IF; END IF;
END IF;
IF v_bot_cash > (v_starting_cash * 3) AND v_fleet_count < v_target_fleet_cap THEN
  v_model_id := NULL; v_purchase_price := NULL; v_purchase_capacity := NULL; v_purchase_model_name := NULL;
  IF v_archetype = 'Regional' THEN
    SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name
    FROM aircraft_models WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600' LIMIT 1;
  ELSIF v_archetype = 'Aggressive' THEN
    SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name
    FROM aircraft_models WHERE manufacturer = 'Airbus' AND model_name = 'A320neo' LIMIT 1;
  ELSE
    SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name
    FROM aircraft_models WHERE manufacturer = 'Boeing' AND model_name = '787-9' LIMIT 1;
  END IF;
  IF v_model_id IS NULL THEN
    SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name
    FROM aircraft_models WHERE range_km >= v_target_distance ORDER BY purchase_price ASC LIMIT 1;
  END IF;
  IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN IF v_archetype = 'Regional' THEN v_economy := FLOOR(v_purchase_capacity * 0.80); v_business := FLOOR(v_purchase_capacity * 0.15); v_first := v_purchase_capacity - v_economy - v_business; ELSIF v_archetype = 'Aggressive' THEN v_economy := FLOOR(v_purchase_capacity * 0.70); v_business := FLOOR(v_purchase_capacity * 0.20); v_first := v_purchase_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_purchase_capacity * 0.50); v_business := FLOOR(v_purchase_capacity * 0.30); v_first := v_purchase_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats) VALUES (r_bot.id, v_model_id, v_purchase_model_name, v_tail, 'purchase', 100.00, 'active', v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN PERFORM debit_bank_account(r_bot.id, v_purchase_price, 'investing', 'aircraft_purchase', 'Aircraft purchase: ' || v_tail, v_game_time); v_bot_cash := v_bot_cash - v_purchase_price; END IF; END IF;
END IF;
SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
SELECT f.id, f.tail_number, f.condition, m.model_name, m.capacity, m.speed_kmh, m.range_km INTO v_idle_aircraft_id, v_idle_tail, v_idle_condition, v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id) ORDER BY f.condition DESC LIMIT 1;
IF v_idle_aircraft_id IS NOT NULL AND v_route_count < v_target_fleet_cap THEN v_attempts := 0; v_inserted := false; WHILE v_attempts < 20 AND NOT v_inserted LOOP SELECT iata INTO v_dest_iata FROM airports WHERE iata != v_origin_iata AND haversine_distance((SELECT latitude FROM airports WHERE iata = v_origin_iata), (SELECT longitude FROM airports WHERE iata = v_origin_iata), latitude, longitude) <= v_idle_range ORDER BY demand_index DESC, random() LIMIT 1; IF v_dest_iata IS NULL THEN EXIT; END IF; SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude) INTO v_distance FROM airports o, airports d WHERE o.iata = v_origin_iata AND d.iata = v_dest_iata; IF v_distance > 0 AND v_distance <= v_idle_range THEN v_base_fare := v_ticket_base_fare + (v_distance * v_ticket_per_km_rate); v_target_price := ROUND(v_base_fare * v_target_price_multiplier, 2); v_max_weekly_flights := calculate_route_max_weekly_flights(v_distance, v_idle_speed::INT); v_target_flights := GREATEST(1, FLOOR(v_max_weekly_flights * v_target_schedule_ratio)); BEGIN INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week) VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, v_target_price, v_idle_aircraft_id, v_target_flights); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; ELSE v_attempts := v_attempts + 1; END IF; END LOOP; END IF;
FOR r_route IN SELECT ra.*, m.speed_kmh, m.range_km, m.turnaround_hours FROM route_assignments ra JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id JOIN aircraft_models m ON m.id = fa.aircraft_model_id WHERE ra.user_id = r_bot.id AND ra.status = 'active' LOOP SELECT COUNT(*) INTO v_human_competitors FROM route_assignments WHERE origin_iata = r_route.origin_iata AND destination_iata = r_route.destination_iata AND status = 'active' AND user_id != r_bot.id; IF v_human_competitors > 0 THEN v_base_fare := v_ticket_base_fare + (r_route.distance_km * v_ticket_per_km_rate); v_new_price := ROUND(v_base_fare * v_target_price_multiplier * CASE WHEN r_route.ticket_price > v_base_fare * 1.3 THEN 0.95 ELSE 1.0 END, 2); IF v_new_price != r_route.ticket_price THEN UPDATE route_assignments SET ticket_price = v_new_price WHERE id = r_route.id; END IF; END IF; END LOOP;
SELECT COUNT(*) INTO v_active_loans FROM loans WHERE user_id = r_bot.id AND status = 'active';
IF v_active_loans = 0 AND v_bot_cash < v_starting_cash * 0.5 AND v_bot_cash > 1000000 THEN
  v_requested_loan := LEAST(5000000, v_starting_cash - v_bot_cash);
  PERFORM success
  FROM take_loan(r_bot.id, v_requested_loan, 52, 'unsecured', NULL);
END IF;
UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;
END LOOP;
IF (SELECT COUNT(*) FROM users WHERE actor_type = 'AI' AND COALESCE(operational_status, 'Active') != 'Bankrupt') <
COALESCE(get_config_int('max_bot_count'), 5) THEN
v_spawned_id := spawn_bot();
END IF;
END;
$function$;

-- ============================================================================
-- FIX 7: refresh live credit scores after the formula and policy change
-- ============================================================================
DO $$
DECLARE
    r_user RECORD;
BEGIN
    FOR r_user IN
        SELECT id, game_current_time
        FROM users
    LOOP
        PERFORM update_credit_score(r_user.id, r_user.game_current_time);
    END LOOP;
END;
$$;
