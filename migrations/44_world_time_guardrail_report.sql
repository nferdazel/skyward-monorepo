-- ============================================================================
-- SKYWARD PHASE 7/8/11-LITE WORLD TIME GUARDRAILS
-- ============================================================================
-- Adds a read-only guardrail report for live audits after the world-clock
-- cutover. This does not mutate simulation state.
-- ============================================================================

CREATE OR REPLACE FUNCTION get_world_tick_guardrail_report()
RETURNS TABLE (
    check_name TEXT,
    check_status TEXT,
    details TEXT
) AS $$
DECLARE
    r_season RECORD;
    r_latest_success RECORD;
    v_lagging_players INT := 0;
    v_lagging_bots INT := 0;
    v_ahead_players INT := 0;
    v_ahead_bots INT := 0;
    v_backwards_logs INT := 0;
BEGIN
    SELECT *
    INTO r_season
    FROM season_clock
    WHERE status = 'active'
    ORDER BY created_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            'active_season_exists',
            'fail',
            'No active season_clock row exists.';
        RETURN;
    END IF;

    RETURN QUERY SELECT
        'active_season_exists',
        'pass',
        'Active season ' || r_season.id || ' at ' || r_season.current_game_time || '.';

    SELECT COUNT(*)::INT
    INTO v_lagging_players
    FROM users u
    WHERE u.season_id = r_season.id
      AND u.game_current_time < r_season.current_game_time;

    SELECT COUNT(*)::INT
    INTO v_lagging_bots
    FROM ai_competitors ai
    WHERE ai.season_id = r_season.id
      AND ai.status != 'Bankrupt'
      AND ai.game_current_time < r_season.current_game_time;

    RETURN QUERY SELECT
        'actors_not_lagging',
        CASE WHEN v_lagging_players = 0 AND v_lagging_bots = 0 THEN 'pass' ELSE 'fail' END,
        'lagging_players=' || v_lagging_players || ', lagging_bots=' || v_lagging_bots || '.';

    SELECT COUNT(*)::INT
    INTO v_ahead_players
    FROM users u
    WHERE u.season_id = r_season.id
      AND u.game_current_time > r_season.current_game_time;

    SELECT COUNT(*)::INT
    INTO v_ahead_bots
    FROM ai_competitors ai
    WHERE ai.season_id = r_season.id
      AND ai.status != 'Bankrupt'
      AND ai.game_current_time > r_season.current_game_time;

    RETURN QUERY SELECT
        'actors_not_ahead',
        CASE WHEN v_ahead_players = 0 AND v_ahead_bots = 0 THEN 'pass' ELSE 'fail' END,
        'ahead_players=' || v_ahead_players || ', ahead_bots=' || v_ahead_bots || '.';

    SELECT COUNT(*)::INT
    INTO v_backwards_logs
    FROM world_tick_log wtl
    WHERE wtl.status = 'success'
      AND wtl.game_time_after < wtl.game_time_before;

    RETURN QUERY SELECT
        'no_backwards_world_ticks',
        CASE WHEN v_backwards_logs = 0 THEN 'pass' ELSE 'fail' END,
        'backwards_success_logs=' || v_backwards_logs || '.';

    SELECT *
    INTO r_latest_success
    FROM world_tick_log wtl
    WHERE wtl.season_id = r_season.id
      AND wtl.status = 'success'
    ORDER BY wtl.started_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            'recent_successful_world_tick',
            'fail',
            'No successful world_tick_log rows exist for active season.';
        RETURN;
    END IF;

    RETURN QUERY SELECT
        'recent_successful_world_tick',
        CASE
            WHEN r_latest_success.started_at >= NOW() - INTERVAL '10 minutes' THEN 'pass'
            ELSE 'warn'
        END,
        'latest_success=' || r_latest_success.started_at
            || ', ticks=' || r_latest_success.ticks_processed
            || ', players=' || r_latest_success.players_processed
            || ', bots=' || r_latest_success.bots_processed || '.';
END;
$$ LANGUAGE plpgsql STABLE;

GRANT EXECUTE ON FUNCTION get_world_tick_guardrail_report() TO authenticated, anon, service_role;

COMMENT ON FUNCTION get_world_tick_guardrail_report() IS
'Read-only live audit report for world-clock health, actor lag, and backwards tick regressions.';
