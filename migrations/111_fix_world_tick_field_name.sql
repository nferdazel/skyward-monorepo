-- Fix: process_world_tick references wrong field name
-- elapsed_game_days → elapsed_days (matching process_player_simulation_to_time return type)

CREATE OR REPLACE FUNCTION process_world_tick(
    p_season_id UUID DEFAULT NULL,
    p_max_ticks INT DEFAULT 10
) RETURNS TABLE (
    season_id UUID,
    ticks_processed INT,
    game_time_after TIMESTAMPTZ,
    players_processed INT,
    bots_processed INT
) AS $fn$
DECLARE
    r_season RECORD;
    v_game_time_after TIMESTAMPTZ;
    v_ticks_processed INT := 0;
    v_players_processed INT := 0;
    v_bots_processed INT := 0;
    r_user RECORD;
    r_player_result RECORD;
    v_lock_key BIGINT;
BEGIN
    -- Get or resolve season
    IF p_season_id IS NOT NULL THEN
        SELECT * INTO r_season FROM season_clock WHERE id = p_season_id;
    ELSE
        SELECT * INTO r_season FROM season_clock WHERE status = 'active' LIMIT 1;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active season found';
    END IF;

    -- Advisory lock to prevent concurrent ticks
    v_lock_key := hashtext(r_season.id::text);
    IF NOT pg_try_advisory_lock(v_lock_key) THEN
        RAISE EXCEPTION 'World tick already in progress for season %', r_season.id;
    END IF;

    -- Calculate game time advancement
    v_game_time_after := r_season.current_game_time + 
        (r_season.tick_interval_seconds * r_season.time_scale_multiplier * INTERVAL '1 second');

    -- Generate/deactivate events
    PERFORM generate_game_events(v_game_time_after);
    PERFORM deactivate_expired_events(v_game_time_after);

    -- Process all players
    FOR r_user IN
        SELECT u.id, u.game_current_time
        FROM users u
        WHERE u.season_id = r_season.id
          AND u.actor_type = 'REAL'
          AND u.operational_status != 'Bankrupt'
    LOOP
        SELECT *
        INTO r_player_result
        FROM process_player_simulation_to_time(r_user.id, v_game_time_after)
        LIMIT 1;
        IF COALESCE(r_player_result.elapsed_days, 0.0) > 0.0 THEN
            v_players_processed := v_players_processed + 1;
        END IF;
    END LOOP;

    -- Process all bots
    v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);

    -- Record rank snapshot once per game day
    IF date_trunc('day', r_season.current_game_time)::DATE <>
       date_trunc('day', v_game_time_after)::DATE THEN
        PERFORM record_rank_snapshot(date_trunc('day', v_game_time_after)::DATE);
    END IF;

    -- Update season clock
    UPDATE season_clock SET
        current_game_time = v_game_time_after,
        last_tick_at = NOW(),
        updated_at = NOW()
    WHERE id = r_season.id;

    -- Log the tick
    INSERT INTO world_tick_log (
        season_id, started_at, finished_at,
        game_time_before, game_time_after,
        ticks_processed, players_processed, bots_processed,
        status
    ) VALUES (
        r_season.id, NOW(), NOW(),
        r_season.current_game_time, v_game_time_after,
        1, v_players_processed, v_bots_processed,
        'success'
    );

    -- Release advisory lock
    PERFORM pg_advisory_unlock(v_lock_key);

    -- Return results
    season_id := r_season.id;
    ticks_processed := 1;
    game_time_after := v_game_time_after;
    players_processed := v_players_processed;
    bots_processed := v_bots_processed;
    RETURN NEXT;
END;
$fn$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;
