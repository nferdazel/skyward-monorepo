-- ============================================================================
-- SKYWARD AIRLINE RESET RPC FUNCTION
-- ============================================================================
-- This function atomically purges a user's active/leased fleet, active route network,
-- ledger transaction history, and resets their starting cash, time, and HQ hub.
-- Starting cash is fetched dynamically from the global_game_settings table.
-- ============================================================================

CREATE OR REPLACE FUNCTION reset_user_airline(p_user_id UUID)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_starting_cash NUMERIC;
BEGIN
    -- 1. Fetch starting cash dynamically from global settings table
    SELECT starting_cash INTO v_starting_cash FROM global_game_settings LIMIT 1;
    v_starting_cash := COALESCE(v_starting_cash, 15000000.00);

    -- 2. Wipe all active owned and leased fleet records
    DELETE FROM user_fleet WHERE user_id = p_user_id;

    -- 3. Wipe all active routes
    DELETE FROM user_routes WHERE user_id = p_user_id;

    -- 4. Wipe all financial ledger transaction history
    DELETE FROM financial_ledger WHERE user_id = p_user_id;

    -- 5. Reset user cash balance, net worth, operational time, and HQ hub dynamically
    UPDATE users 
    SET cash = v_starting_cash,
        net_worth = v_starting_cash,
        game_current_time = '2020-01-01 00:00:00+00'::TIMESTAMP WITH TIME ZONE,
        hq_airport_iata = NULL,
        auto_grounding_threshold = 40.00
    WHERE id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Airline profile reset successfully!'::VARCHAR;
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT FALSE, SQLERRM::VARCHAR;
END;
$$ LANGUAGE plpgsql;
