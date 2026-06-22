-- ============================================================================
-- SKYWARD EVENT SYSTEM AND CATCH-UP MECHANICS
-- ============================================================================
-- Adds dynamic game events that affect simulation economics, and a subsidy
-- system to keep trailing players competitive.
--
-- FIX 1: game_events table — stores active world events with time-bounded
--         effects on fuel prices, demand, and airport taxes.
-- FIX 2: generate_game_events() — probabilistic event generator called each
--         world tick (5% chance per tick for one of four event types).
-- FIX 3: Integrate events into player and bot simulation — fuel price
--         multipliers and demand multipliers from active events are applied
--         to revenue/cost calculations.
-- FIX 4: Catch-up subsidy — players with net worth below 30% of the leader
--         receive a scaled government subsidy (capped at 10% of daily revenue).
-- FIX 5: deactivate_expired_events() — marks past events inactive, called
--         from process_world_tick after advancing the clock.
-- ============================================================================


-- ============================================================================
-- FIX 1: Event system table
-- ============================================================================

CREATE TABLE IF NOT EXISTS game_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type VARCHAR(50) NOT NULL,       -- 'fuel_shock', 'demand_surge', 'weather', 'regulatory'
    title VARCHAR(200) NOT NULL,
    description TEXT,
    effect_type VARCHAR(50) NOT NULL,      -- 'fuel_price', 'demand_index', 'airport_tax'
    effect_target TEXT,                     -- airport IATA code, 'global', etc.
    effect_value NUMERIC NOT NULL,         -- multiplier or absolute value
    start_game_time TIMESTAMPTZ NOT NULL,
    end_game_time TIMESTAMPTZ NOT NULL,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- RLS: events are world-readable, service-role writes
ALTER TABLE game_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS game_events_select_authenticated ON game_events;
CREATE POLICY game_events_select_authenticated
ON game_events
FOR SELECT TO authenticated
USING (true);

REVOKE ALL ON TABLE game_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON game_events TO authenticated;

-- Performance index: simulation queries filter by effect_type, target, and active time window
CREATE INDEX IF NOT EXISTS game_events_active_lookup_idx
    ON game_events(effect_type, effect_target, is_active, start_game_time, end_game_time)
    WHERE is_active = true;


-- ============================================================================
-- FIX 2: Event generation function
-- ============================================================================

CREATE OR REPLACE FUNCTION generate_game_events(p_game_time TIMESTAMPTZ)
RETURNS VOID AS $$
DECLARE
    v_roll NUMERIC;
    v_airport_iata VARCHAR(3);
    v_effect_value NUMERIC;
    v_title TEXT;
    v_description TEXT;
BEGIN
    -- 5% chance per tick to generate an event
    v_roll := random();
    IF v_roll > 0.05 THEN RETURN; END IF;

    -- Pick random event type
    CASE floor(random() * 4)
        WHEN 0 THEN -- Fuel price shock (global)
            v_effect_value := 0.7 + (random() * 0.6); -- 0.7x to 1.3x multiplier
            IF v_effect_value > 1.0 THEN
                v_title := 'Fuel Price Surge';
                v_description := 'Global fuel prices have increased by ' || ROUND((v_effect_value - 1) * 100) || '%';
            ELSE
                v_title := 'Fuel Price Drop';
                v_description := 'Global fuel prices have decreased by ' || ROUND((1 - v_effect_value) * 100) || '%';
            END IF;
            INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time)
            VALUES ('fuel_shock', v_title, v_description, 'fuel_price', 'global', v_effect_value, p_game_time, p_game_time + INTERVAL '72 hours');

        WHEN 1 THEN -- Demand surge at random airport
            SELECT iata INTO v_airport_iata FROM airports ORDER BY random() LIMIT 1;
            IF v_airport_iata IS NULL THEN RETURN; END IF;
            v_effect_value := 1.2 + (random() * 0.3); -- 1.2x to 1.5x demand
            v_title := 'Demand Surge at ' || v_airport_iata;
            v_description := 'Increased passenger demand at ' || v_airport_iata || ' airport';
            INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time)
            VALUES ('demand_surge', v_title, v_description, 'demand_index', v_airport_iata, v_effect_value, p_game_time, p_game_time + INTERVAL '48 hours');

        WHEN 2 THEN -- Weather disruption at high-demand airport
            SELECT iata INTO v_airport_iata FROM airports WHERE demand_index > 70 ORDER BY random() LIMIT 1;
            IF v_airport_iata IS NULL THEN
                -- Fallback: pick any airport
                SELECT iata INTO v_airport_iata FROM airports ORDER BY random() LIMIT 1;
            END IF;
            IF v_airport_iata IS NULL THEN RETURN; END IF;
            v_title := 'Weather Disruption at ' || v_airport_iata;
            v_description := 'Severe weather affecting operations at ' || v_airport_iata;
            INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time)
            VALUES ('weather', v_title, v_description, 'demand_index', v_airport_iata, 0.5, p_game_time, p_game_time + INTERVAL '24 hours');

        WHEN 3 THEN -- Regulatory change (global tax increase)
            v_effect_value := 1.05 + (random() * 0.15); -- 5-20% tax increase
            v_title := 'Airport Tax Increase';
            v_description := 'Airport taxes increased by ' || ROUND((v_effect_value - 1) * 100) || '% globally';
            INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time)
            VALUES ('regulatory', v_title, v_description, 'airport_tax', 'global', v_effect_value, p_game_time, p_game_time + INTERVAL '168 hours');
    END CASE;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- FIX 3: Player simulation with event integration
-- ============================================================================
-- Replaces the version from migration 73. Adds:
--   - v_fuel_price_multiplier: from active global fuel_price events
--   - v_demand_multiplier: from active demand_index events at route airports
--   - v_subsidy / v_leader_net_worth / v_player_net_worth / v_gap_ratio:
--     catch-up subsidy computation (FIX 4)

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
    -- FIX 4: Catch-up subsidy for players far behind the leader
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
-- FIX 3 (continued): Bot simulation with event integration
-- ============================================================================
-- Replaces the version from migration 73. Adds fuel price multiplier and
-- demand multiplier lookups from active game_events.

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
    v_total_seats INT;
    v_economy_pax NUMERIC;
    v_business_pax NUMERIC;
    v_first_pax NUMERIC;
    -- Event system variables
    v_fuel_price_multiplier NUMERIC := 1.0;
    v_demand_multiplier NUMERIC := 1.0;
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

                -- Apply fuel price event multiplier
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


-- ============================================================================
-- FIX 5: Deactivate expired events
-- ============================================================================

CREATE OR REPLACE FUNCTION deactivate_expired_events(p_game_time TIMESTAMPTZ)
RETURNS VOID AS $$
BEGIN
    UPDATE game_events
    SET is_active = false
    WHERE is_active = true
      AND end_game_time <= p_game_time;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- FIX 5 (continued): Wire event generation and deactivation into world tick
-- ============================================================================
-- Replaces the version from migration 43. Adds calls to:
--   - generate_game_events() after advancing the season clock
--   - deactivate_expired_events() after advancing the season clock

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

    -- Generate new events and deactivate expired ones after clock advance
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
-- Comments
-- ============================================================================

COMMENT ON TABLE game_events IS 'Time-bounded world events that modify simulation economics (fuel prices, demand, taxes).';

COMMENT ON FUNCTION generate_game_events(TIMESTAMPTZ) IS
'Generates random game events with 5% probability per tick. Called from process_world_tick after advancing the clock.';

COMMENT ON FUNCTION deactivate_expired_events(TIMESTAMPTZ) IS
'Marks expired game_events as inactive. Called from process_world_tick after advancing the clock.';

COMMENT ON FUNCTION process_player_simulation_to_time(UUID, TIMESTAMP WITH TIME ZONE) IS
'Processes one player simulation tick. Applies active game event multipliers (fuel price, demand) and catch-up subsidy for trailing players.';

COMMENT ON FUNCTION process_all_bots_simulation_to_time(TIMESTAMP WITH TIME ZONE, UUID) IS
'Processes all active bots for one simulation tick. Applies active game event multipliers (fuel price, demand).';

COMMENT ON FUNCTION process_world_tick(UUID, INT) IS
'Advances the active season clock, generates/deactivates game events, and synchronizes player/bot actors to the new season time.';
