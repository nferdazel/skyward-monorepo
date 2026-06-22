-- ============================================================================
-- SKYWARD PHASE 3 WORLD TICK RPC FOUNDATION
-- ============================================================================
-- Adds scheduler-safe world tick RPCs and tick logging for the shared season
-- clock. This phase advances season_clock only. Player and bot actor clocks
-- remain runtime authority until the deterministic daily simulation core is
-- migrated into the world-tick engine.
-- ============================================================================

CREATE TABLE IF NOT EXISTS world_tick_log (
    id BIGSERIAL PRIMARY KEY,
    season_id UUID REFERENCES season_clock(id),
    started_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    finished_at TIMESTAMP WITH TIME ZONE,
    game_time_before TIMESTAMP WITH TIME ZONE,
    game_time_after TIMESTAMP WITH TIME ZONE,
    ticks_processed INT NOT NULL DEFAULT 0,
    real_seconds_processed NUMERIC(20,4) NOT NULL DEFAULT 0.0000,
    game_seconds_processed NUMERIC(20,4) NOT NULL DEFAULT 0.0000,
    players_processed INT NOT NULL DEFAULT 0,
    bots_processed INT NOT NULL DEFAULT 0,
    status VARCHAR(20) NOT NULL DEFAULT 'started' CHECK (status IN ('started', 'skipped', 'success', 'error')),
    message TEXT
);

CREATE INDEX IF NOT EXISTS world_tick_log_season_started_idx
ON world_tick_log(season_id, started_at DESC);


CREATE OR REPLACE FUNCTION resolve_active_season_id(p_season_id UUID DEFAULT NULL)
RETURNS UUID AS $$
DECLARE
    v_season_id UUID;
BEGIN
    IF p_season_id IS NOT NULL THEN
        RETURN p_season_id;
    END IF;

    SELECT id
    INTO v_season_id
    FROM season_clock
    WHERE status = 'active'
    ORDER BY created_at ASC
    LIMIT 1;

    RETURN v_season_id;
END;
$$ LANGUAGE plpgsql STABLE;


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
    v_season_id UUID;
    v_now TIMESTAMP WITH TIME ZONE := NOW();
    v_log_id BIGINT;
    v_elapsed_real_seconds NUMERIC(20,4);
    v_due_ticks INT;
    v_ticks_to_process INT;
    v_real_seconds NUMERIC(20,4);
    v_game_seconds NUMERIC(20,4);
    v_game_time_after TIMESTAMP WITH TIME ZONE;
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
    FROM season_clock
    WHERE id = v_season_id
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

    INSERT INTO world_tick_log (
        season_id,
        game_time_before,
        status
    )
    VALUES (
        r_season.id,
        r_season.current_game_time,
        'started'
    )
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

    UPDATE season_clock
    SET current_game_time = v_game_time_after,
        last_tick_at = r_season.last_tick_at + (v_real_seconds::DOUBLE PRECISION * INTERVAL '1 second'),
        updated_at = v_now
    WHERE id = r_season.id;

    UPDATE world_tick_log
    SET finished_at = v_now,
        game_time_after = v_game_time_after,
        ticks_processed = v_ticks_to_process,
        real_seconds_processed = v_real_seconds,
        game_seconds_processed = v_game_seconds,
        players_processed = 0,
        bots_processed = 0,
        status = 'success',
        message = 'Season clock advanced. Actor simulation remains on legacy clocks in Phase 3.'
    WHERE id = v_log_id;

    RETURN QUERY SELECT
        r_season.id,
        r_season.current_game_time,
        v_game_time_after,
        v_ticks_to_process,
        v_real_seconds,
        v_game_seconds,
        0,
        0,
        'success'::VARCHAR,
        'Season clock advanced. Actor simulation remains on legacy clocks in Phase 3.'::TEXT;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION ensure_world_current(
    p_season_id UUID DEFAULT NULL
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
BEGIN
    RETURN QUERY
    SELECT *
    FROM process_world_tick(p_season_id, 100);
END;
$$ LANGUAGE plpgsql;

COMMENT ON TABLE world_tick_log IS
'Audit log for scheduler-safe season clock ticks. Phase 3 logs season-clock advancement only; actor simulation migrates later.';

COMMENT ON FUNCTION process_world_tick(UUID, INT) IS
'Advances the active season clock using row and advisory locks. Phase 3 does not mutate player or bot actor clocks.';

COMMENT ON FUNCTION ensure_world_current(UUID) IS
'Compatibility wrapper for command RPCs and future snapshot reads to bring the season clock current.';
