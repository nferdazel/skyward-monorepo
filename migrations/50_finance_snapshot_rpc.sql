-- ============================================================================
-- SKYWARD FINANCE SNAPSHOT RPC
-- ============================================================================
-- Adds a shared finance snapshot surface for both human players and AI
-- competitors. This separates current balance-sheet truth from the retained
-- rolling 30-day financial_ledger window.
-- ============================================================================

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
    IF p_is_bot THEN
        SELECT ai.company_name, ai.cash, ai.net_worth, ai.game_current_time
        INTO v_company_name, v_cash, v_net_worth, v_game_current_time
        FROM ai_competitors ai
        WHERE ai.id = p_id;

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
        WHERE f.ai_competitor_id = p_id;

        SELECT COUNT(*)::INT
        INTO v_active_route_count
        FROM user_routes r
        WHERE r.ai_competitor_id = p_id;

        SELECT
            COALESCE(SUM(CASE WHEN fl.transaction_type = 'revenue' THEN fl.amount ELSE 0 END), 0.00),
            COALESCE(SUM(CASE WHEN fl.transaction_type = 'expense' THEN fl.amount ELSE 0 END), 0.00)
        INTO v_revenue_30d, v_expense_30d
        FROM financial_ledger fl
        WHERE fl.ai_competitor_id = p_id
          AND fl.game_date >= v_game_current_time - INTERVAL '30 days';
    ELSE
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
    END IF;

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

COMMENT ON FUNCTION get_finance_snapshot(UUID, BOOLEAN) IS
'Returns current balance-sheet and rolling 30-day finance metrics for one human player or AI competitor.';
