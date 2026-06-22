-- ============================================================================
-- SKYWARD PHASE 1 RPC WRITE BOUNDARY
-- ============================================================================
-- Moves remaining simulation-sensitive client writes behind RPCs.
-- Each command catches the player up first so route, fleet, and settings changes
-- are applied against the latest authoritative backend state.
-- ============================================================================

DROP FUNCTION IF EXISTS purchase_aircraft(UUID, UUID, VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS purchase_aircraft(UUID, UUID, VARCHAR, INT, INT, INT) CASCADE;

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
    WHERE id = p_user_id;

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


DROP FUNCTION IF EXISTS lease_aircraft(UUID, UUID, VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS lease_aircraft(UUID, UUID, VARCHAR, INT, INT, INT) CASCADE;

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
    WHERE id = p_user_id;

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


CREATE OR REPLACE FUNCTION configure_aircraft_seats(
    p_user_id UUID,
    p_fleet_id UUID,
    p_economy_seats INT,
    p_business_seats INT,
    p_first_class_seats INT
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_capacity INT;
    v_slots_used INT;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT m.capacity
    INTO v_capacity
    FROM user_fleet f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id
      AND f.user_id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR;
        RETURN;
    END IF;

    v_slots_used := p_economy_seats + (p_business_seats * 2) + (p_first_class_seats * 3);
    IF p_economy_seats < 0 OR p_business_seats < 0 OR p_first_class_seats < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
        RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR;
        RETURN;
    END IF;

    UPDATE user_fleet
    SET economy_seats = p_economy_seats,
        business_seats = p_business_seats,
        first_class_seats = p_first_class_seats
    WHERE id = p_fleet_id
      AND user_id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Successfully updated seat configuration!'::VARCHAR;
END;
$$ LANGUAGE plpgsql;


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


CREATE OR REPLACE FUNCTION assign_aircraft_to_route(
    p_user_id UUID,
    p_route_id UUID,
    p_aircraft_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_current_aircraft_id UUID;
    v_effective_threshold NUMERIC(5,2);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT assigned_aircraft_id
    INTO v_current_aircraft_id
    FROM user_routes
    WHERE id = p_route_id
      AND user_id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR;
        RETURN;
    END IF;

    IF p_aircraft_id IS NOT NULL THEN
        SELECT GREATEST(
            COALESCE(u.auto_grounding_threshold, 40.00),
            COALESCE(g.absolute_minimum_safety_limit, 30.00)
        )
        INTO v_effective_threshold
        FROM users u
        CROSS JOIN global_game_settings g
        WHERE u.id = p_user_id
        LIMIT 1;

        IF NOT EXISTS (
            SELECT 1
            FROM user_fleet
            WHERE id = p_aircraft_id
              AND user_id = p_user_id
              AND condition >= COALESCE(v_effective_threshold, 40.00)
        ) THEN
            RETURN QUERY SELECT FALSE, 'Aircraft is unavailable or below the safety threshold.'::VARCHAR;
            RETURN;
        END IF;

        IF EXISTS (
            SELECT 1
            FROM user_routes
            WHERE user_id = p_user_id
              AND assigned_aircraft_id = p_aircraft_id
              AND id <> p_route_id
        ) THEN
            RETURN QUERY SELECT FALSE, 'Aircraft is already assigned to another route.'::VARCHAR;
            RETURN;
        END IF;
    END IF;

    UPDATE user_routes
    SET assigned_aircraft_id = p_aircraft_id
    WHERE id = p_route_id
      AND user_id = p_user_id;

    IF p_aircraft_id IS NOT NULL THEN
        UPDATE user_fleet
        SET status = 'active'
        WHERE id = p_aircraft_id
          AND user_id = p_user_id;
    END IF;

    RETURN QUERY SELECT TRUE, 'Aircraft assignment updated successfully!'::VARCHAR;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION update_route_frequency_and_price(
    p_user_id UUID,
    p_route_id UUID,
    p_ticket_price NUMERIC,
    p_flights_per_week INT
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    IF p_ticket_price <= 0 OR p_flights_per_week < 1 OR p_flights_per_week > 168 THEN
        RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR;
        RETURN;
    END IF;

    UPDATE user_routes
    SET ticket_price = p_ticket_price,
        flights_per_week = p_flights_per_week
    WHERE id = p_route_id
      AND user_id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR;
        RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, 'Route frequency and pricing adjusted!'::VARCHAR;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION delete_route(
    p_user_id UUID,
    p_route_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_assigned_aircraft_id UUID;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT assigned_aircraft_id
    INTO v_assigned_aircraft_id
    FROM user_routes
    WHERE id = p_route_id
      AND user_id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR;
        RETURN;
    END IF;

    IF v_assigned_aircraft_id IS NOT NULL THEN
        UPDATE user_fleet
        SET status = 'grounded'
        WHERE id = v_assigned_aircraft_id
          AND user_id = p_user_id;
    END IF;

    DELETE FROM user_routes
    WHERE id = p_route_id
      AND user_id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Route closed and aircraft grounded successfully!'::VARCHAR;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION save_airline_settings(
    p_user_id UUID,
    p_company_name VARCHAR,
    p_auto_grounding_threshold NUMERIC,
    p_hq_airport_iata VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    IF p_auto_grounding_threshold < 30.00 OR p_auto_grounding_threshold > 100.00 THEN
        RETURN QUERY SELECT FALSE, 'Safety threshold must be between 30 and 100.'::VARCHAR;
        RETURN;
    END IF;

    IF p_hq_airport_iata IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_hq_airport_iata) THEN
        RETURN QUERY SELECT FALSE, 'HQ airport not found.'::VARCHAR;
        RETURN;
    END IF;

    UPDATE users
    SET company_name = TRIM(p_company_name),
        auto_grounding_threshold = p_auto_grounding_threshold,
        hq_airport_iata = p_hq_airport_iata
    WHERE id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR;
        RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, 'Settings saved successfully.'::VARCHAR;
END;
$$ LANGUAGE plpgsql;
