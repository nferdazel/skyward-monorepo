-- ============================================================================
-- Migration 24: Finance snapshot active-route truthfulness
-- Goal:
--   make get_finance_snapshot.active_route_count match its contract name by
--   counting only active route_assignments rows for the actor.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_finance_snapshot(
    p_id uuid,
    p_is_bot boolean DEFAULT false
)
RETURNS TABLE(
    actor_id uuid,
    is_bot boolean,
    company_name character varying,
    cash numeric,
    net_worth numeric,
    owned_aircraft_asset_value numeric,
    leased_aircraft_monthly_exposure numeric,
    fleet_count integer,
    owned_fleet_count integer,
    leased_fleet_count integer,
    active_route_count integer,
    rolling_revenue_30d numeric,
    rolling_expense_30d numeric,
    rolling_net_30d numeric,
    ledger_window_days integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    v_game_current_time TIMESTAMPTZ;
BEGIN
    SELECT u.company_name, u.game_current_time
    INTO v_company_name, v_game_current_time
    FROM users u
    WHERE u.id = p_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_cash := get_user_balance(p_id);
    v_net_worth := calculate_user_net_worth(p_id);

    SELECT
        COUNT(*)::INT,
        COUNT(*) FILTER (
            WHERE f.acquisition_type IN ('purchase', 'finance')
        )::INT,
        COUNT(*) FILTER (WHERE f.acquisition_type = 'lease')::INT,
        COALESCE(
            SUM(
                CASE
                    WHEN f.acquisition_type IN ('purchase', 'finance')
                        THEN m.purchase_price * (f.condition / 100.00)
                    ELSE 0
                END
            ),
            0.00
        ),
        COALESCE(
            SUM(
                CASE
                    WHEN f.acquisition_type = 'lease'
                        THEN m.lease_price_per_month
                    ELSE 0
                END
            ),
            0.00
        )
    INTO
        v_fleet_count,
        v_owned_fleet_count,
        v_leased_fleet_count,
        v_owned_asset_value,
        v_leased_monthly_exposure
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.user_id = p_id;

    SELECT COUNT(*)::INT
    INTO v_active_route_count
    FROM route_assignments r
    WHERE r.user_id = p_id
      AND COALESCE(r.status, 'active') = 'active';

    SELECT
        COALESCE(
            SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END),
            0.00
        ),
        COALESCE(
            SUM(CASE WHEN transaction_type = 'debit' THEN ABS(amount) ELSE 0 END),
            0.00
        )
    INTO v_revenue_30d, v_expense_30d
    FROM bank_transactions
    WHERE user_id = p_id
      AND game_date >= v_game_current_time - INTERVAL '30 days';

    RETURN QUERY
    SELECT
        p_id,
        p_is_bot,
        v_company_name::VARCHAR,
        v_cash,
        v_net_worth,
        v_owned_asset_value,
        v_leased_monthly_exposure,
        v_fleet_count,
        v_owned_fleet_count,
        v_leased_fleet_count,
        v_active_route_count,
        v_revenue_30d,
        v_expense_30d,
        v_revenue_30d - v_expense_30d,
        v_ledger_window_days;
END;
$function$;
