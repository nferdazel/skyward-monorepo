-- ============================================================================
-- Migration 115: Fix 6 remaining critical bugs from final verification
-- ============================================================================
-- Bug 1: get_global_leaderboard — ambiguous status column in subquery
-- Bug 2: handle_new_auth_user — inserts into dropped password_hash column
-- Bug 3: execute_bot_decisions — calls non-existent bot_take_loan()
-- Bug 4: execute_bot_decisions — calls non-existent bot_finance_aircraft()
-- Bug 5: process_all_bots_simulation_to_time — calls non-existent process_bot_loan_payments()
-- Bug 6: Cron job calls non-existent ensure_world_current()
-- ============================================================================

-- ============================================================================
-- Bug 1: get_global_leaderboard — qualify ambiguous status column
-- ============================================================================
-- The fleet_aircraft subquery references unqualified "status" which collides
-- with the implicit OUT variable from RETURNS TABLE. Fix: add table alias.
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
        (u.actor_type = 'AI')::BOOLEAN,
        COALESCE(u.archetype, 'Player')::VARCHAR,
        u.cash,
        u.net_worth,
        (SELECT COUNT(*)::INT FROM fleet_aircraft f WHERE f.user_id = u.id AND f.status = 'active'),
        COALESCE((
            SELECT SUM(fl.amount)
            FROM financial_ledger fl
            WHERE fl.user_id = u.id
              AND fl.transaction_type = 'revenue'
              AND fl.game_date >= u.game_current_time - INTERVAL '30 days'
        ), 0.00)::NUMERIC,
        COALESCE(u.operational_status, 'Active')::VARCHAR
    FROM users u;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- Bug 2: handle_new_auth_user — remove dropped password_hash column
-- ============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER AS $$
DECLARE
    v_username TEXT;
    v_expected_email TEXT;
    v_company_name TEXT;
    v_ceo_name TEXT;
    v_starting_cash NUMERIC;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.users u
        WHERE u.auth_user_id = NEW.id
    ) THEN
        RETURN NEW;
    END IF;

    v_username := public.normalize_username(NEW.raw_user_meta_data ->> 'username');
    v_company_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'company_name', '')), '');
    v_ceo_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'ceo_name', '')), '');

    IF v_username IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.username';
    END IF;

    IF v_company_name IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.company_name';
    END IF;

    IF v_ceo_name IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.ceo_name';
    END IF;

    v_expected_email := public.build_synthetic_auth_email(v_username);
    IF lower(COALESCE(NEW.email, '')) <> v_expected_email THEN
        RAISE EXCEPTION 'Auth bootstrap email mismatch for username %', v_username;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.users u
        WHERE u.username = v_username
    ) THEN
        RAISE EXCEPTION 'Username % is already registered.', v_username;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.users u
        WHERE u.company_name = v_company_name
    ) THEN
        RAISE EXCEPTION 'Company name % is already registered.', v_company_name;
    END IF;

    SELECT COALESCE(
        (SELECT g.starting_cash::NUMERIC FROM public.global_game_settings g LIMIT 1),
        15000000.00
    )
    INTO v_starting_cash;

    INSERT INTO public.users (
        auth_user_id,
        username,
        company_name,
        ceo_name,
        cash,
        net_worth,
        last_active_at
    )
    VALUES (
        NEW.id,
        v_username,
        v_company_name,
        v_ceo_name,
        v_starting_cash,
        v_starting_cash,
        NOW()
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog;


-- ============================================================================
-- Bug 3: Create bot_take_loan wrapper (called by execute_bot_decisions)
-- ============================================================================

CREATE OR REPLACE FUNCTION bot_take_loan(
    p_bot_id UUID,
    p_principal NUMERIC,
    p_term_weeks INT DEFAULT 52
) RETURNS BOOLEAN AS $$
DECLARE
    v_existing_loans INT;
    v_cash NUMERIC;
    v_interest_rate NUMERIC := 0.05;
    v_total_repayable NUMERIC;
    v_weekly_payment NUMERIC;
    v_game_time TIMESTAMPTZ;
BEGIN
    SELECT COUNT(*) INTO v_existing_loans
    FROM loans WHERE user_id = p_bot_id AND status = 'active';
    IF v_existing_loans >= 3 THEN RETURN false; END IF;

    IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN false; END IF;

    SELECT cash, game_current_time INTO v_cash, v_game_time
    FROM users WHERE id = p_bot_id;

    v_total_repayable := p_principal * (1 + v_interest_rate * (p_term_weeks / 52.0));
    v_weekly_payment := v_total_repayable / p_term_weeks;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance,
        weekly_payment, status, game_date_taken, loan_type)
    VALUES (p_bot_id, p_principal, v_interest_rate, v_total_repayable,
        v_weekly_payment, 'active', v_game_time, 'unsecured');

    UPDATE users SET cash = cash + p_principal WHERE id = p_bot_id;

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_bot_id, 'revenue', 'loan', p_principal, 'Bot loan disbursement', v_game_time);

    RETURN true;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION bot_take_loan(UUID, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bot_take_loan(UUID, NUMERIC, INT) TO service_role;


-- ============================================================================
-- Bug 4: Create bot_finance_aircraft wrapper (called by execute_bot_decisions)
-- ============================================================================

CREATE OR REPLACE FUNCTION bot_finance_aircraft(
    p_bot_id UUID,
    p_aircraft_model_id UUID,
    p_down_payment_pct NUMERIC DEFAULT 0.20,
    p_term_months INT DEFAULT 60
) RETURNS BOOLEAN AS $$
DECLARE
    v_model RECORD;
    v_purchase_price NUMERIC;
    v_down_payment NUMERIC;
    v_principal NUMERIC;
    v_interest_rate NUMERIC := 0.05;
    v_monthly_payment NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_fleet_id UUID;
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN RETURN false; END IF;

    v_purchase_price := v_model.purchase_price;
    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_monthly_payment := (v_principal * (1 + v_interest_rate)) / p_term_months;

    SELECT cash, game_current_time INTO v_cash, v_game_time
    FROM users WHERE id = p_bot_id;

    IF v_cash < v_down_payment THEN RETURN false; END IF;

    UPDATE users SET cash = cash - v_down_payment WHERE id = p_bot_id;

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, acquisition_type, condition, status,
        tail_number, economy_seats, business_seats, first_class_seats)
    VALUES (p_bot_id, p_aircraft_model_id, 'finance', 100.00, 'active',
        'BOT-' || left(p_bot_id::text, 4),
        FLOOR(v_model.capacity * 0.70)::INT,
        FLOOR(v_model.capacity * 0.20)::INT,
        FLOOR(v_model.capacity * 0.10)::INT)
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance,
        weekly_payment, status, game_date_taken, loan_type,
        aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment,
        term_months, monthly_payment, payments_made)
    VALUES (p_bot_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate),
        0, 'active', v_game_time, 'aircraft_financing',
        p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment,
        p_term_months, v_monthly_payment, 0);

    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (p_bot_id, 'expense', 'aircraft_financing_down', v_down_payment,
        'Bot aircraft financing down payment', v_game_time);

    RETURN true;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION bot_finance_aircraft(UUID, UUID, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bot_finance_aircraft(UUID, UUID, NUMERIC, INT) TO service_role;


-- ============================================================================
-- Bug 5: Create process_bot_loan_payments wrapper
-- ============================================================================
-- Delegates to the consolidated process_loan_payments which already has the
-- AI bot path (actor_type = 'AI' branch with simplified penalty logic).
-- ============================================================================

CREATE OR REPLACE FUNCTION process_bot_loan_payments(
    p_bot_id UUID,
    p_game_date TIMESTAMPTZ
) RETURNS VOID AS $$
BEGIN
    PERFORM process_loan_payments(p_bot_id, p_game_date);
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION process_bot_loan_payments(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_bot_loan_payments(UUID, TIMESTAMPTZ) TO service_role;


-- ============================================================================
-- Bug 6: Create ensure_world_current wrapper (called by pg_cron job)
-- ============================================================================
-- The cron job in migration 40 calls ensure_world_current(NULL). That function
-- was dropped in migration 103. Re-create as a thin wrapper over process_world_tick.
-- ============================================================================

CREATE OR REPLACE FUNCTION ensure_world_current(p_season_id UUID DEFAULT NULL)
RETURNS TABLE (
    season_id UUID,
    ticks_processed INT,
    game_time_after TIMESTAMPTZ,
    players_processed INT,
    bots_processed INT
) AS $$
BEGIN
    RETURN QUERY SELECT * FROM process_world_tick(p_season_id, 10);
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION ensure_world_current(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ensure_world_current(UUID) TO service_role;
