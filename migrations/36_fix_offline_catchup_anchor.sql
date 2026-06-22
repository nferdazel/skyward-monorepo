-- ============================================================================
-- SKYWARD OFFLINE CATCH-UP ANCHOR FIX
-- ============================================================================
-- Preserves the full offline gap by preventing auth/session validation RPCs
-- from mutating users.last_active_at before process_simulation_delta() runs.
-- The authoritative catch-up anchor must be advanced only by simulation sync,
-- reset flows, or other intentional simulation-state mutations.
-- ============================================================================

DROP FUNCTION IF EXISTS login_company(VARCHAR, VARCHAR) CASCADE;

CREATE OR REPLACE FUNCTION login_company(
    p_username VARCHAR,
    p_password VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    session_token VARCHAR,
    user_id UUID,
    user_username VARCHAR,
    company_name VARCHAR,
    ceo_name VARCHAR,
    cash NUMERIC,
    game_current_time TIMESTAMP WITH TIME ZONE,
    hq_airport_iata VARCHAR,
    auto_grounding_threshold NUMERIC,
    operational_status VARCHAR,
    consecutive_negative_days INT,
    recovery_streak_days INT
) AS $$
DECLARE
    r_user RECORD;
    v_token VARCHAR;
    v_expires TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT * INTO r_user FROM users WHERE username = LOWER(TRIM(p_username));

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE,
            'Invalid username or password.'::VARCHAR,
            NULL::VARCHAR,
            NULL::UUID,
            NULL::VARCHAR,
            NULL::VARCHAR,
            NULL::VARCHAR,
            0.00::NUMERIC,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::VARCHAR,
            30.00::NUMERIC,
            'Active'::VARCHAR,
            0,
            0;
        RETURN;
    END IF;

    IF r_user.password_hash != crypt(p_password, r_user.password_hash) THEN
        RETURN QUERY SELECT
            FALSE,
            'Invalid username or password.'::VARCHAR,
            NULL::VARCHAR,
            NULL::UUID,
            NULL::VARCHAR,
            NULL::VARCHAR,
            NULL::VARCHAR,
            0.00::NUMERIC,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::VARCHAR,
            30.00::NUMERIC,
            'Active'::VARCHAR,
            0,
            0;
        RETURN;
    END IF;

    v_token := encode(digest(gen_random_uuid()::text, 'sha256'), 'hex');
    v_expires := NOW() + INTERVAL '30 days';

    INSERT INTO sessions (user_id, token, expires_at)
    VALUES (r_user.id, v_token, v_expires);

    RETURN QUERY SELECT
        TRUE,
        'Login successful!'::VARCHAR,
        v_token,
        r_user.id,
        r_user.username,
        r_user.company_name,
        r_user.ceo_name,
        r_user.cash,
        r_user.game_current_time,
        r_user.hq_airport_iata,
        COALESCE(r_user.auto_grounding_threshold, 30.00),
        COALESCE(r_user.operational_status, 'Active'),
        COALESCE(r_user.consecutive_negative_days, 0),
        COALESCE(r_user.recovery_streak_days, 0);
END;
$$ LANGUAGE plpgsql;


DROP FUNCTION IF EXISTS validate_session(VARCHAR) CASCADE;

CREATE OR REPLACE FUNCTION validate_session(
    p_token VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    user_id UUID,
    user_username VARCHAR,
    company_name VARCHAR,
    ceo_name VARCHAR,
    cash NUMERIC,
    game_current_time TIMESTAMP WITH TIME ZONE,
    hq_airport_iata VARCHAR,
    auto_grounding_threshold NUMERIC,
    operational_status VARCHAR,
    consecutive_negative_days INT,
    recovery_streak_days INT
) AS $$
DECLARE
    r_session RECORD;
    r_user RECORD;
BEGIN
    SELECT * INTO r_session FROM sessions WHERE token = p_token AND expires_at > NOW();

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE,
            NULL::UUID,
            NULL::VARCHAR,
            NULL::VARCHAR,
            NULL::VARCHAR,
            0.00::NUMERIC,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::VARCHAR,
            30.00::NUMERIC,
            'Active'::VARCHAR,
            0,
            0;
        RETURN;
    END IF;

    SELECT * INTO r_user FROM users WHERE id = r_session.user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE,
            NULL::UUID,
            NULL::VARCHAR,
            NULL::VARCHAR,
            NULL::VARCHAR,
            0.00::NUMERIC,
            NULL::TIMESTAMP WITH TIME ZONE,
            NULL::VARCHAR,
            30.00::NUMERIC,
            'Active'::VARCHAR,
            0,
            0;
        RETURN;
    END IF;

    RETURN QUERY SELECT
        TRUE,
        r_user.id,
        r_user.username,
        r_user.company_name,
        r_user.ceo_name,
        r_user.cash,
        r_user.game_current_time,
        r_user.hq_airport_iata,
        COALESCE(r_user.auto_grounding_threshold, 30.00),
        COALESCE(r_user.operational_status, 'Active'),
        COALESCE(r_user.consecutive_negative_days, 0),
        COALESCE(r_user.recovery_streak_days, 0);
END;
$$ LANGUAGE plpgsql;
