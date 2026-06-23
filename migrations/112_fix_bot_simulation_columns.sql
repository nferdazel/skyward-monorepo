-- ============================================================================
-- Migration 112: Fix column reference bugs in simulation functions
-- ============================================================================
-- Fixes:
--   1. process_all_bots_simulation_to_time: m.passenger_capacity → m.capacity
--      (aircraft_models table has 'capacity', NOT 'passenger_capacity')
--   2. Remove v_passenger_capacity variable and simplify to use capacity directly
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Fix process_all_bots_simulation_to_time
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
                v_passengers := calculate_route_expected_passengers(
                    COALESCE(v_route.capacity, 0),
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

COMMENT ON FUNCTION process_all_bots_simulation_to_time(TIMESTAMP WITH TIME ZONE, UUID) IS
    'Simulates all AI bots forward to the given game time. Fixed: uses m.capacity (not m.passenger_capacity) for aircraft_models.';

COMMIT;
