-- ============================================================================
-- SKYWARD ROUTE CONTRACT AND CABIN CAPACITY HARDENING
-- ============================================================================
-- 1. Makes cabin configuration affect effective passenger capacity in the
--    authoritative simulation for players and bots.
-- 2. Enforces route-assignment range checks and assigned-route weekly schedule
--    checks at the backend RPC boundary.
-- 3. Tightens finance snapshot "active route" counting to deployed routes.
-- ============================================================================

CREATE OR REPLACE FUNCTION calculate_effective_passenger_capacity(
    p_model_capacity INT,
    p_economy_seats INT,
    p_business_seats INT,
    p_first_class_seats INT
)
RETURNS INT AS $$
    SELECT GREATEST(
        0,
        COALESCE(
            NULLIF(
                COALESCE(p_economy_seats, 0) +
                COALESCE(p_business_seats, 0) +
                COALESCE(p_first_class_seats, 0),
                0
            ),
            COALESCE(p_model_capacity, 0)
        )
    );
$$ LANGUAGE sql IMMUTABLE;


CREATE OR REPLACE FUNCTION calculate_route_max_weekly_flights(
    p_distance_km DOUBLE PRECISION,
    p_speed_kmh INT
)
RETURNS INT AS $$
    SELECT CASE
        WHEN COALESCE(p_distance_km, 0.0) <= 0.0 OR COALESCE(p_speed_kmh, 0) <= 0 THEN 0
        ELSE FLOOR(
            168.0 /
            NULLIF((COALESCE(p_distance_km, 0.0) / p_speed_kmh::DOUBLE PRECISION) + 1.0, 0.0)
        )::INT
    END;
$$ LANGUAGE sql IMMUTABLE;


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
    v_route_distance_km DOUBLE PRECISION;
    v_route_flights_per_week INT;
    v_aircraft_range_km INT;
    v_aircraft_speed_kmh INT;
    v_max_weekly_flights INT;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT assigned_aircraft_id, distance_km, flights_per_week
    INTO v_current_aircraft_id, v_route_distance_km, v_route_flights_per_week
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

        SELECT
            m.range_km,
            m.speed_kmh
        INTO
            v_aircraft_range_km,
            v_aircraft_speed_kmh
        FROM user_fleet f
        JOIN aircraft_models m ON m.id = f.aircraft_model_id
        WHERE f.id = p_aircraft_id
          AND f.user_id = p_user_id
          AND f.condition >= COALESCE(v_effective_threshold, 40.00);

        IF NOT FOUND THEN
            RETURN QUERY SELECT FALSE, 'Aircraft is unavailable or below the safety threshold.'::VARCHAR;
            RETURN;
        END IF;

        IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN
            RETURN QUERY SELECT FALSE, 'Aircraft range is insufficient for this route.'::VARCHAR;
            RETURN;
        END IF;

        v_max_weekly_flights := calculate_route_max_weekly_flights(
            v_route_distance_km,
            v_aircraft_speed_kmh
        );
        IF v_max_weekly_flights > 0
           AND COALESCE(v_route_flights_per_week, 0) > v_max_weekly_flights THEN
            RETURN QUERY SELECT FALSE, 'Route frequency exceeds this aircraft''s weekly operating capacity.'::VARCHAR;
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
DECLARE
    v_route_distance_km DOUBLE PRECISION;
    v_assigned_aircraft_id UUID;
    v_aircraft_range_km INT;
    v_aircraft_speed_kmh INT;
    v_max_weekly_flights INT;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    IF p_ticket_price <= 0 OR p_flights_per_week < 1 OR p_flights_per_week > 168 THEN
        RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR;
        RETURN;
    END IF;

    SELECT distance_km, assigned_aircraft_id
    INTO v_route_distance_km, v_assigned_aircraft_id
    FROM user_routes
    WHERE id = p_route_id
      AND user_id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR;
        RETURN;
    END IF;

    IF v_assigned_aircraft_id IS NOT NULL THEN
        SELECT m.range_km, m.speed_kmh
        INTO v_aircraft_range_km, v_aircraft_speed_kmh
        FROM user_fleet f
        JOIN aircraft_models m ON m.id = f.aircraft_model_id
        WHERE f.id = v_assigned_aircraft_id
          AND f.user_id = p_user_id;

        IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN
            RETURN QUERY SELECT FALSE, 'Assigned aircraft range is insufficient for this route.'::VARCHAR;
            RETURN;
        END IF;

        v_max_weekly_flights := calculate_route_max_weekly_flights(
            v_route_distance_km,
            v_aircraft_speed_kmh
        );
        IF v_max_weekly_flights > 0 AND p_flights_per_week > v_max_weekly_flights THEN
            RETURN QUERY SELECT FALSE, 'Route frequency exceeds the assigned aircraft''s weekly operating capacity.'::VARCHAR;
            RETURN;
        END IF;
    END IF;

    UPDATE user_routes
    SET ticket_price = p_ticket_price,
        flights_per_week = p_flights_per_week
    WHERE id = p_route_id
      AND user_id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Route frequency and pricing adjusted!'::VARCHAR;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION process_player_simulation_to_time(
    p_user_id UUID,
    p_target_game_time TIMESTAMP WITH TIME ZONE
)
RETURNS TABLE (
    cash_before NUMERIC(20,2),
    cash_after NUMERIC(20,2),
    elapsed_real_sec DOUBLE PRECISION,
    elapsed_game_days DOUBLE PRECISION,
    flights_run INT
) AS $$
DECLARE
    r_user RECORD;
    v_game_sec DOUBLE PRECISION;
    v_game_days DOUBLE PRECISION;
    v_route RECORD;
    v_fleet RECORD;
    v_flights DOUBLE PRECISION;
    v_revenue NUMERIC(20,2) := 0;
    v_fuel_cost NUMERIC(20,2) := 0;
    v_maint_cost NUMERIC(20,2) := 0;
    v_tax_cost NUMERIC(20,2) := 0;
    v_total_cost NUMERIC(20,2) := 0;
    v_total_revenue NUMERIC(20,2) := 0;
    v_total_cost_accum NUMERIC(20,2) := 0;
    v_net NUMERIC(20,2) := 0;
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_completed_flights_all INT := 0;
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
    v_cash_after NUMERIC(20,2);
    v_grounded_count INT := 0;
    v_consecutive_negative_days INT := 0;
    v_recovery_streak_days INT := 0;
    v_new_status VARCHAR(20) := 'Active';
BEGIN
    SELECT *
    INTO r_user
    FROM users
    WHERE id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_game_sec := COALESCE(EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)), 0.0);

    IF v_game_sec < 1 THEN
        cash_before := r_user.cash;
        cash_after := r_user.cash;
        elapsed_real_sec := 0.0;
        elapsed_game_days := 0.0;
        flights_run := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT fuel_price_per_liter, absolute_minimum_safety_limit
    INTO v_fuel_price, v_absolute_minimum_safety_limit
    FROM global_game_settings
    LIMIT 1;

    v_fuel_price := COALESCE(v_fuel_price, 0.85);
    v_absolute_minimum_safety_limit := COALESCE(v_absolute_minimum_safety_limit, 30.00);
    v_game_days := v_game_sec / 86400.0;
    v_effective_grounding_threshold := GREATEST(
        COALESCE(r_user.auto_grounding_threshold, 40.00),
        v_absolute_minimum_safety_limit
    );

    FOR v_fleet IN
        SELECT f.*, m.lease_price_per_month
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.user_id = p_user_id AND f.acquisition_type = 'lease'
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
               m.capacity,
               m.speed_kmh,
               m.fuel_burn_per_km,
               m.maintenance_cost_per_hour,
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
        WHERE r.user_id = p_user_id
    LOOP
        IF COALESCE(v_route.status, 'grounded') != 'active'
           OR COALESCE(v_route.condition, 0.00) < v_effective_grounding_threshold THEN
            CONTINUE;
        END IF;

        v_flight_duration := COALESCE((v_route.distance_km / NULLIF(v_route.speed_kmh, 0)), 0.0) + 1.0;
        v_flights := COALESCE(v_game_days * (v_route.flights_per_week / 7.0), 0.0);

        IF v_flights > 0.0001 THEN
            v_passengers := calculate_route_expected_passengers(
                COALESCE(v_route.passenger_capacity, 0),
                COALESCE(v_route.distance_km, 0.0),
                COALESCE(v_route.ticket_price, 0.00),
                COALESCE(v_route.org_demand, 50),
                COALESCE(v_route.dst_demand, 50)
            );

            v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
            v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price, 0.00);
            v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
            v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
            v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost);

            v_max_weekly_flights := calculate_route_max_weekly_flights(
                COALESCE(v_route.distance_km, 0.0),
                COALESCE(v_route.speed_kmh, 0)
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

            UPDATE user_fleet
            SET condition = GREATEST(0.00, condition - v_net_damage)
            WHERE id = v_route.fleet_aircraft_id;

            UPDATE user_fleet
            SET status = 'grounded'
            WHERE id = v_route.fleet_aircraft_id
              AND condition < v_effective_grounding_threshold;

            v_total_revenue := v_total_revenue + v_revenue;
            v_total_cost_accum := v_total_cost_accum + v_total_cost;
            v_completed_flights_all := v_completed_flights_all + ROUND(v_flights)::INT;
        END IF;
    END LOOP;

    v_total_revenue := GREATEST(0.00, COALESCE(v_total_revenue, 0.00));
    v_total_cost_accum := GREATEST(0.00, COALESCE(v_total_cost_accum, 0.00));
    v_net := v_total_revenue - v_total_cost_accum - v_lease_cost;

    v_buffered_rev_accum := COALESCE(r_user.buffered_revenue, 0.00) + v_total_revenue;
    v_buffered_ops_accum := COALESCE(r_user.buffered_ops_cost, 0.00) + v_total_cost_accum;
    v_buffered_lease_accum := COALESCE(r_user.buffered_lease_cost, 0.00) + v_lease_cost;

    IF date_trunc('day', p_target_game_time) > date_trunc('day', r_user.game_current_time) THEN
        IF v_buffered_rev_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active routes', date_trunc('day', p_target_game_time));
        END IF;

        IF v_buffered_ops_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew maintenance, & landing fees', date_trunc('day', p_target_game_time));
        END IF;

        IF v_buffered_lease_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active fleet', date_trunc('day', p_target_game_time));
        END IF;

        DELETE FROM financial_ledger
        WHERE user_id = p_user_id
          AND game_date < (p_target_game_time - INTERVAL '30 days');

        v_buffered_rev_accum := 0.00;
        v_buffered_ops_accum := 0.00;
        v_buffered_lease_accum := 0.00;
    END IF;

    v_cash_after := r_user.cash + v_net;

    SELECT COUNT(*)::INT
    INTO v_grounded_count
    FROM user_fleet
    WHERE user_id = p_user_id
      AND (status = 'grounded' OR condition < v_effective_grounding_threshold);

    v_consecutive_negative_days := CASE
        WHEN v_net < 0.00 THEN COALESCE(r_user.consecutive_negative_days, 0) + 1
        ELSE 0
    END;

    v_recovery_streak_days := CASE
        WHEN COALESCE(r_user.operational_status, 'Active') IN ('Distress', 'Maintenance', 'Recovery')
             AND v_cash_after >= 0.00
             AND v_grounded_count = 0
             AND v_net >= 0.00
        THEN COALESCE(r_user.recovery_streak_days, 0) + 1
        ELSE 0
    END;

    v_new_status := CASE
        WHEN v_cash_after < 0.00 OR v_consecutive_negative_days >= 2 THEN 'Distress'
        WHEN v_grounded_count > 0 THEN 'Maintenance'
        WHEN v_recovery_streak_days > 0 THEN 'Recovery'
        ELSE 'Active'
    END;

    IF v_recovery_streak_days >= 3 THEN
        v_new_status := 'Active';
        v_recovery_streak_days := 0;
    END IF;

    UPDATE users
    SET cash = v_cash_after,
        game_current_time = p_target_game_time,
        last_active_at = NOW(),
        buffered_revenue = v_buffered_rev_accum,
        buffered_ops_cost = v_buffered_ops_accum,
        buffered_lease_cost = v_buffered_lease_accum,
        operational_status = v_new_status,
        consecutive_negative_days = v_consecutive_negative_days,
        recovery_streak_days = v_recovery_streak_days
    WHERE id = p_user_id;

    cash_before := r_user.cash;
    cash_after := v_cash_after;
    elapsed_real_sec := 0.0;
    elapsed_game_days := v_game_days;
    flights_run := v_completed_flights_all;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION process_all_bots_simulation_to_time(
    p_target_game_time TIMESTAMP WITH TIME ZONE,
    p_season_id UUID DEFAULT NULL
)
RETURNS INT AS $$
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
BEGIN
    SELECT fuel_price_per_liter, absolute_minimum_safety_limit
    INTO v_fuel_price, v_absolute_minimum_safety_limit
    FROM global_game_settings
    LIMIT 1;

    v_fuel_price := COALESCE(v_fuel_price, 0.85);
    v_absolute_minimum_safety_limit := COALESCE(v_absolute_minimum_safety_limit, 30.00);

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
                   m.capacity,
                   m.speed_kmh,
                   m.fuel_burn_per_km,
                   m.maintenance_cost_per_hour,
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

            v_flight_duration := COALESCE((v_route.distance_km / NULLIF(v_route.speed_kmh, 0)), 0.0) + 1.0;
            v_flights := COALESCE(v_game_days * (v_route.flights_per_week / 7.0), 0.0);

            IF v_flights > 0.0001 THEN
                v_passengers := calculate_route_expected_passengers(
                    COALESCE(v_route.passenger_capacity, 0),
                    COALESCE(v_route.distance_km, 0.0),
                    COALESCE(v_route.ticket_price, 0.00),
                    COALESCE(v_route.org_demand, 50),
                    COALESCE(v_route.dst_demand, 50)
                );

                v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
                v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price, 0.00);
                v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
                v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
                v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost);

                v_max_weekly_flights := calculate_route_max_weekly_flights(
                    COALESCE(v_route.distance_km, 0.0),
                    COALESCE(v_route.speed_kmh, 0)
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

                UPDATE user_fleet
                SET condition = GREATEST(0.00, condition - v_net_damage)
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
                VALUES (r_bot.id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew, & airport landing fees', date_trunc('day', p_target_game_time));
            END IF;

            IF v_buffered_lease_accum > 0 THEN
                INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                VALUES (r_bot.id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active bot fleet', date_trunc('day', p_target_game_time));
            END IF;

            DELETE FROM financial_ledger
            WHERE ai_competitor_id = r_bot.id
              AND game_date < (p_target_game_time - INTERVAL '30 days');

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
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION get_finance_snapshot(
    p_id UUID,
    p_is_bot BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    actor_id UUID,
    is_bot BOOLEAN,
    company_name VARCHAR,
    cash NUMERIC,
    net_worth NUMERIC,
    owned_aircraft_asset_value NUMERIC,
    leased_aircraft_monthly_exposure NUMERIC,
    fleet_count INT,
    owned_fleet_count INT,
    leased_fleet_count INT,
    active_route_count INT,
    rolling_revenue_30d NUMERIC,
    rolling_expense_30d NUMERIC,
    rolling_net_30d NUMERIC,
    ledger_window_days INT
) AS $$
DECLARE
    v_company_name VARCHAR;
    v_cash NUMERIC := 0.00;
    v_net_worth NUMERIC := 0.00;
    v_owned_asset_value NUMERIC := 0.00;
    v_leased_monthly_exposure NUMERIC := 0.00;
    v_fleet_count INT := 0;
    v_owned_fleet_count INT := 0;
    v_leased_fleet_count INT := 0;
    v_active_route_count INT := 0;
    v_revenue_30d NUMERIC := 0.00;
    v_expense_30d NUMERIC := 0.00;
    v_ledger_window_days INT := 30;
    v_game_current_time TIMESTAMP WITH TIME ZONE;
BEGIN
    IF p_is_bot THEN
        SELECT ai.company_name, ai.cash, ai.net_worth, ai.game_current_time
        INTO v_company_name, v_cash, v_net_worth, v_game_current_time
        FROM ai_competitors ai
        WHERE ai.id = p_id;

        IF NOT FOUND THEN
            RETURN;
        END IF;

        SELECT
            COUNT(*)::INT,
            COUNT(*) FILTER (WHERE f.acquisition_type = 'purchase')::INT,
            COUNT(*) FILTER (WHERE f.acquisition_type = 'lease')::INT,
            COALESCE(SUM(CASE
                WHEN f.acquisition_type = 'purchase' THEN m.purchase_price
                ELSE 0
            END), 0.00),
            COALESCE(SUM(CASE
                WHEN f.acquisition_type = 'lease' THEN m.lease_price_per_month
                ELSE 0
            END), 0.00)
        INTO
            v_fleet_count,
            v_owned_fleet_count,
            v_leased_fleet_count,
            v_owned_asset_value,
            v_leased_monthly_exposure
        FROM user_fleet f
        JOIN aircraft_models m ON m.id = f.aircraft_model_id
        WHERE f.ai_competitor_id = p_id;

        SELECT COUNT(*)::INT
        INTO v_active_route_count
        FROM user_routes r
        WHERE r.ai_competitor_id = p_id
          AND r.assigned_aircraft_id IS NOT NULL;

        SELECT
            COALESCE(SUM(CASE WHEN fl.transaction_type = 'revenue' THEN fl.amount ELSE 0 END), 0.00),
            COALESCE(SUM(CASE WHEN fl.transaction_type = 'expense' THEN fl.amount ELSE 0 END), 0.00)
        INTO v_revenue_30d, v_expense_30d
        FROM financial_ledger fl
        WHERE fl.ai_competitor_id = p_id
          AND fl.game_date >= v_game_current_time - INTERVAL '30 days';
    ELSE
        SELECT u.company_name, u.cash, u.net_worth, u.game_current_time
        INTO v_company_name, v_cash, v_net_worth, v_game_current_time
        FROM users u
        WHERE u.id = p_id;

        IF NOT FOUND THEN
            RETURN;
        END IF;

        SELECT
            COUNT(*)::INT,
            COUNT(*) FILTER (WHERE f.acquisition_type = 'purchase')::INT,
            COUNT(*) FILTER (WHERE f.acquisition_type = 'lease')::INT,
            COALESCE(SUM(CASE
                WHEN f.acquisition_type = 'purchase' THEN m.purchase_price
                ELSE 0
            END), 0.00),
            COALESCE(SUM(CASE
                WHEN f.acquisition_type = 'lease' THEN m.lease_price_per_month
                ELSE 0
            END), 0.00)
        INTO
            v_fleet_count,
            v_owned_fleet_count,
            v_leased_fleet_count,
            v_owned_asset_value,
            v_leased_monthly_exposure
        FROM user_fleet f
        JOIN aircraft_models m ON m.id = f.aircraft_model_id
        WHERE f.user_id = p_id;

        SELECT COUNT(*)::INT
        INTO v_active_route_count
        FROM user_routes r
        WHERE r.user_id = p_id
          AND r.assigned_aircraft_id IS NOT NULL;

        SELECT
            COALESCE(SUM(CASE WHEN fl.transaction_type = 'revenue' THEN fl.amount ELSE 0 END), 0.00),
            COALESCE(SUM(CASE WHEN fl.transaction_type = 'expense' THEN fl.amount ELSE 0 END), 0.00)
        INTO v_revenue_30d, v_expense_30d
        FROM financial_ledger fl
        WHERE fl.user_id = p_id
          AND fl.game_date >= v_game_current_time - INTERVAL '30 days';
    END IF;

    RETURN QUERY
    SELECT
        p_id,
        p_is_bot,
        v_company_name,
        COALESCE(v_cash, 0.00),
        COALESCE(v_net_worth, 0.00),
        COALESCE(v_owned_asset_value, 0.00),
        COALESCE(v_leased_monthly_exposure, 0.00),
        COALESCE(v_fleet_count, 0),
        COALESCE(v_owned_fleet_count, 0),
        COALESCE(v_leased_fleet_count, 0),
        COALESCE(v_active_route_count, 0),
        COALESCE(v_revenue_30d, 0.00),
        COALESCE(v_expense_30d, 0.00),
        COALESCE(v_revenue_30d, 0.00) - COALESCE(v_expense_30d, 0.00),
        v_ledger_window_days;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

