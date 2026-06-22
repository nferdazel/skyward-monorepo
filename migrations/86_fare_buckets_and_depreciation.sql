-- ============================================================================
-- FARE BUCKETS, DEPRECIATION, AND DEBT COVENANTS
-- ============================================================================
-- Adds per-cabin fare pricing, aircraft age depreciation, fleet commonality
-- discounts, CASM/RASM analytics, and debt covenant compliance tracking.
--
-- 1. Fare buckets     — per-cabin pricing on routes (economy/business/first)
-- 2. Depreciation     — aircraft value depreciates 5% per game-year of age
-- 3. Commonality      — maintenance discount when fleet shares a manufacturer
-- 4. CASM/RASM        — cost and revenue per available seat mile analytics
-- 5. Debt covenants   — minimum cash and max debt ratio constraints on loans
-- ============================================================================


-- ============================================================================
-- 1. FARE BUCKETS
-- ============================================================================
-- Add per-cabin fare columns to user_routes.
-- Defaults set by trigger based on base_fare × cabin multiplier.

ALTER TABLE user_routes ADD COLUMN IF NOT EXISTS economy_fare NUMERIC;
ALTER TABLE user_routes ADD COLUMN IF NOT EXISTS business_fare NUMERIC;
ALTER TABLE user_routes ADD COLUMN IF NOT EXISTS first_fare NUMERIC;

COMMENT ON COLUMN user_routes.economy_fare IS
    'Economy class fare for this route. Defaults to base_fare(distance_km).';
COMMENT ON COLUMN user_routes.business_fare IS
    'Business class fare. Defaults to base_fare × 2.5.';
COMMENT ON COLUMN user_routes.first_fare IS
    'First class fare. Defaults to base_fare × 4.0.';

-- Set defaults on existing routes where fares are NULL
UPDATE user_routes
SET economy_fare = calculate_route_base_fare(distance_km),
    business_fare = ROUND(calculate_route_base_fare(distance_km) * 2.5, 2),
    first_fare = ROUND(calculate_route_base_fare(distance_km) * 4.0, 2)
WHERE economy_fare IS NULL OR business_fare IS NULL OR first_fare IS NULL;

-- Trigger to auto-set fare defaults on INSERT
CREATE OR REPLACE FUNCTION set_default_fare_buckets()
RETURNS TRIGGER AS $$
DECLARE
    v_base_fare NUMERIC;
BEGIN
    IF NEW.economy_fare IS NULL OR NEW.business_fare IS NULL OR NEW.first_fare IS NULL THEN
        v_base_fare := calculate_route_base_fare(NEW.distance_km);
        NEW.economy_fare  := COALESCE(NEW.economy_fare,  v_base_fare);
        NEW.business_fare := COALESCE(NEW.business_fare, ROUND(v_base_fare * 2.5, 2));
        NEW.first_fare    := COALESCE(NEW.first_fare,    ROUND(v_base_fare * 4.0, 2));
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_default_fare_buckets ON user_routes;
CREATE TRIGGER trg_set_default_fare_buckets
    BEFORE INSERT ON user_routes
    FOR EACH ROW
    EXECUTE FUNCTION set_default_fare_buckets();


-- ============================================================================
-- 2. AIRCRAFT DEPRECIATION
-- ============================================================================
-- Track when each airframe was acquired (game-time) for age-based depreciation.

ALTER TABLE user_fleet ADD COLUMN IF NOT EXISTS acquired_game_date TIMESTAMPTZ;

COMMENT ON COLUMN user_fleet.acquired_game_date IS
    'Game-time timestamp when this aircraft was acquired. Used for age-based depreciation on resale.';

-- Trigger to auto-set acquired_game_date on INSERT
CREATE OR REPLACE FUNCTION set_acquired_game_date()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.acquired_game_date IS NULL THEN
        IF NEW.user_id IS NOT NULL THEN
            SELECT game_current_time INTO NEW.acquired_game_date
            FROM users WHERE id = NEW.user_id;
        ELSIF NEW.ai_competitor_id IS NOT NULL THEN
            SELECT game_current_time INTO NEW.acquired_game_date
            FROM ai_competitors WHERE id = NEW.ai_competitor_id;
        END IF;
        NEW.acquired_game_date := COALESCE(NEW.acquired_game_date, NOW());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_acquired_game_date ON user_fleet;
CREATE TRIGGER trg_set_acquired_game_date
    BEFORE INSERT ON user_fleet
    FOR EACH ROW
    EXECUTE FUNCTION set_acquired_game_date();

-- Backfill existing fleet entries with a reasonable default (game_current_time)
UPDATE user_fleet f
SET acquired_game_date = COALESCE(
    (SELECT u.game_current_time FROM users u WHERE u.id = f.user_id),
    (SELECT ac.game_current_time FROM ai_competitors ac WHERE ac.id = f.ai_competitor_id),
    NOW()
)
WHERE acquired_game_date IS NULL;

-- Update sell_aircraft to depreciate value by 5% per year of game-age
CREATE OR REPLACE FUNCTION sell_aircraft(
    p_user_id UUID,
    p_fleet_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_user RECORD;
    v_fleet RECORD;
    v_base_value NUMERIC(20,2);
    v_age_years NUMERIC;
    v_depreciation_factor NUMERIC;
    v_sale_value NUMERIC(20,2);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    SELECT f.*, m.model_name, m.purchase_price
    INTO v_fleet
    FROM user_fleet f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'purchase' THEN
        RETURN QUERY SELECT FALSE, 'Only owned aircraft can be sold.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM user_routes
        WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id
    ) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Base sale value: 72% of purchase price scaled by condition
    v_base_value := calculate_owned_aircraft_sale_value(
        v_fleet.purchase_price, v_fleet.condition);

    -- Age depreciation: 5% per game-year, floor at 10% of base value
    IF v_fleet.acquired_game_date IS NOT NULL AND v_user.game_current_time IS NOT NULL THEN
        v_age_years := EXTRACT(EPOCH FROM (v_user.game_current_time - v_fleet.acquired_game_date))
                       / (365.25 * 86400.0);
        v_depreciation_factor := GREATEST(0.10, 1.0 - (0.05 * COALESCE(v_age_years, 0)));
        v_sale_value := ROUND(v_base_value * v_depreciation_factor, 2);
    ELSE
        v_sale_value := v_base_value;
    END IF;

    UPDATE users SET cash = cash + v_sale_value WHERE id = p_user_id
    RETURNING cash INTO new_cash;

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_user_id, 'revenue', 'aircraft_sale', v_sale_value,
            'Sold owned aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') ||
            ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
            date_trunc('day', v_user.game_current_time));

    DELETE FROM user_fleet WHERE id = p_fleet_id AND user_id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Aircraft sold successfully!'::VARCHAR, new_cash;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION sell_aircraft(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sell_aircraft(UUID, UUID) TO authenticated, service_role;

COMMENT ON FUNCTION sell_aircraft(UUID, UUID) IS
    'Sells owned aircraft. Sale value depreciated 5% per game-year of age (floor 10% of base value).';


-- ============================================================================
-- 3. FLEET COMMONALITY DISCOUNT
-- ============================================================================
-- Airlines operating multiple aircraft from the same manufacturer benefit from
-- shared parts, training, and maintenance infrastructure.
-- Discount: 5% per additional same-manufacturer aircraft, max 20%.

CREATE OR REPLACE FUNCTION get_fleet_commonality_discount(p_user_id UUID)
RETURNS NUMERIC AS $$
DECLARE
    v_max_same_mfr INT := 0;
    v_total_fleet INT := 0;
BEGIN
    SELECT COUNT(*) INTO v_total_fleet
    FROM user_fleet f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.user_id = p_user_id AND f.status = 'active';

    IF v_total_fleet < 2 THEN RETURN 0.0; END IF;

    -- Find the largest manufacturer group
    SELECT COALESCE(MAX(cnt), 0) INTO v_max_same_mfr
    FROM (
        SELECT COUNT(*) AS cnt
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.user_id = p_user_id AND f.status = 'active'
        GROUP BY m.manufacturer
    ) sub;

    RETURN LEAST(0.20, (v_max_same_mfr - 1) * 0.05);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION get_fleet_commonality_discount(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_fleet_commonality_discount(UUID) TO authenticated, service_role;

COMMENT ON FUNCTION get_fleet_commonality_discount(UUID) IS
    'Returns maintenance cost discount (0.0–0.20) based on fleet manufacturer commonality. 5% per additional same-manufacturer aircraft, max 20%.';


-- ============================================================================
-- 4. CASM / RASM CALCULATION HELPER
-- ============================================================================
-- Cost per Available Seat Mile and Revenue per Available Seat Mile.
-- Period defaults to 30 game-days.

CREATE OR REPLACE FUNCTION calculate_casm_rasm(
    p_user_id UUID,
    p_period_days INT DEFAULT 30
)
RETURNS TABLE (
    total_cost NUMERIC,
    total_revenue NUMERIC,
    total_available_seat_miles NUMERIC,
    casm NUMERIC,
    rasm NUMERIC
) AS $$
DECLARE
    v_game_time TIMESTAMPTZ;
    v_total_cost NUMERIC := 0;
    v_total_revenue NUMERIC := 0;
    v_total_asm NUMERIC := 0;
BEGIN
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_user_id;
    IF v_game_time IS NULL THEN
        total_cost := 0; total_revenue := 0; total_available_seat_miles := 0;
        casm := 0; rasm := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT
        COALESCE(SUM(CASE WHEN transaction_type = 'expense' THEN amount ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN transaction_type = 'revenue' THEN amount ELSE 0 END), 0)
    INTO v_total_cost, v_total_revenue
    FROM financial_ledger
    WHERE user_id = p_user_id
      AND game_date >= v_game_time - (p_period_days || ' days')::INTERVAL;

    -- Available Seat Miles = seats * distance_km * 0.621371 * flights_over_period
    SELECT COALESCE(SUM(
        calculate_effective_passenger_capacity(m.capacity, f.economy_seats, f.business_seats, f.first_class_seats)
        * r.distance_km * 0.621371
        * (r.flights_per_week * p_period_days / 7.0)
    ), 0)
    INTO v_total_asm
    FROM user_routes r
    JOIN user_fleet f ON r.assigned_aircraft_id = f.id
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE r.user_id = p_user_id
      AND COALESCE(r.status, 'active') = 'active'
      AND f.status = 'active';

    total_cost := v_total_cost;
    total_revenue := v_total_revenue;
    total_available_seat_miles := v_total_asm;

    IF v_total_asm > 0 THEN
        casm  := ROUND(v_total_cost / v_total_asm, 4);
        rasm  := ROUND(v_total_revenue / v_total_asm, 4);
    ELSE
        casm := 0;
        rasm := 0;
    END IF;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION calculate_casm_rasm(UUID, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION calculate_casm_rasm(UUID, INT) TO authenticated;

COMMENT ON FUNCTION calculate_casm_rasm(UUID, INT) IS
    'Computes Cost per Available Seat Mile (CASM) and Revenue per Available Seat Mile (RASM) for a player over a given period.';


-- ============================================================================
-- 5. DEBT COVENANTS
-- ============================================================================
-- Loans can carry covenant constraints: minimum cash balance and maximum
-- debt-to-net-worth ratio. Violations are tracked for game-day reporting.

ALTER TABLE loans ADD COLUMN IF NOT EXISTS covenant_min_cash NUMERIC;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS covenant_max_debt_ratio NUMERIC;

COMMENT ON COLUMN loans.covenant_min_cash IS
    'Minimum cash balance the borrower must maintain while this loan is active. NULL = no covenant.';
COMMENT ON COLUMN loans.covenant_max_debt_ratio IS
    'Maximum debt-to-net-worth ratio the borrower must maintain. NULL = no covenant.';

-- Check covenant compliance for a player
CREATE OR REPLACE FUNCTION check_debt_covenants(p_user_id UUID)
RETURNS TABLE (
    loan_id UUID,
    loan_type VARCHAR,
    covenant_type TEXT,
    threshold NUMERIC,
    actual_value NUMERIC,
    is_compliant BOOLEAN
) AS $$
DECLARE
    r_loan RECORD;
    v_cash NUMERIC;
    v_net_worth NUMERIC;
    v_total_debt NUMERIC;
    v_debt_ratio NUMERIC;
BEGIN
    SELECT u.cash, u.net_worth INTO v_cash, v_net_worth
    FROM users u WHERE u.id = p_user_id;

    v_cash := COALESCE(v_cash, 0);
    v_net_worth := COALESCE(v_net_worth, 0);

    -- Total outstanding debt
    SELECT COALESCE(SUM(remaining_balance), 0) INTO v_total_debt
    FROM loans WHERE user_id = p_user_id AND status = 'active';
    v_total_debt := v_total_debt + COALESCE(
        (SELECT SUM(remaining_balance) FROM aircraft_financing
         WHERE user_id = p_user_id AND status = 'active'), 0);

    IF v_net_worth > 0 THEN
        v_debt_ratio := v_total_debt / v_net_worth;
    ELSIF v_total_debt > 0 THEN
        v_debt_ratio := 999.0;
    ELSE
        v_debt_ratio := 0.0;
    END IF;

    FOR r_loan IN
        SELECT l.id, l.loan_type, l.covenant_min_cash, l.covenant_max_debt_ratio
        FROM loans l
        WHERE l.user_id = p_user_id AND l.status = 'active'
          AND (l.covenant_min_cash IS NOT NULL OR l.covenant_max_debt_ratio IS NOT NULL)
    LOOP
        -- Minimum cash covenant
        IF r_loan.covenant_min_cash IS NOT NULL THEN
            loan_id := r_loan.id;
            loan_type := r_loan.loan_type;
            covenant_type := 'min_cash';
            threshold := r_loan.covenant_min_cash;
            actual_value := v_cash;
            is_compliant := v_cash >= r_loan.covenant_min_cash;
            RETURN NEXT;
        END IF;

        -- Maximum debt ratio covenant
        IF r_loan.covenant_max_debt_ratio IS NOT NULL THEN
            loan_id := r_loan.id;
            loan_type := r_loan.loan_type;
            covenant_type := 'max_debt_ratio';
            threshold := r_loan.covenant_max_debt_ratio;
            actual_value := ROUND(v_debt_ratio, 4);
            is_compliant := v_debt_ratio <= r_loan.covenant_max_debt_ratio;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION check_debt_covenants(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION check_debt_covenants(UUID) TO authenticated;

COMMENT ON FUNCTION check_debt_covenants(UUID) IS
    'Checks all active loan covenants for a player. Returns compliance status for minimum cash and maximum debt ratio constraints.';
