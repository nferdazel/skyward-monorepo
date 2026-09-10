-- Migration 04: Wave 1 game-review fixes
-- Source: docs/reviews/game-design-review-2026-09.md, docs/reviews/aviation-realism-review-2026-09.md
-- Items: GAME-05 (lease repair economics), AVIATION-26 (GRU name), AVIATION-27 (UAE demand)
--
-- NOTE: the Go engine (apps/api/internal/engine) is authoritative at runtime.
-- This migration keeps the DB-side legacy RPC + reference data consistent so
-- bots/legacy callers and fresh DB restores behave identically.

-- ============================================================================
-- 1. GAME-05 — Lease repair priced off aircraft value, not monthly lease rent
-- ============================================================================
-- Old: `(100 - condition) * lease_price * 0.50` made a full repair of an
-- ATR 42-500 cost $2.45M (~10x the monthly lease), turning leasing into a trap.
-- New: value-based, identical to the owned formula. Leased aircraft already
-- carry higher wear (leased_wear_per_flight_cycle), which is the intended
-- differentiator. The Go path (fleet.go Repair) was fixed in the same commit.
CREATE OR REPLACE FUNCTION "public"."perform_actor_aircraft_repair"(
    "p_user_id" "uuid",
    "p_fleet_id" "uuid",
    "p_min_cash_reserve" numeric DEFAULT 0,
    "p_game_time" timestamp with time zone DEFAULT NULL::timestamp with time zone,
    "p_description" "text" DEFAULT NULL::"text"
) RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric, "repair_cost" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
    v_cash NUMERIC;
    v_condition NUMERIC;
    v_purchase_price NUMERIC;
    v_model_name VARCHAR;
    v_repair_cost NUMERIC;
    v_effective_game_time TIMESTAMPTZ;
    v_required_cash NUMERIC;
    v_description TEXT;
BEGIN
    SELECT game_current_time
      INTO v_effective_game_time
      FROM users
     WHERE id = p_user_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0::NUMERIC, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT f.condition, m.purchase_price, m.model_name
      INTO v_condition, v_purchase_price, v_model_name
      FROM fleet_aircraft f
      JOIN aircraft_models m
        ON m.id = f.aircraft_model_id
     WHERE f.id = p_fleet_id
       AND f.user_id = p_user_id;

    v_cash := get_user_balance(p_user_id);

    IF p_game_time IS NOT NULL THEN
        v_effective_game_time := p_game_time;
    END IF;

    IF v_model_name IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, v_cash, 0::NUMERIC;
        RETURN;
    END IF;

    IF v_condition >= 100.00 THEN
        RETURN QUERY
        SELECT FALSE,
               ('Aircraft ' || v_model_name || ' is already in pristine condition.')::VARCHAR,
               v_cash,
               0::NUMERIC;
        RETURN;
    END IF;

    -- Value-based repair cost for both owned and leased aircraft.
    v_repair_cost := (100.00 - v_condition) * (COALESCE(v_purchase_price, 0.00) * 0.0005);

    v_required_cash := v_repair_cost + GREATEST(COALESCE(p_min_cash_reserve, 0), 0);

    IF v_cash < v_required_cash THEN
        RETURN QUERY
        SELECT FALSE,
               ('Insufficient funds for repair. Required: $' || ROUND(v_required_cash, 2))::VARCHAR,
               v_cash,
               v_repair_cost;
        RETURN;
    END IF;

    v_description := COALESCE(
        p_description,
        'Maintenance completed for ' || v_model_name ||
        ' - restored from ' || ROUND(v_condition, 2) || '% to 100%'
    );

    PERFORM public.debit_bank_account(p_user_id, v_repair_cost, 'cogs', 'maintenance', v_description, v_effective_game_time);

    UPDATE public.fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = p_fleet_id;

    v_cash := public.get_user_balance(p_user_id);

    RETURN QUERY SELECT TRUE, 'Aircraft maintenance complete. Health restored to 100%!'::VARCHAR, v_cash, v_repair_cost;
END;
$_$;

ALTER FUNCTION "public"."perform_actor_aircraft_repair"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_min_cash_reserve" numeric, "p_game_time" timestamp with time zone, "p_description" "text") OWNER TO "postgres";

-- ============================================================================
-- 2. AVIATION-26 — Correct GRU airport name
-- ============================================================================
-- "Sander International Airport" is a data error; the real name is
-- São Paulo/Guarulhos International Airport.
UPDATE public.airports
   SET name = 'São Paulo/Guarulhos International Airport'
 WHERE iata = 'GRU'
   AND name = 'Sander International Airport';

-- ============================================================================
-- 3. AVIATION-27 — Recalibrate UAE secondary airport demand
-- ============================================================================
-- FJR/AAN/RKT/SHJ/DWC were all at 88 — equal to Frankfurt/San Francisco.
-- Tier them against real traffic (Sharjah ~15M pax vs Dubai ~87M).
UPDATE public.airports SET demand_index = 65 WHERE iata = 'SHJ';
UPDATE public.airports SET demand_index = 60 WHERE iata = 'DWC';
UPDATE public.airports SET demand_index = 45 WHERE iata = 'RKT';
UPDATE public.airports SET demand_index = 40 WHERE iata = 'AAN';
UPDATE public.airports SET demand_index = 35 WHERE iata = 'FJR';
