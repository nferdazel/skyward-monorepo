-- ============================================================================
-- SKYWARD CRITICAL SECURITY AND DATA INTEGRITY FIXES
-- ============================================================================
-- Addresses five critical issues discovered during security audit:
--
-- FIX 1: Financial Race Condition
--   purchase_aircraft, lease_aircraft, and repair_aircraft read users.cash
--   without FOR UPDATE, allowing concurrent requests to overdraft.
--
-- FIX 2: Route Distance Validation
--   create_route accepts p_distance_km from the client without server-side
--   validation. Adds Haversine distance computation and 10% tolerance check.
--
-- FIX 3: Bot Bankruptcy Audit Trail
--   execute_bot_decisions DELETEs all bot data on bankruptcy. Changes to
--   soft-delete (status = 'Bankrupt') so fleet/routes/ledger are preserved.
--
-- FIX 4: Missing RLS Policies
--   data_retention_policy, ai_competitors, and season_clock have RLS enabled
--   but no SELECT policies for authenticated users.
--
-- FIX 5: Missing Performance Indexes
--   Adds indexes on user_fleet.user_id, financial_ledger(user_id, game_date),
--   and user_routes.assigned_aircraft_id for common query patterns.
-- ============================================================================


-- ============================================================================
-- FIX 1: Financial Race Condition — Add FOR UPDATE to cash reads
-- ============================================================================

CREATE OR REPLACE FUNCTION purchase_aircraft(
    p_user_id UUID,
    p_model_id UUID,
    p_nickname VARCHAR,
    p_economy_seats INT DEFAULT NULL,
    p_business_seats INT DEFAULT 0,
    p_first_class_seats INT DEFAULT 0
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_cash NUMERIC;
    v_price NUMERIC;
    v_model_name VARCHAR;
    v_capacity INT;
    v_hq_iata VARCHAR(3);
    v_tail VARCHAR(20);
    v_economy INT;
    v_business INT;
    v_first INT;
    v_slots_used INT;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT cash, hq_airport_iata
    INTO v_cash, v_hq_iata
    FROM users
    WHERE id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC;
        RETURN;
    END IF;

    SELECT purchase_price, model_name, capacity
    INTO v_price, v_model_name, v_capacity
    FROM aircraft_models
    WHERE id = p_model_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash;
        RETURN;
    END IF;

    v_economy := COALESCE(p_economy_seats, v_capacity);
    v_business := COALESCE(p_business_seats, 0);
    v_first := COALESCE(p_first_class_seats, 0);
    v_slots_used := v_economy + (v_business * 2) + (v_first * 3);

    IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
        RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash;
        RETURN;
    END IF;

    IF v_cash < v_price THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds to purchase ' || v_model_name || '.')::VARCHAR, v_cash;
        RETURN;
    END IF;

    LOOP
        v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
        EXIT WHEN NOT EXISTS (SELECT 1 FROM user_fleet WHERE tail_number = v_tail);
    END LOOP;

    UPDATE users
    SET cash = cash - v_price
    WHERE id = p_user_id
    RETURNING cash INTO v_cash;

    INSERT INTO user_fleet (
        user_id,
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
        p_user_id,
        p_model_id,
        TRIM(p_nickname),
        'purchase',
        100.00,
        'active',
        v_tail,
        v_economy,
        v_business,
        v_first
    );

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        p_user_id,
        'expense',
        'aircraft_purchase',
        v_price,
        'Purchased aircraft ' || v_model_name || ' with Call Sign: ' || TRIM(p_nickname) || ' (Tail: ' || v_tail || ')',
        (SELECT game_current_time FROM users WHERE id = p_user_id)
    );

    RETURN QUERY SELECT TRUE, ('Successfully purchased ' || v_model_name || '!')::VARCHAR, v_cash;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION lease_aircraft(
    p_user_id UUID,
    p_model_id UUID,
    p_nickname VARCHAR,
    p_economy_seats INT DEFAULT NULL,
    p_business_seats INT DEFAULT 0,
    p_first_class_seats INT DEFAULT 0
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_cash NUMERIC;
    v_lease_price NUMERIC;
    v_model_name VARCHAR;
    v_capacity INT;
    v_hq_iata VARCHAR(3);
    v_tail VARCHAR(20);
    v_deposit_pct NUMERIC;
    v_lease_deposit NUMERIC;
    v_economy INT;
    v_business INT;
    v_first INT;
    v_slots_used INT;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT cash, hq_airport_iata
    INTO v_cash, v_hq_iata
    FROM users
    WHERE id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC;
        RETURN;
    END IF;

    SELECT lease_price_per_month, model_name, capacity
    INTO v_lease_price, v_model_name, v_capacity
    FROM aircraft_models
    WHERE id = p_model_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash;
        RETURN;
    END IF;

    SELECT base_lease_deposit_percentage
    INTO v_deposit_pct
    FROM global_game_settings
    LIMIT 1;
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
    v_lease_deposit := v_lease_price * (v_deposit_pct * 10.0);

    v_economy := COALESCE(p_economy_seats, v_capacity);
    v_business := COALESCE(p_business_seats, 0);
    v_first := COALESCE(p_first_class_seats, 0);
    v_slots_used := v_economy + (v_business * 2) + (v_first * 3);

    IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
        RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash;
        RETURN;
    END IF;

    IF v_cash < v_lease_deposit THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds for lease down payment of ' || v_model_name || '. Required: $' || ROUND(v_lease_deposit, 2))::VARCHAR, v_cash;
        RETURN;
    END IF;

    LOOP
        v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
        EXIT WHEN NOT EXISTS (SELECT 1 FROM user_fleet WHERE tail_number = v_tail);
    END LOOP;

    UPDATE users
    SET cash = cash - v_lease_deposit
    WHERE id = p_user_id
    RETURNING cash INTO v_cash;

    INSERT INTO user_fleet (
        user_id,
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
        p_user_id,
        p_model_id,
        TRIM(p_nickname),
        'lease',
        100.00,
        'active',
        v_tail,
        v_economy,
        v_business,
        v_first
    );

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        p_user_id,
        'expense',
        'aircraft_lease',
        v_lease_deposit,
        'Leased aircraft ' || v_model_name || ' with Call Sign: ' || TRIM(p_nickname) || ' - Initial deposit (Tail: ' || v_tail || ')',
        (SELECT game_current_time FROM users WHERE id = p_user_id)
    );

    RETURN QUERY SELECT TRUE, ('Successfully leased ' || v_model_name || '!')::VARCHAR, v_cash;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION repair_aircraft(
    p_user_id UUID,
    p_fleet_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_cash NUMERIC;
    v_condition NUMERIC;
    v_purchase_price NUMERIC;
    v_lease_price NUMERIC;
    v_model_name VARCHAR;
    v_repair_cost NUMERIC;
    v_acquisition_type VARCHAR;
BEGIN
    SELECT
        f.condition,
        f.acquisition_type,
        m.purchase_price,
        m.lease_price_per_month,
        m.model_name
    INTO
        v_condition,
        v_acquisition_type,
        v_purchase_price,
        v_lease_price,
        v_model_name
    FROM user_fleet f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id;

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id FOR UPDATE;

    IF v_model_name IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, v_cash;
        RETURN;
    END IF;

    IF v_condition >= 100.00 THEN
        RETURN QUERY SELECT FALSE, ('Aircraft ' || v_model_name || ' is already in pristine condition.')::VARCHAR, v_cash;
        RETURN;
    END IF;

    v_repair_cost := CASE
        WHEN v_acquisition_type = 'lease'
            THEN (100.00 - v_condition) * (COALESCE(v_lease_price, 0.00) * 0.50)
        ELSE (100.00 - v_condition) * (COALESCE(v_purchase_price, 0.00) * 0.0005)
    END;

    IF v_cash < v_repair_cost THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds for repair. Required: $' || ROUND(v_repair_cost, 2))::VARCHAR, v_cash;
        RETURN;
    END IF;

    UPDATE users
    SET cash = cash - v_repair_cost
    WHERE id = p_user_id
    RETURNING cash INTO v_cash;

    UPDATE user_fleet
    SET condition = 100.00,
        status = 'active'
    WHERE id = p_fleet_id;

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        p_user_id,
        'expense',
        'aircraft_repair',
        v_repair_cost,
        'Maintenance check completed for ' || v_model_name || ' - restored condition from ' || ROUND(v_condition::numeric, 2) || '% to 100%',
        (SELECT game_current_time FROM users WHERE id = p_user_id)
    );

    RETURN QUERY SELECT TRUE, 'Aircraft maintenance complete. Health restored to 100%!'::VARCHAR, v_cash;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- FIX 2: Route Distance Validation — Server-side Haversine
-- ============================================================================

CREATE OR REPLACE FUNCTION haversine_distance(
    lat1 NUMERIC,
    lon1 NUMERIC,
    lat2 NUMERIC,
    lon2 NUMERIC
)
RETURNS NUMERIC AS $$
DECLARE
    R NUMERIC := 6371; -- Earth radius in km
    dlat NUMERIC;
    dlon NUMERIC;
    a NUMERIC;
    c NUMERIC;
BEGIN
    dlat := radians(lat2 - lat1);
    dlon := radians(lon2 - lon1);
    a := sin(dlat/2)^2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon/2)^2;
    c := 2 * atan2(sqrt(a), sqrt(1-a));
    RETURN R * c;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


CREATE OR REPLACE FUNCTION create_route(
    p_user_id UUID,
    p_origin_iata VARCHAR,
    p_destination_iata VARCHAR,
    p_distance_km NUMERIC,
    p_ticket_price NUMERIC,
    p_flights_per_week INT
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_actual_distance NUMERIC;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    IF p_origin_iata = p_destination_iata THEN
        RETURN QUERY SELECT FALSE, 'Origin and destination must be different.'::VARCHAR;
        RETURN;
    END IF;

    IF p_distance_km <= 0 OR p_ticket_price <= 0 OR p_flights_per_week < 1 OR p_flights_per_week > 168 THEN
        RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_origin_iata)
       OR NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_destination_iata) THEN
        RETURN QUERY SELECT FALSE, 'Route airport not found.'::VARCHAR;
        RETURN;
    END IF;

    -- Server-side distance validation: compute actual Haversine distance
    SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude)
    INTO v_actual_distance
    FROM airports o, airports d
    WHERE o.iata = p_origin_iata AND d.iata = p_destination_iata;

    -- Reject if client-reported distance deviates more than 10% from actual
    IF v_actual_distance > 0 AND ABS(p_distance_km - v_actual_distance) / v_actual_distance > 0.10 THEN
        RETURN QUERY SELECT FALSE, ('Distance validation failed. Expected ~' || ROUND(v_actual_distance, 1)::TEXT || ' km.')::VARCHAR;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM user_routes
        WHERE user_id = p_user_id
          AND origin_iata = p_origin_iata
          AND destination_iata = p_destination_iata
    ) THEN
        RETURN QUERY SELECT FALSE, 'Route already exists.'::VARCHAR;
        RETURN;
    END IF;

    INSERT INTO user_routes (
        user_id,
        origin_iata,
        destination_iata,
        distance_km,
        ticket_price,
        flights_per_week
    )
    VALUES (
        p_user_id,
        p_origin_iata,
        p_destination_iata,
        p_distance_km,
        p_ticket_price,
        p_flights_per_week
    );

    RETURN QUERY SELECT TRUE, 'Route established successfully!'::VARCHAR;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- FIX 3: Bot Bankruptcy — Status Instead of DELETE
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

        -- Soft-delete: mark bankrupt instead of destroying audit data
        IF r_bot.status = 'Bankrupt' OR v_bot_cash < -5000000.00 THEN
            UPDATE ai_competitors SET status = 'Bankrupt' WHERE id = r_bot.id;
            UPDATE user_fleet SET status = 'grounded' WHERE ai_competitor_id = r_bot.id;
            -- Note: Do NOT delete routes, fleet, or ledger — keep for audit
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
                            ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2),
                            ROUND((ticket_price * 0.90)::numeric, 2)
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


-- ============================================================================
-- FIX 4: Missing RLS Policies
-- ============================================================================
-- These tables have RLS enabled (migration 67) and GRANT SELECT to
-- authenticated, but were missing the USING clause that actually permits
-- the read. Without a policy the GRANT is ineffective.

DROP POLICY IF EXISTS data_retention_policy_select_authenticated ON public.data_retention_policy;
CREATE POLICY data_retention_policy_select_authenticated
ON public.data_retention_policy
FOR SELECT TO authenticated
USING (true);

DROP POLICY IF EXISTS ai_competitors_select_authenticated ON public.ai_competitors;
CREATE POLICY ai_competitors_select_authenticated
ON public.ai_competitors
FOR SELECT TO authenticated
USING (true);

DROP POLICY IF EXISTS season_clock_select_authenticated ON public.season_clock;
CREATE POLICY season_clock_select_authenticated
ON public.season_clock
FOR SELECT TO authenticated
USING (true);


-- ============================================================================
-- FIX 5: Missing Performance Indexes
-- ============================================================================

-- user_fleet: join/filter on user_id is the most common access pattern
CREATE INDEX IF NOT EXISTS user_fleet_user_id_idx
    ON user_fleet(user_id);

-- financial_ledger: player dashboard queries filter by user + date range
CREATE INDEX IF NOT EXISTS financial_ledger_user_game_date_idx
    ON financial_ledger(user_id, game_date DESC);

-- user_routes: the assign_aircraft_to_route check queries for existing
-- assignments; partial index avoids bloating on NULL rows
CREATE INDEX IF NOT EXISTS user_routes_assigned_aircraft_id_idx
    ON user_routes(assigned_aircraft_id)
    WHERE assigned_aircraft_id IS NOT NULL;
