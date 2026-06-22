-- ============================================================================
-- BOT FINANCIAL BEHAVIOR
-- ============================================================================
-- Adds financial intelligence to the bot decision loop so bots can:
--   1. Take loans when cash is low (bridging capital)
--   2. Finance aircraft when they can afford the down payment but not full price
--   3. Pay off loans early when cash is abundant (saving on interest)
--   4. Maintain a credit score that determines their borrowing terms
--
-- Schema changes:
--   - ai_competitors  : credit_score, credit_tier columns
--   - loans           : ai_competitor_id column (bot loans)
--   - aircraft_financing : ai_competitor_id column (bot financing)
--
-- New functions:
--   - calculate_bot_credit_score(UUID)  — bot-specific credit scoring
--   - bot_take_loan(UUID, NUMERIC, INT) — loan origination for bots
--   - bot_finance_aircraft(UUID, UUID, NUMERIC, INT) — aircraft financing for bots
--   - execute_bot_decisions()           — replaced with financial intelligence
-- ============================================================================


-- ============================================================================
-- PART 1: Schema — add bot columns to financial tables
-- ============================================================================

-- Credit tracking on ai_competitors
ALTER TABLE ai_competitors ADD COLUMN IF NOT EXISTS credit_score INT DEFAULT 500;
ALTER TABLE ai_competitors ADD COLUMN IF NOT EXISTS credit_tier VARCHAR(20) DEFAULT 'Standard';

-- Bot loans support — make user_id nullable so bots can hold loans without a user FK
ALTER TABLE loans ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE loans ADD COLUMN IF NOT EXISTS ai_competitor_id UUID REFERENCES ai_competitors(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS loans_ai_competitor_status_idx
    ON loans(ai_competitor_id, status) WHERE ai_competitor_id IS NOT NULL;

-- Bot aircraft financing support — same nullable pattern
ALTER TABLE aircraft_financing ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE aircraft_financing ADD COLUMN IF NOT EXISTS ai_competitor_id UUID REFERENCES ai_competitors(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS aircraft_financing_ai_competitor_status_idx
    ON aircraft_financing(ai_competitor_id, status) WHERE ai_competitor_id IS NOT NULL;


-- ============================================================================
-- PART 2: calculate_bot_credit_score(UUID)
-- ============================================================================
-- Bot-specific credit score calculation using the same 5-component model
-- as players (fleet health, revenue stability, debt ratio, cash reserves,
-- profit history) but reading from ai_competitors and bot financial data.

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
    SELECT ac.cash, ac.net_worth, ac.game_current_time
    INTO v_bot
    FROM ai_competitors ac WHERE ac.id = p_bot_id;

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

    -- ── Fleet Health (0–200) ──
    SELECT
        COUNT(*)::INT,
        COALESCE(AVG(condition), 100.0),
        COALESCE(
            COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC /
            NULLIF(COUNT(*), 0), 0.0
        )
    INTO v_fleet_count, v_avg_condition, v_grounded_ratio
    FROM user_fleet WHERE ai_competitor_id = p_bot_id;

    IF v_fleet_count > 0 THEN
        v_fleet_health := (v_avg_condition / 100.0) * 150.0
                        + 50.0 * (1.0 - v_grounded_ratio);
    ELSE
        v_fleet_health := 100.0;
    END IF;
    v_fleet_health := GREATEST(0.0, LEAST(200.0, v_fleet_health));

    -- ── Revenue Stability (0–200) ──
    SELECT
        COUNT(DISTINCT date_trunc('day', game_date))::INT,
        COUNT(DISTINCT date_trunc('day', game_date)) FILTER (
            WHERE transaction_type = 'revenue' AND amount > 0
        )::INT
    INTO v_revenue_days, v_positive_days
    FROM financial_ledger
    WHERE ai_competitor_id = p_bot_id
      AND game_date >= v_bot.game_current_time - INTERVAL '30 days';

    IF v_revenue_days > 0 THEN
        v_revenue_stability := (v_positive_days::NUMERIC / GREATEST(v_revenue_days, 1)) * 200.0;
    ELSE
        v_revenue_stability := 100.0;
    END IF;
    v_revenue_stability := GREATEST(0.0, LEAST(200.0, v_revenue_stability));

    -- ── Debt Ratio (0–200) ──
    SELECT COALESCE(SUM(remaining_balance), 0) INTO v_total_debt
    FROM loans WHERE ai_competitor_id = p_bot_id AND status = 'active';

    v_total_debt := v_total_debt + COALESCE(
        (SELECT SUM(remaining_balance) FROM aircraft_financing
         WHERE ai_competitor_id = p_bot_id AND status = 'active'), 0);

    IF v_net_worth > 0 THEN
        v_debt_ratio := GREATEST(0.0, 200.0 * (1.0 - (v_total_debt / v_net_worth)));
    ELSIF v_total_debt > 0 THEN
        v_debt_ratio := 0.0;
    ELSE
        v_debt_ratio := 100.0;
    END IF;
    v_debt_ratio := GREATEST(0.0, LEAST(200.0, v_debt_ratio));

    -- ── Cash Reserves (0–200) ──
    IF v_starting_cash > 0 THEN
        v_cash_reserve := LEAST(200.0, (v_cash / v_starting_cash) * 100.0);
    ELSE
        v_cash_reserve := 100.0;
    END IF;
    IF v_cash < 0 THEN v_cash_reserve := 0.0; END IF;
    v_cash_reserve := GREATEST(0.0, LEAST(200.0, v_cash_reserve));

    -- ── Profit History (0–200) ──
    SELECT
        COALESCE(SUM(CASE WHEN transaction_type = 'revenue' THEN amount ELSE 0 END), 0.0),
        COALESCE(SUM(CASE WHEN transaction_type = 'expense' THEN amount ELSE 0 END), 0.0)
    INTO v_total_revenue_30d, v_total_expense_30d
    FROM financial_ledger
    WHERE ai_competitor_id = p_bot_id
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

COMMENT ON FUNCTION calculate_bot_credit_score(UUID) IS
    'Computes a 0-1000 credit score for a bot from fleet health, revenue stability, debt ratio, cash reserves, and profit history.';


-- ============================================================================
-- PART 3: bot_take_loan(UUID, NUMERIC, INT)
-- ============================================================================
-- Loan origination for bots. Mirrors the player take_loan function but
-- operates on ai_competitor_id and uses a fixed 5% interest rate.
-- Max 3 active loans per bot; principal capped at $5M.

CREATE OR REPLACE FUNCTION bot_take_loan(
    p_bot_id UUID,
    p_principal NUMERIC,
    p_term_weeks INT DEFAULT 52
)
RETURNS BOOLEAN AS $$
DECLARE
    v_existing_loans INT;
    v_interest_rate NUMERIC := 0.05;
    v_weekly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_bot_cash NUMERIC;
BEGIN
    -- Guard: max 3 active loans per bot
    SELECT COUNT(*) INTO v_existing_loans
    FROM loans WHERE ai_competitor_id = p_bot_id AND status = 'active';
    IF v_existing_loans >= 3 THEN
        RETURN false;
    END IF;

    -- Guard: principal within sane bounds
    IF p_principal < 100000 OR p_principal > 5000000 THEN
        RETURN false;
    END IF;

    SELECT game_current_time, cash INTO v_game_time, v_bot_cash
    FROM ai_competitors WHERE id = p_bot_id;

    IF NOT FOUND THEN RETURN false; END IF;

    -- Simple-interest model matching player loans
    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    -- Credit the bot
    UPDATE ai_competitors SET cash = cash + p_principal WHERE id = p_bot_id;

    INSERT INTO loans (
        ai_competitor_id, principal, interest_rate, remaining_balance,
        weekly_payment, game_date_taken, status
    ) VALUES (
        p_bot_id, p_principal, v_interest_rate, v_total_repayable,
        v_weekly_payment, v_game_time, 'active'
    );

    -- Ledger entry: loan proceeds are revenue (cash inflow)
    INSERT INTO financial_ledger (
        ai_competitor_id, transaction_type, category, amount, description, game_date
    ) VALUES (
        p_bot_id, 'revenue', 'loan', p_principal,
        'Bank loan taken — $' || p_principal::TEXT || ' at 5% APR',
        v_game_time
    );

    RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION bot_take_loan(UUID, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bot_take_loan(UUID, NUMERIC, INT) TO service_role;

COMMENT ON FUNCTION bot_take_loan(UUID, NUMERIC, INT) IS
    'Originate a bank loan for a bot. Fixed 5% APR, max $5M principal, max 3 active loans.';


-- ============================================================================
-- PART 4: bot_finance_aircraft(UUID, UUID, NUMERIC, INT)
-- ============================================================================
-- Aircraft financing for bots. Down payment deducted immediately, remainder
-- financed over p_term_months at 5% APR. Creates fleet entry + financing record.

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
    FROM ai_competitors WHERE id = p_bot_id;

    IF NOT FOUND THEN RETURN false; END IF;

    v_purchase_price := v_model.purchase_price;
    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_total_repayable := v_principal * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;

    -- Guard: must have cash for down payment
    IF v_bot_cash < v_down_payment THEN
        RETURN false;
    END IF;

    -- Deduct down payment
    UPDATE ai_competitors SET cash = cash - v_down_payment WHERE id = p_bot_id;

    -- Archetype-based cabin layout
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

    INSERT INTO user_fleet (
        ai_competitor_id, aircraft_model_id, tail_number,
        acquisition_type, condition, status,
        economy_seats, business_seats, first_class_seats
    ) VALUES (
        p_bot_id, p_aircraft_model_id, v_tail,
        'purchase', 100.00, 'active',
        v_economy, v_business, v_first
    ) RETURNING id INTO v_fleet_id;

    INSERT INTO aircraft_financing (
        ai_competitor_id, aircraft_model_id, fleet_aircraft_id,
        purchase_price, down_payment, principal,
        interest_rate, monthly_payment, term_months,
        remaining_balance, taken_at
    ) VALUES (
        p_bot_id, p_aircraft_model_id, v_fleet_id,
        v_purchase_price, v_down_payment, v_principal,
        v_interest_rate, v_monthly_payment, p_term_months,
        v_total_repayable, v_game_time
    );

    -- Ledger: down payment expense
    INSERT INTO financial_ledger (
        ai_competitor_id, transaction_type, category, amount, description, game_date
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

COMMENT ON FUNCTION bot_finance_aircraft(UUID, UUID, NUMERIC, INT) IS
    'Finance an aircraft purchase for a bot with a down payment and monthly installments at 5% APR.';


-- ============================================================================
-- PART 5: Replace execute_bot_decisions() with financial intelligence
-- ============================================================================
-- Adds four financial behaviors to the bot decision loop:
--   1. Emergency loan:       cash < 50% of starting capital and fewer than 2 active loans
--   2. Aircraft financing:   can't afford purchase but can cover 20% down payment
--   3. Early loan payoff:    cash > 3× starting capital — retire highest-rate loan
--   4. Credit score update:  recalculate and persist after all financial decisions
--
-- These run AFTER the existing fleet expansion and competitive response logic
-- so that the cash position reflects all operational decisions before financial
-- strategy is applied.

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
    -- Premium cabin seat distribution
    v_economy INT;
    v_business INT;
    v_first INT;
    -- Competitive response
    r_route RECORD;
    v_human_competitors INT;
    v_new_price NUMERIC;
    v_base_fare NUMERIC;
    v_purchase_capacity INT;
    -- Financial intelligence
    v_active_loans INT;
    v_loan_record RECORD;
    v_fin_model_id UUID;
    v_fin_model_price NUMERIC;
    v_credit_score INT;
    v_credit_tier VARCHAR(10);
BEGIN
    SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1;
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);

    FOR r_bot IN SELECT * FROM ai_competitors LOOP
        v_bot_cash := COALESCE(r_bot.cash, 0.00);
        v_origin_iata := r_bot.hq_airport_iata;
        v_effective_threshold := GREATEST(
            v_absolute_minimum_safety_limit,
            COALESCE(r_bot.auto_grounding_threshold, 40.00)
        );

        IF r_bot.status = 'Bankrupt' OR v_bot_cash < -5000000.00 THEN
            -- Soft-delete: mark as bankrupt, ground fleet, preserve data for audit
            UPDATE ai_competitors SET status = 'Bankrupt' WHERE id = r_bot.id;
            UPDATE user_fleet SET status = 'grounded' WHERE ai_competitor_id = r_bot.id;
            -- Keep routes and ledger intact for historical analysis
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
        FROM user_fleet
        WHERE ai_competitor_id = r_bot.id;

        SELECT COUNT(*)::INT INTO v_route_count
        FROM user_routes
        WHERE ai_competitor_id = r_bot.id;

        SELECT COUNT(*)::INT INTO v_idle_aircraft_count
        FROM user_fleet f
        WHERE f.ai_competitor_id = r_bot.id
          AND f.status = 'active'
          AND f.condition >= v_effective_threshold
          AND NOT EXISTS (
              SELECT 1
              FROM user_routes r
              WHERE r.assigned_aircraft_id = f.id
          );

        -- Bots must pay to recover grounded airframes just like the player.
        SELECT
            f.id,
            f.condition,
            f.acquisition_type,
            m.model_name,
            m.lease_price_per_month,
            m.purchase_price
        INTO
            v_grounded_aircraft_id,
            v_grounded_condition,
            v_grounded_acquisition_type,
            v_grounded_model_name,
            v_grounded_lease_price,
            v_grounded_purchase_price
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.ai_competitor_id = r_bot.id
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
                UPDATE ai_competitors
                SET cash = cash - v_repair_cost
                WHERE id = r_bot.id;

                UPDATE user_fleet
                SET condition = 100.00,
                    status = 'active'
                WHERE id = v_grounded_aircraft_id;

                INSERT INTO financial_ledger (
                    ai_competitor_id,
                    transaction_type,
                    category,
                    amount,
                    description,
                    game_date
                )
                VALUES (
                    r_bot.id,
                    'expense',
                    'aircraft_repair',
                    v_repair_cost,
                    'Bot maintenance recovery completed for ' || v_grounded_model_name,
                    r_bot.game_current_time
                );

                v_bot_cash := v_bot_cash - v_repair_cost;
            END IF;
        END IF;

        -- Distressed bots cut weak routes before expanding again.
        IF v_bot_cash < 3000000.00 OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN
            SELECT
                r.id,
                r.flights_per_week,
                (50.00 + (r.distance_km * 0.12))::NUMERIC
            INTO
                v_selected_route_id,
                v_selected_flights,
                v_selected_base_fare
            FROM user_routes r
            WHERE r.ai_competitor_id = r_bot.id
            ORDER BY
                (r.ticket_price / NULLIF((50.00 + (r.distance_km * 0.12)), 0)) DESC,
                r.flights_per_week DESC
            LIMIT 1;

            IF v_selected_route_id IS NOT NULL THEN
                IF v_selected_flights > 8 THEN
                    UPDATE user_routes
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
                    DELETE FROM user_routes WHERE id = v_selected_route_id;
                END IF;
            END IF;
        END IF;

        -- Healthy bots can expand fleet with archetype-specific aggression.
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
                    FROM aircraft_models
                    WHERE manufacturer = 'ATR'
                    ORDER BY capacity DESC
                    LIMIT 1;
                ELSIF r_bot.archetype = 'Aggressive' THEN
                    SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
                    INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                    FROM aircraft_models
                    WHERE manufacturer = 'Airbus'
                    ORDER BY capacity DESC
                    LIMIT 1;
                ELSE
                    SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
                    INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                    FROM aircraft_models
                    WHERE manufacturer = 'Boeing'
                    ORDER BY capacity DESC
                    LIMIT 1;
                END IF;
            END IF;

            v_deposit_amount := COALESCE(v_lease_price, 0.00) * (v_deposit_pct * 10.0);

            IF v_model_id IS NOT NULL AND v_bot_cash >= v_deposit_amount THEN
                v_tail := generate_tail_number(r_bot.hq_airport_iata);
                v_new_aircraft_id := gen_random_uuid();

                -- Premium cabin seat distribution by archetype
                IF r_bot.archetype = 'Regional' THEN
                    v_economy := FLOOR(v_capacity * 0.80);
                    v_business := FLOOR(v_capacity * 0.15);
                    v_first := v_capacity - v_economy - v_business;
                ELSIF r_bot.archetype = 'Aggressive' THEN
                    v_economy := FLOOR(v_capacity * 0.70);
                    v_business := FLOOR(v_capacity * 0.20);
                    v_first := v_capacity - v_economy - v_business;
                ELSE -- Premium
                    v_economy := FLOOR(v_capacity * 0.50);
                    v_business := FLOOR(v_capacity * 0.30);
                    v_first := v_capacity - v_economy - v_business;
                END IF;

                INSERT INTO user_fleet (
                    id,
                    ai_competitor_id,
                    aircraft_model_id,
                    nickname,
                    acquisition_type,
                    condition,
                    status,
                    tail_number,
                    economy_seats,
                    business_seats,
                    first_class_seats
                )
                VALUES (
                    v_new_aircraft_id,
                    r_bot.id,
                    v_model_id,
                    v_model_name,
                    'lease',
                    100.00,
                    'active',
                    v_tail,
                    v_economy,
                    v_business,
                    v_first
                );

                UPDATE ai_competitors
                SET cash = cash - v_deposit_amount
                WHERE id = r_bot.id;

                INSERT INTO financial_ledger (
                    ai_competitor_id,
                    transaction_type,
                    category,
                    amount,
                    description,
                    game_date
                )
                VALUES (
                    r_bot.id,
                    'expense',
                    'aircraft_lease',
                    v_deposit_amount,
                    'Leased aircraft ' || v_model_name || ' with Call Sign: ' || v_tail || ' - Downpayment deposit',
                    r_bot.game_current_time
                );

                v_bot_cash := v_bot_cash - v_deposit_amount;
            END IF;
        END IF;

        -- Bot purchase: if cash > 3x starting cash, buy instead of lease
        IF v_bot_cash > (v_starting_cash * 3) AND v_fleet_count < v_target_fleet_cap THEN
            -- Find cheapest suitable aircraft for purchase
            SELECT id, purchase_price, capacity
            INTO v_model_id, v_purchase_price, v_purchase_capacity
            FROM aircraft_models
            WHERE range_km >= v_target_distance
            ORDER BY purchase_price ASC
            LIMIT 1;

            IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN
                -- Premium cabin seat distribution by archetype (purchase path)
                IF r_bot.archetype = 'Regional' THEN
                    v_economy := FLOOR(v_purchase_capacity * 0.80);
                    v_business := FLOOR(v_purchase_capacity * 0.15);
                    v_first := v_purchase_capacity - v_economy - v_business;
                ELSIF r_bot.archetype = 'Aggressive' THEN
                    v_economy := FLOOR(v_purchase_capacity * 0.70);
                    v_business := FLOOR(v_purchase_capacity * 0.20);
                    v_first := v_purchase_capacity - v_economy - v_business;
                ELSE -- Premium
                    v_economy := FLOOR(v_purchase_capacity * 0.50);
                    v_business := FLOOR(v_purchase_capacity * 0.30);
                    v_first := v_purchase_capacity - v_economy - v_business;
                END IF;

                -- Generate tail number with retry
                v_attempts := 0;
                v_inserted := false;
                WHILE v_attempts < 10 AND NOT v_inserted LOOP
                    v_tail := generate_tail_number(r_bot.hq_airport_iata);
                    BEGIN
                        INSERT INTO user_fleet (
                            ai_competitor_id, aircraft_model_id, tail_number,
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
                    UPDATE ai_competitors SET cash = cash - v_purchase_price WHERE id = r_bot.id;
                    INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                    VALUES (r_bot.id, 'expense', 'acquisition', v_purchase_price, 'Aircraft purchase: ' || v_tail, r_bot.game_current_time);
                    v_bot_cash := v_bot_cash - v_purchase_price;
                END IF;
            END IF;
        END IF;

        SELECT COUNT(*)::INT INTO v_fleet_count
        FROM user_fleet
        WHERE ai_competitor_id = r_bot.id;

        SELECT COUNT(*)::INT INTO v_route_count
        FROM user_routes
        WHERE ai_competitor_id = r_bot.id;

        -- Put idle aircraft to work with archetype-shaped route plans.
        SELECT
            f.id,
            f.tail_number,
            f.condition,
            m.model_name,
            m.capacity,
            m.speed_kmh,
            m.range_km
        INTO
            v_idle_aircraft_id,
            v_idle_tail,
            v_idle_condition,
            v_idle_model_name,
            v_idle_capacity,
            v_idle_speed,
            v_idle_range
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.ai_competitor_id = r_bot.id
          AND f.status = 'active'
          AND f.condition >= v_effective_threshold
          AND NOT EXISTS (
              SELECT 1
              FROM user_routes r
              WHERE r.assigned_aircraft_id = f.id
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
                    1,
                    FLOOR(168.0 / ((v_distance / v_idle_speed) + 1.0))
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

                INSERT INTO user_routes (
                    ai_competitor_id,
                    origin_iata,
                    destination_iata,
                    distance_km,
                    ticket_price,
                    assigned_aircraft_id,
                    flights_per_week
                )
                VALUES (
                    r_bot.id,
                    v_origin_iata,
                    v_dest_iata,
                    v_distance,
                    v_target_price,
                    v_idle_aircraft_id,
                    v_target_flights
                )
                ON CONFLICT DO NOTHING;
            END IF;
        END IF;

        -- ====================================================================
        -- Competitive response: adjust prices when a human player serves the
        -- same origin-destination pair as this bot.
        -- ====================================================================
        FOR r_route IN
            SELECT * FROM user_routes
            WHERE ai_competitor_id = r_bot.id AND status = 'active'
        LOOP
            SELECT COUNT(*) INTO v_human_competitors
            FROM user_routes
            WHERE origin_iata = r_route.origin_iata
              AND destination_iata = r_route.destination_iata
              AND user_id IS NOT NULL
              AND status = 'active';

            IF v_human_competitors > 0 THEN
                -- Base fare for this route distance
                v_base_fare := 50.00 + (r_route.distance_km * 0.12);

                -- Bot discounts 3 % but never below 85 % of base fare
                v_new_price := r_route.ticket_price * 0.97;
                IF v_new_price >= v_base_fare * 0.85 THEN
                    UPDATE user_routes
                    SET ticket_price = ROUND(v_new_price::numeric, 2)
                    WHERE id = r_route.id;
                END IF;
            END IF;
        END LOOP;

        -- ====================================================================
        -- ═══════════════════════════════════════════════════════════════════
        -- FINANCIAL INTELLIGENCE
        -- ═══════════════════════════════════════════════════════════════════
        -- Runs after all operational decisions (fleet expansion, route
        -- assignment, competitive pricing) so the cash position reflects
        -- actual operational costs before financial strategy is applied.
        -- ====================================================================

        -- Re-read cash after all prior operations
        SELECT cash INTO v_bot_cash FROM ai_competitors WHERE id = r_bot.id;

        -- ── 1. Emergency loan: bridge capital when cash is dangerously low ──
        -- Takes a loan if cash drops below 50% of starting capital and the
        -- bot has fewer than 2 active loans. This prevents bankruptcy spirals
        -- while keeping bots financially disciplined (max 3 loans total).
        IF v_bot_cash < v_starting_cash * 0.5 THEN
            SELECT COUNT(*) INTO v_active_loans
            FROM loans WHERE ai_competitor_id = r_bot.id AND status = 'active';

            IF v_active_loans < 2 THEN
                PERFORM bot_take_loan(r_bot.id, v_starting_cash * 0.5, 52);
            END IF;
        END IF;

        -- ── 2. Aircraft financing: spread cost when full purchase is out of reach ──
        -- If the bot needs more fleet, has enough for a 20% down payment but
        -- not enough to buy outright, finance the aircraft instead of waiting.
        -- This keeps bots competitive even when cash is moderate.
        SELECT cash INTO v_bot_cash FROM ai_competitors WHERE id = r_bot.id;

        IF v_fleet_count < v_target_fleet_cap AND v_bot_cash > 3000000 THEN
            -- Find the cheapest aircraft that meets the bot's range requirement
            SELECT id, purchase_price INTO v_fin_model_id, v_fin_model_price
            FROM aircraft_models
            WHERE range_km >= v_target_distance
            ORDER BY purchase_price ASC
            LIMIT 1;

            IF v_fin_model_price IS NOT NULL
               AND v_bot_cash < v_fin_model_price
               AND v_bot_cash > v_fin_model_price * 0.20 THEN
                -- Can't afford full price, but can cover the 20% down payment
                PERFORM bot_finance_aircraft(r_bot.id, v_fin_model_id, 0.20, 60);
            END IF;
        END IF;

        -- ── 3. Early loan payoff: save on interest when cash is abundant ──
        -- When cash exceeds 3× starting capital, retire the highest-rate loan
        -- to reduce interest burden and improve the debt ratio component of
        -- the credit score.
        SELECT cash INTO v_bot_cash FROM ai_competitors WHERE id = r_bot.id;

        IF v_bot_cash > v_starting_cash * 3 THEN
            SELECT * INTO v_loan_record
            FROM loans
            WHERE ai_competitor_id = r_bot.id AND status = 'active'
            ORDER BY interest_rate DESC
            LIMIT 1;

            IF v_loan_record.id IS NOT NULL
               AND v_bot_cash > v_loan_record.remaining_balance THEN
                -- Deduct the payoff amount
                UPDATE ai_competitors
                SET cash = cash - v_loan_record.remaining_balance
                WHERE id = r_bot.id;

                -- Mark the loan as paid off
                UPDATE loans
                SET status = 'paid_off',
                    paid_off_at = NOW(),
                    remaining_balance = 0
                WHERE id = v_loan_record.id;

                -- Ledger entry for the payoff
                INSERT INTO financial_ledger (
                    ai_competitor_id, transaction_type, category,
                    amount, description, game_date
                ) VALUES (
                    r_bot.id, 'expense', 'loan_payment',
                    v_loan_record.remaining_balance,
                    'Early loan payoff — saved on future interest',
                    r_bot.game_current_time
                );
            END IF;
        END IF;

        -- ── 4. Update credit score ──
        -- Recalculate after all financial activity so the score reflects
        -- current debt, fleet health, and cash position.
        SELECT * INTO v_credit_score, v_credit_tier
        FROM calculate_bot_credit_score(r_bot.id)
        LIMIT 1;

        UPDATE ai_competitors
        SET credit_score = v_credit_score,
            credit_tier = v_credit_tier
        WHERE id = r_bot.id;

        -- ====================================================================
        -- End of financial intelligence
        -- ====================================================================

        SELECT COUNT(*)::INT INTO v_grounded_count
        FROM user_fleet
        WHERE ai_competitor_id = r_bot.id
          AND (status = 'grounded' OR condition < v_effective_threshold);

        UPDATE ai_competitors
        SET consecutive_negative_days = CASE
                WHEN cash < 0.00 THEN COALESCE(consecutive_negative_days, 0) + 1
                ELSE 0
            END,
            status = CASE
                WHEN cash < 0.00 THEN 'Distress'
                WHEN v_grounded_count > 0 THEN 'Maintenance'
                ELSE 'Active'
            END
        WHERE id = r_bot.id
        RETURNING consecutive_negative_days INTO v_negative_days;

        IF COALESCE(v_negative_days, 0) >= 3 THEN
            UPDATE ai_competitors
            SET status = 'Bankrupt'
            WHERE id = r_bot.id;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
