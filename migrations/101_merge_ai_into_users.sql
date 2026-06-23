-- ============================================================================
-- Migration 101: Merge ai_competitors into users
-- ============================================================================
-- Consolidates all actor data into the users table by adding actor_type,
-- migrating bot data, updating all functions/triggers, and dropping ai_competitors.
-- ============================================================================

BEGIN;

-- ============================================================================
-- Step 1: Add new columns to users
-- ============================================================================
ALTER TABLE users ADD COLUMN IF NOT EXISTS actor_type VARCHAR(10) NOT NULL DEFAULT 'REAL'
    CHECK (actor_type IN ('REAL', 'AI'));

ALTER TABLE users ADD COLUMN IF NOT EXISTS archetype VARCHAR(30)
    CHECK (archetype IN ('Aggressive', 'Premium', 'Regional'));

ALTER TABLE users ADD COLUMN IF NOT EXISTS credit_tier VARCHAR(20) DEFAULT 'Standard';

-- ============================================================================
-- Step 2: Make auth columns nullable (bots don't have auth)
-- ============================================================================
ALTER TABLE users ALTER COLUMN username DROP NOT NULL;
ALTER TABLE users ALTER COLUMN auth_user_id DROP NOT NULL;

-- Expand operational_status check to include 'Bankrupt' (used by bots)
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_operational_status_check;
ALTER TABLE users ADD CONSTRAINT users_operational_status_check
    CHECK (operational_status IN ('Active', 'Distress', 'Maintenance', 'Recovery', 'Bankrupt'));

-- ============================================================================
-- Step 3: Insert bot data into users
-- ============================================================================
INSERT INTO users (
    id, actor_type, company_name, ceo_name, archetype,
    cash, net_worth, hq_airport_iata, auto_grounding_threshold,
    game_current_time, last_active_at, operational_status,
    consecutive_negative_days, recovery_streak_days,
    credit_score, credit_tier, season_id,
    buffered_revenue, buffered_ops_cost, buffered_lease_cost, buffered_cargo_revenue
)
SELECT
    id, 'AI', company_name, ceo_name, archetype,
    cash, net_worth, hq_airport_iata, auto_grounding_threshold,
    game_current_time, last_active_at,
    CASE status
        WHEN 'Active' THEN 'Active'
        WHEN 'Distress' THEN 'Distress'
        WHEN 'Bankrupt' THEN 'Bankrupt'
        ELSE 'Active'
    END,
    consecutive_negative_days, 0,
    COALESCE(credit_score, 500), COALESCE(credit_tier, 'Standard'), season_id,
    COALESCE(buffered_revenue, 0.00), COALESCE(buffered_ops_cost, 0.00),
    COALESCE(buffered_lease_cost, 0.00), COALESCE(buffered_cargo_revenue, 0.00)
FROM ai_competitors
ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- Step 4: Migrate fleet ownership
-- ============================================================================
-- Drop exclusive owner constraint (no longer meaningful after consolidation)
ALTER TABLE user_fleet DROP CONSTRAINT IF EXISTS exclusive_owner_fleet;

-- Migrate ai_competitor_id → user_id
UPDATE user_fleet SET user_id = ai_competitor_id
WHERE user_id IS NULL AND ai_competitor_id IS NOT NULL;

-- Drop the fleet trigger that references ai_competitor_id in its column list
DROP TRIGGER IF EXISTS trg_fleet_change ON user_fleet;

-- Drop all FK constraints and indexes referencing ai_competitor_id
ALTER TABLE user_fleet DROP CONSTRAINT IF EXISTS user_fleet_ai_competitor_id_fkey;
ALTER TABLE user_fleet DROP CONSTRAINT IF EXISTS user_fleet_ai_competitor_fk;
DROP INDEX IF EXISTS user_fleet_ai_competitor_id_idx;
ALTER TABLE user_fleet DROP COLUMN IF EXISTS ai_competitor_id;

-- ============================================================================
-- Step 5: Migrate route ownership
-- ============================================================================
-- Drop exclusive owner constraint
ALTER TABLE user_routes DROP CONSTRAINT IF EXISTS exclusive_owner_routes;

-- Migrate ai_competitor_id → user_id
UPDATE user_routes SET user_id = ai_competitor_id
WHERE user_id IS NULL AND ai_competitor_id IS NOT NULL;

-- Drop all FK constraints and indexes
ALTER TABLE user_routes DROP CONSTRAINT IF EXISTS user_routes_ai_competitor_id_fkey;
DROP INDEX IF EXISTS user_routes_ai_competitor_id_idx;
DROP INDEX IF EXISTS unique_ai_route;
ALTER TABLE user_routes DROP COLUMN IF EXISTS ai_competitor_id;

-- ============================================================================
-- Step 6: Migrate financial ledger ownership
-- ============================================================================
-- Drop check constraint before column removal
ALTER TABLE financial_ledger DROP CONSTRAINT IF EXISTS chk_ledger_owner;

-- Migrate ai_competitor_id → user_id
UPDATE financial_ledger SET user_id = ai_competitor_id
WHERE user_id IS NULL AND ai_competitor_id IS NOT NULL;

-- Drop FK constraint and index
ALTER TABLE financial_ledger DROP CONSTRAINT IF EXISTS financial_ledger_ai_competitor_id_fkey;
DROP INDEX IF EXISTS financial_ledger_ai_competitor_id_idx;
ALTER TABLE financial_ledger DROP COLUMN IF EXISTS ai_competitor_id;

-- ============================================================================
-- Step 7: Migrate loans ownership
-- ============================================================================
-- Migrate ai_competitor_id → user_id
UPDATE loans SET user_id = ai_competitor_id
WHERE user_id IS NULL AND ai_competitor_id IS NOT NULL;

-- Drop FK constraint and index
ALTER TABLE loans DROP CONSTRAINT IF EXISTS loans_ai_competitor_id_fkey;
DROP INDEX IF EXISTS loans_ai_competitor_status_idx;
ALTER TABLE loans DROP COLUMN IF EXISTS ai_competitor_id;
ALTER TABLE loans ALTER COLUMN user_id SET NOT NULL;

-- ============================================================================
-- Step 7b: Migrate aircraft_financing ownership
-- ============================================================================
UPDATE aircraft_financing SET user_id = ai_competitor_id
WHERE user_id IS NULL AND ai_competitor_id IS NOT NULL;

ALTER TABLE aircraft_financing DROP CONSTRAINT IF EXISTS aircraft_financing_ai_competitor_id_fkey;
DROP INDEX IF EXISTS aircraft_financing_ai_competitor_status_idx;
ALTER TABLE aircraft_financing DROP COLUMN IF EXISTS ai_competitor_id;

-- ============================================================================
-- Step 8: Update functions that reference ai_competitors
-- ============================================================================

-- ── 8a. calculate_ai_net_worth ──
CREATE OR REPLACE FUNCTION calculate_ai_net_worth(p_ai_id UUID)
RETURNS NUMERIC AS $$
DECLARE
    v_cash NUMERIC;
    v_fleet_value NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_ai_id;

    SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
    INTO v_fleet_value
    FROM user_fleet f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.user_id = p_ai_id AND f.acquisition_type = 'purchase';

    RETURN COALESCE(v_cash, 0) + v_fleet_value;
END;
$$ LANGUAGE plpgsql;

-- ── 8b. trg_update_ai_net_worth ──
CREATE OR REPLACE FUNCTION trg_update_ai_net_worth()
RETURNS TRIGGER AS $$
BEGIN
    NEW.net_worth := calculate_ai_net_worth(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ── 8c. trg_fleet_reconcile_net_worth ──
CREATE OR REPLACE FUNCTION trg_fleet_reconcile_net_worth()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.user_id IS NOT NULL THEN
            UPDATE users SET net_worth = calculate_user_net_worth(OLD.user_id) WHERE id = OLD.user_id;
        END IF;
        RETURN OLD;
    ELSE
        IF NEW.user_id IS NOT NULL THEN
            UPDATE users SET net_worth = calculate_user_net_worth(NEW.user_id) WHERE id = NEW.user_id;
        END IF;

        IF TG_OP = 'UPDATE' THEN
            IF OLD.user_id IS NOT NULL AND OLD.user_id != COALESCE(NEW.user_id, gen_random_uuid()) THEN
                UPDATE users SET net_worth = calculate_user_net_worth(OLD.user_id) WHERE id = OLD.user_id;
            END IF;
        END IF;
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Recreate the fleet trigger (now references only user_id)
CREATE TRIGGER trg_fleet_change
    AFTER INSERT OR UPDATE OF condition, status, user_id OR DELETE ON user_fleet
    FOR EACH ROW
    EXECUTE FUNCTION trg_fleet_reconcile_net_worth();

-- ── 8d. reconcile_all_net_worths ──
CREATE OR REPLACE FUNCTION reconcile_all_net_worths()
RETURNS VOID AS $$
BEGIN
    UPDATE users u SET net_worth = calculate_user_net_worth(u.id);
END;
$$ LANGUAGE plpgsql;

-- ── 8e. get_competitor_insights ──
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
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.user_id = p_id
          AND f.status = 'active'
        GROUP BY m.manufacturer, m.model_name, f.acquisition_type
    ) d;

    SELECT COALESCE(jsonb_agg(route_label), '[]'::jsonb)
    INTO v_routes
    FROM (
        SELECT (origin_iata || '-' || destination_iata) AS route_label
        FROM user_routes
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

-- ── 8f. get_global_leaderboard ──
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
        (SELECT COUNT(*)::INT FROM user_fleet WHERE user_id = u.id AND status = 'active') AS fleet_size,
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

-- ── 8g. get_finance_snapshot ──
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
    FROM user_fleet f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.user_id = p_id;

    SELECT COUNT(*)::INT
    INTO v_active_route_count
    FROM user_routes r
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

-- ── 8h. record_rank_snapshot ──
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
                 FROM user_fleet uf
                 JOIN aircraft_models am ON uf.aircraft_model_id = am.id
                 WHERE uf.user_id = u.id AND uf.status = 'active'),
                0
            ) AS net_worth,
            (SELECT COUNT(*)::INT
             FROM user_fleet
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

-- ── 8i. calculate_bot_credit_score ──
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
    FROM user_fleet WHERE user_id = p_bot_id;

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

    v_total_debt := v_total_debt + COALESCE(
        (SELECT SUM(remaining_balance) FROM aircraft_financing
         WHERE user_id = p_bot_id AND status = 'active'), 0);

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

-- ── 8j. bot_take_loan ──
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
    SELECT COUNT(*) INTO v_existing_loans
    FROM loans WHERE user_id = p_bot_id AND status = 'active';
    IF v_existing_loans >= 3 THEN
        RETURN false;
    END IF;

    IF p_principal < 100000 OR p_principal > 5000000 THEN
        RETURN false;
    END IF;

    SELECT game_current_time, cash INTO v_game_time, v_bot_cash
    FROM users WHERE id = p_bot_id AND actor_type = 'AI';

    IF NOT FOUND THEN RETURN false; END IF;

    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    UPDATE users SET cash = cash + p_principal WHERE id = p_bot_id;

    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance,
        weekly_payment, game_date_taken, status
    ) VALUES (
        p_bot_id, p_principal, v_interest_rate, v_total_repayable,
        v_weekly_payment, v_game_time, 'active'
    );

    INSERT INTO financial_ledger (
        user_id, transaction_type, category, amount, description, game_date
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

-- ── 8k. bot_finance_aircraft ──
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

    INSERT INTO user_fleet (
        user_id, aircraft_model_id, tail_number,
        acquisition_type, condition, status,
        economy_seats, business_seats, first_class_seats
    ) VALUES (
        p_bot_id, p_aircraft_model_id, v_tail,
        'purchase', 100.00, 'active',
        v_economy, v_business, v_first
    ) RETURNING id INTO v_fleet_id;

    INSERT INTO aircraft_financing (
        user_id, aircraft_model_id, fleet_aircraft_id,
        purchase_price, down_payment, principal,
        interest_rate, monthly_payment, term_months,
        remaining_balance, taken_at
    ) VALUES (
        p_bot_id, p_aircraft_model_id, v_fleet_id,
        v_purchase_price, v_down_payment, v_principal,
        v_interest_rate, v_monthly_payment, p_term_months,
        v_total_repayable, v_game_time
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

-- ── 8l. process_all_bots_simulation_to_time ──
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
    v_buffered_cargo_accum NUMERIC(20,2);
    v_cargo_rev NUMERIC(20,2);
    v_processed INT := 0;
BEGIN
    SELECT fuel_price_per_liter, absolute_minimum_safety_limit
    INTO v_fuel_price, v_absolute_minimum_safety_limit
    FROM global_game_settings
    LIMIT 1;

    v_fuel_price := COALESCE(v_fuel_price, 0.85);
    v_absolute_minimum_safety_limit := COALESCE(v_absolute_minimum_safety_limit, 30.00);

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
            FROM user_fleet f
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
            WHERE r.user_id = r_bot.id
        LOOP
            IF COALESCE(v_route.status, 'grounded') != 'active'
               OR COALESCE(v_route.condition, 0.00) < v_effective_grounding_threshold THEN
                CONTINUE;
            END IF;

            v_flight_duration := COALESCE((v_route.distance_km / NULLIF(v_route.speed_kmh, 0)), 0.0) + 1.0;
            v_flights := COALESCE(v_game_days * (v_route.flights_per_week / 7.0), 0.0);

            IF v_flights > 0.0001 THEN
                v_passengers := calculate_route_expected_passengers(
                    COALESCE(v_route.capacity, 0),
                    COALESCE(v_route.distance_km, 0.0),
                    COALESCE(v_route.ticket_price, 0.00),
                    COALESCE(v_route.org_demand, 50),
                    COALESCE(v_route.dst_demand, 50)
                );

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
                VALUES (r_bot.id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew, & airport landing fees', date_trunc('day', p_target_game_time));
            END IF;

            IF v_buffered_lease_accum > 0 THEN
                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (r_bot.id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active bot fleet', date_trunc('day', p_target_game_time));
            END IF;

            DELETE FROM financial_ledger
            WHERE user_id = r_bot.id
              AND game_date < (p_target_game_time - INTERVAL '30 days');

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

-- ── 8m. execute_bot_decisions ──
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
            UPDATE user_fleet SET status = 'grounded' WHERE user_id = r_bot.id;
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
        FROM user_fleet WHERE user_id = r_bot.id;

        SELECT COUNT(*)::INT INTO v_route_count
        FROM user_routes WHERE user_id = r_bot.id;

        SELECT COUNT(*)::INT INTO v_idle_aircraft_count
        FROM user_fleet f
        WHERE f.user_id = r_bot.id
          AND f.status = 'active'
          AND f.condition >= v_effective_threshold
          AND NOT EXISTS (
              SELECT 1 FROM user_routes r WHERE r.assigned_aircraft_id = f.id
          );

        SELECT
            f.id, f.condition, f.acquisition_type,
            m.model_name, m.lease_price_per_month, m.purchase_price
        INTO
            v_grounded_aircraft_id, v_grounded_condition, v_grounded_acquisition_type,
            v_grounded_model_name, v_grounded_lease_price, v_grounded_purchase_price
        FROM user_fleet f
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

                UPDATE user_fleet
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
            FROM user_routes r
            WHERE r.user_id = r_bot.id
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

                INSERT INTO user_fleet (
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
                        INSERT INTO user_fleet (
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

        SELECT COUNT(*)::INT INTO v_fleet_count FROM user_fleet WHERE user_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_route_count FROM user_routes WHERE user_id = r_bot.id;

        SELECT
            f.id, f.tail_number, f.condition,
            m.model_name, m.capacity, m.speed_kmh, m.range_km
        INTO
            v_idle_aircraft_id, v_idle_tail, v_idle_condition,
            v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range
        FROM user_fleet f
        JOIN aircraft_models m ON f.aircraft_model_id = m.id
        WHERE f.user_id = r_bot.id
          AND f.status = 'active'
          AND f.condition >= v_effective_threshold
          AND NOT EXISTS (
              SELECT 1 FROM user_routes r WHERE r.assigned_aircraft_id = f.id
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

                INSERT INTO user_routes (
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
            SELECT * FROM user_routes
            WHERE user_id = r_bot.id AND status = 'active'
        LOOP
            SELECT COUNT(*) INTO v_human_competitors
            FROM user_routes
            WHERE origin_iata = r_route.origin_iata
              AND destination_iata = r_route.destination_iata
              AND user_id IS NOT NULL
              AND status = 'active'
              AND user_id != r_bot.id;

            IF v_human_competitors > 0 THEN
                v_base_fare := 50.00 + (r_route.distance_km * 0.12);
                v_new_price := r_route.ticket_price * 0.97;
                IF v_new_price >= v_base_fare * 0.85 THEN
                    UPDATE user_routes
                    SET ticket_price = ROUND(v_new_price::numeric, 2)
                    WHERE id = r_route.id;
                END IF;
            END IF;
        END LOOP;

        -- ── Financial Intelligence ──

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
        FROM user_fleet
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
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

-- ============================================================================
-- Step 9: Update triggers
-- ============================================================================

-- Drop old triggers on ai_competitors
DROP TRIGGER IF EXISTS trg_ai_cash_change ON ai_competitors;
DROP TRIGGER IF EXISTS trg_ai_competitors_assign_active_season_id ON ai_competitors;

-- Create new triggers on users (with actor_type filter)
CREATE TRIGGER trg_ai_cash_change
    BEFORE UPDATE OF cash ON users
    FOR EACH ROW
    WHEN (NEW.actor_type = 'AI')
    EXECUTE FUNCTION trg_update_ai_net_worth();

CREATE TRIGGER trg_ai_assign_season
    BEFORE INSERT ON users
    FOR EACH ROW
    WHEN (NEW.actor_type = 'AI')
    EXECUTE FUNCTION assign_active_season_id();

-- ============================================================================
-- Step 10: Update RLS policies
-- ============================================================================
DROP POLICY IF EXISTS ai_competitors_select_authenticated ON ai_competitors;
-- Existing users RLS already handles SELECT for authenticated users.
-- AI data is now in the users table, readable by all authenticated users.

-- ============================================================================
-- Step 11: Drop ai_competitors table
-- ============================================================================
DROP TABLE IF EXISTS ai_competitors CASCADE;

-- ============================================================================
-- Step 12: Drop aircraft_financing table (now merged into loans)
-- ============================================================================
DROP TABLE IF EXISTS aircraft_financing CASCADE;

COMMIT;
