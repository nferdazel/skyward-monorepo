-- ============================================================================
-- Migration: Fix game_events generation bugs (3-in-1 pass)
-- Bug 1: 'weather' → 'weather_disruption' (type mismatch with consumers)
-- Bug 2: Remove 'regulatory'/'airport_tax' branch (never consumed)
-- Bug 3: Add 'maintenance_shock' branch (consumed but never generated)
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.generate_game_events(p_game_time timestamp with time zone)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_roll NUMERIC;
    v_airport_iata VARCHAR(3);
    v_effect_value NUMERIC;
    v_title TEXT;
    v_description TEXT;
    v_event_type VARCHAR(50);
    v_effect_type VARCHAR(50);
    v_effect_target TEXT;
BEGIN
    -- 5% chance per tick to generate an event
    v_roll := random();
    IF v_roll > 0.05 THEN RETURN; END IF;

    -- Pick random event type
    CASE floor(random() * 4)
    WHEN 0 THEN -- Fuel price shock (global)
        v_event_type   := 'fuel_shock';
        v_effect_type  := 'fuel_price';
        v_effect_target := 'global';
        v_effect_value := 0.7 + (random() * 0.6); -- 0.7x to 1.3x multiplier
        IF v_effect_value > 1.0 THEN
            v_title := 'Fuel Price Surge';
            v_description := 'Global fuel prices have increased by ' || ROUND((v_effect_value - 1) * 100) || '%';
        ELSE
            v_title := 'Fuel Price Drop';
            v_description := 'Global fuel prices have decreased by ' || ROUND((1 - v_effect_value) * 100) || '%';
        END IF;
    WHEN 1 THEN -- Demand surge at random airport
        SELECT iata INTO v_airport_iata FROM airports ORDER BY random() LIMIT 1;
        IF v_airport_iata IS NULL THEN RETURN; END IF;
        v_event_type    := 'demand_surge';
        v_effect_type   := 'demand_index';
        v_effect_target := v_airport_iata;
        v_effect_value  := 1.2 + (random() * 0.3); -- 1.2x to 1.5x demand
        v_title := 'Demand Surge at ' || v_airport_iata;
        v_description := 'Increased passenger demand at ' || v_airport_iata || ' airport';
    WHEN 2 THEN -- Weather disruption at high-demand airport
        SELECT iata INTO v_airport_iata FROM airports WHERE demand_index > 70 ORDER BY random() LIMIT 1;
        IF v_airport_iata IS NULL THEN
            SELECT iata INTO v_airport_iata FROM airports ORDER BY random() LIMIT 1;
        END IF;
        IF v_airport_iata IS NULL THEN RETURN; END IF;
        v_event_type    := 'weather_disruption';
        v_effect_type   := 'demand_index';
        v_effect_target := v_airport_iata;
        v_effect_value  := 0.5;
        v_title := 'Weather Disruption at ' || v_airport_iata;
        v_description := 'Severe weather affecting operations at ' || v_airport_iata;
    WHEN 3 THEN -- Maintenance shock (global cost increase)
        v_event_type    := 'maintenance_shock';
        v_effect_type   := 'maintenance_cost';
        v_effect_target := 'global';
        v_effect_value  := 1.10 + (random() * 0.20); -- 10-30% cost increase
        v_title := 'Maintenance Cost Surge';
        v_description := 'Maintenance costs increased by ' || ROUND((v_effect_value - 1) * 100) || '% globally';
    END CASE;

    -- Check for existing active event of same type and target
    IF EXISTS (
        SELECT 1 FROM game_events
         WHERE event_type  = v_event_type
           AND is_active   = true
           AND effect_target = v_effect_target
           AND end_game_time > p_game_time
    ) THEN
        RETURN;
    END IF;

    INSERT INTO game_events (event_type, title, description, effect_type,
                             effect_target, effect_value, start_game_time, end_game_time)
    VALUES (v_event_type, v_title, v_description, v_effect_type,
            v_effect_target, v_effect_value, p_game_time,
            CASE v_event_type
                WHEN 'fuel_shock'         THEN p_game_time + INTERVAL '72 hours'
                WHEN 'demand_surge'       THEN p_game_time + INTERVAL '48 hours'
                WHEN 'weather_disruption' THEN p_game_time + INTERVAL '24 hours'
                WHEN 'maintenance_shock'  THEN p_game_time + INTERVAL '168 hours'
                ELSE p_game_time + INTERVAL '72 hours'
            END);
END;
$function$;

COMMIT;
