-- ============================================================================
-- SKYWARD BOT OPERATIONAL QUALITY PASS
-- ============================================================================
-- Improves bot behavior so competitors do more than blindly lease and idle.
-- Adds:
-- - archetype-specific growth parameters
-- - idle-aircraft route deployment using real airport coordinates
-- - distress route cutbacks before bankruptcy
-- - paid grounded-aircraft recovery for bots
-- ============================================================================

CREATE OR REPLACE FUNCTION execute_bot_decisions()
RETURNS VOID AS $$
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
            DELETE FROM user_routes WHERE ai_competitor_id = r_bot.id;
            DELETE FROM user_fleet WHERE ai_competitor_id = r_bot.id;
            DELETE FROM financial_ledger WHERE ai_competitor_id = r_bot.id;
            DELETE FROM ai_competitors WHERE id = r_bot.id;
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

        -- Bots must pay to recover grounded airframes just like the player.
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

        -- Distressed bots cut weak routes before expanding again.
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
                            ROUND(v_selected_base_fare * v_target_price_multiplier, 2),
                            ROUND(ticket_price * 0.90, 2)
                        )
                    WHERE id = v_selected_route_id;
                ELSE
                    DELETE FROM user_routes WHERE id = v_selected_route_id;
                END IF;
            END IF;
        END IF;

        -- Healthy bots can expand fleet with archetype-specific aggression.
        IF v_fleet_count < v_target_fleet_cap
           AND v_bot_cash > v_min_cash_reserve
           AND COALESCE(r_bot.consecutive_negative_days, 0) = 0
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
                    v_capacity,
                    0,
                    0
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

        SELECT COUNT(*)::INT INTO v_fleet_count
        FROM user_fleet
        WHERE ai_competitor_id = r_bot.id;

        SELECT COUNT(*)::INT INTO v_route_count
        FROM user_routes
        WHERE ai_competitor_id = r_bot.id;

        -- Put idle aircraft to work with archetype-shaped route plans.
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
           AND v_bot_cash > (v_min_cash_reserve * 0.55)
           AND (v_route_count = 0 OR random() < 0.55) THEN
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
                v_target_price := ROUND((50.00 + (v_distance * 0.12)) * v_target_price_multiplier, 2);

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
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
