-- ============================================================================
-- SKYWARD HUB BONUS AND FINANCIAL HISTORY
-- ============================================================================
-- Adds hub-and-spoke mechanics and historical trend visualization.
--
-- FIX 1: Hub bonus helper — when multiple routes share the same origin
--         airport, each route gets a small demand boost (hub effect).
--         2% per additional route, capped at 20%.
-- FIX 2: Integrate hub bonus into calculate_route_expected_passengers
--         (8-param overload) so all passenger calculations benefit from
--         the hub effect automatically.
-- FIX 3: financial_snapshots table — stores daily financial snapshots
--         for historical trend visualization in the UI.
-- FIX 4: Record daily snapshot at end of each game day in
--         process_player_simulation_to_time.
-- ============================================================================


-- ============================================================================
-- FIX 1: Hub bonus calculation helper
-- ============================================================================
-- Returns a multiplier (1.0 to 1.20) based on how many active routes
-- share the same origin airport for a given user/bot. A second function
-- returns the raw bonus percentage for UI display.

CREATE OR REPLACE FUNCTION calculate_hub_bonus(
    p_origin_iata VARCHAR(3),
    p_user_id UUID
)
RETURNS NUMERIC AS $$
DECLARE
    v_hub_routes_count INT;
BEGIN
    SELECT COUNT(*) INTO v_hub_routes_count
    FROM user_routes
    WHERE origin_iata = p_origin_iata
      AND (user_id = p_user_id OR ai_competitor_id = p_user_id)
      AND status = 'active';

    IF v_hub_routes_count > 1 THEN
        RETURN 1.0 + LEAST((v_hub_routes_count - 1) * 0.02, 0.20);
    END IF;

    RETURN 1.0;
END;
$$ LANGUAGE plpgsql STABLE;


-- Helper for UI: returns the bonus as a percentage (e.g. 12.0 for "+12%")
CREATE OR REPLACE FUNCTION get_hub_bonus_percentage(
    p_origin_iata VARCHAR(3),
    p_user_id UUID
)
RETURNS NUMERIC AS $$
DECLARE
    v_hub_routes_count INT;
BEGIN
    SELECT COUNT(*) INTO v_hub_routes_count
    FROM user_routes
    WHERE origin_iata = p_origin_iata
      AND (user_id = p_user_id OR ai_competitor_id = p_user_id)
      AND status = 'active';

    IF v_hub_routes_count > 1 THEN
        RETURN LEAST((v_hub_routes_count - 1) * 2.0, 20.0);
    END IF;

    RETURN 0.0;
END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================================================
-- FIX 2: Updated passenger calculation with hub bonus
-- ============================================================================
-- Replaces the 8-param overload from migration 74. Adds the hub bonus
-- multiplier on top of existing competition and congestion factors.

CREATE OR REPLACE FUNCTION calculate_route_expected_passengers(
    p_capacity INT,
    p_distance_km DOUBLE PRECISION,
    p_ticket_price NUMERIC,
    p_origin_demand INT,
    p_destination_demand INT,
    p_origin_iata VARCHAR(3),
    p_destination_iata VARCHAR(3),
    p_user_id UUID
)
RETURNS INT AS $$
DECLARE
    v_base_passengers INT;
    v_competitor_count INT;
    v_my_frequency INT;
    v_total_frequency INT;
    v_competition_factor NUMERIC := 1.0;
    v_congestion_factor NUMERIC := 1.0;
    v_hub_bonus NUMERIC := 1.0;
BEGIN
    -- Base passenger calculation (same formula as the 5-param overload)
    v_base_passengers := GREATEST(
        0,
        LEAST(
            COALESCE(p_capacity, 0),
            FLOOR(
                COALESCE(p_capacity, 0) *
                0.95 *
                calculate_airport_demand_factor(p_origin_demand, p_destination_demand) *
                calculate_route_demand_multiplier(p_distance_km, p_ticket_price)
            )::INT
        )
    );

    -- Competition factor: split demand when multiple actors serve same route
    SELECT COUNT(*) INTO v_competitor_count
    FROM user_routes
    WHERE origin_iata = p_origin_iata
      AND destination_iata = p_destination_iata
      AND status = 'active';

    IF v_competitor_count > 1 THEN
        SELECT COALESCE(flights_per_week, 0) INTO v_my_frequency
        FROM user_routes
        WHERE origin_iata = p_origin_iata
          AND destination_iata = p_destination_iata
          AND (user_id = p_user_id OR ai_competitor_id = p_user_id)
          AND status = 'active'
        LIMIT 1;

        SELECT COALESCE(SUM(flights_per_week), 1) INTO v_total_frequency
        FROM user_routes
        WHERE origin_iata = p_origin_iata
          AND destination_iata = p_destination_iata
          AND status = 'active';

        IF v_total_frequency > 0 THEN
            v_competition_factor := v_my_frequency::NUMERIC / v_total_frequency;
        END IF;
    END IF;

    -- Congestion factor: reduce demand when the origin airport is overloaded
    v_congestion_factor := calculate_airport_congestion_factor(p_origin_iata);

    -- Hub bonus: boost demand when multiple routes share the same origin
    v_hub_bonus := calculate_hub_bonus(p_origin_iata, p_user_id);

    -- Apply all factors
    RETURN GREATEST(0, FLOOR(v_base_passengers * v_competition_factor * v_congestion_factor * v_hub_bonus)::INT);
END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================================================
-- FIX 3: Financial snapshots table for historical trends
-- ============================================================================

CREATE TABLE IF NOT EXISTS financial_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id),
    game_date DATE NOT NULL,
    cash NUMERIC NOT NULL,
    net_worth NUMERIC NOT NULL,
    daily_revenue NUMERIC DEFAULT 0,
    daily_expense NUMERIC DEFAULT 0,
    fleet_count INT DEFAULT 0,
    route_count INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, game_date)
);

ALTER TABLE financial_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS financial_snapshots_select_own ON financial_snapshots;
CREATE POLICY financial_snapshots_select_own
ON financial_snapshots
FOR SELECT TO authenticated
USING (user_id = (SELECT id FROM users WHERE auth_user_id = auth.uid()));

REVOKE ALL ON TABLE financial_snapshots FROM PUBLIC, anon, authenticated;
GRANT SELECT ON financial_snapshots TO authenticated;

CREATE INDEX IF NOT EXISTS financial_snapshots_user_date_idx
    ON financial_snapshots(user_id, game_date DESC);


-- ============================================================================
-- FIX 4: Player simulation with daily snapshot recording
-- ============================================================================
-- Replaces the version from migration 75. Adds:
--   - Hub bonus integration (already in calculate_route_expected_passengers)
--   - Daily financial snapshot recording at end of each game day

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
    -- Snapshot variables
    v_fleet_count INT := 0;
    v_route_count INT := 0;
    v_daily_revenue NUMERIC := 0;
    v_daily_expense NUMERIC := 0;
    v_game_date DATE;
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

            v_passengers := GREATEST(0, FLOOR(v_passengers * v_demand_multiplier));

            -- Premium cabin revenue: distribute passengers across seat classes
            v_total_seats := COALESCE(v_route.economy_seats, 0)
                           + COALESCE(v_route.business_seats, 0)
                           + COALESCE(v_route.first_class_seats, 0);

            IF v_total_seats > 0 THEN
                v_economy_pax := v_passengers * (v_route.economy_seats::NUMERIC / v_total_seats);
                v_business_pax := v_passengers * (v_route.business_seats::NUMERIC / v_total_seats);
                v_first_pax := v_passengers * (v_route.first_class_seats::NUMERIC / v_total_seats);

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

    -- ========================================================================
    -- Catch-up subsidy for players far behind the leader
    -- ========================================================================
    -- Compute the player's asset value (fleet resale value at 70% of purchase price)
    SELECT COALESCE(SUM(am.purchase_price * 0.7), 0)
    INTO v_asset_value
    FROM user_fleet uf
    JOIN aircraft_models am ON uf.aircraft_model_id = am.id
    WHERE uf.user_id = p_user_id AND uf.status = 'active';

    v_player_net_worth := r_user.cash + v_asset_value;

    -- Get the leader's net worth (highest cash + fleet value among non-bankrupt users)
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

    -- If player is less than 30% of leader, provide subsidy
    IF v_leader_net_worth > 0 AND v_player_net_worth < (v_leader_net_worth * 0.3) THEN
        v_gap_ratio := v_player_net_worth / v_leader_net_worth;
        -- Subsidy scales from 0% at 30% gap to ~10% at 0% gap
        v_subsidy := v_total_revenue * (0.3 - v_gap_ratio) * 0.33;
        v_subsidy := GREATEST(0, LEAST(v_subsidy, v_total_revenue * 0.10)); -- Cap at 10%

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
            VALUES (p_user_id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew maintenance, & landing fees', date_trunc('day', p_target_game_time));
        END IF;

        IF v_buffered_lease_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active fleet', date_trunc('day', p_target_game_time));
        END IF;

        DELETE FROM financial_ledger
        WHERE user_id = p_user_id
          AND game_date < (p_target_game_time - INTERVAL '30 days');

        -- ====================================================================
        -- Record daily financial snapshot for historical trends
        -- ====================================================================
        v_game_date := date_trunc('day', p_target_game_time)::DATE;

        -- Count fleet and routes for snapshot
        SELECT COUNT(*)::INT INTO v_fleet_count
        FROM user_fleet
        WHERE user_id = p_user_id AND status = 'active';

        SELECT COUNT(*)::INT INTO v_route_count
        FROM user_routes
        WHERE user_id = p_user_id AND status = 'active';

        -- Recalculate asset value for net worth snapshot
        SELECT COALESCE(SUM(am.purchase_price * 0.7), 0)
        INTO v_asset_value
        FROM user_fleet uf
        JOIN aircraft_models am ON uf.aircraft_model_id = am.id
        WHERE uf.user_id = p_user_id AND uf.status = 'active';

        v_daily_revenue := v_buffered_rev_accum;
        v_daily_expense := v_buffered_ops_accum + v_buffered_lease_accum;

        INSERT INTO financial_snapshots (
            user_id, game_date, cash, net_worth,
            daily_revenue, daily_expense,
            fleet_count, route_count
        )
        VALUES (
            p_user_id,
            v_game_date,
            r_user.cash + v_net,
            r_user.cash + v_net + v_asset_value,
            v_daily_revenue,
            v_daily_expense,
            v_fleet_count,
            v_route_count
        )
        ON CONFLICT (user_id, game_date) DO UPDATE SET
            cash = EXCLUDED.cash,
            net_worth = EXCLUDED.net_worth,
            daily_revenue = EXCLUDED.daily_revenue,
            daily_expense = EXCLUDED.daily_expense,
            fleet_count = EXCLUDED.fleet_count,
            route_count = EXCLUDED.route_count;

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
-- Comments
-- ============================================================================

COMMENT ON FUNCTION calculate_hub_bonus(VARCHAR, UUID) IS
'Returns a demand multiplier (1.0–1.20) based on hub-and-spoke effect. 2% bonus per additional active route sharing the same origin, capped at 20%.';

COMMENT ON FUNCTION get_hub_bonus_percentage(VARCHAR, UUID) IS
'Returns the hub bonus as a percentage (0–20) for UI display. E.g. returns 12.0 for a "+12% HUB BONUS" label.';

COMMENT ON TABLE financial_snapshots IS
'Daily financial snapshots for historical trend visualization. One row per user per game day.';

COMMENT ON FUNCTION process_player_simulation_to_time(UUID, TIMESTAMP WITH TIME ZONE) IS
'Processes one player simulation tick. Applies active game event multipliers (fuel price, demand), hub bonus, catch-up subsidy, and records daily financial snapshots.';
