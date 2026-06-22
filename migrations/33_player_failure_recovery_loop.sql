-- ============================================================================
-- SKYWARD PLAYER FAILURE AND RECOVERY LOOP
-- ============================================================================
-- Adds a soft player operational-status loop without hard-locking the account:
--   1. Users receive backend-owned operational status and streak counters.
--   2. process_simulation_delta updates those fields after each authoritative
--      economy cycle.
--   3. Auth/session RPCs return the new fields.
--   4. Airline reset clears the new lifecycle state.
-- ============================================================================

ALTER TABLE users
ADD COLUMN IF NOT EXISTS operational_status VARCHAR(20) NOT NULL DEFAULT 'Active';

ALTER TABLE users
ADD COLUMN IF NOT EXISTS consecutive_negative_days INT NOT NULL DEFAULT 0;

ALTER TABLE users
ADD COLUMN IF NOT EXISTS recovery_streak_days INT NOT NULL DEFAULT 0;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'users_operational_status_check'
    ) THEN
        ALTER TABLE users
        ADD CONSTRAINT users_operational_status_check
        CHECK (operational_status IN ('Active', 'Distress', 'Maintenance', 'Recovery'));
    END IF;
END $$;

UPDATE users
SET operational_status = 'Active',
    consecutive_negative_days = COALESCE(consecutive_negative_days, 0),
    recovery_streak_days = COALESCE(recovery_streak_days, 0)
WHERE operational_status IS NULL;

DROP FUNCTION IF EXISTS reset_user_airline(UUID) CASCADE;

CREATE FUNCTION reset_user_airline(p_user_id UUID)
RETURNS TABLE (
    success BOOLEAN,
    message TEXT
) AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RETURN QUERY SELECT FALSE, 'User not found';
        RETURN;
    END IF;

    DELETE FROM user_routes WHERE user_id = p_user_id;
    DELETE FROM user_fleet WHERE user_id = p_user_id;
    DELETE FROM financial_ledger WHERE user_id = p_user_id;

    UPDATE users
    SET cash = 15000000.00,
        game_current_time = TIMESTAMP WITH TIME ZONE '2020-01-01 00:00:00+00',
        hq_airport_iata = 'SIN',
        auto_grounding_threshold = 40.00,
        buffered_revenue = 0.00,
        buffered_ops_cost = 0.00,
        buffered_lease_cost = 0.00,
        operational_status = 'Active',
        consecutive_negative_days = 0,
        recovery_streak_days = 0,
        last_active_at = NOW()
    WHERE id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Airline reset successfully';
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS login_company(VARCHAR, VARCHAR) CASCADE;

CREATE OR REPLACE FUNCTION login_company(
    p_username VARCHAR,
    p_password VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    session_token VARCHAR,
    user_id UUID,
    user_username VARCHAR,
    company_name VARCHAR,
    ceo_name VARCHAR,
    cash NUMERIC,
    game_current_time TIMESTAMP WITH TIME ZONE,
    hq_airport_iata VARCHAR,
    auto_grounding_threshold NUMERIC,
    operational_status VARCHAR,
    consecutive_negative_days INT,
    recovery_streak_days INT
) AS $$
DECLARE
    r_user RECORD;
    v_token VARCHAR;
    v_expires TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT * INTO r_user FROM users WHERE username = LOWER(TRIM(p_username));

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE,
            'Invalid username or password.'::VARCHAR,
            NULL::VARCHAR,
            NULL::UUID,
            NULL::VARCHAR,
            NULL::VARCHAR,
            NULL::VARCHAR,
            0.00::NUMERIC,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::VARCHAR,
            30.00::NUMERIC,
            'Active'::VARCHAR,
            0,
            0;
        RETURN;
    END IF;

    IF r_user.password_hash != crypt(p_password, r_user.password_hash) THEN
        RETURN QUERY SELECT
            FALSE,
            'Invalid username or password.'::VARCHAR,
            NULL::VARCHAR,
            NULL::UUID,
            NULL::VARCHAR,
            NULL::VARCHAR,
            NULL::VARCHAR,
            0.00::NUMERIC,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::VARCHAR,
            30.00::NUMERIC,
            'Active'::VARCHAR,
            0,
            0;
        RETURN;
    END IF;

    v_token := encode(digest(gen_random_uuid()::text, 'sha256'), 'hex');
    v_expires := NOW() + INTERVAL '30 days';

    INSERT INTO sessions (user_id, token, expires_at)
    VALUES (r_user.id, v_token, v_expires);

    RETURN QUERY SELECT
        TRUE,
        'Login successful!'::VARCHAR,
        v_token,
        r_user.id,
        r_user.username,
        r_user.company_name,
        r_user.ceo_name,
        r_user.cash,
        r_user.game_current_time,
        r_user.hq_airport_iata,
        COALESCE(r_user.auto_grounding_threshold, 30.00),
        COALESCE(r_user.operational_status, 'Active'),
        COALESCE(r_user.consecutive_negative_days, 0),
        COALESCE(r_user.recovery_streak_days, 0);
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS validate_session(VARCHAR) CASCADE;

CREATE OR REPLACE FUNCTION validate_session(
    p_token VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    user_id UUID,
    user_username VARCHAR,
    company_name VARCHAR,
    ceo_name VARCHAR,
    cash NUMERIC,
    game_current_time TIMESTAMP WITH TIME ZONE,
    hq_airport_iata VARCHAR,
    auto_grounding_threshold NUMERIC,
    operational_status VARCHAR,
    consecutive_negative_days INT,
    recovery_streak_days INT
) AS $$
DECLARE
    r_session RECORD;
    r_user RECORD;
BEGIN
    SELECT * INTO r_session FROM sessions WHERE token = p_token AND expires_at > NOW();

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE,
            NULL::UUID,
            NULL::VARCHAR,
            NULL::VARCHAR,
            NULL::VARCHAR,
            0.00::NUMERIC,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::VARCHAR,
            30.00::NUMERIC,
            'Active'::VARCHAR,
            0,
            0;
        RETURN;
    END IF;

    SELECT * INTO r_user FROM users WHERE id = r_session.user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE,
            NULL::UUID,
            NULL::VARCHAR,
            NULL::VARCHAR,
            NULL::VARCHAR,
            0.00::NUMERIC,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::VARCHAR,
            30.00::NUMERIC,
            'Active'::VARCHAR,
            0,
            0;
        RETURN;
    END IF;

    RETURN QUERY SELECT
        TRUE,
        r_user.id,
        r_user.username,
        r_user.company_name,
        r_user.ceo_name,
        r_user.cash,
        r_user.game_current_time,
        r_user.hq_airport_iata,
        COALESCE(r_user.auto_grounding_threshold, 30.00),
        COALESCE(r_user.operational_status, 'Active'),
        COALESCE(r_user.consecutive_negative_days, 0),
        COALESCE(r_user.recovery_streak_days, 0);
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
    v_cash_after NUMERIC(20,2);
    v_grounded_count INT := 0;
    v_consecutive_negative_days INT := 0;
    v_recovery_streak_days INT := 0;
    v_new_status VARCHAR(20) := 'Active';
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
        game_current_time = v_game_current_time_new,
        last_active_at = v_now,
        buffered_revenue = v_buffered_rev_accum,
        buffered_ops_cost = v_buffered_ops_accum,
        buffered_lease_cost = v_buffered_lease_accum,
        operational_status = v_new_status,
        consecutive_negative_days = v_consecutive_negative_days,
        recovery_streak_days = v_recovery_streak_days
    WHERE id = p_user_id;

    cash_before := r_user.cash;
    cash_after := v_cash_after;
    elapsed_real_sec := v_real_sec;
    elapsed_game_days := v_game_days;
    flights_run := v_completed_flights_all;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
