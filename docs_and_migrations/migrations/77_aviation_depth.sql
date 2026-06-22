-- ============================================================================
-- SKYWARD AVIATION DEPTH
-- ============================================================================
-- Adds six layers of aviation realism to the simulation engine:
--
-- FIX 1: Per-aircraft-type turnaround times on aircraft_models, replacing the
--         hardcoded 1.0-hour turnaround in max-flights-per-week calculations.
-- FIX 2: Fare-class demand elasticity — business and first-class passengers
--         respond to fare pricing with diminishing demand curves.
-- FIX 3: Crew cost model — captain, first officer, and cabin crew costs
--         added as a per-flight-hour expense.
-- FIX 4: Variable turnaround impact on scheduling — new 3-param overload of
--         calculate_route_max_weekly_flights that uses aircraft turnaround.
-- FIX 5: Seasonal demand modifiers — peak (Jun-Aug, Dec), normal (Mar-May,
--         Sep), and off-season (Jan-Feb, Oct-Nov) multipliers on passengers.
-- FIX 6: Maintenance check milestones — A-check every 500 flights and
--         C-check every 3000 flights with condition penalties if overdue.
-- ============================================================================


-- ============================================================================
-- FIX 1: Per-aircraft-type turnaround hours
-- ============================================================================
-- Adds turnaround_hours to aircraft_models so each aircraft class carries its
-- own ground-handling time. Regional turboprops turn faster than wide-bodies.

ALTER TABLE aircraft_models
    ADD COLUMN IF NOT EXISTS turnaround_hours NUMERIC DEFAULT 1.0;

-- Set realistic turnaround times based on seat capacity
UPDATE aircraft_models SET turnaround_hours = 0.5  WHERE capacity <= 80;                       -- Regional turboprops
UPDATE aircraft_models SET turnaround_hours = 0.75 WHERE capacity > 80  AND capacity <= 200;   -- Narrow-bodies
UPDATE aircraft_models SET turnaround_hours = 1.5  WHERE capacity > 200 AND capacity <= 350;   -- Wide-bodies
UPDATE aircraft_models SET turnaround_hours = 2.0  WHERE capacity > 350;                       -- Ultra-wide-bodies

COMMENT ON COLUMN aircraft_models.turnaround_hours IS
'Ground-handling time in hours between landing and next takeoff. Set by aircraft size class (0.5–2.0 hrs).';


-- ============================================================================
-- FIX 4: New calculate_route_max_weekly_flights overload with turnaround
-- ============================================================================
-- A new 3-param overload that accepts a turnaround_hours value. The existing
-- 2-param overload (from migration 52) is preserved for backward compat and
-- remains used by the owner-optimizer and route assignment checks.

CREATE OR REPLACE FUNCTION calculate_route_max_weekly_flights(
    p_distance_km DOUBLE PRECISION,
    p_speed_kmh INT,
    p_turnaround_hours NUMERIC
)
RETURNS INT AS $$
    SELECT CASE
        WHEN COALESCE(p_distance_km, 0.0) <= 0.0
          OR COALESCE(p_speed_kmh, 0) <= 0 THEN 0
        ELSE FLOOR(
            168.0 /
            NULLIF(
                (COALESCE(p_distance_km, 0.0) / p_speed_kmh::DOUBLE PRECISION)
                + COALESCE(p_turnaround_hours, 1.0),
                0.0
            )
        )::INT
    END;
$$ LANGUAGE sql IMMUTABLE;


-- ============================================================================
-- FIX 6: Maintenance check milestones on user_fleet
-- ============================================================================
-- Tracks total flights accumulated per airframe and the flight counts at
-- which the last A-check and C-check were performed. Enables scheduled
-- maintenance milestones (A-check every 500 flights, C-check every 3000).

ALTER TABLE user_fleet
    ADD COLUMN IF NOT EXISTS total_flights INT DEFAULT 0;

ALTER TABLE user_fleet
    ADD COLUMN IF NOT EXISTS last_a_check_at INT DEFAULT 0;

ALTER TABLE user_fleet
    ADD COLUMN IF NOT EXISTS last_c_check_at INT DEFAULT 0;

COMMENT ON COLUMN user_fleet.total_flights IS
'Total number of flights completed by this airframe since acquisition.';
COMMENT ON COLUMN user_fleet.last_a_check_at IS
'Flight count at which the last A-check was performed (every 500 flights).';
COMMENT ON COLUMN user_fleet.last_c_check_at IS
'Flight count at which the last C-check was performed (every 3000 flights).';


-- ============================================================================
-- FIX 2 + 3 + 5 + 6: Player simulation with all depth features
-- ============================================================================
-- Replaces the version from migration 75. Adds:
--   - Fare-class demand elasticity (FIX 2)
--   - Crew cost per flight hour (FIX 3)
--   - Seasonal demand modifiers (FIX 5)
--   - Variable turnaround in max-flights calculation (FIX 4)
--   - Maintenance check milestones (FIX 6)

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
    v_crew_cost NUMERIC(20,2) := 0;
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
    v_total_seats INT;
    v_economy_pax NUMERIC;
    v_business_pax NUMERIC;
    v_first_pax NUMERIC;
    -- Event system variables
    v_fuel_price_multiplier NUMERIC := 1.0;
    v_demand_multiplier NUMERIC := 1.0;
    -- Catch-up subsidy variables
    v_leader_net_worth NUMERIC := 0;
    v_player_net_worth NUMERIC := 0;
    v_asset_value NUMERIC := 0;
    v_gap_ratio NUMERIC;
    v_subsidy NUMERIC := 0;
    -- FIX 2: Fare-class demand elasticity
    v_base_fare NUMERIC;
    v_business_demand NUMERIC;
    v_first_demand NUMERIC;
    -- FIX 3: Crew cost model
    v_crew_cost_per_hour NUMERIC := 350.0;
    -- FIX 5: Seasonal demand
    v_seasonal_multiplier NUMERIC := 1.0;
    v_game_month INT;
    -- FIX 6: Maintenance milestones
    v_fleet_total_flights INT;
    v_fleet_last_a_check INT;
    v_fleet_last_c_check INT;
    v_turnaround_hours NUMERIC;
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

    -- Check for active global fuel price events
    SELECT COALESCE(
        (SELECT effect_value FROM game_events
         WHERE effect_type = 'fuel_price' AND effect_target = 'global'
           AND is_active = true
           AND start_game_time <= p_target_game_time
           AND end_game_time > p_target_game_time
         ORDER BY start_game_time DESC LIMIT 1),
        1.0
    ) INTO v_fuel_price_multiplier;

    -- FIX 5: Compute seasonal demand multiplier from game date month
    v_game_month := EXTRACT(MONTH FROM p_target_game_time);
    v_seasonal_multiplier := CASE
        WHEN v_game_month IN (6, 7, 8, 12) THEN 1.15   -- Peak: summer & holidays
        WHEN v_game_month IN (3, 4, 5, 9)   THEN 1.0    -- Normal: spring & early fall
        ELSE 0.90                                        -- Off-season: Jan, Feb, Oct, Nov
    END;

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
        WHERE r.user_id = p_user_id
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
                p_user_id
            );

            -- Apply demand events at this route's airports
            SELECT COALESCE(
                (SELECT effect_value FROM game_events
                 WHERE effect_type = 'demand_index' AND effect_target = v_route.origin_iata
                   AND is_active = true
                   AND start_game_time <= p_target_game_time
                   AND end_game_time > p_target_game_time
                 ORDER BY start_game_time DESC LIMIT 1),
                1.0
            ) INTO v_demand_multiplier;

            -- FIX 5: Apply seasonal demand modifier
            v_passengers := GREATEST(0, FLOOR(v_passengers * v_demand_multiplier * v_seasonal_multiplier));

            -- Premium cabin revenue: distribute passengers across seat classes
            v_total_seats := COALESCE(v_route.economy_seats, 0)
                           + COALESCE(v_route.business_seats, 0)
                           + COALESCE(v_route.first_class_seats, 0);

            IF v_total_seats > 0 THEN
                v_economy_pax := v_passengers * (v_route.economy_seats::NUMERIC / v_total_seats);
                v_business_pax := v_passengers * (v_route.business_seats::NUMERIC / v_total_seats);
                v_first_pax := v_passengers * (v_route.first_class_seats::NUMERIC / v_total_seats);

                -- FIX 2: Fare-class demand elasticity
                -- Premium cabins attract fewer passengers than a simple seat-ratio split
                -- would suggest. The quadratic demand model:
                --   demand = a - b * (fare_ratio)^2
                -- where fare_ratio = actual_cabin_fare / base_economy_fare.
                --
                -- Business: f(x) = 1.2 - 0.5*x^2  → at 2.5x: 1.2 - 0.5*6.25 = -1.925 (clamped 0)
                -- First:    f(x) = 1.5 - 0.8*x^2  → at 4.0x: 1.5 - 0.8*16.0 = -11.3  (clamped 0)
                --
                -- These produce near-zero raw demand at standard multipliers, which is
                -- unrealistic. Instead, normalize the ratio so that the STANDARD cabin
                -- multiplier yields a demand factor of ~0.7 (the realistic "premium load
                -- factor" — only 70% of the proportional split actually books premium):
                --   ratio = (actual_cabin_multiplier / nominal_cabin_multiplier)
                --   business nominal = 2.5, first nominal = 4.0
                -- At ratio=1.0: demand = 1.2 - 0.5*1.0 = 0.7  (business, 30% fewer pax)
                -- At ratio=1.0: demand = 1.5 - 0.8*1.0 = 0.7  (first, 30% fewer pax)
                -- At ratio=1.2: demand = 1.2 - 0.5*1.44 = 0.48 (business, steep drop)
                -- At ratio=1.2: demand = 1.5 - 0.8*1.44 = 0.348 (first, steeper drop)
                --
                -- Since all cabins currently use fixed multipliers (2.5x/4.0x), ratio=1.0
                -- always, so demand = 0.7 for both. The formula is structured for future
                -- dynamic per-route pricing where operators can set custom multipliers.

                -- Compute the fare ratio: current cabin premium / nominal premium
                -- For now the cabin multipliers are fixed, so ratio = 1.0
                v_business_demand := GREATEST(0.0, 1.2 - 0.5 * POWER(1.0, 2));  -- = 0.7
                v_first_demand    := GREATEST(0.0, 1.5 - 0.8 * POWER(1.0, 2));  -- = 0.7

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

            -- Apply fuel price event multiplier to fuel cost
            v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier, 0.00);
            v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
            v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);

            -- FIX 3: Crew cost = $350/hr * flight hours
            v_crew_cost := COALESCE(v_flights * v_flight_duration * v_crew_cost_per_hour, 0.00);

            v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost + v_crew_cost);

            -- FIX 4: Use per-aircraft turnaround in max-flights calculation
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

            -- FIX 6: Maintenance check milestones
            v_fleet_total_flights := COALESCE(v_route.total_flights, 0) + ROUND(v_flights)::INT;
            v_fleet_last_a_check := COALESCE(v_route.last_a_check_at, 0);
            v_fleet_last_c_check := COALESCE(v_route.last_c_check_at, 0);

            -- A-check every 500 flights: 10% condition penalty if skipped
            IF v_fleet_total_flights >= v_fleet_last_a_check + 500 THEN
                v_net_damage := v_net_damage + 10.0;
                v_fleet_last_a_check := v_fleet_total_flights;
            END IF;

            -- C-check every 3000 flights: 25% condition penalty if skipped
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
            v_completed_flights_all := v_completed_flights_all + ROUND(v_flights)::INT;
        END IF;
    END LOOP;

    v_total_revenue := GREATEST(0.00, COALESCE(v_total_revenue, 0.00));
    v_total_cost_accum := GREATEST(0.00, COALESCE(v_total_cost_accum, 0.00));
    v_net := v_total_revenue - v_total_cost_accum - v_lease_cost;

    -- ========================================================================
    -- Catch-up subsidy for players far behind the leader (from migration 75)
    -- ========================================================================
    SELECT COALESCE(SUM(am.purchase_price * 0.7), 0)
    INTO v_asset_value
    FROM user_fleet uf
    JOIN aircraft_models am ON uf.aircraft_model_id = am.id
    WHERE uf.user_id = p_user_id AND uf.status = 'active';

    v_player_net_worth := r_user.cash + v_asset_value;

    SELECT MAX(sub.net_worth) INTO v_leader_net_worth
    FROM (
        SELECT u.cash + COALESCE(
            (SELECT SUM(am2.purchase_price * 0.7)
             FROM user_fleet uf2
             JOIN aircraft_models am2 ON uf2.aircraft_model_id = am2.id
             WHERE uf2.user_id = u.id AND uf2.status = 'active'),
            0
        ) AS net_worth
        FROM users u
        WHERE u.operational_status != 'Bankrupt'
          AND u.season_id = r_user.season_id
    ) sub;

    v_leader_net_worth := COALESCE(v_leader_net_worth, 0);

    IF v_leader_net_worth > 0 AND v_player_net_worth < (v_leader_net_worth * 0.3) THEN
        v_gap_ratio := v_player_net_worth / v_leader_net_worth;
        v_subsidy := v_total_revenue * (0.3 - v_gap_ratio) * 0.33;
        v_subsidy := GREATEST(0, LEAST(v_subsidy, v_total_revenue * 0.10));

        IF v_subsidy > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'subsidy', v_subsidy, 'Government route subsidy', date_trunc('day', p_target_game_time));
            v_net := v_net + v_subsidy;
        END IF;
    END IF;

    v_buffered_rev_accum := COALESCE(r_user.buffered_revenue, 0.00) + v_total_revenue + v_subsidy;
    v_buffered_ops_accum := COALESCE(r_user.buffered_ops_cost, 0.00) + v_total_cost_accum;
    v_buffered_lease_accum := COALESCE(r_user.buffered_lease_cost, 0.00) + v_lease_cost;

    IF date_trunc('day', p_target_game_time) > date_trunc('day', r_user.game_current_time) THEN
        IF v_buffered_rev_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active routes', date_trunc('day', p_target_game_time));
        END IF;

        IF v_buffered_ops_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew, maintenance, & landing fees', date_trunc('day', p_target_game_time));
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


-- ============================================================================
-- FIX 2 + 3 + 5 + 6: Bot simulation with all depth features
-- ============================================================================
-- Replaces the version from migration 75. Same depth additions as the player
-- simulation: fare-class elasticity, crew costs, seasonal demand, variable
-- turnaround, and maintenance check milestones.

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
    -- Event system variables
    v_fuel_price_multiplier NUMERIC := 1.0;
    v_demand_multiplier NUMERIC := 1.0;
    -- FIX 2: Fare-class demand elasticity
    v_base_fare NUMERIC;
    v_business_demand NUMERIC;
    v_first_demand NUMERIC;
    -- FIX 3: Crew cost model
    v_crew_cost_per_hour NUMERIC := 350.0;
    -- FIX 5: Seasonal demand
    v_seasonal_multiplier NUMERIC := 1.0;
    v_game_month INT;
    -- FIX 6: Maintenance milestones
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

    -- Check for active global fuel price events (shared across all bots)
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

        -- FIX 5: Seasonal demand multiplier from game date
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

                -- Apply demand events at this route's origin airport
                SELECT COALESCE(
                    (SELECT effect_value FROM game_events
                     WHERE effect_type = 'demand_index' AND effect_target = v_route.origin_iata
                       AND is_active = true
                       AND start_game_time <= p_target_game_time
                       AND end_game_time > p_target_game_time
                     ORDER BY start_game_time DESC LIMIT 1),
                    1.0
                ) INTO v_demand_multiplier;

                -- FIX 5: Apply seasonal demand modifier
                v_passengers := GREATEST(0, FLOOR(v_passengers * v_demand_multiplier * v_seasonal_multiplier));

                -- Premium cabin revenue: distribute passengers across seat classes
                v_total_seats := COALESCE(v_route.economy_seats, 0)
                               + COALESCE(v_route.business_seats, 0)
                               + COALESCE(v_route.first_class_seats, 0);

                IF v_total_seats > 0 THEN
                    v_economy_pax := v_passengers * (v_route.economy_seats::NUMERIC / v_total_seats);
                    v_business_pax := v_passengers * (v_route.business_seats::NUMERIC / v_total_seats);
                    v_first_pax := v_passengers * (v_route.first_class_seats::NUMERIC / v_total_seats);

                    -- FIX 2: Fare-class demand elasticity (same model as player simulation)
                    -- At the standard 2.5x/4.0x cabin multipliers, demand = 0.7 for both
                    -- premium cabins (30% fewer passengers than seat-ratio split).
                    -- See player simulation comments for full derivation.
                    v_business_demand := GREATEST(0.0, 1.2 - 0.5 * POWER(1.0, 2));  -- = 0.7
                    v_first_demand    := GREATEST(0.0, 1.5 - 0.8 * POWER(1.0, 2));  -- = 0.7

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

                -- Apply fuel price event multiplier
                v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier, 0.00);
                v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
                v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);

                -- FIX 3: Crew cost = $350/hr * flight hours
                v_crew_cost := COALESCE(v_flights * v_flight_duration * v_crew_cost_per_hour, 0.00);

                v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost + v_crew_cost);

                -- FIX 4: Use per-aircraft turnaround in max-flights calculation
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

                -- FIX 6: Maintenance check milestones
                v_fleet_total_flights := COALESCE(v_route.total_flights, 0) + ROUND(v_flights)::INT;
                v_fleet_last_a_check := COALESCE(v_route.last_a_check_at, 0);
                v_fleet_last_c_check := COALESCE(v_route.last_c_check_at, 0);

                -- A-check every 500 flights: 10% condition penalty if overdue
                IF v_fleet_total_flights >= v_fleet_last_a_check + 500 THEN
                    v_net_damage := v_net_damage + 10.0;
                    v_fleet_last_a_check := v_fleet_total_flights;
                END IF;

                -- C-check every 3000 flights: 25% condition penalty if overdue
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


-- ============================================================================
-- Comments
-- ============================================================================

COMMENT ON FUNCTION calculate_route_max_weekly_flights(DOUBLE PRECISION, INT, NUMERIC) IS
'3-param overload that accepts per-aircraft turnaround_hours. Used by simulation engine for accurate scheduling capacity.';

COMMENT ON FUNCTION process_player_simulation_to_time(UUID, TIMESTAMP WITH TIME ZONE) IS
'Processes one player simulation tick. Adds aviation depth: per-aircraft turnaround, fare-class demand elasticity, crew costs, seasonal demand modifiers, and A/C-check maintenance milestones.';

COMMENT ON FUNCTION process_all_bots_simulation_to_time(TIMESTAMP WITH TIME ZONE, UUID) IS
'Processes all active bots for one simulation tick. Adds aviation depth: per-aircraft turnaround, fare-class demand elasticity, crew costs, seasonal demand modifiers, and A/C-check maintenance milestones.';
