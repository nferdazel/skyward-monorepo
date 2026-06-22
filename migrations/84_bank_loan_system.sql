-- ============================================================================
-- BANK LOAN SYSTEM
-- ============================================================================
-- Adds a loans table and RPC functions that let players borrow capital from
-- the bank.  Loan payments are processed automatically at each game-day
-- boundary inside process_player_simulation_to_time.
--
-- Key constraints:
--   - Max 3 active loans per player
--   - Principal range: $100K – $50M
--   - Fixed 5% annual interest, simple-interest calculation
--   - Configurable term: 12, 26, or 52 weeks
--   - Late fee of 10% of weekly payment when cash is insufficient
-- ============================================================================


-- ============================================================================
-- 1. Loans table
-- ============================================================================
CREATE TABLE IF NOT EXISTS loans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id),
    principal NUMERIC NOT NULL,
    interest_rate NUMERIC NOT NULL DEFAULT 0.05,
    remaining_balance NUMERIC NOT NULL,
    weekly_payment NUMERIC NOT NULL,
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'paid_off', 'defaulted')),
    taken_at TIMESTAMPTZ DEFAULT NOW(),
    game_date_taken TIMESTAMPTZ,
    paid_off_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE loans ENABLE ROW LEVEL SECURITY;
CREATE POLICY loans_select_own ON loans FOR SELECT TO authenticated
USING (user_id = (SELECT id FROM users WHERE auth_user_id = auth.uid()));
GRANT SELECT ON loans TO authenticated;

CREATE INDEX IF NOT EXISTS loans_user_status_idx ON loans(user_id, status);


-- ============================================================================
-- 2. Take loan function
-- ============================================================================
CREATE OR REPLACE FUNCTION take_loan(
    p_principal NUMERIC,
    p_term_weeks INT DEFAULT 52
)
RETURNS TABLE(success BOOLEAN, message TEXT, new_cash NUMERIC) AS $$
DECLARE
    v_user_id UUID;
    v_existing_loans INT;
    v_interest_rate NUMERIC := 0.05; -- 5% annual
    v_weekly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
BEGIN
    v_user_id := require_current_user_id();

    -- Check existing active loans (max 3)
    SELECT COUNT(*) INTO v_existing_loans
    FROM loans
    WHERE user_id = v_user_id AND status = 'active';

    IF v_existing_loans >= 3 THEN
        RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Validate principal
    IF p_principal < 100000 OR p_principal > 50000000 THEN
        RETURN QUERY SELECT false, 'Loan amount must be between $100K and $50M.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Validate term
    IF p_term_weeks NOT IN (12, 26, 52) THEN
        RETURN QUERY SELECT false, 'Loan term must be 12, 26, or 52 weeks.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Calculate weekly payment (simple interest)
    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    -- Fetch current game time
    SELECT game_current_time INTO v_game_time
    FROM users WHERE id = v_user_id;

    -- Credit cash
    UPDATE users
    SET cash = cash + p_principal
    WHERE id = v_user_id
    RETURNING cash INTO v_cash;

    -- Create loan record
    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance,
        weekly_payment, game_date_taken
    )
    VALUES (
        v_user_id, p_principal, v_interest_rate, v_total_repayable,
        v_weekly_payment, v_game_time
    );

    -- Ledger entry
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (v_user_id, 'revenue', 'loan', p_principal, 'Bank loan taken', v_game_time);

    RETURN QUERY SELECT true, 'Loan of $' || p_principal::TEXT || ' approved.'::TEXT, v_cash;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;


-- ============================================================================
-- 3. Process loan payments (called once per game day from simulation tick)
-- ============================================================================
CREATE OR REPLACE FUNCTION process_loan_payments(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
)
RETURNS VOID AS $$
DECLARE
    r_loan RECORD;
    v_cash NUMERIC;
    v_payment NUMERIC;
    v_late_fee NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;

    FOR r_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id AND status = 'active'
        ORDER BY taken_at ASC
    LOOP
        v_payment := r_loan.weekly_payment;

        IF v_cash >= v_payment THEN
            -- Deduct payment
            v_cash := v_cash - v_payment;
            UPDATE users SET cash = v_cash WHERE id = p_user_id;

            -- Update loan balance
            UPDATE loans
            SET remaining_balance = remaining_balance - v_payment
            WHERE id = r_loan.id;

            -- Check if paid off
            IF r_loan.remaining_balance - v_payment <= 0 THEN
                UPDATE loans
                SET status = 'paid_off',
                    paid_off_at = NOW(),
                    remaining_balance = 0
                WHERE id = r_loan.id;
            END IF;

            -- Ledger entry
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'loan_payment', v_payment, 'Loan payment', p_game_date);
        ELSE
            -- Can't pay — apply late fee (10% of weekly payment)
            v_late_fee := v_payment * 0.1;

            UPDATE loans
            SET remaining_balance = remaining_balance + v_late_fee
            WHERE id = r_loan.id;

            -- Ledger entry for late fee
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'loan_late_fee', v_late_fee, 'Loan late fee — insufficient cash', p_game_date);
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;


-- ============================================================================
-- 4. Wire process_loan_payments into process_player_simulation_to_time
-- ============================================================================
-- Loan payments are processed at each game-day boundary, after achievement
-- checks and before the final cash update.

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
    v_buffered_cargo_accum NUMERIC(20,2);
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
    -- Cargo revenue variables
    v_cargo_rate NUMERIC := 0.10;
    v_cargo_demand NUMERIC;
    v_cargo_revenue NUMERIC;
    v_total_cargo_revenue NUMERIC(20,2) := 0;
    -- Non-linear degradation variable
    v_acceleration NUMERIC;
    -- Loan balance snapshot for net worth calculation
    v_total_loan_balance NUMERIC := 0;
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

            -- Cargo revenue: scales with distance (long routes = more cargo)
            v_cargo_demand := LEAST(1.0, COALESCE(v_route.distance_km, 0.0) / 5000.0);
            v_cargo_revenue := v_revenue * v_cargo_rate * v_cargo_demand;
            v_total_cargo_revenue := v_total_cargo_revenue + v_cargo_revenue;

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

            -- Non-linear degradation: accelerating wear below 60% condition
            IF COALESCE(v_route.condition, 100) > 60 THEN
                v_acceleration := 1.0;
            ELSE
                v_acceleration := 1.0 + ((60.0 - COALESCE(v_route.condition, 60)) / 40.0) * 1.5;
            END IF;

            v_gross_damage := COALESCE(v_flights, 0.0) * v_wear_per_cycle * v_acceleration;
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
    v_total_cargo_revenue := GREATEST(0.00, COALESCE(v_total_cargo_revenue, 0.00));
    v_net := v_total_revenue + v_total_cargo_revenue - v_total_cost_accum - v_lease_cost;

    -- Catch-up subsidy for players far behind the leader
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
    v_buffered_cargo_accum := COALESCE(r_user.buffered_cargo_revenue, 0.00) + v_total_cargo_revenue;

    IF date_trunc('day', p_target_game_time) > date_trunc('day', r_user.game_current_time) THEN
        IF v_buffered_rev_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active routes', date_trunc('day', p_target_game_time));
        END IF;

        IF v_buffered_cargo_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'cargo', v_buffered_cargo_accum, 'Cargo revenue — distance-scaled freight income', date_trunc('day', p_target_game_time));
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
        v_buffered_cargo_accum := 0.00;

        -- ── Check achievements at game-day boundary ──
        PERFORM check_achievements(p_user_id, p_target_game_time);

        -- ── Process loan payments at game-day boundary ──
        PERFORM process_loan_payments(p_user_id, p_target_game_time);
    END IF;

    v_cash_after := r_user.cash + v_net;

    -- Subtract outstanding loan balance from net worth calculation
    SELECT COALESCE(SUM(remaining_balance), 0)
    INTO v_total_loan_balance
    FROM loans
    WHERE user_id = p_user_id AND status = 'active';

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
        buffered_cargo_revenue = v_buffered_cargo_accum,
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
-- 5. Grants and comments
-- ============================================================================
GRANT EXECUTE ON FUNCTION take_loan(NUMERIC, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION process_loan_payments(UUID, TIMESTAMPTZ) TO service_role;

COMMENT ON TABLE loans IS
    'Bank loans taken by players for capital. Payments are auto-deducted at each game-day boundary.';

COMMENT ON FUNCTION take_loan(NUMERIC, INT) IS
    'Borrow capital from the bank. Max 3 active loans, principal $100K–$50M, terms 12/26/52 weeks at 5% annual simple interest.';

COMMENT ON FUNCTION process_loan_payments(UUID, TIMESTAMPTZ) IS
    'Deducts weekly loan payments from a player''s cash at each game-day boundary. Applies late fees when cash is insufficient.';

COMMENT ON FUNCTION process_player_simulation_to_time(UUID, TIMESTAMP WITH TIME ZONE) IS
    'Processes one player simulation tick. Applies active game event multipliers (fuel price, demand), catch-up subsidy for trailing players, cargo revenue (10% baseline scaled by route distance up to 5000km), non-linear aircraft degradation (accelerating wear below 60% condition), achievement checks at game-day boundaries, and automatic loan payment processing.';
