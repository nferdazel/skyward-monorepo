-- ============================================================================
-- Migration 96: Bank fixes — cascade delete, bot loan payments, early repayment
-- ============================================================================
-- PART 1: reset_user_airline — add financial table cleanup
-- PART 2: execute_bot_decisions — mark bot loans/financing as defaulted on bankruptcy
-- PART 3: repay_loan RPC for players
-- PART 4: process_bot_loan_payments + wire into simulation tick


-- ============================================================================
-- PART 1: Fix reset_user_airline — add financial table cleanup
-- ============================================================================

DROP FUNCTION IF EXISTS public.reset_user_airline(uuid);

CREATE OR REPLACE FUNCTION public.reset_user_airline(p_user_id uuid)
 RETURNS TABLE(success boolean, message text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RETURN QUERY SELECT FALSE, 'User not found';
        RETURN;
    END IF;
    -- Clean up financial tables before route/fleet/ledger deletes
    DELETE FROM loans WHERE user_id = p_user_id;
    DELETE FROM credit_scores WHERE user_id = p_user_id;
    DELETE FROM credit_score_history WHERE user_id = p_user_id;
    DELETE FROM aircraft_financing WHERE user_id = p_user_id;
    -- Original deletes
    DELETE FROM user_routes WHERE user_id = p_user_id;
    DELETE FROM user_fleet WHERE user_id = p_user_id;
    DELETE FROM financial_ledger WHERE user_id = p_user_id;
    UPDATE users
    SET cash = 15000000.00,
        game_current_time = TIMESTAMP WITH TIME ZONE '2020-01-01 00:00:00+00',
        hq_airport_iata = 'SIN',
        auto_grounding_threshold = 40.00,
        buffered_revenue = 0.00,
        buffered_ops_cost = 0.00,
        buffered_lease_cost = 0.00,
        operational_status = 'Active',
        consecutive_negative_days = 0,
        recovery_streak_days = 0,
        last_active_at = NOW()
    WHERE id = p_user_id;
    RETURN QUERY SELECT TRUE, 'Airline reset successfully';
END;
$function$;


-- ============================================================================
-- PART 2: Fix execute_bot_decisions — mark bot loans/financing as defaulted
-- ============================================================================

CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    r_bot RECORD;
    v_model_id UUID;
    v_model_name VARCHAR;
    v_lease_price NUMERIC;
    v_purchase_price NUMERIC;
    v_capacity INT;
    v_speed_kmh NUMERIC;
    v_range_km NUMERIC;
    v_deposit_pct NUMERIC;
    v_deposit_amount NUMERIC;
    v_tail VARCHAR(20);
    v_new_aircraft_id UUID;
    v_origin_iata VARCHAR(3);
    v_dest_iata VARCHAR(3);
    v_distance DOUBLE PRECISION;
    v_fleet_count INT;
    v_route_count INT;
    v_idle_aircraft_count INT;
    v_idle_aircraft_id UUID;
    v_idle_tail VARCHAR(20);
    v_idle_condition NUMERIC;
    v_idle_model_name VARCHAR;
    v_idle_capacity INT;
    v_idle_speed NUMERIC;
    v_idle_range NUMERIC;
    v_grounded_aircraft_id UUID;
    v_grounded_condition NUMERIC;
    v_grounded_acquisition_type VARCHAR;
    v_grounded_model_name VARCHAR;
    v_grounded_lease_price NUMERIC;
    v_grounded_purchase_price NUMERIC;
    v_repair_cost NUMERIC;
    v_target_fleet_cap INT;
    v_min_cash_reserve NUMERIC;
    v_growth_chance NUMERIC;
    v_target_distance DOUBLE PRECISION;
    v_target_price_multiplier NUMERIC;
    v_target_schedule_ratio NUMERIC;
    v_effective_threshold NUMERIC(5,2);
    v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00;
    v_selected_route_id UUID;
    v_selected_flights INT;
    v_selected_base_fare NUMERIC;
    v_max_weekly_flights INT;
    v_target_flights INT;
    v_target_price NUMERIC;
    v_bot_cash NUMERIC;
    v_grounded_count INT;
    v_negative_days INT;
    v_starting_cash NUMERIC := 15000000.00;
    v_attempts INT;
    v_inserted BOOLEAN;
    v_economy INT;
    v_business INT;
    v_first INT;
    r_route RECORD;
    v_human_competitors INT;
    v_new_price NUMERIC;
    v_base_fare NUMERIC;
    v_purchase_capacity INT;
    v_active_loans INT;
    v_loan_record RECORD;
    v_fin_model_id UUID;
    v_fin_model_price NUMERIC;
    v_credit_score INT;
    v_credit_tier VARCHAR(10);
BEGIN
    SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1;
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
    FOR r_bot IN SELECT * FROM ai_competitors LOOP
        v_bot_cash := COALESCE(r_bot.cash, 0.00);
        v_origin_iata := r_bot.hq_airport_iata;
        v_effective_threshold := GREATEST(
            v_absolute_minimum_safety_limit,
            COALESCE(r_bot.auto_grounding_threshold, 40.00)
        );
        IF r_bot.status = 'Bankrupt' OR v_bot_cash < -5000000.00 THEN
            UPDATE ai_competitors SET status = 'Bankrupt' WHERE id = r_bot.id;
            UPDATE user_fleet SET status = 'grounded' WHERE ai_competitor_id = r_bot.id;
            -- Mark bot loans as defaulted
            UPDATE loans SET status = 'defaulted', remaining_balance = 0
            WHERE ai_competitor_id = r_bot.id AND status = 'active';
            -- Mark bot financing as repossessed
            UPDATE aircraft_financing SET status = 'repossessed', remaining_balance = 0
            WHERE ai_competitor_id = r_bot.id AND status = 'active';
            CONTINUE;
        END IF;
        CASE r_bot.archetype
            WHEN 'Regional' THEN
                v_target_fleet_cap := 8;
                v_min_cash_reserve := 3500000.00;
                v_growth_chance := 0.20;
                v_target_distance := 900.0;
                v_target_price_multiplier := 0.95;
                v_target_schedule_ratio := 0.72;
            WHEN 'Aggressive' THEN
                v_target_fleet_cap := 14;
                v_min_cash_reserve := 4500000.00;
                v_growth_chance := 0.26;
                v_target_distance := 1800.0;
                v_target_price_multiplier := 1.02;
                v_target_schedule_ratio := 0.82;
            ELSE
                v_target_fleet_cap := 10;
                v_min_cash_reserve := 7000000.00;
                v_growth_chance := 0.16;
                v_target_distance := 4200.0;
                v_target_price_multiplier := 1.18;
                v_target_schedule_ratio := 0.58;
        END CASE;
        SELECT COUNT(*)::INT INTO v_fleet_count
        FROM user_fleet
        WHERE ai_competitor_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_route_count
        FROM user_routes
        WHERE ai_competitor_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_idle_aircraft_count
        FROM user_fleet f
        WHERE f.ai_competitor_id = r_bot.id
          AND f.status = 'active'
          AND f.condition >= v_effective_threshold
          AND NOT EXISTS (
              SELECT 1
              FROM user_routes r
              WHERE r.assigned_aircraft_id = f.id
          );
        SELECT
            f.id,
            f.condition,
            f.acquisition_type,
            m.model_name,
            m.lease_price_per_month,
            m.purchase_price
        INTO
            v_grounded_aircraft_id,
            v_grounded_condition,
            v_grounded_acquisition_type,
            v_grounded_model_name,
            v_grounded_lease_price,
            v_grounded_purchase_price
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.ai_competitor_id = r_bot.id
          AND (f.status = 'grounded' OR f.condition < v_effective_threshold)
        ORDER BY f.condition DESC
        LIMIT 1;
        IF v_grounded_aircraft_id IS NOT NULL THEN
            v_repair_cost := CASE
                WHEN v_grounded_acquisition_type = 'lease'
                    THEN (100.00 - v_grounded_condition) * (COALESCE(v_grounded_lease_price, 0.00) * 0.50)
                ELSE (100.00 - v_grounded_condition) * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005)
            END;
            IF v_repair_cost > 0 AND v_bot_cash >= (v_repair_cost + 500000.00) THEN
                UPDATE ai_competitors
                SET cash = cash - v_repair_cost
                WHERE id = r_bot.id;
                UPDATE user_fleet
                SET condition = 100.00,
                    status = 'active'
                WHERE id = v_grounded_aircraft_id;
                INSERT INTO financial_ledger (
                    ai_competitor_id,
                    transaction_type,
                    category,
                    amount,
                    description,
                    game_date
                )
                VALUES (
                    r_bot.id,
                    'expense',
                    'aircraft_repair',
                    v_repair_cost,
                    'Bot maintenance recovery completed for ' || v_grounded_model_name,
                    r_bot.game_current_time
                );
                v_bot_cash := v_bot_cash - v_repair_cost;
            END IF;
        END IF;
        IF v_bot_cash < 3000000.00 OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN
            SELECT
                r.id,
                r.flights_per_week,
                (50.00 + (r.distance_km * 0.12))::NUMERIC
            INTO
                v_selected_route_id,
                v_selected_flights,
                v_selected_base_fare
            FROM user_routes r
            WHERE r.ai_competitor_id = r_bot.id
            ORDER BY
                (r.ticket_price / NULLIF((50.00 + (r.distance_km * 0.12)), 0)) DESC,
                r.flights_per_week DESC
            LIMIT 1;
            IF v_selected_route_id IS NOT NULL THEN
                IF v_selected_flights > 8 THEN
                    UPDATE user_routes
                    SET flights_per_week = GREATEST(
                            6,
                            flights_per_week - CASE r_bot.archetype
                                WHEN 'Regional' THEN 6
                                WHEN 'Aggressive' THEN 4
                                ELSE 2
                            END
                        ),
                        ticket_price = GREATEST(
                            ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2),
                            ROUND((ticket_price * 0.90)::numeric, 2)
                        )
                    WHERE id = v_selected_route_id;
                ELSE
                    DELETE FROM user_routes WHERE id = v_selected_route_id;
                END IF;
            END IF;
        END IF;
        IF v_fleet_count < v_target_fleet_cap
           AND v_bot_cash > v_min_cash_reserve
           AND COALESCE(r_bot.consecutive_negative_days, 0) = 0
           AND v_idle_aircraft_count = 0
           AND v_route_count >= v_fleet_count
           AND random() < v_growth_chance THEN
            v_model_id := NULL;
            v_model_name := NULL;
            v_lease_price := NULL;
            v_purchase_price := NULL;
            v_capacity := NULL;
            IF r_bot.archetype = 'Regional' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                FROM aircraft_models
                WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600'
                LIMIT 1;
            ELSIF r_bot.archetype = 'Aggressive' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                FROM aircraft_models
                WHERE manufacturer = 'Airbus' AND model_name = 'A320neo'
                LIMIT 1;
            ELSE
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                FROM aircraft_models
                WHERE manufacturer = 'Boeing' AND model_name = '787-9'
                LIMIT 1;
            END IF;
            IF v_model_id IS NULL THEN
                IF r_bot.archetype = 'Regional' THEN
                    SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
                    INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                    FROM aircraft_models
                    WHERE manufacturer = 'ATR'
                    ORDER BY capacity DESC
                    LIMIT 1;
                ELSIF r_bot.archetype = 'Aggressive' THEN
                    SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
                    INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                    FROM aircraft_models
                    WHERE manufacturer = 'Airbus'
                    ORDER BY capacity DESC
                    LIMIT 1;
                ELSE
                    SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
                    INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                    FROM aircraft_models
                    WHERE manufacturer = 'Boeing'
                    ORDER BY capacity DESC
                    LIMIT 1;
                END IF;
            END IF;
            v_deposit_amount := COALESCE(v_lease_price, 0.00) * (v_deposit_pct * 10.0);
            IF v_model_id IS NOT NULL AND v_bot_cash >= v_deposit_amount THEN
                v_tail := generate_tail_number(r_bot.hq_airport_iata);
                v_new_aircraft_id := gen_random_uuid();
                IF r_bot.archetype = 'Regional' THEN
                    v_economy := FLOOR(v_capacity * 0.80);
                    v_business := FLOOR(v_capacity * 0.15);
                    v_first := v_capacity - v_economy - v_business;
                ELSIF r_bot.archetype = 'Aggressive' THEN
                    v_economy := FLOOR(v_capacity * 0.70);
                    v_business := FLOOR(v_capacity * 0.20);
                    v_first := v_capacity - v_economy - v_business;
                ELSE
                    v_economy := FLOOR(v_capacity * 0.50);
                    v_business := FLOOR(v_capacity * 0.30);
                    v_first := v_capacity - v_economy - v_business;
                END IF;
                INSERT INTO user_fleet (
                    id,
                    ai_competitor_id,
                    aircraft_model_id,
                    nickname,
                    acquisition_type,
                    condition,
                    status,
                    tail_number,
                    economy_seats,
                    business_seats,
                    first_class_seats
                )
                VALUES (
                    v_new_aircraft_id,
                    r_bot.id,
                    v_model_id,
                    v_model_name,
                    'lease',
                    100.00,
                    'active',
                    v_tail,
                    v_economy,
                    v_business,
                    v_first
                );
                UPDATE ai_competitors
                SET cash = cash - v_deposit_amount
                WHERE id = r_bot.id;
                INSERT INTO financial_ledger (
                    ai_competitor_id,
                    transaction_type,
                    category,
                    amount,
                    description,
                    game_date
                )
                VALUES (
                    r_bot.id,
                    'expense',
                    'aircraft_lease',
                    v_deposit_amount,
                    'Leased aircraft ' || v_model_name || ' with Call Sign: ' || v_tail || ' - Downpayment deposit',
                    r_bot.game_current_time
                );
                v_bot_cash := v_bot_cash - v_deposit_amount;
            END IF;
        END IF;
        IF v_bot_cash > (v_starting_cash * 3) AND v_fleet_count < v_target_fleet_cap THEN
            SELECT id, purchase_price, capacity
            INTO v_model_id, v_purchase_price, v_purchase_capacity
            FROM aircraft_models
            WHERE range_km >= v_target_distance
            ORDER BY purchase_price ASC
            LIMIT 1;
            IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN
                IF r_bot.archetype = 'Regional' THEN
                    v_economy := FLOOR(v_purchase_capacity * 0.80);
                    v_business := FLOOR(v_purchase_capacity * 0.15);
                    v_first := v_purchase_capacity - v_economy - v_business;
                ELSIF r_bot.archetype = 'Aggressive' THEN
                    v_economy := FLOOR(v_purchase_capacity * 0.70);
                    v_business := FLOOR(v_purchase_capacity * 0.20);
                    v_first := v_purchase_capacity - v_economy - v_business;
                ELSE
                    v_economy := FLOOR(v_purchase_capacity * 0.50);
                    v_business := FLOOR(v_purchase_capacity * 0.30);
                    v_first := v_purchase_capacity - v_economy - v_business;
                END IF;
                v_attempts := 0;
                v_inserted := false;
                WHILE v_attempts < 10 AND NOT v_inserted LOOP
                    v_tail := generate_tail_number(r_bot.hq_airport_iata);
                    BEGIN
                        INSERT INTO user_fleet (
                            ai_competitor_id, aircraft_model_id, tail_number,
                            acquisition_type, condition, status,
                            economy_seats, business_seats, first_class_seats
                        ) VALUES (
                            r_bot.id, v_model_id, v_tail,
                            'purchase', 100.00, 'active',
                            v_economy, v_business, v_first
                        );
                        v_inserted := true;
                    EXCEPTION WHEN unique_violation THEN
                        v_attempts := v_attempts + 1;
                    END;
                END LOOP;
                IF v_inserted THEN
                    UPDATE ai_competitors SET cash = cash - v_purchase_price WHERE id = r_bot.id;
                    INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                    VALUES (r_bot.id, 'expense', 'acquisition', v_purchase_price, 'Aircraft purchase: ' || v_tail, r_bot.game_current_time);
                    v_bot_cash := v_bot_cash - v_purchase_price;
                END IF;
            END IF;
        END IF;
        SELECT COUNT(*)::INT INTO v_fleet_count
        FROM user_fleet
        WHERE ai_competitor_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_route_count
        FROM user_routes
        WHERE ai_competitor_id = r_bot.id;
        SELECT
            f.id,
            f.tail_number,
            f.condition,
            m.model_name,
            m.capacity,
            m.speed_kmh,
            m.range_km
        INTO
            v_idle_aircraft_id,
            v_idle_tail,
            v_idle_condition,
            v_idle_model_name,
            v_idle_capacity,
            v_idle_speed,
            v_idle_range
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.ai_competitor_id = r_bot.id
          AND f.status = 'active'
          AND f.condition >= v_effective_threshold
          AND NOT EXISTS (
              SELECT 1
              FROM user_routes r
              WHERE r.assigned_aircraft_id = f.id
          )
        ORDER BY f.condition DESC, m.capacity DESC
        LIMIT 1;
        IF v_idle_aircraft_id IS NOT NULL
           AND v_bot_cash > (v_min_cash_reserve * 0.35) THEN
            SELECT candidate.iata, candidate.distance_km
            INTO v_dest_iata, v_distance
            FROM (
                SELECT
                    a.iata,
                    a.demand_index,
                    6371.0 * 2 * ASIN(
                        SQRT(
                            POWER(SIN(RADIANS(a.latitude - h.latitude) / 2), 2) +
                            COS(RADIANS(h.latitude)) * COS(RADIANS(a.latitude)) *
                            POWER(SIN(RADIANS(a.longitude - h.longitude) / 2), 2)
                        )
                    ) AS distance_km
                FROM airports a
                JOIN airports h ON h.iata = v_origin_iata
                WHERE a.iata != v_origin_iata
            ) candidate
            WHERE candidate.distance_km BETWEEN GREATEST(250.0, v_target_distance * 0.55)
                                            AND LEAST(COALESCE(v_idle_range, v_target_distance), v_target_distance * 1.35)
            ORDER BY
                ABS(candidate.distance_km - LEAST(v_target_distance, COALESCE(v_idle_range, v_target_distance) * 0.80)),
                candidate.demand_index DESC,
                random()
            LIMIT 1;
            IF v_dest_iata IS NULL THEN
                SELECT candidate.iata, candidate.distance_km
                INTO v_dest_iata, v_distance
                FROM (
                    SELECT
                        a.iata,
                        a.demand_index,
                        6371.0 * 2 * ASIN(
                            SQRT(
                                POWER(SIN(RADIANS(a.latitude - h.latitude) / 2), 2) +
                                COS(RADIANS(h.latitude)) * COS(RADIANS(a.latitude)) *
                                POWER(SIN(RADIANS(a.longitude - h.longitude) / 2), 2)
                            )
                        ) AS distance_km
                    FROM airports a
                    JOIN airports h ON h.iata = v_origin_iata
                    WHERE a.iata != v_origin_iata
                ) candidate
                WHERE candidate.distance_km <= COALESCE(v_idle_range, v_target_distance)
                ORDER BY candidate.demand_index DESC, random()
                LIMIT 1;
            END IF;
            IF v_dest_iata IS NOT NULL AND v_distance IS NOT NULL AND COALESCE(v_idle_speed, 0) > 0 THEN
                v_max_weekly_flights := GREATEST(
                    1,
                    FLOOR(168.0 / ((v_distance / v_idle_speed) + 1.0))
                );
                v_target_flights := GREATEST(
                    6,
                    LEAST(
                        v_max_weekly_flights,
                        FLOOR(v_max_weekly_flights * v_target_schedule_ratio)
                    )
                );
                v_target_price := ROUND(
                    ((50.00 + (v_distance * 0.12)) * v_target_price_multiplier)::numeric,
                    2
                );
                INSERT INTO user_routes (
                    ai_competitor_id,
                    origin_iata,
                    destination_iata,
                    distance_km,
                    ticket_price,
                    assigned_aircraft_id,
                    flights_per_week
                )
                VALUES (
                    r_bot.id,
                    v_origin_iata,
                    v_dest_iata,
                    v_distance,
                    v_target_price,
                    v_idle_aircraft_id,
                    v_target_flights
                )
                ON CONFLICT DO NOTHING;
            END IF;
        END IF;
        FOR r_route IN
            SELECT * FROM user_routes
            WHERE ai_competitor_id = r_bot.id AND status = 'active'
        LOOP
            SELECT COUNT(*) INTO v_human_competitors
            FROM user_routes
            WHERE origin_iata = r_route.origin_iata
              AND destination_iata = r_route.destination_iata
              AND user_id IS NOT NULL
              AND status = 'active';
            IF v_human_competitors > 0 THEN
                v_base_fare := 50.00 + (r_route.distance_km * 0.12);
                v_new_price := r_route.ticket_price * 0.97;
                IF v_new_price >= v_base_fare * 0.85 THEN
                    UPDATE user_routes
                    SET ticket_price = ROUND(v_new_price::numeric, 2)
                    WHERE id = r_route.id;
                END IF;
            END IF;
        END LOOP;
        -- Financial intelligence
        SELECT cash INTO v_bot_cash FROM ai_competitors WHERE id = r_bot.id;
        IF v_bot_cash < v_starting_cash * 0.5 THEN
            SELECT COUNT(*) INTO v_active_loans
            FROM loans WHERE ai_competitor_id = r_bot.id AND status = 'active';
            IF v_active_loans < 2 THEN
                PERFORM bot_take_loan(r_bot.id, v_starting_cash * 0.5, 52);
            END IF;
        END IF;
        SELECT cash INTO v_bot_cash FROM ai_competitors WHERE id = r_bot.id;
        IF v_fleet_count < v_target_fleet_cap AND v_bot_cash > 3000000 THEN
            SELECT id, purchase_price INTO v_fin_model_id, v_fin_model_price
            FROM aircraft_models
            WHERE range_km >= v_target_distance
            ORDER BY purchase_price ASC
            LIMIT 1;
            IF v_fin_model_price IS NOT NULL
               AND v_bot_cash < v_fin_model_price
               AND v_bot_cash > v_fin_model_price * 0.20 THEN
                PERFORM bot_finance_aircraft(r_bot.id, v_fin_model_id, 0.20, 60);
            END IF;
        END IF;
        SELECT cash INTO v_bot_cash FROM ai_competitors WHERE id = r_bot.id;
        IF v_bot_cash > v_starting_cash * 3 THEN
            SELECT * INTO v_loan_record
            FROM loans
            WHERE ai_competitor_id = r_bot.id AND status = 'active'
            ORDER BY interest_rate DESC
            LIMIT 1;
            IF v_loan_record.id IS NOT NULL
               AND v_bot_cash > v_loan_record.remaining_balance THEN
                UPDATE ai_competitors
                SET cash = cash - v_loan_record.remaining_balance
                WHERE id = r_bot.id;
                UPDATE loans
                SET status = 'paid_off',
                    paid_off_at = NOW(),
                    remaining_balance = 0
                WHERE id = v_loan_record.id;
                INSERT INTO financial_ledger (
                    ai_competitor_id, transaction_type, category,
                    amount, description, game_date
                ) VALUES (
                    r_bot.id, 'expense', 'loan_payment',
                    v_loan_record.remaining_balance,
                    'Early loan payoff — saved on future interest',
                    r_bot.game_current_time
                );
            END IF;
        END IF;
        SELECT * INTO v_credit_score, v_credit_tier
        FROM calculate_bot_credit_score(r_bot.id)
        LIMIT 1;
        UPDATE ai_competitors
        SET credit_score = v_credit_score,
            credit_tier = v_credit_tier
        WHERE id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_grounded_count
        FROM user_fleet
        WHERE ai_competitor_id = r_bot.id
          AND (status = 'grounded' OR condition < v_effective_threshold);
        UPDATE ai_competitors
        SET consecutive_negative_days = CASE
                WHEN cash < 0.00 THEN COALESCE(consecutive_negative_days, 0) + 1
                ELSE 0
            END,
            status = CASE
                WHEN cash < 0.00 THEN 'Distress'
                WHEN v_grounded_count > 0 THEN 'Maintenance'
                ELSE 'Active'
            END
        WHERE id = r_bot.id
        RETURNING consecutive_negative_days INTO v_negative_days;
        IF COALESCE(v_negative_days, 0) >= 3 THEN
            UPDATE ai_competitors
            SET status = 'Bankrupt'
            WHERE id = r_bot.id;
            -- Mark bot loans as defaulted
            UPDATE loans SET status = 'defaulted', remaining_balance = 0
            WHERE ai_competitor_id = r_bot.id AND status = 'active';
            -- Mark bot financing as repossessed
            UPDATE aircraft_financing SET status = 'repossessed', remaining_balance = 0
            WHERE ai_competitor_id = r_bot.id AND status = 'active';
        END IF;
    END LOOP;
END;
$function$;


-- ============================================================================
-- PART 3: repay_loan RPC for players
-- ============================================================================

CREATE OR REPLACE FUNCTION repay_loan(
    p_loan_id UUID,
    p_amount NUMERIC DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT, new_cash NUMERIC, paid_off BOOLEAN) AS $$
DECLARE
    v_user_id UUID;
    v_loan RECORD;
    v_payment NUMERIC;
    v_cash NUMERIC;
    v_is_paid_off BOOLEAN := false;
BEGIN
    v_user_id := require_current_user_id();

    SELECT * INTO v_loan FROM loans
    WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Loan not found or already paid off.'::TEXT, 0::NUMERIC, false;
        RETURN;
    END IF;

    IF p_amount IS NULL THEN
        v_payment := v_loan.remaining_balance;
    ELSE
        v_payment := LEAST(p_amount, v_loan.remaining_balance);
    END IF;

    IF v_payment <= 0 THEN
        RETURN QUERY SELECT false, 'Payment amount must be positive.'::TEXT, 0::NUMERIC, false;
        RETURN;
    END IF;

    SELECT cash INTO v_cash FROM users WHERE id = v_user_id FOR UPDATE;
    IF v_cash < v_payment THEN
        RETURN QUERY SELECT false,
            'Insufficient cash. Need $' || v_payment::TEXT || ', have $' || v_cash::TEXT || '.'::TEXT,
            v_cash, false;
        RETURN;
    END IF;

    UPDATE users SET cash = cash - v_payment WHERE id = v_user_id;

    UPDATE loans SET
        remaining_balance = remaining_balance - v_payment,
        status = CASE
            WHEN remaining_balance - v_payment <= 0 THEN 'paid_off'::VARCHAR
            ELSE status
        END,
        paid_off_at = CASE
            WHEN remaining_balance - v_payment <= 0 THEN NOW()
            ELSE paid_off_at
        END
    WHERE id = p_loan_id;

    v_is_paid_off := (SELECT remaining_balance <= 0 FROM loans WHERE id = p_loan_id);

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        v_user_id,
        'expense',
        'loan_repayment',
        v_payment,
        CASE WHEN v_is_paid_off
            THEN 'Loan fully repaid (ID: ' || p_loan_id::TEXT || ')'
            ELSE 'Partial loan repayment (ID: ' || p_loan_id::TEXT || ')'
        END,
        NOW()
    );

    SELECT cash INTO v_cash FROM users WHERE id = v_user_id;

    RETURN QUERY SELECT true,
        CASE WHEN v_is_paid_off
            THEN 'Loan fully repaid!'
            ELSE 'Payment of $' || v_payment::TEXT || ' applied.'
        END::TEXT,
        v_cash,
        v_is_paid_off;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION repay_loan(UUID, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION repay_loan(UUID, NUMERIC) TO authenticated;


-- ============================================================================
-- PART 4: process_bot_loan_payments + wire into simulation tick
-- ============================================================================

CREATE OR REPLACE FUNCTION process_bot_loan_payments(
    p_bot_id UUID,
    p_game_date TIMESTAMPTZ
) RETURNS VOID AS $$
DECLARE
    v_loan RECORD;
    v_cash NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM ai_competitors WHERE id = p_bot_id;

    FOR v_loan IN
        SELECT * FROM loans
        WHERE ai_competitor_id = p_bot_id AND status = 'active'
    LOOP
        IF v_cash >= v_loan.weekly_payment THEN
            UPDATE ai_competitors SET cash = cash - v_loan.weekly_payment WHERE id = p_bot_id;
            v_cash := v_cash - v_loan.weekly_payment;

            UPDATE loans SET remaining_balance = remaining_balance - v_loan.weekly_payment
            WHERE id = v_loan.id;

            IF (SELECT remaining_balance FROM loans WHERE id = v_loan.id) <= 0 THEN
                UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0
                WHERE id = v_loan.id;
            END IF;
        ELSE
            UPDATE loans SET
                remaining_balance = remaining_balance * 1.10,
                missed_payments = missed_payments + 1
            WHERE id = v_loan.id;

            IF (SELECT missed_payments FROM loans WHERE id = v_loan.id) >= 4 THEN
                UPDATE loans SET status = 'defaulted' WHERE id = v_loan.id;
            END IF;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION process_bot_loan_payments(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_bot_loan_payments(UUID, TIMESTAMPTZ) TO service_role;


-- Wire bot loan payments into the simulation tick game-day boundary
-- Replaces process_all_bots_simulation_to_time with bot loan payment call added

DROP FUNCTION IF EXISTS public.process_all_bots_simulation_to_time(TIMESTAMPTZ, UUID);

CREATE OR REPLACE FUNCTION public.process_all_bots_simulation_to_time(
    p_target_game_time TIMESTAMPTZ,
    p_season_id UUID DEFAULT NULL
)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    r_bot RECORD;
    v_game_sec DOUBLE PRECISION;
    v_game_days DOUBLE PRECISION;
    v_route RECORD;
    v_fleet RECORD;
    v_flights DOUBLE PRECISION;
    v_revenue NUMERIC(20,2) := 0;
    v_fuel_cost NUMERIC(20,2) := 0;
    v_maint_cost NUMERIC(20,2) := 0;
    v_tax_cost NUMERIC(20,2) := 0;
    v_crew_cost NUMERIC(20,2) := 0;
    v_total_cost NUMERIC(20,2) := 0;
    v_total_revenue NUMERIC(20,2) := 0;
    v_total_cost_accum NUMERIC(20,2) := 0;
    v_net NUMERIC(20,2) := 0;
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_lease_cost NUMERIC(20,2) := 0;
    v_fuel_price NUMERIC;
    v_absolute_minimum_safety_limit NUMERIC(5,2);
    v_effective_grounding_threshold NUMERIC(5,2);
    v_max_weekly_flights INT;
    v_unused_slots INT;
    v_maintenance_hours DOUBLE PRECISION;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_buffered_rev_accum NUMERIC(20,2);
    v_buffered_ops_accum NUMERIC(20,2);
    v_buffered_lease_accum NUMERIC(20,2);
    v_processed INT := 0;
    v_total_seats INT;
    v_economy_pax NUMERIC;
    v_business_pax NUMERIC;
    v_first_pax NUMERIC;
    v_fuel_price_multiplier NUMERIC := 1.0;
    v_demand_multiplier NUMERIC := 1.0;
    v_base_fare NUMERIC;
    v_business_demand NUMERIC;
    v_first_demand NUMERIC;
    v_crew_cost_per_hour NUMERIC := 350.0;
    v_seasonal_multiplier NUMERIC := 1.0;
    v_game_month INT;
    v_fleet_total_flights INT;
    v_fleet_last_a_check INT;
    v_fleet_last_c_check INT;
    v_turnaround_hours NUMERIC;
BEGIN
    SELECT fuel_price_per_liter, absolute_minimum_safety_limit
    INTO v_fuel_price, v_absolute_minimum_safety_limit
    FROM global_game_settings
    LIMIT 1;
    v_fuel_price := COALESCE(v_fuel_price, 0.85);
    v_absolute_minimum_safety_limit := COALESCE(v_absolute_minimum_safety_limit, 30.00);
    SELECT COALESCE(
        (SELECT effect_value FROM game_events
         WHERE effect_type = 'fuel_price' AND effect_target = 'global'
           AND is_active = true
           AND start_game_time <= p_target_game_time
           AND end_game_time > p_target_game_time
         ORDER BY start_game_time DESC LIMIT 1),
        1.0
    ) INTO v_fuel_price_multiplier;
    FOR r_bot IN
        SELECT *
        FROM ai_competitors
        WHERE status != 'Bankrupt'
          AND (p_season_id IS NULL OR season_id = p_season_id)
        FOR UPDATE
    LOOP
        v_game_sec := COALESCE(EXTRACT(EPOCH FROM (p_target_game_time - r_bot.game_current_time)), 0.0);
        IF v_game_sec < 1 THEN
            CONTINUE;
        END IF;
        v_game_days := v_game_sec / 86400.0;
        v_effective_grounding_threshold := GREATEST(
            COALESCE(r_bot.auto_grounding_threshold, 40.00),
            v_absolute_minimum_safety_limit
        );
        v_lease_cost := 0.00;
        v_total_revenue := 0.00;
        v_total_cost_accum := 0.00;
        v_game_month := EXTRACT(MONTH FROM p_target_game_time);
        v_seasonal_multiplier := CASE
            WHEN v_game_month IN (6, 7, 8, 12) THEN 1.15
            WHEN v_game_month IN (3, 4, 5, 9)   THEN 1.0
            ELSE 0.90
        END;
        FOR v_fleet IN
            SELECT f.*, m.lease_price_per_month
            FROM user_fleet f
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            WHERE f.ai_competitor_id = r_bot.id AND f.acquisition_type = 'lease'
        LOOP
            v_lease_cost := v_lease_cost + COALESCE((v_game_days * (v_fleet.lease_price_per_month / 30.0)), 0.00);
        END LOOP;
        v_lease_cost := GREATEST(0.00, COALESCE(v_lease_cost, 0.00));
        FOR v_route IN
            SELECT r.*,
                   f.id AS fleet_aircraft_id,
                   f.condition,
                   f.status,
                   f.acquisition_type,
                   f.economy_seats,
                   f.business_seats,
                   f.first_class_seats,
                   f.total_flights,
                   f.last_a_check_at,
                   f.last_c_check_at,
                   m.capacity,
                   m.speed_kmh,
                   m.fuel_burn_per_km,
                   m.maintenance_cost_per_hour,
                   m.turnaround_hours,
                   calculate_effective_passenger_capacity(
                       m.capacity,
                       f.economy_seats,
                       f.business_seats,
                       f.first_class_seats
                   ) AS passenger_capacity,
                   org.demand_index AS org_demand,
                   org.airport_tax AS org_tax,
                   dst.demand_index AS dst_demand,
                   dst.airport_tax AS dst_tax
            FROM user_routes r
            JOIN user_fleet f ON r.assigned_aircraft_id = f.id
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            JOIN airports org ON r.origin_iata = org.iata
            JOIN airports dst ON r.destination_iata = dst.iata
            WHERE r.ai_competitor_id = r_bot.id
        LOOP
            IF COALESCE(v_route.status, 'grounded') != 'active'
               OR COALESCE(v_route.condition, 0.00) < v_effective_grounding_threshold THEN
                CONTINUE;
            END IF;
            v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
            v_flight_duration := COALESCE((v_route.distance_km / NULLIF(v_route.speed_kmh, 0)), 0.0) + v_turnaround_hours;
            v_flights := COALESCE(v_game_days * (v_route.flights_per_week / 7.0), 0.0);
            IF v_flights > 0.0001 THEN
                v_passengers := calculate_route_expected_passengers(
                    COALESCE(v_route.passenger_capacity, 0),
                    COALESCE(v_route.distance_km, 0.0),
                    COALESCE(v_route.ticket_price, 0.00),
                    COALESCE(v_route.org_demand, 50),
                    COALESCE(v_route.dst_demand, 50),
                    v_route.origin_iata,
                    v_route.destination_iata,
                    r_bot.id
                );
                SELECT COALESCE(
                    (SELECT effect_value FROM game_events
                     WHERE effect_type = 'demand_index' AND effect_target = v_route.origin_iata
                       AND is_active = true
                       AND start_game_time <= p_target_game_time
                       AND end_game_time > p_target_game_time
                     ORDER BY start_game_time DESC LIMIT 1),
                    1.0
                ) INTO v_demand_multiplier;
                v_passengers := GREATEST(0, FLOOR(v_passengers * v_demand_multiplier * v_seasonal_multiplier));
                v_total_seats := COALESCE(v_route.economy_seats, 0)
                               + COALESCE(v_route.business_seats, 0)
                               + COALESCE(v_route.first_class_seats, 0);
                IF v_total_seats > 0 THEN
                    v_economy_pax := v_passengers * (v_route.economy_seats::NUMERIC / v_total_seats);
                    v_business_pax := v_passengers * (v_route.business_seats::NUMERIC / v_total_seats);
                    v_first_pax := v_passengers * (v_route.first_class_seats::NUMERIC / v_total_seats);
                    v_business_demand := GREATEST(0.0, 1.2 - 0.5 * POWER(1.0, 2));
                    v_first_demand    := GREATEST(0.0, 1.5 - 0.8 * POWER(1.0, 2));
                    v_business_pax := v_business_pax * v_business_demand;
                    v_first_pax    := v_first_pax * v_first_demand;
                    v_revenue := COALESCE(v_flights * (
                        (v_economy_pax * v_route.ticket_price) +
                        (v_business_pax * v_route.ticket_price * 2.5) +
                        (v_first_pax * v_route.ticket_price * 4.0)
                    ), 0.00);
                ELSE
                    v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
                END IF;
                v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier, 0.00);
                v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
                v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
                v_crew_cost := COALESCE(v_flights * v_flight_duration * v_crew_cost_per_hour, 0.00);
                v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost + v_crew_cost);
                v_max_weekly_flights := calculate_route_max_weekly_flights(
                    COALESCE(v_route.distance_km, 0.0),
                    COALESCE(v_route.speed_kmh, 0),
                    v_turnaround_hours
                );
                v_unused_slots := GREATEST(0, COALESCE(v_max_weekly_flights, 0) - COALESCE(v_route.flights_per_week, 0));
                v_maintenance_hours := COALESCE(v_unused_slots, 0) * v_flight_duration * (v_game_days / 7.0);
                v_wear_per_cycle := CASE
                    WHEN COALESCE(v_route.acquisition_type, 'purchase') = 'lease' THEN 0.70
                    ELSE 0.50
                END;
                v_gross_damage := COALESCE(v_flights, 0.0) * v_wear_per_cycle;
                v_self_healing_credit := COALESCE(v_maintenance_hours, 0.0) * 0.85;
                v_net_damage := GREATEST(0.00, v_gross_damage - v_self_healing_credit);
                v_fleet_total_flights := COALESCE(v_route.total_flights, 0) + ROUND(v_flights)::INT;
                v_fleet_last_a_check := COALESCE(v_route.last_a_check_at, 0);
                v_fleet_last_c_check := COALESCE(v_route.last_c_check_at, 0);
                IF v_fleet_total_flights >= v_fleet_last_a_check + 500 THEN
                    v_net_damage := v_net_damage + 10.0;
                    v_fleet_last_a_check := v_fleet_total_flights;
                END IF;
                IF v_fleet_total_flights >= v_fleet_last_c_check + 3000 THEN
                    v_net_damage := v_net_damage + 25.0;
                    v_fleet_last_c_check := v_fleet_total_flights;
                END IF;
                UPDATE user_fleet
                SET condition = GREATEST(0.00, condition - v_net_damage),
                    total_flights = v_fleet_total_flights,
                    last_a_check_at = v_fleet_last_a_check,
                    last_c_check_at = v_fleet_last_c_check
                WHERE id = v_route.fleet_aircraft_id;
                UPDATE user_fleet
                SET status = 'grounded'
                WHERE id = v_route.fleet_aircraft_id
                  AND condition < v_effective_grounding_threshold;
                v_total_revenue := v_total_revenue + v_revenue;
                v_total_cost_accum := v_total_cost_accum + v_total_cost;
            END IF;
        END LOOP;
        v_total_revenue := GREATEST(0.00, COALESCE(v_total_revenue, 0.00));
        v_total_cost_accum := GREATEST(0.00, COALESCE(v_total_cost_accum, 0.00));
        v_net := v_total_revenue - v_total_cost_accum - v_lease_cost;
        v_buffered_rev_accum := COALESCE(r_bot.buffered_revenue, 0.00) + v_total_revenue;
        v_buffered_ops_accum := COALESCE(r_bot.buffered_ops_cost, 0.00) + v_total_cost_accum;
        v_buffered_lease_accum := COALESCE(r_bot.buffered_lease_cost, 0.00) + v_lease_cost;
        IF date_trunc('day', p_target_game_time) > date_trunc('day', r_bot.game_current_time) THEN
            IF v_buffered_rev_accum > 0 THEN
                INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                VALUES (r_bot.id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active bot routes', date_trunc('day', p_target_game_time));
            END IF;
            IF v_buffered_ops_accum > 0 THEN
                INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                VALUES (r_bot.id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew, maintenance, & airport landing fees', date_trunc('day', p_target_game_time));
            END IF;
            IF v_buffered_lease_accum > 0 THEN
                INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                VALUES (r_bot.id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active bot fleet', date_trunc('day', p_target_game_time));
            END IF;
            DELETE FROM financial_ledger
            WHERE ai_competitor_id = r_bot.id
              AND game_date < (p_target_game_time - INTERVAL '30 days');
            -- Process bot loan payments at game-day boundary
            PERFORM process_bot_loan_payments(r_bot.id, p_target_game_time);
            v_buffered_rev_accum := 0.00;
            v_buffered_ops_accum := 0.00;
            v_buffered_lease_accum := 0.00;
        END IF;
        UPDATE ai_competitors
        SET cash = cash + v_net,
            game_current_time = p_target_game_time,
            last_active_at = NOW(),
            buffered_revenue = v_buffered_rev_accum,
            buffered_ops_cost = v_buffered_ops_accum,
            buffered_lease_cost = v_buffered_lease_accum
        WHERE id = r_bot.id;
        v_processed := v_processed + 1;
    END LOOP;
    IF v_processed > 0 THEN
        PERFORM execute_bot_decisions();
    END IF;
    RETURN v_processed;
END;
$function$;
