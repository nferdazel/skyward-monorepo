-- ============================================================================
-- SKYWARD PHASE 5.1 WORLD ACTOR TICK BOOTSTRAP FIX
-- ============================================================================
-- Fixes the first live Phase 5 issue:
--   1. process_world_tick() had an ambiguous season_id reference.
--   2. Existing actors had already progressed beyond the newly-created season
--      clock, so the season clock must be bootstrapped forward, not actors
--      pulled backward.
--   3. Newly inserted actors should join at active season time.
-- ============================================================================

CREATE OR REPLACE FUNCTION assign_active_season_id()
RETURNS TRIGGER AS $$
DECLARE
    r_season RECORD;
BEGIN
    IF NEW.season_id IS NULL THEN
        SELECT id, current_game_time
        INTO r_season
        FROM season_clock
        WHERE status = 'active'
        ORDER BY created_at ASC
        LIMIT 1;

        NEW.season_id := r_season.id;
    ELSE
        SELECT id, current_game_time
        INTO r_season
        FROM season_clock
        WHERE id = NEW.season_id
        LIMIT 1;
    END IF;

    IF r_season.id IS NOT NULL
       AND (NEW.game_current_time IS NULL OR NEW.game_current_time < r_season.current_game_time) THEN
        NEW.game_current_time := r_season.current_game_time;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


WITH actor_frontier AS (
    SELECT
        sc.id AS season_id,
        GREATEST(
            sc.current_game_time,
            COALESCE(MAX(u.game_current_time), sc.current_game_time),
            COALESCE(MAX(ai.game_current_time), sc.current_game_time)
        ) AS frontier_game_time
    FROM season_clock sc
    LEFT JOIN users u ON u.season_id = sc.id
    LEFT JOIN ai_competitors ai ON ai.season_id = sc.id
    WHERE sc.status = 'active'
    GROUP BY sc.id, sc.current_game_time
)
UPDATE season_clock sc
SET current_game_time = actor_frontier.frontier_game_time,
    last_tick_at = CASE
        WHEN actor_frontier.frontier_game_time > sc.current_game_time THEN NOW()
        ELSE sc.last_tick_at
    END,
    updated_at = NOW()
FROM actor_frontier
WHERE sc.id = actor_frontier.season_id
  AND actor_frontier.frontier_game_time > sc.current_game_time;


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

COMMENT ON FUNCTION assign_active_season_id() IS
'Assigns active season membership and starts new actors at the active season game time.';

COMMENT ON FUNCTION process_world_tick(UUID, INT) IS
'Advances the active season clock and synchronizes player/bot actors to the new season time.';
