-- ============================================================================
-- Rank history: track each player's leaderboard rank over time
-- Enables the UI to show rank changes (up/down/stable).
-- ============================================================================

-- 1. Rank history table
CREATE TABLE IF NOT EXISTS rank_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    is_bot BOOLEAN DEFAULT false,
    game_date DATE NOT NULL,
    rank_position INT NOT NULL,
    net_worth NUMERIC NOT NULL,
    fleet_size INT DEFAULT 0,
    monthly_revenue NUMERIC DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Indexes for efficient lookups
CREATE INDEX IF NOT EXISTS rank_history_user_date_idx
    ON rank_history(user_id, game_date DESC);
CREATE INDEX IF NOT EXISTS rank_history_date_idx
    ON rank_history(game_date DESC);

-- 3. RLS: read-only for authenticated users
ALTER TABLE rank_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY rank_history_select_authenticated
    ON rank_history FOR SELECT TO authenticated USING (true);
GRANT SELECT ON rank_history TO authenticated;

-- 4. Record rank snapshot (called once per game day from process_world_tick)
CREATE OR REPLACE FUNCTION record_rank_snapshot(p_game_date DATE)
RETURNS VOID AS $$
BEGIN
    -- Record human player rankings
    INSERT INTO rank_history (user_id, is_bot, game_date, rank_position, net_worth, fleet_size, monthly_revenue)
    SELECT
        sub.id,
        false,
        p_game_date,
        ROW_NUMBER() OVER (ORDER BY sub.net_worth DESC),
        sub.net_worth,
        sub.fleet_count,
        sub.monthly_rev
    FROM (
        SELECT
            u.id,
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

    -- Record AI competitor rankings (appended after human players)
    INSERT INTO rank_history (user_id, is_bot, game_date, rank_position, net_worth, fleet_size, monthly_revenue)
    SELECT
        sub.id,
        true,
        p_game_date,
        ROW_NUMBER() OVER (ORDER BY sub.net_worth DESC)
            + (SELECT COUNT(*) FROM users WHERE COALESCE(operational_status, 'Active') != 'Bankrupt'),
        sub.net_worth,
        sub.fleet_count,
        0
    FROM (
        SELECT
            ai.id,
            ai.cash + COALESCE(
                (SELECT SUM(am.purchase_price * 0.7)
                 FROM user_fleet uf
                 JOIN aircraft_models am ON uf.aircraft_model_id = am.id
                 WHERE uf.ai_competitor_id = ai.id AND uf.status = 'active'),
                0
            ) AS net_worth,
            (SELECT COUNT(*)::INT
             FROM user_fleet
             WHERE ai_competitor_id = ai.id AND status = 'active') AS fleet_count
        FROM ai_competitors ai
        WHERE ai.status != 'Bankrupt'
    ) sub;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

COMMENT ON TABLE rank_history IS
    'Daily snapshots of player and bot leaderboard ranks. Enables rank-change indicators in the UI.';

COMMENT ON FUNCTION record_rank_snapshot(DATE) IS
    'Records current rank positions for all non-bankrupt actors. Called once per game day from process_world_tick.';

-- 5. Wire record_rank_snapshot into process_world_tick (once per game day)
--    Recreate the function with a game-day boundary check after actor processing.
CREATE OR REPLACE FUNCTION process_world_tick(
    p_season_id UUID DEFAULT NULL,
    p_max_ticks INT DEFAULT 10
)
RETURNS TABLE (
    season_id UUID,
    game_time_before TIMESTAMP WITH TIME ZONE,
    game_time_after TIMESTAMP WITH TIME ZONE,
    ticks_processed INT,
    real_seconds_processed NUMERIC,
    game_seconds_processed NUMERIC,
    players_processed INT,
    bots_processed INT,
    status VARCHAR,
    message TEXT
) AS $$
DECLARE
    r_season RECORD;
    r_user RECORD;
    r_player_result RECORD;
    v_season_id UUID;
    v_now TIMESTAMP WITH TIME ZONE := NOW();
    v_log_id BIGINT;
    v_elapsed_real_seconds NUMERIC(20,4);
    v_due_ticks INT;
    v_ticks_to_process INT;
    v_real_seconds NUMERIC(20,4);
    v_game_seconds NUMERIC(20,4);
    v_game_time_after TIMESTAMP WITH TIME ZONE;
    v_players_processed INT := 0;
    v_bots_processed INT := 0;
BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtext('skyward.process_world_tick')::BIGINT) THEN
        RETURN QUERY SELECT
            p_season_id,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::TIMESTAMP WITH TIME ZONE,
            0,
            0.0000::NUMERIC,
            0.0000::NUMERIC,
            0,
            0,
            'skipped'::VARCHAR,
            'World tick already running.'::TEXT;
        RETURN;
    END IF;

    v_season_id := resolve_active_season_id(p_season_id);
    IF v_season_id IS NULL THEN
        RETURN QUERY SELECT
            NULL::UUID,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::TIMESTAMP WITH TIME ZONE,
            0,
            0.0000::NUMERIC,
            0.0000::NUMERIC,
            0,
            0,
            'error'::VARCHAR,
            'No active season found.'::TEXT;
        RETURN;
    END IF;

    SELECT *
    INTO r_season
    FROM season_clock sc
    WHERE sc.id = v_season_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            v_season_id,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::TIMESTAMP WITH TIME ZONE,
            0,
            0.0000::NUMERIC,
            0.0000::NUMERIC,
            0,
            0,
            'error'::VARCHAR,
            'Season not found.'::TEXT;
        RETURN;
    END IF;

    INSERT INTO world_tick_log (season_id, game_time_before, status)
    VALUES (r_season.id, r_season.current_game_time, 'started')
    RETURNING id INTO v_log_id;

    IF r_season.status <> 'active' THEN
        UPDATE world_tick_log
        SET finished_at = v_now,
            game_time_after = r_season.current_game_time,
            status = 'skipped',
            message = 'Season is not active.'
        WHERE id = v_log_id;

        RETURN QUERY SELECT
            r_season.id,
            r_season.current_game_time,
            r_season.current_game_time,
            0,
            0.0000::NUMERIC,
            0.0000::NUMERIC,
            0,
            0,
            'skipped'::VARCHAR,
            'Season is not active.'::TEXT;
        RETURN;
    END IF;

    v_elapsed_real_seconds := GREATEST(
        0.0000,
        EXTRACT(EPOCH FROM (v_now - r_season.last_tick_at))::NUMERIC
    );
    v_due_ticks := FLOOR(v_elapsed_real_seconds / r_season.tick_interval_seconds)::INT;
    v_ticks_to_process := LEAST(GREATEST(COALESCE(p_max_ticks, 1), 1), v_due_ticks);

    IF v_ticks_to_process <= 0 THEN
        UPDATE world_tick_log
        SET finished_at = v_now,
            game_time_after = r_season.current_game_time,
            status = 'skipped',
            message = 'No due world ticks.'
        WHERE id = v_log_id;

        RETURN QUERY SELECT
            r_season.id,
            r_season.current_game_time,
            r_season.current_game_time,
            0,
            0.0000::NUMERIC,
            0.0000::NUMERIC,
            0,
            0,
            'skipped'::VARCHAR,
            'No due world ticks.'::TEXT;
        RETURN;
    END IF;

    v_real_seconds := v_ticks_to_process * r_season.tick_interval_seconds;
    v_game_seconds := v_real_seconds * r_season.time_scale_multiplier;
    v_game_time_after := r_season.current_game_time + (v_game_seconds::DOUBLE PRECISION * INTERVAL '1 second');

    UPDATE season_clock sc
    SET current_game_time = v_game_time_after,
        last_tick_at = r_season.last_tick_at + (v_real_seconds::DOUBLE PRECISION * INTERVAL '1 second'),
        updated_at = v_now
    WHERE sc.id = r_season.id;

    -- Generate new events and deactivate expired ones after clock advance
    PERFORM generate_game_events(v_game_time_after);
    PERFORM deactivate_expired_events(v_game_time_after);

    FOR r_user IN
        SELECT u.id
        FROM users u
        WHERE u.season_id = r_season.id
    LOOP
        SELECT *
        INTO r_player_result
        FROM process_player_simulation_to_time(r_user.id, v_game_time_after)
        LIMIT 1;

        IF COALESCE(r_player_result.elapsed_game_days, 0.0) > 0.0 THEN
            v_players_processed := v_players_processed + 1;
        END IF;
    END LOOP;

    v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);

    -- Record rank snapshot once per game day (when the calendar day changes)
    IF date_trunc('day', r_season.current_game_time)::DATE <>
       date_trunc('day', v_game_time_after)::DATE THEN
        PERFORM record_rank_snapshot(date_trunc('day', v_game_time_after)::DATE);
    END IF;

    UPDATE world_tick_log
    SET finished_at = NOW(),
        game_time_after = v_game_time_after,
        ticks_processed = v_ticks_to_process,
        real_seconds_processed = v_real_seconds,
        game_seconds_processed = v_game_seconds,
        players_processed = v_players_processed,
        bots_processed = v_bots_processed,
        status = 'success',
        message = 'Season clock and actor state advanced from shared world tick.'
    WHERE id = v_log_id;

    RETURN QUERY SELECT
        r_season.id,
        r_season.current_game_time,
        v_game_time_after,
        v_ticks_to_process,
        v_real_seconds,
        v_game_seconds,
        v_players_processed,
        v_bots_processed,
        'success'::VARCHAR,
        'Season clock and actor state advanced from shared world tick.'::TEXT;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION process_world_tick(UUID, INT) IS
'Advances the active season clock, generates/deactivates game events, records a rank snapshot once per game day, and synchronizes player/bot actors to the new season time.';
