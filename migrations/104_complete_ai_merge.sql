-- ============================================================================
-- Migration 104: Complete AI merge — fix all remaining ai_competitors references
-- ============================================================================
-- The ai_competitors table has been dropped and columns renamed (ai_competitor_id
-- → user_id, aircraft_financing merged into loans), but several functions still
-- reference the old schema. This migration rewrites them all.
--
-- Functions fixed (8 reference ai_competitors, 11 reference ai_competitor_id):
--   1. process_all_bots_simulation_to_time
--   2. execute_bot_decisions
--   3. bot_finance_aircraft
--   4. calculate_bot_credit_score
--   5. get_competitor_insights
--   6. get_global_leaderboard
--   7. get_finance_snapshot
--   8. record_rank_snapshot
--   9. calculate_hub_bonus         (ai_competitor_id only)
--  10. get_hub_bonus_percentage    (ai_competitor_id only)
--  11. calculate_route_expected_passengers (ai_competitor_id only, 8-param overload)
--
-- Also:
--  - Wire record_rank_snapshot into process_world_tick (game-day boundary)
--  - Fix get_credit_report() to write back credit_tier to users table
--  - Drop calculate_ai_net_worth and trg_update_ai_net_worth if they exist
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. process_all_bots_simulation_to_time
-- ============================================================================
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
    v_crew_cost NUMERIC(20,2) := 0;
    v_total_cost NUMERIC(20,2) := 0;
    v_total_revenue NUMERIC(20,2) := 0;
    v_total_cost_accum NUMERIC(20,2) := 0;
    v_net NUMERIC(20,2) := 0;
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_turnaround_hours DOUBLE PRECISION;
    v_lease_cost NUMERIC(20,2) := 0;
    v_fuel_price NUMERIC;
    v_fuel_price_multiplier NUMERIC;
    v_crew_cost_per_hour NUMERIC;
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
    v_buffered_cargo_accum NUMERIC(20,2);
    v_cargo_rev NUMERIC(20,2);
    v_processed INT := 0;
    v_demand_multiplier NUMERIC;
    v_seasonal_multiplier NUMERIC;
    v_total_seats INT;
    v_economy_pax NUMERIC;
    v_business_pax NUMERIC;
    v_first_pax NUMERIC;
    v_business_demand NUMERIC;
    v_first_demand NUMERIC;
    v_fleet_total_flights INT;
    v_fleet_last_a_check INT;
    v_fleet_last_c_check INT;
    v_passenger_capacity INT;
BEGIN
    SELECT fuel_price_per_liter, absolute_minimum_safety_limit,
           COALESCE(crew_cost_per_hour, 350.0)
    INTO v_fuel_price, v_absolute_minimum_safety_limit, v_crew_cost_per_hour
    FROM global_game_settings
    LIMIT 1;

    v_fuel_price := COALESCE(v_fuel_price, 0.85);
    v_fuel_price_multiplier := COALESCE(v_fuel_price_multiplier, 1.0);
    v_absolute_minimum_safety_limit := COALESCE(v_absolute_minimum_safety_limit, 30.00);
    v_seasonal_multiplier := 1.0;

    FOR r_bot IN
        SELECT *
        FROM users
        WHERE actor_type = 'AI'
          AND COALESCE(operational_status, 'Active') != 'Bankrupt'
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
        v_buffered_cargo_accum := 0.00;

        FOR v_fleet IN
            SELECT f.*, m.lease_price_per_month
            FROM fleet_aircraft f
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            WHERE f.user_id = r_bot.id AND f.acquisition_type = 'lease'
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
                   m.passenger_capacity,
                   m.speed_kmh,
                   m.fuel_burn_per_km,
                   m.maintenance_cost_per_hour,
                   m.turnaround_hours,
                   org.demand_index AS org_demand,
                   org.airport_tax AS org_tax,
                   dst.demand_index AS dst_demand,
                   dst.airport_tax AS dst_tax
            FROM route_assignments r
            JOIN fleet_aircraft f ON r.assigned_aircraft_id = f.id
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            JOIN airports org ON r.origin_iata = org.iata
            JOIN airports dst ON r.destination_iata = dst.iata
            WHERE r.user_id = r_bot.id
        LOOP
            IF COALESCE(v_route.status, 'grounded') != 'active'
               OR COALESCE(v_route.condition, 0.00) < v_effective_grounding_threshold THEN
                CONTINUE;
            END IF;

            v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
            v_flight_duration := COALESCE((v_route.distance_km / NULLIF(v_route.speed_kmh, 0)), 0.0) + v_turnaround_hours;
            v_flights := COALESCE(v_game_days * (v_route.flights_per_week / 7.0), 0.0);

            IF v_flights > 0.0001 THEN
                v_passenger_capacity := COALESCE(v_route.passenger_capacity, v_route.capacity);
                v_passengers := calculate_route_expected_passengers(
                    COALESCE(v_passenger_capacity, 0),
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
                     WHERE effect_type = 'demand_index'
                       AND effect_target = v_route.origin_iata
                       AND is_active = true
                       AND start_game_time <= p_target_game_time
                       AND end_game_time > p_target_game_time
                     ORDER BY start_game_time DESC LIMIT 1),
                    1.0
                ) INTO v_demand_multiplier;

                v_passengers := GREATEST(0, FLOOR(v_passengers * v_demand_multiplier * v_seasonal_multiplier));

                v_total_seats := COALESCE(v_route.economy_seats, 0) + COALESCE(v_route.business_seats, 0) + COALESCE(v_route.first_class_seats, 0);
                IF v_total_seats > 0 THEN
                    v_economy_pax := v_passengers * (v_route.economy_seats::NUMERIC / v_total_seats);
                    v_business_pax := v_passengers * (v_route.business_seats::NUMERIC / v_total_seats);
                    v_first_pax := v_passengers * (v_route.first_class_seats::NUMERIC / v_total_seats);
                    v_business_demand := GREATEST(0.0, 1.2 - 0.5 * POWER(1.0, 2));
                    v_first_demand := GREATEST(0.0, 1.5 - 0.8 * POWER(1.0, 2));
                    v_business_pax := v_business_pax * v_business_demand;
                    v_first_pax := v_first_pax * v_first_demand;
                    v_revenue := COALESCE(v_flights * ((v_economy_pax * v_route.ticket_price) + (v_business_pax * v_route.ticket_price * 2.5) + (v_first_pax * v_route.ticket_price * 4.0)), 0.00);
                ELSE
                    v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
                END IF;

                v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier, 0.00);
                v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
                v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
                v_crew_cost := COALESCE(v_flights * v_flight_duration * v_crew_cost_per_hour, 0.00);
                v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost + v_crew_cost);

                v_max_weekly_flights := calculate_route_max_weekly_flights(COALESCE(v_route.distance_km, 0.0), COALESCE(v_route.speed_kmh, 0), v_turnaround_hours);
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

                UPDATE fleet_aircraft
                SET condition = GREATEST(0.00, condition - v_net_damage),
                    total_flights = v_fleet_total_flights,
                    last_a_check_at = v_fleet_last_a_check,
                    last_c_check_at = v_fleet_last_c_check
                WHERE id = v_route.fleet_aircraft_id;

                UPDATE fleet_aircraft
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
                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (r_bot.id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active bot routes', date_trunc('day', p_target_game_time));
            END IF;

            IF v_buffered_ops_accum > 0 THEN
                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (r_bot.id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew, maintenance, & airport landing fees', date_trunc('day', p_target_game_time));
            END IF;

            IF v_buffered_lease_accum > 0 THEN
                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (r_bot.id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active bot fleet', date_trunc('day', p_target_game_time));
            END IF;

            DELETE FROM financial_ledger
            WHERE user_id = r_bot.id
              AND game_date < (p_target_game_time - INTERVAL '30 days');

            PERFORM process_bot_loan_payments(r_bot.id, p_target_game_time);

            v_buffered_rev_accum := 0.00;
            v_buffered_ops_accum := 0.00;
            v_buffered_lease_accum := 0.00;
            v_buffered_cargo_accum := 0.00;
        END IF;

        UPDATE users
        SET cash = cash + v_net,
            game_current_time = p_target_game_time,
            last_active_at = NOW(),
            buffered_revenue = v_buffered_rev_accum,
            buffered_ops_cost = v_buffered_ops_accum,
            buffered_lease_cost = v_buffered_lease_accum,
            buffered_cargo_revenue = v_buffered_cargo_accum
        WHERE id = r_bot.id;

        v_processed := v_processed + 1;
    END LOOP;

    IF v_processed > 0 THEN
        PERFORM execute_bot_decisions();
    END IF;

    RETURN v_processed;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;


-- ============================================================================
-- 2. execute_bot_decisions
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

    FOR r_bot IN SELECT * FROM users WHERE actor_type = 'AI' LOOP
        v_bot_cash := COALESCE(r_bot.cash, 0.00);
        v_origin_iata := r_bot.hq_airport_iata;
        v_effective_threshold := GREATEST(
            v_absolute_minimum_safety_limit,
            COALESCE(r_bot.auto_grounding_threshold, 40.00)
        );

        IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < -5000000.00 THEN
            UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
            UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id;
            UPDATE loans SET status = 'defaulted', remaining_balance = 0 WHERE user_id = r_bot.id AND status = 'active';
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
        FROM fleet_aircraft WHERE user_id = r_bot.id;

        SELECT COUNT(*)::INT INTO v_route_count
        FROM route_assignments WHERE user_id = r_bot.id;

        SELECT COUNT(*)::INT INTO v_idle_aircraft_count
        FROM fleet_aircraft f
        WHERE f.user_id = r_bot.id
          AND f.status = 'active'
          AND f.condition >= v_effective_threshold
          AND NOT EXISTS (
              SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id
          );

        SELECT
            f.id, f.condition, f.acquisition_type,
            m.model_name, m.lease_price_per_month, m.purchase_price
        INTO
            v_grounded_aircraft_id, v_grounded_condition, v_grounded_acquisition_type,
            v_grounded_model_name, v_grounded_lease_price, v_grounded_purchase_price
        FROM fleet_aircraft f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.user_id = r_bot.id
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
                UPDATE users SET cash = cash - v_repair_cost WHERE id = r_bot.id;

                UPDATE fleet_aircraft
                SET condition = 100.00, status = 'active'
                WHERE id = v_grounded_aircraft_id;

                INSERT INTO financial_ledger (
                    user_id, transaction_type, category, amount, description, game_date
                ) VALUES (
                    r_bot.id, 'expense', 'aircraft_repair', v_repair_cost,
                    'Bot maintenance recovery completed for ' || v_grounded_model_name,
                    r_bot.game_current_time
                );

                v_bot_cash := v_bot_cash - v_repair_cost;
            END IF;
        END IF;

        IF v_bot_cash < 3000000.00 OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN
            SELECT r.id, r.flights_per_week, (50.00 + (r.distance_km * 0.12))::NUMERIC
            INTO v_selected_route_id, v_selected_flights, v_selected_base_fare
            FROM route_assignments r
            WHERE r.user_id = r_bot.id
            ORDER BY
                (r.ticket_price / NULLIF((50.00 + (r.distance_km * 0.12)), 0)) DESC,
                r.flights_per_week DESC
            LIMIT 1;

            IF v_selected_route_id IS NOT NULL THEN
                IF v_selected_flights > 8 THEN
                    UPDATE route_assignments
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
                    DELETE FROM route_assignments WHERE id = v_selected_route_id;
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
                    FROM aircraft_models WHERE manufacturer = 'ATR'
                    ORDER BY capacity DESC LIMIT 1;
                ELSIF r_bot.archetype = 'Aggressive' THEN
                    SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
                    INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                    FROM aircraft_models WHERE manufacturer = 'Airbus'
                    ORDER BY capacity DESC LIMIT 1;
                ELSE
                    SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
                    INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                    FROM aircraft_models WHERE manufacturer = 'Boeing'
                    ORDER BY capacity DESC LIMIT 1;
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

                INSERT INTO fleet_aircraft (
                    id, user_id, aircraft_model_id, nickname,
                    acquisition_type, condition, status,
                    tail_number, economy_seats, business_seats, first_class_seats
                ) VALUES (
                    v_new_aircraft_id, r_bot.id, v_model_id, v_model_name,
                    'lease', 100.00, 'active',
                    v_tail, v_economy, v_business, v_first
                );

                UPDATE users SET cash = cash - v_deposit_amount WHERE id = r_bot.id;

                INSERT INTO financial_ledger (
                    user_id, transaction_type, category, amount, description, game_date
                ) VALUES (
                    r_bot.id, 'expense', 'aircraft_lease', v_deposit_amount,
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
                        INSERT INTO fleet_aircraft (
                            user_id, aircraft_model_id, tail_number,
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
                    UPDATE users SET cash = cash - v_purchase_price WHERE id = r_bot.id;
                    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                    VALUES (r_bot.id, 'expense', 'acquisition', v_purchase_price, 'Aircraft purchase: ' || v_tail, r_bot.game_current_time);
                    v_bot_cash := v_bot_cash - v_purchase_price;
                END IF;
            END IF;
        END IF;

        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;

        SELECT
            f.id, f.tail_number, f.condition,
            m.model_name, m.capacity, m.speed_kmh, m.range_km
        INTO
            v_idle_aircraft_id, v_idle_tail, v_idle_condition,
            v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range
        FROM fleet_aircraft f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.user_id = r_bot.id
          AND f.status = 'active'
          AND f.condition >= v_effective_threshold
          AND NOT EXISTS (
              SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id
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
                    1, FLOOR(168.0 / ((v_distance / v_idle_speed) + 1.0))
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

                INSERT INTO route_assignments (
                    user_id, origin_iata, destination_iata, distance_km,
                    ticket_price, assigned_aircraft_id, flights_per_week
                ) VALUES (
                    r_bot.id, v_origin_iata, v_dest_iata, v_distance,
                    v_target_price, v_idle_aircraft_id, v_target_flights
                )
                ON CONFLICT DO NOTHING;
            END IF;
        END IF;

        FOR r_route IN
            SELECT * FROM route_assignments
            WHERE user_id = r_bot.id AND status = 'active'
        LOOP
            SELECT COUNT(*) INTO v_human_competitors
            FROM route_assignments
            WHERE origin_iata = r_route.origin_iata
              AND destination_iata = r_route.destination_iata
              AND user_id IS NOT NULL
              AND status = 'active'
              AND user_id != r_bot.id;

            IF v_human_competitors > 0 THEN
                v_base_fare := 50.00 + (r_route.distance_km * 0.12);
                v_new_price := r_route.ticket_price * 0.97;
                IF v_new_price >= v_base_fare * 0.85 THEN
                    UPDATE route_assignments
                    SET ticket_price = ROUND(v_new_price::numeric, 2)
                    WHERE id = r_route.id;
                END IF;
            END IF;
        END LOOP;

        SELECT cash INTO v_bot_cash FROM users WHERE id = r_bot.id;

        IF v_bot_cash < v_starting_cash * 0.5 THEN
            SELECT COUNT(*) INTO v_active_loans
            FROM loans WHERE user_id = r_bot.id AND status = 'active';

            IF v_active_loans < 2 THEN
                PERFORM bot_take_loan(r_bot.id, v_starting_cash * 0.5, 52);
            END IF;
        END IF;

        SELECT cash INTO v_bot_cash FROM users WHERE id = r_bot.id;

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

        SELECT cash INTO v_bot_cash FROM users WHERE id = r_bot.id;

        IF v_bot_cash > v_starting_cash * 3 THEN
            SELECT * INTO v_loan_record
            FROM loans
            WHERE user_id = r_bot.id AND status = 'active'
            ORDER BY interest_rate DESC
            LIMIT 1;

            IF v_loan_record.id IS NOT NULL
               AND v_bot_cash > v_loan_record.remaining_balance THEN
                UPDATE users
                SET cash = cash - v_loan_record.remaining_balance
                WHERE id = r_bot.id;

                UPDATE loans
                SET status = 'paid_off',
                    paid_off_at = NOW(),
                    remaining_balance = 0
                WHERE id = v_loan_record.id;

                INSERT INTO financial_ledger (
                    user_id, transaction_type, category,
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

        UPDATE users
        SET credit_score = v_credit_score,
            credit_tier = v_credit_tier
        WHERE id = r_bot.id;

        SELECT COUNT(*)::INT INTO v_grounded_count
        FROM fleet_aircraft
        WHERE user_id = r_bot.id
          AND (status = 'grounded' OR condition < v_effective_threshold);

        UPDATE users
        SET consecutive_negative_days = CASE
                WHEN cash < 0.00 THEN COALESCE(consecutive_negative_days, 0) + 1
                ELSE 0
            END,
            operational_status = CASE
                WHEN cash < 0.00 THEN 'Distress'
                WHEN v_grounded_count > 0 THEN 'Maintenance'
                ELSE 'Active'
            END
        WHERE id = r_bot.id
        RETURNING consecutive_negative_days INTO v_negative_days;

        IF COALESCE(v_negative_days, 0) >= 3 THEN
            UPDATE users
            SET operational_status = 'Bankrupt'
            WHERE id = r_bot.id;
            UPDATE loans SET status = 'defaulted', remaining_balance = 0
            WHERE user_id = r_bot.id AND status = 'active';
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;


-- ============================================================================
-- 3. bot_finance_aircraft
-- ============================================================================
CREATE OR REPLACE FUNCTION bot_finance_aircraft(
    p_bot_id UUID,
    p_aircraft_model_id UUID,
    p_down_payment_pct NUMERIC DEFAULT 0.20,
    p_term_months INT DEFAULT 60
)
RETURNS BOOLEAN AS $$
DECLARE
    v_model RECORD;
    v_purchase_price NUMERIC;
    v_down_payment NUMERIC;
    v_principal NUMERIC;
    v_interest_rate NUMERIC := 0.05;
    v_monthly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_bot_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_hq_iata VARCHAR(3);
    v_fleet_id UUID;
    v_tail VARCHAR(20);
    v_economy INT;
    v_business INT;
    v_first INT;
    v_archetype VARCHAR;
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN RETURN false; END IF;

    SELECT cash, game_current_time, hq_airport_iata, archetype
    INTO v_bot_cash, v_game_time, v_hq_iata, v_archetype
    FROM users WHERE id = p_bot_id AND actor_type = 'AI';

    IF NOT FOUND THEN RETURN false; END IF;

    v_purchase_price := v_model.purchase_price;
    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_total_repayable := v_principal * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;

    IF v_bot_cash < v_down_payment THEN
        RETURN false;
    END IF;

    UPDATE users SET cash = cash - v_down_payment WHERE id = p_bot_id;

    v_economy := CASE
        WHEN v_archetype = 'Regional'  THEN FLOOR(v_model.capacity * 0.80)
        WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)
        ELSE FLOOR(v_model.capacity * 0.50)
    END;
    v_business := CASE
        WHEN v_archetype = 'Regional'  THEN FLOOR(v_model.capacity * 0.15)
        WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)
        ELSE FLOOR(v_model.capacity * 0.30)
    END;
    v_first := v_model.capacity - v_economy - v_business;

    v_tail := generate_tail_number(COALESCE(v_hq_iata, 'SG'));

    INSERT INTO fleet_aircraft (
        user_id, aircraft_model_id, tail_number,
        acquisition_type, condition, status,
        economy_seats, business_seats, first_class_seats
    ) VALUES (
        p_bot_id, p_aircraft_model_id, v_tail,
        'purchase', 100.00, 'active',
        v_economy, v_business, v_first
    ) RETURNING id INTO v_fleet_id;

    INSERT INTO loans (
        user_id, aircraft_model_id, fleet_aircraft_id,
        purchase_price, down_payment, principal,
        interest_rate, monthly_payment, term_months,
        remaining_balance, weekly_payment, taken_at,
        loan_type, loan_subtype
    ) VALUES (
        p_bot_id, p_aircraft_model_id, v_fleet_id,
        v_purchase_price, v_down_payment, v_principal,
        v_interest_rate, v_monthly_payment, p_term_months,
        v_total_repayable, 0, v_game_time,
        'aircraft_financing', 'aircraft_financing'
    );

    INSERT INTO financial_ledger (
        user_id, transaction_type, category, amount, description, game_date
    ) VALUES (
        p_bot_id, 'expense', 'aircraft_financing_down', v_down_payment,
        'Aircraft financing down payment — ' || v_model.model_name,
        v_game_time
    );

    RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION bot_finance_aircraft(UUID, UUID, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bot_finance_aircraft(UUID, UUID, NUMERIC, INT) TO service_role;


-- ============================================================================
-- 4. calculate_bot_credit_score
-- ============================================================================
CREATE OR REPLACE FUNCTION calculate_bot_credit_score(p_bot_id UUID)
RETURNS TABLE (
    score INT,
    tier VARCHAR(10),
    fleet_health INT,
    revenue_stability INT,
    debt_ratio INT,
    cash_reserve INT,
    profit_history INT
) AS $$
DECLARE
    v_bot RECORD;
    v_fleet_count INT := 0;
    v_avg_condition NUMERIC := 100.0;
    v_grounded_ratio NUMERIC := 0.0;
    v_fleet_health NUMERIC := 200.0;

    v_revenue_days INT := 0;
    v_positive_days INT := 0;
    v_revenue_stability NUMERIC := 200.0;

    v_total_debt NUMERIC := 0.0;
    v_net_worth NUMERIC := 0.0;
    v_debt_ratio NUMERIC := 200.0;

    v_cash NUMERIC := 0.0;
    v_starting_cash NUMERIC := 15000000.0;
    v_cash_reserve NUMERIC := 200.0;

    v_total_revenue_30d NUMERIC := 0.0;
    v_total_expense_30d NUMERIC := 0.0;
    v_profit_margin NUMERIC := 0.0;
    v_profit_history NUMERIC := 200.0;

    v_total_score INT;
    v_tier VARCHAR(10);
BEGIN
    SELECT u.cash, u.net_worth, u.game_current_time
    INTO v_bot
    FROM users u WHERE u.id = p_bot_id AND u.actor_type = 'AI';

    IF NOT FOUND THEN
        score := 500; tier := 'Standard';
        fleet_health := 100; revenue_stability := 100;
        debt_ratio := 100; cash_reserve := 100; profit_history := 100;
        RETURN NEXT;
        RETURN;
    END IF;

    v_cash := COALESCE(v_bot.cash, 0.0);
    v_net_worth := COALESCE(v_bot.net_worth, 0.0);

    SELECT starting_cash INTO v_starting_cash FROM global_game_settings LIMIT 1;
    v_starting_cash := COALESCE(v_starting_cash, 15000000.0);

    SELECT
        COUNT(*)::INT,
        COALESCE(AVG(condition), 100.0),
        COALESCE(
            COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC /
            NULLIF(COUNT(*), 0), 0.0
        )
    INTO v_fleet_count, v_avg_condition, v_grounded_ratio
    FROM fleet_aircraft WHERE user_id = p_bot_id;

    IF v_fleet_count > 0 THEN
        v_fleet_health := (v_avg_condition / 100.0) * 150.0
                        + 50.0 * (1.0 - v_grounded_ratio);
    ELSE
        v_fleet_health := 100.0;
    END IF;
    v_fleet_health := GREATEST(0.0, LEAST(200.0, v_fleet_health));

    SELECT
        COUNT(DISTINCT date_trunc('day', game_date))::INT,
        COUNT(DISTINCT date_trunc('day', game_date)) FILTER (
            WHERE transaction_type = 'revenue' AND amount > 0
        )::INT
    INTO v_revenue_days, v_positive_days
    FROM financial_ledger
    WHERE user_id = p_bot_id
      AND game_date >= v_bot.game_current_time - INTERVAL '30 days';

    IF v_revenue_days > 0 THEN
        v_revenue_stability := (v_positive_days::NUMERIC / GREATEST(v_revenue_days, 1)) * 200.0;
    ELSE
        v_revenue_stability := 100.0;
    END IF;
    v_revenue_stability := GREATEST(0.0, LEAST(200.0, v_revenue_stability));

    SELECT COALESCE(SUM(remaining_balance), 0) INTO v_total_debt
    FROM loans WHERE user_id = p_bot_id AND status = 'active';

    IF v_net_worth > 0 THEN
        v_debt_ratio := GREATEST(0.0, 200.0 * (1.0 - (v_total_debt / v_net_worth)));
    ELSIF v_total_debt > 0 THEN
        v_debt_ratio := 0.0;
    ELSE
        v_debt_ratio := 100.0;
    END IF;
    v_debt_ratio := GREATEST(0.0, LEAST(200.0, v_debt_ratio));

    IF v_starting_cash > 0 THEN
        v_cash_reserve := LEAST(200.0, (v_cash / v_starting_cash) * 100.0);
    ELSE
        v_cash_reserve := 100.0;
    END IF;
    IF v_cash < 0 THEN v_cash_reserve := 0.0; END IF;
    v_cash_reserve := GREATEST(0.0, LEAST(200.0, v_cash_reserve));

    SELECT
        COALESCE(SUM(CASE WHEN transaction_type = 'revenue' THEN amount ELSE 0 END), 0.0),
        COALESCE(SUM(CASE WHEN transaction_type = 'expense' THEN amount ELSE 0 END), 0.0)
    INTO v_total_revenue_30d, v_total_expense_30d
    FROM financial_ledger
    WHERE user_id = p_bot_id
      AND game_date >= v_bot.game_current_time - INTERVAL '30 days';

    IF v_total_revenue_30d > 0 THEN
        v_profit_margin := (v_total_revenue_30d - v_total_expense_30d) / v_total_revenue_30d;
        v_profit_history := GREATEST(0.0, LEAST(200.0, (v_profit_margin + 0.5) * 200.0));
    ELSE
        v_profit_history := 100.0;
    END IF;
    v_profit_history := GREATEST(0.0, LEAST(200.0, v_profit_history));

    v_total_score := ROUND(v_fleet_health + v_revenue_stability +
                           v_debt_ratio + v_cash_reserve + v_profit_history);
    v_total_score := GREATEST(0, LEAST(1000, v_total_score));

    v_tier := CASE
        WHEN v_total_score >= 900 THEN 'Platinum'
        WHEN v_total_score >= 750 THEN 'Gold'
        WHEN v_total_score >= 600 THEN 'Silver'
        WHEN v_total_score >= 400 THEN 'Standard'
        ELSE 'Subprime'
    END;

    score := v_total_score;
    tier := v_tier;
    fleet_health := ROUND(v_fleet_health)::INT;
    revenue_stability := ROUND(v_revenue_stability)::INT;
    debt_ratio := ROUND(v_debt_ratio)::INT;
    cash_reserve := ROUND(v_cash_reserve)::INT;
    profit_history := ROUND(v_profit_history)::INT;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION calculate_bot_credit_score(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION calculate_bot_credit_score(UUID) TO service_role;


-- ============================================================================
-- 5. get_competitor_insights
-- ============================================================================
CREATE OR REPLACE FUNCTION get_competitor_insights(p_id UUID, p_is_bot BOOLEAN)
RETURNS TABLE (
    company_name VARCHAR,
    ceo_name VARCHAR,
    cash NUMERIC,
    net_worth NUMERIC,
    status VARCHAR,
    fleet_breakdown JSONB,
    network_routes JSONB
) AS $$
DECLARE
    v_company VARCHAR;
    v_ceo VARCHAR;
    v_cash NUMERIC;
    v_net_worth NUMERIC;
    v_status VARCHAR;
    v_fleet JSONB;
    v_routes JSONB;
BEGIN
    SELECT u.company_name, u.ceo_name, u.cash, u.net_worth, COALESCE(u.operational_status, 'Active')
    INTO v_company, v_ceo, v_cash, v_net_worth, v_status
    FROM users u
    WHERE u.id = p_id;

    SELECT COALESCE(jsonb_object_agg(model_label, count_val), '{}'::jsonb)
    INTO v_fleet
    FROM (
        SELECT
            (m.manufacturer || ' ' || m.model_name || ' (' || f.acquisition_type || ')')
                AS model_label,
            COUNT(*)::INT AS count_val
        FROM fleet_aircraft f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.user_id = p_id
          AND f.status = 'active'
        GROUP BY m.manufacturer, m.model_name, f.acquisition_type
    ) d;

    SELECT COALESCE(jsonb_agg(route_label), '[]'::jsonb)
    INTO v_routes
    FROM (
        SELECT (origin_iata || '-' || destination_iata) AS route_label
        FROM route_assignments
        WHERE user_id = p_id
    ) r;

    RETURN QUERY
    SELECT
        v_company::VARCHAR,
        v_ceo::VARCHAR,
        v_cash,
        v_net_worth,
        v_status::VARCHAR,
        v_fleet,
        v_routes;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;


-- ============================================================================
-- 6. get_global_leaderboard
-- ============================================================================
CREATE OR REPLACE FUNCTION get_global_leaderboard()
RETURNS TABLE (
    id UUID,
    company_name VARCHAR,
    ceo_name VARCHAR,
    is_bot BOOLEAN,
    archetype VARCHAR,
    cash NUMERIC,
    net_worth NUMERIC,
    fleet_size INT,
    monthly_revenue NUMERIC,
    status VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        u.id,
        u.company_name::VARCHAR,
        u.ceo_name::VARCHAR,
        (u.actor_type = 'AI') AS is_bot,
        COALESCE(u.archetype, 'Player')::VARCHAR AS archetype,
        u.cash,
        u.net_worth,
        (SELECT COUNT(*)::INT FROM fleet_aircraft WHERE user_id = u.id AND status = 'active') AS fleet_size,
        COALESCE((
            SELECT SUM(amount)
            FROM financial_ledger
            WHERE user_id = u.id
              AND transaction_type = 'revenue'
              AND game_date >= u.game_current_time - INTERVAL '30 days'
        ), 0.00)::NUMERIC AS monthly_revenue,
        COALESCE(u.operational_status, 'Active')::VARCHAR AS status
    FROM users u;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 7. get_finance_snapshot
-- ============================================================================
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
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.user_id = p_id;

    SELECT COUNT(*)::INT
    INTO v_active_route_count
    FROM route_assignments r
    WHERE r.user_id = p_id;

    SELECT
        COALESCE(SUM(CASE WHEN fl.transaction_type = 'revenue' THEN fl.amount ELSE 0 END), 0.00),
        COALESCE(SUM(CASE WHEN fl.transaction_type = 'expense' THEN fl.amount ELSE 0 END), 0.00)
    INTO v_revenue_30d, v_expense_30d
    FROM financial_ledger fl
    WHERE fl.user_id = p_id
      AND fl.game_date >= v_game_current_time - INTERVAL '30 days';

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

REVOKE ALL ON FUNCTION get_finance_snapshot(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_finance_snapshot(UUID, BOOLEAN) TO authenticated, anon, service_role;


-- ============================================================================
-- 8. record_rank_snapshot
-- ============================================================================
CREATE OR REPLACE FUNCTION record_rank_snapshot(p_game_date DATE)
RETURNS VOID AS $$
BEGIN
    INSERT INTO rank_history (user_id, is_bot, game_date, rank_position, net_worth, fleet_size, monthly_revenue)
    SELECT
        sub.id,
        (sub.actor_type = 'AI'),
        p_game_date,
        ROW_NUMBER() OVER (ORDER BY sub.net_worth DESC),
        sub.net_worth,
        sub.fleet_count,
        sub.monthly_rev
    FROM (
        SELECT
            u.id,
            u.actor_type,
            u.cash + COALESCE(
                (SELECT SUM(am.purchase_price * 0.7)
                 FROM fleet_aircraft uf
                 JOIN aircraft_models am ON uf.aircraft_model_id = am.id
                 WHERE uf.user_id = u.id AND uf.status = 'active'),
                0
            ) AS net_worth,
            (SELECT COUNT(*)::INT
             FROM fleet_aircraft
             WHERE user_id = u.id AND status = 'active') AS fleet_count,
            COALESCE(
                (SELECT SUM(amount)
                 FROM financial_ledger
                 WHERE user_id = u.id
                   AND transaction_type = 'revenue'
                   AND game_date >= u.game_current_time - INTERVAL '30 days'),
                0.00
            ) AS monthly_rev
        FROM users u
        WHERE COALESCE(u.operational_status, 'Active') != 'Bankrupt'
    ) sub;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;


-- ============================================================================
-- 9. calculate_hub_bonus (fix ai_competitor_id → user_id)
-- ============================================================================
CREATE OR REPLACE FUNCTION calculate_hub_bonus(p_origin_iata VARCHAR, p_user_id UUID)
RETURNS NUMERIC AS $$
DECLARE
    v_hub_routes_count INT;
BEGIN
    SELECT COUNT(*) INTO v_hub_routes_count
    FROM route_assignments
    WHERE origin_iata = p_origin_iata
      AND user_id = p_user_id
      AND status = 'active';

    IF v_hub_routes_count > 1 THEN
        RETURN 1.0 + LEAST((v_hub_routes_count - 1) * 0.02, 0.20);
    END IF;
    RETURN 1.0;
END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================================================
-- 10. get_hub_bonus_percentage (fix ai_competitor_id → user_id)
-- ============================================================================
CREATE OR REPLACE FUNCTION get_hub_bonus_percentage(p_origin_iata VARCHAR, p_user_id UUID)
RETURNS NUMERIC AS $$
DECLARE
    v_hub_routes_count INT;
BEGIN
    SELECT COUNT(*) INTO v_hub_routes_count
    FROM route_assignments
    WHERE origin_iata = p_origin_iata
      AND user_id = p_user_id
      AND status = 'active';

    IF v_hub_routes_count > 1 THEN
        RETURN LEAST((v_hub_routes_count - 1) * 2.0, 20.0);
    END IF;
    RETURN 0.0;
END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================================================
-- 11. calculate_route_expected_passengers (8-param overload, fix ai_competitor_id)
-- ============================================================================
CREATE OR REPLACE FUNCTION calculate_route_expected_passengers(
    p_capacity INT,
    p_distance_km DOUBLE PRECISION,
    p_ticket_price NUMERIC,
    p_origin_demand INT,
    p_destination_demand INT,
    p_origin_iata VARCHAR,
    p_destination_iata VARCHAR,
    p_user_id UUID
) RETURNS INT AS $$
DECLARE
    v_base_passengers INT;
    v_competitor_count INT;
    v_my_frequency INT;
    v_total_frequency INT;
    v_competition_factor NUMERIC := 1.0;
    v_congestion_factor NUMERIC := 1.0;
    v_hub_bonus NUMERIC := 1.0;
BEGIN
    v_base_passengers := GREATEST(0, LEAST(
        COALESCE(p_capacity, 0),
        FLOOR(COALESCE(p_capacity, 0) * 0.95 *
            calculate_airport_demand_factor(p_origin_demand, p_destination_demand) *
            calculate_route_demand_multiplier(p_distance_km, p_ticket_price)
        )::INT
    ));

    SELECT COUNT(*) INTO v_competitor_count
    FROM route_assignments
    WHERE origin_iata = p_origin_iata
      AND destination_iata = p_destination_iata
      AND status = 'active';

    IF v_competitor_count > 1 THEN
        SELECT COALESCE(flights_per_week, 0) INTO v_my_frequency
        FROM route_assignments
        WHERE origin_iata = p_origin_iata
          AND destination_iata = p_destination_iata
          AND user_id = p_user_id
          AND status = 'active'
        LIMIT 1;

        SELECT COALESCE(SUM(flights_per_week), 1) INTO v_total_frequency
        FROM route_assignments
        WHERE origin_iata = p_origin_iata
          AND destination_iata = p_destination_iata
          AND status = 'active';

        IF v_total_frequency > 0 THEN
            v_competition_factor := v_my_frequency::NUMERIC / v_total_frequency;
        END IF;
    END IF;

    v_congestion_factor := calculate_airport_congestion_factor(p_origin_iata);
    v_hub_bonus := calculate_hub_bonus(p_origin_iata, p_user_id);

    RETURN GREATEST(0, FLOOR(v_base_passengers * v_competition_factor * v_congestion_factor * v_hub_bonus)::INT);
END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================================================
-- 12. Wire record_rank_snapshot into process_world_tick
-- ============================================================================
CREATE OR REPLACE FUNCTION process_world_tick(
    p_season_id UUID DEFAULT NULL,
    p_max_ticks INT DEFAULT 10
)
RETURNS TABLE (
    season_id UUID,
    game_time_before TIMESTAMP WITH TIME ZONE,
    game_time_after TIMESTAMP WITH TIME ZONE,
    ticks_processed INT,
    real_seconds_processed NUMERIC,
    game_seconds_processed NUMERIC,
    players_processed INT,
    bots_processed INT,
    status VARCHAR,
    message TEXT
) AS $$
DECLARE
    r_season RECORD;
    r_user RECORD;
    r_player_result RECORD;
    v_season_id UUID;
    v_now TIMESTAMP WITH TIME ZONE := NOW();
    v_log_id BIGINT;
    v_elapsed_real_seconds NUMERIC(20,4);
    v_due_ticks INT;
    v_ticks_to_process INT;
    v_real_seconds NUMERIC(20,4);
    v_game_seconds NUMERIC(20,4);
    v_game_time_after TIMESTAMP WITH TIME ZONE;
    v_players_processed INT := 0;
    v_bots_processed INT := 0;
BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtext('skyward.process_world_tick')::BIGINT) THEN
        RETURN QUERY SELECT
            p_season_id,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::TIMESTAMP WITH TIME ZONE,
            0,
            0.0000::NUMERIC,
            0.0000::NUMERIC,
            0,
            0,
            'skipped'::VARCHAR,
            'World tick already running.'::TEXT;
        RETURN;
    END IF;

    v_season_id := resolve_active_season_id(p_season_id);
    IF v_season_id IS NULL THEN
        RETURN QUERY SELECT
            NULL::UUID,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::TIMESTAMP WITH TIME ZONE,
            0,
            0.0000::NUMERIC,
            0.0000::NUMERIC,
            0,
            0,
            'error'::VARCHAR,
            'No active season found.'::TEXT;
        RETURN;
    END IF;

    SELECT *
    INTO r_season
    FROM season_clock sc
    WHERE sc.id = v_season_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            v_season_id,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::TIMESTAMP WITH TIME ZONE,
            0,
            0.0000::NUMERIC,
            0.0000::NUMERIC,
            0,
            0,
            'error'::VARCHAR,
            'Season not found.'::TEXT;
        RETURN;
    END IF;

    INSERT INTO world_tick_log (season_id, game_time_before, status)
    VALUES (r_season.id, r_season.current_game_time, 'started')
    RETURNING id INTO v_log_id;

    IF r_season.status <> 'active' THEN
        UPDATE world_tick_log
        SET finished_at = v_now,
            game_time_after = r_season.current_game_time,
            status = 'skipped',
            message = 'Season is not active.'
        WHERE id = v_log_id;

        RETURN QUERY SELECT
            r_season.id,
            r_season.current_game_time,
            r_season.current_game_time,
            0,
            0.0000::NUMERIC,
            0.0000::NUMERIC,
            0,
            0,
            'skipped'::VARCHAR,
            'Season is not active.'::TEXT;
        RETURN;
    END IF;

    v_elapsed_real_seconds := GREATEST(
        0.0000,
        EXTRACT(EPOCH FROM (v_now - r_season.last_tick_at))::NUMERIC
    );
    v_due_ticks := FLOOR(v_elapsed_real_seconds / r_season.tick_interval_seconds)::INT;
    v_ticks_to_process := LEAST(GREATEST(COALESCE(p_max_ticks, 1), 1), v_due_ticks);

    IF v_ticks_to_process <= 0 THEN
        UPDATE world_tick_log
        SET finished_at = v_now,
            game_time_after = r_season.current_game_time,
            status = 'skipped',
            message = 'No due world ticks.'
        WHERE id = v_log_id;

        RETURN QUERY SELECT
            r_season.id,
            r_season.current_game_time,
            r_season.current_game_time,
            0,
            0.0000::NUMERIC,
            0.0000::NUMERIC,
            0,
            0,
            'skipped'::VARCHAR,
            'No due world ticks.'::TEXT;
        RETURN;
    END IF;

    v_real_seconds := v_ticks_to_process * r_season.tick_interval_seconds;
    v_game_seconds := v_real_seconds * r_season.time_scale_multiplier;
    v_game_time_after := r_season.current_game_time + (v_game_seconds::DOUBLE PRECISION * INTERVAL '1 second');

    UPDATE season_clock sc
    SET current_game_time = v_game_time_after,
        last_tick_at = r_season.last_tick_at + (v_real_seconds::DOUBLE PRECISION * INTERVAL '1 second'),
        updated_at = v_now
    WHERE sc.id = r_season.id;

    PERFORM generate_game_events(v_game_time_after);
    PERFORM deactivate_expired_events(v_game_time_after);

    FOR r_user IN
        SELECT u.id
        FROM users u
        WHERE u.season_id = r_season.id
    LOOP
        SELECT *
        INTO r_player_result
        FROM process_player_simulation_to_time(r_user.id, v_game_time_after)
        LIMIT 1;

        IF COALESCE(r_player_result.elapsed_game_days, 0.0) > 0.0 THEN
            v_players_processed := v_players_processed + 1;
        END IF;
    END LOOP;

    v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);

    -- Record rank snapshot once per game day
    IF date_trunc('day', r_season.current_game_time)::DATE <>
       date_trunc('day', v_game_time_after)::DATE THEN
        PERFORM record_rank_snapshot(date_trunc('day', v_game_time_after)::DATE);
    END IF;

    UPDATE world_tick_log
    SET finished_at = NOW(),
        game_time_after = v_game_time_after,
        ticks_processed = v_ticks_to_process,
        real_seconds_processed = v_real_seconds,
        game_seconds_processed = v_game_seconds,
        players_processed = v_players_processed,
        bots_processed = v_bots_processed,
        status = 'success',
        message = 'Season clock and actor state advanced from shared world tick.'
    WHERE id = v_log_id;

    RETURN QUERY SELECT
        r_season.id,
        r_season.current_game_time,
        v_game_time_after,
        v_ticks_to_process,
        v_real_seconds,
        v_game_seconds,
        v_players_processed,
        v_bots_processed,
        'success'::VARCHAR,
        'Season clock and actor state advanced from shared world tick.'::TEXT;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 13. Fix get_credit_report — write back credit_tier to users table
-- ============================================================================
CREATE OR REPLACE FUNCTION get_credit_report()
RETURNS TABLE (
    current_score        INT,
    fleet_health         INT,
    revenue_stability    INT,
    debt_ratio           INT,
    cash_reserve         INT,
    profit_history       INT,
    credit_tier          VARCHAR(20),
    max_unsecured_loan   NUMERIC,
    max_secured_loan     NUMERIC,
    max_financing_amount NUMERIC,
    base_interest_rate   NUMERIC,
    suggestions          TEXT[]
) AS $$
DECLARE
    v_user_id  UUID;
    v_score    RECORD;
    v_tier     VARCHAR(20);
    v_config   JSONB;
    v_tier_cfg JSONB;
    v_sugg     TEXT[] := '{}';
BEGIN
    v_user_id := require_current_user_id();

    SELECT credit_tier_config INTO v_config
    FROM global_game_settings WHERE id = 1;

    SELECT * INTO v_score
    FROM calculate_credit_score(v_user_id)
    LIMIT 1;

    IF NOT FOUND THEN
        current_score      := 500;
        fleet_health       := 100;
        revenue_stability  := 100;
        debt_ratio         := 100;
        cash_reserve       := 100;
        profit_history     := 100;
        credit_tier        := 'Standard';
        max_unsecured_loan := 5000000;
        max_secured_loan   := 25000000;
        max_financing_amount := 20000000;
        base_interest_rate := 0.07;
        suggestions        := ARRAY['Build your fleet and routes to establish credit history.'];
        RETURN NEXT;
        RETURN;
    END IF;

    v_tier := resolve_credit_tier(v_score.total_score);

    -- Write back to users.credit_score AND users.credit_tier cache
    UPDATE users SET credit_score = v_score.total_score,
                     credit_tier  = v_tier
    WHERE id = v_user_id;

    -- Upsert into credit_scores table
    INSERT INTO credit_scores (
        user_id, score, tier,
        fleet_health_score, revenue_stability_score,
        debt_ratio_score, cash_reserves_score, profit_history_score,
        computed_at
    ) VALUES (
        v_user_id, v_score.total_score, v_tier,
        v_score.fleet_health, v_score.revenue_stability,
        v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history,
        NOW()
    )
    ON CONFLICT (user_id) DO UPDATE SET
        score = EXCLUDED.score,
        tier = EXCLUDED.tier,
        fleet_health_score = EXCLUDED.fleet_health_score,
        revenue_stability_score = EXCLUDED.revenue_stability_score,
        debt_ratio_score = EXCLUDED.debt_ratio_score,
        cash_reserves_score = EXCLUDED.cash_reserves_score,
        profit_history_score = EXCLUDED.profit_history_score,
        computed_at = EXCLUDED.computed_at;

    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);

    current_score    := v_score.total_score;
    fleet_health     := v_score.fleet_health;
    revenue_stability := v_score.revenue_stability;
    debt_ratio       := v_score.debt_ratio;
    cash_reserve     := v_score.cash_reserve;
    profit_history   := v_score.profit_history;
    credit_tier      := v_tier;

    max_unsecured_loan  := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
    max_secured_loan    := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
    max_financing_amount := COALESCE((v_tier_cfg->>'max_financing')::NUMERIC, 20000000);
    base_interest_rate  := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);

    IF v_score.fleet_health < 100 THEN
        v_sugg := array_append(v_sugg,
            'Maintain your aircraft — low fleet condition hurts your credit.');
    END IF;
    IF v_score.revenue_stability < 100 THEN
        v_sugg := array_append(v_sugg,
            'Operate routes consistently — irregular revenue lowers your score.');
    END IF;
    IF v_score.debt_ratio < 100 THEN
        v_sugg := array_append(v_sugg,
            'Reduce outstanding debt to improve borrowing capacity.');
    END IF;
    IF v_score.cash_reserve < 100 THEN
        v_sugg := array_append(v_sugg,
            'Build cash reserves — low cash hurts your credit score.');
    END IF;
    IF v_score.profit_history < 100 THEN
        v_sugg := array_append(v_sugg,
            'Improve profitability — consistent losses damage your credit.');
    END IF;
    IF v_sugg = '{}'::TEXT[] THEN
        v_sugg := ARRAY['Excellent credit profile. Keep it up!'];
    END IF;
    suggestions := v_sugg;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION get_credit_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_credit_report() TO authenticated;


-- ============================================================================
-- 14. Drop redundant AI-specific objects if they exist
-- ============================================================================
DROP FUNCTION IF EXISTS calculate_ai_net_worth(UUID);
DROP FUNCTION IF EXISTS trg_update_ai_net_worth();
DROP TRIGGER IF EXISTS trg_ai_cash_change ON users;

COMMIT;
