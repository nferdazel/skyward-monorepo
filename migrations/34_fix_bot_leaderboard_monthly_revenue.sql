-- ============================================================================
-- SKYWARD BOT LEADERBOARD MONTHLY REVENUE FIX
-- ============================================================================
-- Aligns bot leaderboard monthly revenue with the human definition:
-- realized revenue ledger rows over the last 30 in-game days, instead of a
-- projected route-theory estimate. This keeps the leaderboard contract
-- consistent with what operators can verify directly in financial_ledger.
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
        (
            SELECT COUNT(*)::INT
            FROM user_fleet
            WHERE user_fleet.user_id = u.id
              AND user_fleet.status = 'active'
        ) AS fleet_size,
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
        (
            SELECT COUNT(*)::INT
            FROM user_fleet
            WHERE user_fleet.ai_competitor_id = ai.id
              AND user_fleet.status = 'active'
        ) AS fleet_size,
        COALESCE((
            SELECT SUM(amount)
            FROM financial_ledger
            WHERE ai_competitor_id = ai.id
              AND transaction_type = 'revenue'
              AND game_date >= ai.game_current_time - INTERVAL '30 days'
        ), 0.00)::NUMERIC AS monthly_revenue,
        ai.status::VARCHAR AS status
    FROM ai_competitors ai;
END;
$$ LANGUAGE plpgsql;
