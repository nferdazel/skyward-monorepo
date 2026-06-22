-- ============================================================================
-- SKYWARD PHASE 9 DETERMINISTIC DAILY SIMULATION
-- ============================================================================
-- Keeps the current economy formulas intact, but runs them through day-bounded
-- segments. Multi-day catch-up now flushes ledger rows and operational streaks
-- once per crossed game day instead of aggregating the whole window into one
-- final-day update.
-- ============================================================================

ALTER FUNCTION process_player_simulation_to_time(UUID, TIMESTAMP WITH TIME ZONE)
RENAME TO process_player_simulation_segment;

ALTER FUNCTION process_all_bots_simulation_to_time(TIMESTAMP WITH TIME ZONE, UUID)
RENAME TO process_all_bots_simulation_segment;


CREATE OR REPLACE FUNCTION process_player_simulation_to_time(
    p_user_id UUID,
    p_target_game_time TIMESTAMP WITH TIME ZONE
)
RETURNS TABLE (
    cash_before NUMERIC(20,2),
    cash_after NUMERIC(20,2),
    elapsed_real_sec DOUBLE PRECISION,
    elapsed_game_days DOUBLE PRECISION,
    flights_run INT
) AS $$
DECLARE
    r_user RECORD;
    r_segment RECORD;
    v_cursor TIMESTAMP WITH TIME ZONE;
    v_next_target TIMESTAMP WITH TIME ZONE;
    v_initial_cash NUMERIC(20,2);
    v_final_cash NUMERIC(20,2);
    v_elapsed_game_days DOUBLE PRECISION := 0.0;
    v_flights_run INT := 0;
BEGIN
    SELECT *
    INTO r_user
    FROM users
    WHERE id = p_user_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF p_target_game_time <= r_user.game_current_time THEN
        cash_before := r_user.cash;
        cash_after := r_user.cash;
        elapsed_real_sec := 0.0;
        elapsed_game_days := 0.0;
        flights_run := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    v_cursor := r_user.game_current_time;
    v_initial_cash := r_user.cash;
    v_final_cash := r_user.cash;

    WHILE v_cursor < p_target_game_time LOOP
        v_next_target := LEAST(
            date_trunc('day', v_cursor) + INTERVAL '1 day',
            p_target_game_time
        );

        IF v_next_target <= v_cursor THEN
            v_next_target := p_target_game_time;
        END IF;

        SELECT *
        INTO r_segment
        FROM process_player_simulation_segment(p_user_id, v_next_target)
        LIMIT 1;

        IF FOUND THEN
            v_final_cash := COALESCE(r_segment.cash_after, v_final_cash);
            v_elapsed_game_days := v_elapsed_game_days + COALESCE(r_segment.elapsed_game_days, 0.0);
            v_flights_run := v_flights_run + COALESCE(r_segment.flights_run, 0);
        END IF;

        v_cursor := v_next_target;
    END LOOP;

    cash_before := v_initial_cash;
    cash_after := v_final_cash;
    elapsed_real_sec := 0.0;
    elapsed_game_days := v_elapsed_game_days;
    flights_run := v_flights_run;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION process_all_bots_simulation_to_time(
    p_target_game_time TIMESTAMP WITH TIME ZONE,
    p_season_id UUID DEFAULT NULL
)
RETURNS INT AS $$
DECLARE
    v_cursor TIMESTAMP WITH TIME ZONE;
    v_next_target TIMESTAMP WITH TIME ZONE;
    v_segment_processed INT := 0;
    v_total_processed INT := 0;
BEGIN
    SELECT MIN(ai.game_current_time)
    INTO v_cursor
    FROM ai_competitors ai
    WHERE ai.status != 'Bankrupt'
      AND ai.game_current_time < p_target_game_time
      AND (p_season_id IS NULL OR ai.season_id = p_season_id);

    IF v_cursor IS NULL THEN
        RETURN 0;
    END IF;

    WHILE v_cursor < p_target_game_time LOOP
        v_next_target := LEAST(
            date_trunc('day', v_cursor) + INTERVAL '1 day',
            p_target_game_time
        );

        IF v_next_target <= v_cursor THEN
            v_next_target := p_target_game_time;
        END IF;

        v_segment_processed := process_all_bots_simulation_segment(v_next_target, p_season_id);
        v_total_processed := GREATEST(v_total_processed, v_segment_processed);
        v_cursor := v_next_target;
    END LOOP;

    RETURN v_total_processed;
END;
$$ LANGUAGE plpgsql;


COMMENT ON FUNCTION process_player_simulation_segment(UUID, TIMESTAMP WITH TIME ZONE) IS
'Phase 9 internal aggregate player simulation segment. Use process_player_simulation_to_time for day-bounded simulation.';

COMMENT ON FUNCTION process_player_simulation_to_time(UUID, TIMESTAMP WITH TIME ZONE) IS
'Processes one player to target game time through deterministic day-bounded segments.';

COMMENT ON FUNCTION process_all_bots_simulation_segment(TIMESTAMP WITH TIME ZONE, UUID) IS
'Phase 9 internal aggregate bot simulation segment. Use process_all_bots_simulation_to_time for day-bounded simulation.';

COMMENT ON FUNCTION process_all_bots_simulation_to_time(TIMESTAMP WITH TIME ZONE, UUID) IS
'Processes active bots to target game time through deterministic day-bounded segments.';
