-- ============================================================================
-- Migration 17: Align bot decision cadence with humanization cooldowns
-- Goal:
--   ensure execute_bot_decisions() runs every world tick so the hourly
--   cooldowns introduced in migration 16 actually take effect in gameplay.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_world_tick(
    p_season_id uuid DEFAULT NULL::uuid,
    p_max_ticks integer DEFAULT 10
)
RETURNS TABLE(
    season_id uuid,
    ticks_processed integer,
    game_time_after timestamp with time zone,
    players_processed integer,
    bots_processed integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    r_season RECORD;
    v_game_time_before TIMESTAMPTZ;
    v_game_time_after TIMESTAMPTZ;
    v_ticks_processed INT := 0;
    v_players_processed INT := 0;
    v_bots_processed INT := 0;
    r_user RECORD;
    r_player_result RECORD;
    v_lock_key BIGINT;
    v_error_msg TEXT;
    v_start_time TIMESTAMPTZ;
BEGIN
    v_start_time := NOW();

    IF p_season_id IS NOT NULL THEN
        SELECT * INTO r_season FROM season_clock WHERE id = p_season_id;
    ELSE
        SELECT * INTO r_season FROM season_clock WHERE status = 'active' LIMIT 1;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active season found';
    END IF;

    v_lock_key := hashtext(r_season.id::text);
    IF NOT pg_try_advisory_xact_lock(v_lock_key) THEN
        RAISE EXCEPTION 'World tick already in progress for season %', r_season.id;
    END IF;

    v_game_time_before := r_season.current_game_time;
    v_game_time_after := r_season.current_game_time
        + (r_season.tick_interval_seconds * r_season.time_scale_multiplier * INTERVAL '1 second');

    PERFORM generate_game_events(v_game_time_after);
    PERFORM deactivate_expired_events(v_game_time_after);

    FOR r_user IN
        SELECT u.id, u.game_current_time
        FROM users u
        WHERE u.season_id = r_season.id
          AND u.actor_type = 'REAL'
          AND COALESCE(u.operational_status, 'Active') != 'Bankrupt'
    LOOP
        BEGIN
            SELECT * INTO r_player_result
            FROM process_player_simulation_to_time(r_user.id, v_game_time_after)
            LIMIT 1;

            IF COALESCE(r_player_result.elapsed_days, 0.0) > 0.0 THEN
                v_players_processed := v_players_processed + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_error_msg = MESSAGE_TEXT;
            INSERT INTO world_tick_log (season_id, status, message, started_at, finished_at)
            VALUES (
                r_season.id,
                'player_error',
                'Player ' || r_user.id || ': ' || v_error_msg,
                NOW(),
                NOW()
            );
        END;
    END LOOP;

    v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);

    -- Humanized bot behavior uses sub-day cooldowns, so decisions must be tick-based.
    PERFORM execute_bot_decisions();

    UPDATE season_clock
    SET current_game_time = v_game_time_after,
        last_tick_at = NOW(),
        updated_at = NOW()
    WHERE id = r_season.id;

    v_ticks_processed := 1;

    INSERT INTO world_tick_log (
        season_id,
        started_at,
        finished_at,
        game_time_before,
        game_time_after,
        ticks_processed,
        players_processed,
        bots_processed,
        status,
        message
    ) VALUES (
        r_season.id,
        v_start_time,
        NOW(),
        v_game_time_before,
        v_game_time_after,
        1,
        v_players_processed,
        v_bots_processed,
        'success',
        'Tick completed successfully'
    );

    season_id := r_season.id;
    ticks_processed := v_ticks_processed;
    game_time_after := v_game_time_after;
    players_processed := v_players_processed;
    bots_processed := v_bots_processed;
    RETURN NEXT;
END;
$function$;
