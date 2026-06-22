-- ============================================================================
-- FIX: get_competitor_insights fleet count alignment
-- ============================================================================
-- The leaderboard (get_global_leaderboard) counts only active fleet via
-- `AND user_fleet.status = 'active'`, but get_competitor_insights counts ALL
-- fleet regardless of status (active, grounded, sold, maintenance). This
-- causes the competitor intel panel to show inflated fleet counts compared
-- to the leaderboard table.
--
-- Fix: add `AND f.status = 'active'` to both fleet breakdown subqueries
-- (bot branch and human branch) so both surfaces agree on what counts.
-- ============================================================================

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
    IF p_is_bot THEN
        SELECT ai.company_name, ai.ceo_name, ai.cash, ai.net_worth, ai.status
        INTO v_company, v_ceo, v_cash, v_net_worth, v_status
        FROM ai_competitors ai
        WHERE ai.id = p_id;

        SELECT COALESCE(jsonb_object_agg(model_label, count_val), '{}'::jsonb)
        INTO v_fleet
        FROM (
            SELECT
                (m.manufacturer || ' ' || m.model_name || ' (' || f.acquisition_type || ')')
                    AS model_label,
                COUNT(*)::INT AS count_val
            FROM user_fleet f
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            WHERE f.ai_competitor_id = p_id
              AND f.status = 'active'
            GROUP BY m.manufacturer, m.model_name, f.acquisition_type
        ) d;

        SELECT COALESCE(jsonb_agg(route_label), '[]'::jsonb)
        INTO v_routes
        FROM (
            SELECT (origin_iata || '-' || destination_iata) AS route_label
            FROM user_routes
            WHERE ai_competitor_id = p_id
        ) r;
    ELSE
        SELECT
            u.company_name,
            u.ceo_name,
            u.cash,
            u.net_worth,
            COALESCE(u.operational_status, 'Active')
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
    END IF;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;
