-- ============================================================================
-- SKYWARD BOT COMPETITIVENESS PASS
-- ============================================================================
-- Improves bot differentiation and cleans legacy bot route state:
--   1. Recalculates existing bot route distances from airport geometry.
--   2. Gives each archetype a distinct stage-length, demand, fare, and
--      schedule doctrine.
--   3. Retunes existing routes gradually instead of leaving stale settings in
--      place forever.
--   4. Makes distress cuts based on route contribution proxy, not only price.
-- ============================================================================

UPDATE user_routes r
SET distance_km = 6371.0 * 2 * ASIN(
    SQRT(
        POWER(SIN(RADIANS(dst.latitude - org.latitude) / 2), 2) +
        COS(RADIANS(org.latitude)) * COS(RADIANS(dst.latitude)) *
        POWER(SIN(RADIANS(dst.longitude - org.longitude) / 2), 2)
    )
)
FROM airports org, airports dst
WHERE r.ai_competitor_id IS NOT NULL
  AND org.iata = r.origin_iata
  AND dst.iata = r.destination_iata;


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
    v_stage_min DOUBLE PRECISION;
    v_stage_max DOUBLE PRECISION;
    v_min_demand INT;
    v_effective_threshold NUMERIC(5,2);
    v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00;
    v_selected_route_id UUID;
    v_selected_flights INT;
    v_selected_base_fare NUMERIC;
    v_selected_distance DOUBLE PRECISION;
    v_selected_speed NUMERIC;
    v_selected_org_demand INT;
    v_selected_dst_demand INT;
    v_selected_capacity INT;
    v_selected_fuel NUMERIC;
    v_selected_maint NUMERIC;
    v_selected_org_tax NUMERIC;
    v_selected_dst_tax NUMERIC;
    v_max_weekly_flights INT;
    v_target_flights INT;
    v_target_price NUMERIC;
    v_bot_cash NUMERIC;
    v_grounded_count INT;
    v_negative_days INT;
    v_monthly_lease_burden NUMERIC(20,2);
    v_distress_cash_floor NUMERIC(20,2);
    v_avg_demand NUMERIC;
    v_route_duration DOUBLE PRECISION;
    v_route_direct_cost NUMERIC;
    v_route_contribution NUMERIC;
    v_demand_adjustment NUMERIC;
BEGIN
    SELECT base_lease_deposit_percentage
    INTO v_deposit_pct
    FROM global_game_settings
    LIMIT 1;
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);

    FOR r_bot IN SELECT * FROM ai_competitors LOOP
        v_bot_cash := COALESCE(r_bot.cash, 0.00);
        v_origin_iata := r_bot.hq_airport_iata;
        v_effective_threshold := GREATEST(
            v_absolute_minimum_safety_limit,
            COALESCE(r_bot.auto_grounding_threshold, 40.00)
        );

        SELECT COALESCE(SUM(m.lease_price_per_month), 0.00)
        INTO v_monthly_lease_burden
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.ai_competitor_id = r_bot.id
          AND f.acquisition_type = 'lease';

        v_distress_cash_floor := GREATEST(
            3000000.00,
            COALESCE(v_monthly_lease_burden, 0.00) * 2.00
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
                v_target_fleet_cap := 9;
                v_min_cash_reserve := 4500000.00;
                v_growth_chance := 0.16;
                v_target_distance := 850.0;
                v_target_price_multiplier := 0.93;
                v_target_schedule_ratio := 0.76;
                v_stage_min := 250.0;
                v_stage_max := 1600.0;
                v_min_demand := 40;
            WHEN 'Aggressive' THEN
                v_target_fleet_cap := 15;
                v_min_cash_reserve := 6000000.00;
                v_growth_chance := 0.24;
                v_target_distance := 1800.0;
                v_target_price_multiplier := 0.98;
                v_target_schedule_ratio := 0.84;
                v_stage_min := 700.0;
                v_stage_max := 3600.0;
                v_min_demand := 55;
            ELSE
                v_target_fleet_cap := 10;
                v_min_cash_reserve := 8500000.00;
                v_growth_chance := 0.11;
                v_target_distance := 4200.0;
                v_target_price_multiplier := 1.12;
                v_target_schedule_ratio := 0.55;
                v_stage_min := 2500.0;
                v_stage_max := 7200.0;
                v_min_demand := 68;
        END CASE;

        SELECT COUNT(*)::INT
        INTO v_fleet_count
        FROM user_fleet
        WHERE ai_competitor_id = r_bot.id;

        SELECT COUNT(*)::INT
        INTO v_route_count
        FROM user_routes
        WHERE ai_competitor_id = r_bot.id;

        SELECT COUNT(*)::INT
        INTO v_idle_aircraft_count
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
                    THEN (100.00 - v_grounded_condition) *
                        (COALESCE(v_grounded_lease_price, 0.00) * 0.50)
                ELSE (100.00 - v_grounded_condition) *
                    (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005)
            END;

            IF v_repair_cost > 0
               AND v_bot_cash >= (
                   v_repair_cost +
                   GREATEST(500000.00, COALESCE(v_monthly_lease_burden, 0.00) * 0.30)
               ) THEN
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

        -- Retune one active route each cycle so old routes drift toward the
        -- archetype doctrine instead of keeping stale frequencies/prices forever.
        SELECT
            r.id,
            r.flights_per_week,
            calculate_route_base_fare(r.distance_km),
            r.distance_km,
            m.speed_kmh,
            org.demand_index,
            dst.demand_index,
            m.capacity,
            m.fuel_burn_per_km,
            m.maintenance_cost_per_hour,
            org.airport_tax,
            dst.airport_tax
        INTO
            v_selected_route_id,
            v_selected_flights,
            v_selected_base_fare,
            v_selected_distance,
            v_selected_speed,
            v_selected_org_demand,
            v_selected_dst_demand,
            v_selected_capacity,
            v_selected_fuel,
            v_selected_maint,
            v_selected_org_tax,
            v_selected_dst_tax
        FROM user_routes r
        JOIN user_fleet f ON r.assigned_aircraft_id = f.id
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        JOIN airports org ON r.origin_iata = org.iata
        JOIN airports dst ON r.destination_iata = dst.iata
        WHERE r.ai_competitor_id = r_bot.id
        ORDER BY
            ABS(r.distance_km - v_target_distance),
            ABS(
                (r.ticket_price / NULLIF(calculate_route_base_fare(r.distance_km), 0.00)) -
                v_target_price_multiplier
            ) DESC
        LIMIT 1;

        IF v_selected_route_id IS NOT NULL AND COALESCE(v_selected_speed, 0) > 0 THEN
            v_avg_demand := (
                COALESCE(v_selected_org_demand, 50) +
                COALESCE(v_selected_dst_demand, 50)
            )::NUMERIC / 2.0;
            v_demand_adjustment := GREATEST(-0.06, LEAST(0.08, (v_avg_demand - 60.0) / 250.0));
            v_route_duration := (v_selected_distance / v_selected_speed) + 1.0;
            v_max_weekly_flights := GREATEST(1, FLOOR(168.0 / v_route_duration));
            v_target_flights := GREATEST(
                6,
                LEAST(
                    v_max_weekly_flights,
                    FLOOR(v_max_weekly_flights * (v_target_schedule_ratio + v_demand_adjustment))
                )
            );
            v_target_price := ROUND(
                (
                    v_selected_base_fare *
                    (v_target_price_multiplier + (v_demand_adjustment * 0.8))
                )::NUMERIC,
                2
            );

            UPDATE user_routes
            SET ticket_price = ROUND((((ticket_price * 0.60) + (v_target_price * 0.40)))::NUMERIC, 2),
                flights_per_week = GREATEST(
                    6,
                    LEAST(
                        v_max_weekly_flights,
                        ROUND(((flights_per_week * 0.55) + (v_target_flights * 0.45)))::INT
                    )
                )
            WHERE id = v_selected_route_id;
        END IF;

        -- Distressed bots cut the weakest routes first using a contribution proxy.
        IF v_bot_cash < v_distress_cash_floor
           OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN
            SELECT
                candidate.id,
                candidate.flights_per_week,
                candidate.base_fare,
                candidate.contribution
            INTO
                v_selected_route_id,
                v_selected_flights,
                v_selected_base_fare,
                v_route_contribution
            FROM (
                SELECT
                    r.id,
                    r.flights_per_week,
                    calculate_route_base_fare(r.distance_km) AS base_fare,
                    (
                        calculate_route_expected_passengers(
                            m.capacity,
                            r.distance_km,
                            r.ticket_price,
                            org.demand_index,
                            dst.demand_index
                        ) * r.ticket_price
                    ) - (
                        (r.distance_km * m.fuel_burn_per_km * COALESCE(g.fuel_price_per_liter, 0.85)) +
                        (((r.distance_km / NULLIF(m.speed_kmh, 0)) + 1.0) * m.maintenance_cost_per_hour) +
                        org.airport_tax + dst.airport_tax
                    ) AS contribution
                FROM user_routes r
                JOIN user_fleet f ON r.assigned_aircraft_id = f.id
                JOIN aircraft_models m ON f.aircraft_model_id = m.id
                JOIN airports org ON r.origin_iata = org.iata
                JOIN airports dst ON r.destination_iata = dst.iata
                CROSS JOIN (
                    SELECT fuel_price_per_liter FROM global_game_settings LIMIT 1
                ) g
                WHERE r.ai_competitor_id = r_bot.id
            ) candidate
            ORDER BY candidate.contribution ASC, candidate.flights_per_week DESC
            LIMIT 1;

            IF v_selected_route_id IS NOT NULL THEN
                IF COALESCE(v_route_contribution, 0.00) < 0.00 OR v_selected_flights <= 8 THEN
                    DELETE FROM user_routes WHERE id = v_selected_route_id;
                ELSE
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
                            ROUND((v_selected_base_fare * v_target_price_multiplier)::NUMERIC, 2),
                            ROUND((ticket_price * 0.92)::NUMERIC, 2)
                        )
                    WHERE id = v_selected_route_id;
                END IF;
            END IF;
        END IF;

        IF v_fleet_count < v_target_fleet_cap
           AND v_bot_cash > (
               v_min_cash_reserve + (COALESCE(v_monthly_lease_burden, 0.00) * 1.25)
           )
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

            IF v_model_id IS NOT NULL
               AND v_bot_cash >= (
                   v_deposit_amount + (COALESCE(v_monthly_lease_burden, 0.00) * 0.25)
               ) THEN
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
                  AND a.demand_index >= v_min_demand
                  AND NOT EXISTS (
                      SELECT 1
                      FROM user_routes r
                      WHERE r.ai_competitor_id = r_bot.id
                        AND r.origin_iata = v_origin_iata
                        AND r.destination_iata = a.iata
                  )
            ) candidate
            WHERE candidate.distance_km BETWEEN v_stage_min
                                            AND LEAST(COALESCE(v_idle_range, v_stage_max), v_stage_max)
            ORDER BY
                CASE
                    WHEN r_bot.archetype = 'Regional'
                        THEN (candidate.demand_index * 12.0) - ABS(candidate.distance_km - v_target_distance)
                    WHEN r_bot.archetype = 'Aggressive'
                        THEN (candidate.demand_index * 10.0) - (ABS(candidate.distance_km - v_target_distance) * 0.8)
                    ELSE (candidate.demand_index * 14.0) - (ABS(candidate.distance_km - v_target_distance) * 0.4)
                END DESC,
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
                      AND NOT EXISTS (
                          SELECT 1
                          FROM user_routes r
                          WHERE r.ai_competitor_id = r_bot.id
                            AND r.origin_iata = v_origin_iata
                            AND r.destination_iata = a.iata
                      )
                ) candidate
                WHERE candidate.distance_km <= COALESCE(v_idle_range, v_stage_max)
                ORDER BY candidate.demand_index DESC, random()
                LIMIT 1;
            END IF;

            IF v_dest_iata IS NOT NULL
               AND v_distance IS NOT NULL
               AND COALESCE(v_idle_speed, 0) > 0 THEN
                v_avg_demand := v_min_demand;
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
                    (calculate_route_base_fare(v_distance) * v_target_price_multiplier)::NUMERIC,
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

        SELECT COUNT(*)::INT
        INTO v_grounded_count
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
