-- ============================================================================
-- SKYWARD TIME SCALE MULTIPLIER SETTING
-- ============================================================================
-- Adds an authoritative game-speed setting to global_game_settings and updates
-- the player and bot simulation functions to read from that source instead of
-- relying on a hardcoded 30x multiplier. Rollout default: 60x.
-- ============================================================================

ALTER TABLE global_game_settings
ADD COLUMN IF NOT EXISTS time_scale_multiplier NUMERIC(10,2) NOT NULL DEFAULT 60.00;

UPDATE global_game_settings
SET time_scale_multiplier = 60.00
WHERE time_scale_multiplier IS NULL
   OR time_scale_multiplier = 30.00;

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

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;

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


CREATE OR REPLACE FUNCTION process_simulation_delta(p_user_id UUID)
RETURNS TABLE (
    cash_before NUMERIC(20,2),
    cash_after NUMERIC(20,2),
    elapsed_real_sec DOUBLE PRECISION,
    elapsed_game_days DOUBLE PRECISION,
    flights_run INT
) AS $$
DECLARE
    r_user RECORD;
    v_now TIMESTAMP WITH TIME ZONE;
    v_real_sec DOUBLE PRECISION;
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
    v_demand_multiplier NUMERIC(6,4);
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_completed_flights_all INT := 0;
    v_lease_cost NUMERIC(20,2) := 0;
    v_fuel_price NUMERIC;
    v_time_scale_multiplier NUMERIC(10,2);
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
    v_game_current_time_new TIMESTAMP WITH TIME ZONE;
BEGIN
    PERFORM process_all_bots_simulation();

    SELECT * INTO r_user FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT fuel_price_per_liter, time_scale_multiplier, absolute_minimum_safety_limit
    INTO v_fuel_price, v_time_scale_multiplier, v_absolute_minimum_safety_limit
    FROM global_game_settings
    LIMIT 1;

    v_fuel_price := COALESCE(v_fuel_price, 0.85);
    v_time_scale_multiplier := COALESCE(v_time_scale_multiplier, 60.00);
    v_absolute_minimum_safety_limit := COALESCE(v_absolute_minimum_safety_limit, 30.00);

    v_now := NOW();
    v_real_sec := COALESCE(EXTRACT(EPOCH FROM (v_now - r_user.last_active_at)), 0.0);

    IF v_real_sec > 1209600 THEN
        v_real_sec := 1209600;
    END IF;

    IF v_real_sec < 2 THEN
        cash_before := r_user.cash;
        cash_after := r_user.cash;
        elapsed_real_sec := v_real_sec;
        elapsed_game_days := 0.0;
        flights_run := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    v_game_sec := v_real_sec * v_time_scale_multiplier;
    v_game_days := v_game_sec / 86400.0;
    v_game_current_time_new := r_user.game_current_time + (v_game_sec * INTERVAL '1 second');
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
               m.capacity,
               m.speed_kmh,
               m.fuel_burn_per_km,
               m.maintenance_cost_per_hour,
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
            v_demand_multiplier := 1.5 - 0.8 * POWER(
                (COALESCE(v_route.ticket_price, 0.00) / NULLIF((50.0 + (COALESCE(v_route.distance_km, 0.0) * 0.12)), 0)),
                2
            );
            v_demand_multiplier := GREATEST(0.00, LEAST(1.50, COALESCE(v_demand_multiplier, 0.00)));

            v_passengers := FLOOR(COALESCE(v_route.capacity, 0) * 0.75 * v_demand_multiplier);
            v_passengers := GREATEST(0, LEAST(COALESCE(v_route.capacity, 0), v_passengers));

            v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
            v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price, 0.00);
            v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
            v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
            v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost);

            v_max_weekly_flights := FLOOR(168.0 / NULLIF(v_flight_duration, 0.0));
            v_unused_slots := GREATEST(0, COALESCE(v_max_weekly_flights, 0) - COALESCE(v_route.flights_per_week, 0));
            v_maintenance_hours := COALESCE(v_unused_slots, 0) * v_flight_duration * (v_game_days / 7.0);
            v_wear_per_cycle := CASE
                WHEN COALESCE(v_route.acquisition_type, 'purchase') = 'lease' THEN 0.70
                ELSE 0.50
            END;
            v_gross_damage := COALESCE(v_flights, 0.0) * v_wear_per_cycle;
            v_self_healing_credit := COALESCE(v_maintenance_hours, 0.0) * 1.0;
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

    IF date_trunc('day', v_game_current_time_new) > date_trunc('day', r_user.game_current_time) THEN
        IF v_buffered_rev_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (
                p_user_id,
                'revenue',
                'ticket_sales',
                v_buffered_rev_accum,
                'Consolidated ticket sales revenue for active routes',
                date_trunc('day', v_game_current_time_new)
            );
        END IF;

        IF v_buffered_ops_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (
                p_user_id,
                'expense',
                'operations',
                v_buffered_ops_accum,
                'Consolidated operations fuel, crew maintenance, & landing fees',
                date_trunc('day', v_game_current_time_new)
            );
        END IF;

        IF v_buffered_lease_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (
                p_user_id,
                'expense',
                'aircraft_lease',
                v_buffered_lease_accum,
                'Consolidated leasing fees for active fleet',
                date_trunc('day', v_game_current_time_new)
            );
        END IF;

        DELETE FROM financial_ledger
        WHERE user_id = p_user_id
          AND game_date < (v_game_current_time_new - INTERVAL '30 days');

        v_buffered_rev_accum := 0.00;
        v_buffered_ops_accum := 0.00;
        v_buffered_lease_accum := 0.00;
    END IF;

    UPDATE users
    SET cash = cash + v_net,
        game_current_time = v_game_current_time_new,
        last_active_at = v_now,
        buffered_revenue = v_buffered_rev_accum,
        buffered_ops_cost = v_buffered_ops_accum,
        buffered_lease_cost = v_buffered_lease_accum
    WHERE id = p_user_id;

    cash_before := r_user.cash;
    cash_after := r_user.cash + v_net;
    elapsed_real_sec := v_real_sec;
    elapsed_game_days := v_game_days;
    flights_run := v_completed_flights_all;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION process_all_bots_simulation()
RETURNS VOID AS $$
DECLARE
    r_bot RECORD;
    v_now TIMESTAMP WITH TIME ZONE;
    v_real_sec DOUBLE PRECISION;
    v_game_sec DOUBLE PRECISION;
    v_game_days DOUBLE PRECISION;
    v_route RECORD;
    v_fleet RECORD;
    v_flights DOUBLE PRECISION;
    v_revenue NUMERIC(20,2);
    v_fuel_cost NUMERIC(20,2);
    v_maint_cost NUMERIC(20,2);
    v_tax_cost NUMERIC(20,2);
    v_total_cost NUMERIC(20,2);
    v_total_revenue NUMERIC(20,2);
    v_total_cost_accum NUMERIC(20,2);
    v_net NUMERIC(20,2);
    v_demand_multiplier NUMERIC(6,4);
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_lease_cost NUMERIC(20,2);
    v_fuel_price NUMERIC;
    v_time_scale_multiplier NUMERIC(10,2);
    v_absolute_minimum_safety_limit NUMERIC(5,2);
    v_effective_grounding_threshold NUMERIC(5,2);
    v_max_weekly_flights INT;
    v_unused_slots INT;
    v_maintenance_hours DOUBLE PRECISION;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_game_current_time_new TIMESTAMP WITH TIME ZONE;

    v_buffered_rev_accum NUMERIC(20,2);
    v_buffered_ops_accum NUMERIC(20,2);
    v_buffered_lease_accum NUMERIC(20,2);
BEGIN
    v_now := NOW();

    SELECT fuel_price_per_liter, time_scale_multiplier, absolute_minimum_safety_limit
    INTO v_fuel_price, v_time_scale_multiplier, v_absolute_minimum_safety_limit
    FROM global_game_settings
    LIMIT 1;

    v_fuel_price := COALESCE(v_fuel_price, 0.85);
    v_time_scale_multiplier := COALESCE(v_time_scale_multiplier, 60.00);
    v_absolute_minimum_safety_limit := COALESCE(v_absolute_minimum_safety_limit, 30.00);

    FOR r_bot IN SELECT * FROM ai_competitors WHERE status != 'Bankrupt' LOOP
        v_real_sec := COALESCE(EXTRACT(EPOCH FROM (v_now - r_bot.last_active_at)), 0.0);

        IF v_real_sec > 1209600 THEN
            v_real_sec := 1209600;
        END IF;

        IF v_real_sec >= 2 THEN
            v_game_sec := v_real_sec * v_time_scale_multiplier;
            v_game_days := v_game_sec / 86400.0;
            v_game_current_time_new := r_bot.game_current_time + (v_game_sec * INTERVAL '1 second');
            v_effective_grounding_threshold := GREATEST(
                COALESCE(r_bot.auto_grounding_threshold, 40.00),
                v_absolute_minimum_safety_limit
            );

            v_lease_cost := 0.00;
            FOR v_fleet IN
                SELECT f.*, m.lease_price_per_month
                FROM user_fleet f
                JOIN aircraft_models m ON f.aircraft_model_id = m.id
                WHERE f.ai_competitor_id = r_bot.id AND f.acquisition_type = 'lease'
            LOOP
                v_lease_cost := v_lease_cost + COALESCE((v_game_days * (v_fleet.lease_price_per_month / 30.0)), 0.00);
            END LOOP;
            v_lease_cost := GREATEST(0.00, COALESCE(v_lease_cost, 0.00));

            v_total_revenue := 0.00;
            v_total_cost_accum := 0.00;

            FOR v_route IN
                SELECT r.*,
                       f.id AS fleet_aircraft_id,
                       f.condition,
                       f.status,
                       f.acquisition_type,
                       m.capacity,
                       m.speed_kmh,
                       m.fuel_burn_per_km,
                       m.maintenance_cost_per_hour,
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
                    v_demand_multiplier := 1.5 - 0.8 * POWER(
                        (COALESCE(v_route.ticket_price, 0.00) / NULLIF((50.0 + (COALESCE(v_route.distance_km, 0.0) * 0.12)), 0)),
                        2
                    );
                    v_demand_multiplier := GREATEST(0.00, LEAST(1.50, COALESCE(v_demand_multiplier, 0.00)));

                    v_passengers := FLOOR(COALESCE(v_route.capacity, 0) * 0.75 * v_demand_multiplier);
                    v_passengers := GREATEST(0, LEAST(COALESCE(v_route.capacity, 0), v_passengers));

                    v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
                    v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price, 0.00);
                    v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
                    v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
                    v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost);

                    v_max_weekly_flights := FLOOR(168.0 / NULLIF(v_flight_duration, 0.0));
                    v_unused_slots := GREATEST(0, COALESCE(v_max_weekly_flights, 0) - COALESCE(v_route.flights_per_week, 0));
                    v_maintenance_hours := COALESCE(v_unused_slots, 0) * v_flight_duration * (v_game_days / 7.0);
                    v_wear_per_cycle := CASE
                        WHEN COALESCE(v_route.acquisition_type, 'purchase') = 'lease' THEN 0.70
                        ELSE 0.50
                    END;
                    v_gross_damage := COALESCE(v_flights, 0.0) * v_wear_per_cycle;
                    v_self_healing_credit := COALESCE(v_maintenance_hours, 0.0) * 1.0;
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

            IF date_trunc('day', v_game_current_time_new) > date_trunc('day', r_bot.game_current_time) THEN
                IF v_buffered_rev_accum > 0 THEN
                    INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                    VALUES (r_bot.id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active bot routes', date_trunc('day', v_game_current_time_new));
                END IF;

                IF v_buffered_ops_accum > 0 THEN
                    INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                    VALUES (r_bot.id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew, & airport landing fees', date_trunc('day', v_game_current_time_new));
                END IF;

                IF v_buffered_lease_accum > 0 THEN
                    INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                    VALUES (r_bot.id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active bot fleet', date_trunc('day', v_game_current_time_new));
                END IF;

                DELETE FROM financial_ledger
                WHERE ai_competitor_id = r_bot.id
                  AND game_date < (v_game_current_time_new - INTERVAL '30 days');

                v_buffered_rev_accum := 0.00;
                v_buffered_ops_accum := 0.00;
                v_buffered_lease_accum := 0.00;
            END IF;

            UPDATE ai_competitors
            SET cash = cash + v_net,
                game_current_time = v_game_current_time_new,
                last_active_at = v_now,
                buffered_revenue = v_buffered_rev_accum,
                buffered_ops_cost = v_buffered_ops_accum,
                buffered_lease_cost = v_buffered_lease_accum
            WHERE id = r_bot.id;
        END IF;
    END LOOP;

    PERFORM execute_bot_decisions();
END;
$$ LANGUAGE plpgsql;
