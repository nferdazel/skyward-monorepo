-- Fix: execute_bot_decisions still calls dropped calculate_bot_credit_score
-- Replace with calculate_credit_score (consolidated in migration 106)

DO $do$
DECLARE
    v_def TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc WHERE proname = 'execute_bot_decisions';
    
    v_def := REPLACE(v_def, 'calculate_bot_credit_score', 'calculate_credit_score');
    
    EXECUTE v_def;
END;
$do$;
