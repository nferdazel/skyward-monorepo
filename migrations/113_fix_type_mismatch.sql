-- Fix: process_all_bots_simulation_to_time type mismatch
-- v_turnaround_hours DOUBLE PRECISION → NUMERIC to match calculate_route_max_weekly_flights signature

DO $do$
DECLARE
    v_def TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc WHERE proname = 'process_all_bots_simulation_to_time';
    
    -- Replace DOUBLE PRECISION with NUMERIC for v_turnaround_hours
    v_def := REPLACE(v_def, 
        'v_turnaround_hours DOUBLE PRECISION', 
        'v_turnaround_hours NUMERIC');
    
    -- Execute the modified function definition
    EXECUTE v_def;
END;
$do$;
