-- =============================================================================
-- SKYWARD SIMULATION ENGINE - GLOBAL LEADERBOARD & INSIGHTS RPCS (UPDATED)
-- Run this in the Supabase SQL Editor to resolve ambiguous column conflicts (code 42702)
-- =============================================================================

-- 1. DROP EXISTING FUNCTION TO PREVENT RETURN TYPE COLLISIONS
DROP FUNCTION IF EXISTS get_global_leaderboard() CASCADE;

-- 2. RECREATE GLOBAL LEADERBOARD AGGREGATION RPC WITH VARIABLE_CONFLICT RESOLVED
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
#variable_conflict use_column
BEGIN
    RETURN QUERY
    -- 1. Human Players
    SELECT 
        u.id,
        u.company_name::VARCHAR,
        u.ceo_name::VARCHAR,
        FALSE AS is_bot,
        'Player'::VARCHAR AS archetype,
        u.cash,
        u.net_worth,
        (SELECT COUNT(*)::INT FROM user_fleet WHERE user_fleet.user_id = u.id AND user_fleet.status = 'active') AS fleet_size,
        COALESCE((
            SELECT SUM(amount) 
            FROM financial_ledger 
            WHERE user_id = u.id 
              AND transaction_type = 'revenue' 
              AND game_date >= u.game_current_time - INTERVAL '30 days'
        ), 0.00)::NUMERIC AS monthly_revenue,
        COALESCE(u.operational_status, 'Active')::VARCHAR AS status
    FROM users u
    
    UNION ALL
    
    -- 2. AI Competitors
    SELECT 
        ai.id,
        ai.company_name::VARCHAR,
        ai.ceo_name::VARCHAR,
        TRUE AS is_bot,
        ai.archetype::VARCHAR AS archetype,
        ai.cash,
        ai.net_worth,
        (SELECT COUNT(*)::INT FROM user_fleet WHERE user_fleet.ai_competitor_id = ai.id AND user_fleet.status = 'active') AS fleet_size,
        -- Dynamic monthly revenue projection for bots based on active flight operations
        COALESCE((
            SELECT SUM(r.flights_per_week * r.ticket_price * LEAST(m.capacity, FLOOR((org.demand_index + dst.demand_index) * GREATEST(0.0, 1.5 - 0.8 * POWER(r.ticket_price / (50.00 + r.distance_km * 0.12), 2)) * 10))) * 4.33
            FROM user_routes r
            JOIN user_fleet f ON r.assigned_aircraft_id = f.id
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            JOIN airports org ON r.origin_iata = org.iata
            JOIN airports dst ON r.destination_iata = dst.iata
            WHERE r.ai_competitor_id = ai.id 
              AND f.condition >= 40.0 
              AND f.status = 'active'
        ), 0.00)::NUMERIC AS monthly_revenue,
        ai.status::VARCHAR AS status
    FROM ai_competitors ai;
END;
$$ LANGUAGE plpgsql;




-- 3. RECREATE COMPETITOR INSIGHTS DETAILED DRAWER RPC
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
        
        -- Fleet breakdown aggregation: e.g. "{"Airbus A320neo (lease)": 3, "ATR 72-600 (purchase)": 1}"
        SELECT COALESCE(jsonb_object_agg(model_label, count_val), '{}'::jsonb)
        INTO v_fleet
        FROM (
            SELECT (m.manufacturer || ' ' || m.model_name || ' (' || f.acquisition_type || ')') AS model_label, COUNT(*)::INT AS count_val
            FROM user_fleet f
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            WHERE f.ai_competitor_id = p_id
            GROUP BY m.manufacturer, m.model_name, f.acquisition_type
        ) d;
        
        -- Route list: e.g. "["CGK-SIN", "SIN-KUL"]"
        SELECT COALESCE(jsonb_agg(route_label), '[]'::jsonb)
        INTO v_routes
        FROM (
            SELECT (origin_iata || '-' || destination_iata) AS route_label
            FROM user_routes
            WHERE ai_competitor_id = p_id
        ) r;
    ELSE
        SELECT u.company_name,
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
            SELECT (m.manufacturer || ' ' || m.model_name || ' (' || f.acquisition_type || ')') AS model_label, COUNT(*)::INT AS count_val
            FROM user_fleet f
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            WHERE f.user_id = p_id
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
    
    RETURN QUERY SELECT v_company::VARCHAR, v_ceo::VARCHAR, v_cash, v_net_worth, v_status::VARCHAR, v_fleet, v_routes;
END;
$$ LANGUAGE plpgsql;
