-- ============================================================================
-- SKYWARD RESET FIX: CLEAR SIMULATION BUFFERS AND LAST-ACTIVE TIMING
-- ============================================================================
-- Fixes a reset anomaly where stale buffered revenue / ops / lease values could
-- survive an airline reset and be flushed into the ledger on the next sim sync.
-- Also resets last_active_at to prevent a large post-reset catchup window.
-- ============================================================================

CREATE OR REPLACE FUNCTION reset_user_airline(p_user_id UUID)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_starting_cash NUMERIC;
BEGIN
    SELECT starting_cash INTO v_starting_cash FROM global_game_settings LIMIT 1;
    v_starting_cash := COALESCE(v_starting_cash, 15000000.00);

    DELETE FROM user_fleet WHERE user_id = p_user_id;
    DELETE FROM user_routes WHERE user_id = p_user_id;
    DELETE FROM financial_ledger WHERE user_id = p_user_id;

    UPDATE users
    SET cash = v_starting_cash,
        net_worth = v_starting_cash,
        game_current_time = '2020-01-01 00:00:00+00'::TIMESTAMP WITH TIME ZONE,
        last_active_at = NOW(),
        hq_airport_iata = NULL,
        auto_grounding_threshold = 40.00,
        buffered_revenue = 0.00,
        buffered_ops_cost = 0.00,
        buffered_lease_cost = 0.00
    WHERE id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Airline profile reset successfully!'::VARCHAR;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT FALSE, SQLERRM::VARCHAR;
END;
$$ LANGUAGE plpgsql;
