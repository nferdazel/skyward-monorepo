-- =============================================================================
-- SKYWARD SYSTEM UPDATE: FLEET TAIL NUMBER CONSTRAINT FIX (v3.1)
-- Fixes code 23502 (null value in column "tail_number" violates not-null constraint)
-- =============================================================================

-- 1. DROP OLD FUNCTIONS (CASCADE TO AVOID COLLISION)
DROP FUNCTION IF EXISTS purchase_aircraft(UUID, UUID, VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS lease_aircraft(UUID, UUID, VARCHAR) CASCADE;

-- 2. RECREATE FLEET PURCHASE FUNCTION WITH TAIL NUMBER POPULATION
CREATE OR REPLACE FUNCTION purchase_aircraft(
    p_user_id UUID,
    p_model_id UUID,
    p_nickname VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_cash NUMERIC;
    v_price NUMERIC;
    v_model_name VARCHAR;
    v_hq_iata VARCHAR(3);
    v_tail VARCHAR(20);
BEGIN
    -- Fetch user's current cash balance and HQ airport
    SELECT cash, hq_airport_iata INTO v_cash, v_hq_iata FROM users WHERE id = p_user_id;
    v_hq_iata := COALESCE(v_hq_iata, 'CGK');
    
    -- Fetch target aircraft model price and identifier
    SELECT purchase_price, model_name INTO v_price, v_model_name FROM aircraft_models WHERE id = p_model_id;
    
    -- Verify liquidity
    IF v_cash < v_price THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds to purchase ' || v_model_name || '.')::VARCHAR, v_cash;
        RETURN;
    END IF;
    
    -- Generate unique tail number
    LOOP
        v_tail := generate_tail_number(v_hq_iata);
        EXIT WHEN NOT EXISTS (SELECT 1 FROM user_fleet WHERE tail_number = v_tail);
    END LOOP;

    -- Deduct cash balance atomically
    UPDATE users 
    SET cash = cash - v_price 
    WHERE id = p_user_id 
    RETURNING cash INTO v_cash;
    
    -- Add aircraft to user fleet with generated tail number
    INSERT INTO user_fleet (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number)
    VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'purchase', 100.00, 'active', v_tail);
    
    -- Log transaction to the ledger
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        p_user_id,
        'expense',
        'aircraft_purchase',
        v_price,
        'Purchased aircraft ' || v_model_name || ' with Call Sign: ' || TRIM(p_nickname) || ' (Tail: ' || v_tail || ')',
        (SELECT game_current_time FROM users WHERE id = p_user_id)
    );
    
    RETURN QUERY SELECT TRUE, ('Successfully purchased ' || v_model_name || '!')::VARCHAR, v_cash;
END;
$$ LANGUAGE plpgsql;

-- 3. RECREATE FLEET LEASE FUNCTION WITH TAIL NUMBER POPULATION
CREATE OR REPLACE FUNCTION lease_aircraft(
    p_user_id UUID,
    p_model_id UUID,
    p_nickname VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_cash NUMERIC;
    v_lease_price NUMERIC;
    v_model_name VARCHAR;
    v_hq_iata VARCHAR(3);
    v_tail VARCHAR(20);
BEGIN
    -- Fetch user's current cash balance and HQ airport
    SELECT cash, hq_airport_iata INTO v_cash, v_hq_iata FROM users WHERE id = p_user_id;
    v_hq_iata := COALESCE(v_hq_iata, 'CGK');
    
    -- Fetch target aircraft model lease price and identifier
    SELECT lease_price_per_month, model_name INTO v_lease_price, v_model_name FROM aircraft_models WHERE id = p_model_id;
    
    -- Charge first month's lease up front as down payment
    IF v_cash < v_lease_price THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds for lease down payment of ' || v_model_name || '.')::VARCHAR, v_cash;
        RETURN;
    END IF;
    
    -- Generate unique tail number
    LOOP
        v_tail := generate_tail_number(v_hq_iata);
        EXIT WHEN NOT EXISTS (SELECT 1 FROM user_fleet WHERE tail_number = v_tail);
    END LOOP;

    -- Deduct initial lease cash balance atomically
    UPDATE users 
    SET cash = cash - v_lease_price 
    WHERE id = p_user_id 
    RETURNING cash INTO v_cash;
    
    -- Add leased aircraft to user fleet with generated tail number
    INSERT INTO user_fleet (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number)
    VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'lease', 100.00, 'active', v_tail);
    
    -- Log transaction to ledger
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
    VALUES (
        p_user_id,
        'expense',
        'aircraft_lease',
        v_lease_price,
        'Leased aircraft ' || v_model_name || ' with Call Sign: ' || TRIM(p_nickname) || ' - Initial month deposit (Tail: ' || v_tail || ')',
        (SELECT game_current_time FROM users WHERE id = p_user_id)
    );
    
    RETURN QUERY SELECT TRUE, ('Successfully leased ' || v_model_name || '!')::VARCHAR, v_cash;
END;
$$ LANGUAGE plpgsql;
