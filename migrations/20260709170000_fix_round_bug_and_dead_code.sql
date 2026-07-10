-- ============================================================================
-- Migration 38: Fix round() bug + dead code cleanup
-- Goal:
--   1. Fix round(double precision, integer) error in get_route_performance()
--      caused by type propagation from distance_km (double precision)
--   2. Drop confirmed dead functions
-- ============================================================================

BEGIN;

-- ============================================================================
-- FIX 1: round() type bug in get_route_performance()
-- ============================================================================
-- distance_km is double precision, which propagates through cost calculations.
-- PostgreSQL has round(numeric, int) but not round(double precision, int).
-- Fix: cast to ::numeric before rounding.

CREATE OR REPLACE FUNCTION public.get_route_performance(p_user_id uuid)
RETURNS TABLE(
    route_id            uuid,
    origin_iata         varchar,
    destination_iata    varchar,
    distance_km         double precision,
    ticket_price        numeric,
    flights_per_week    int,
    assigned_aircraft   varchar,
    effective_capacity  int,
    expected_passengers int,
    load_factor         numeric,
    revenue_per_flight  numeric,
    cost_per_flight     numeric,
    profit_per_flight   numeric,
    weekly_profit       numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_fuel_price_per_liter NUMERIC;
    v_crew_cost_per_hour NUMERIC;
    v_cargo_revenue_pct NUMERIC;
    v_ticket_base_fare NUMERIC;
    v_ticket_per_km_rate NUMERIC;
    v_fuel_price_multiplier NUMERIC := 1.0;
    v_maintenance_multiplier NUMERIC := 1.0;
BEGIN
    -- Load config
    v_fuel_price_per_liter := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_crew_cost_per_hour := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_cargo_revenue_pct := COALESCE(get_config_numeric('cargo_revenue_percentage'), 0.05);
    v_ticket_base_fare := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
    v_ticket_per_km_rate := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);

    -- Check for active fuel/maintenance events
    SELECT COALESCE(MAX(effect_value), 1.0) INTO v_fuel_price_multiplier
    FROM game_events
    WHERE event_type = 'fuel_shock' AND effect_type = 'fuel_price' AND is_active = true;

    SELECT COALESCE(MAX(effect_value), 1.0) INTO v_maintenance_multiplier
    FROM game_events
    WHERE event_type = 'maintenance_shock' AND effect_type = 'maintenance_cost' AND is_active = true;

    RETURN QUERY
    WITH route_data AS (
        SELECT
            r.id AS r_id,
            r.origin_iata AS r_origin,
            r.destination_iata AS r_dest,
            r.distance_km AS r_distance,
            r.ticket_price AS r_price,
            r.flights_per_week AS r_flights,
            r.assigned_aircraft_id AS r_aircraft_id,
            f.economy_seats,
            f.business_seats,
            f.first_class_seats,
            m.model_name,
            m.capacity AS model_capacity,
            m.speed_kmh,
            m.fuel_burn_per_km,
            m.maintenance_cost_per_hour,
            m.turnaround_hours,
            o.demand_index AS origin_demand,
            d.demand_index AS dest_demand
        FROM route_assignments r
        LEFT JOIN fleet_aircraft f ON f.id = r.assigned_aircraft_id
        LEFT JOIN aircraft_models m ON m.id = f.aircraft_model_id
        LEFT JOIN airports o ON o.iata = r.origin_iata
        LEFT JOIN airports d ON d.iata = r.destination_iata
        WHERE r.user_id = p_user_id
          AND r.status = 'active'
    ),
    computed AS (
        SELECT
            rd.*,
            -- Effective capacity
            GREATEST(0, COALESCE(
                NULLIF(COALESCE(rd.economy_seats, 0) + COALESCE(rd.business_seats, 0) + COALESCE(rd.first_class_seats, 0), 0),
                COALESCE(rd.model_capacity, 0)
            ))::INT AS eff_capacity,
            -- Expected passengers (8-param version)
            calculate_route_expected_passengers(
                GREATEST(0, COALESCE(
                    NULLIF(COALESCE(rd.economy_seats, 0) + COALESCE(rd.business_seats, 0) + COALESCE(rd.first_class_seats, 0), 0),
                    COALESCE(rd.model_capacity, 0)
                ))::INT,
                rd.r_distance,
                rd.r_price,
                rd.origin_demand,
                rd.dest_demand,
                rd.r_origin,
                rd.r_dest,
                p_user_id
            ) AS exp_passengers,
            -- Fuel cost per flight (cast to numeric to avoid double precision propagation)
            (rd.r_distance * COALESCE(rd.fuel_burn_per_km, 0.03) * v_fuel_price_per_liter * v_fuel_price_multiplier)::NUMERIC AS fuel_cost,
            -- Crew cost per flight
            (((rd.r_distance / GREATEST(rd.speed_kmh, 1)) + COALESCE(rd.turnaround_hours, 1.0)) * v_crew_cost_per_hour)::NUMERIC AS crew_cost,
            -- Maintenance cost per flight
            ((rd.r_distance / GREATEST(rd.speed_kmh, 1)) * COALESCE(rd.maintenance_cost_per_hour, 500.0) * v_maintenance_multiplier)::NUMERIC AS maint_cost
        FROM route_data rd
    )
    SELECT
        c.r_id,
        c.r_origin::varchar,
        c.r_dest::varchar,
        c.r_distance,
        c.r_price,
        c.r_flights,
        COALESCE(c.model_name, 'Unassigned')::varchar,
        c.eff_capacity,
        c.exp_passengers,
        -- Load factor
        CASE WHEN c.eff_capacity > 0
            THEN ROUND(c.exp_passengers::numeric / c.eff_capacity, 2)
            ELSE 0
        END,
        -- Revenue per flight (ticket + cargo)
        ROUND(c.exp_passengers * c.r_price * (1 + v_cargo_revenue_pct), 2),
        -- Cost per flight (fuel + crew + maintenance) — now numeric, safe for ROUND
        ROUND(c.fuel_cost + c.crew_cost + c.maint_cost, 2),
        -- Profit per flight
        ROUND((c.exp_passengers * c.r_price * (1 + v_cargo_revenue_pct)) - (c.fuel_cost + c.crew_cost + c.maint_cost), 2),
        -- Weekly profit
        ROUND(c.r_flights * ((c.exp_passengers * c.r_price * (1 + v_cargo_revenue_pct)) - (c.fuel_cost + c.crew_cost + c.maint_cost)), 2)
    FROM computed c;
END;
$function$;

-- ============================================================================
-- FIX 2: Drop confirmed dead functions
-- ============================================================================

-- compact_world_tick_log: replaced by prune_world_tick_log, cron caller fails
DROP FUNCTION IF EXISTS public.compact_world_tick_log(boolean);

-- get_world_tick_log_compaction_report: zero callers anywhere
DROP FUNCTION IF EXISTS public.get_world_tick_log_compaction_report();

-- get_config_text: zero callers, all config reads use get_config_int/numeric/jsonb
DROP FUNCTION IF EXISTS public.get_config_text(text);

-- calculate_effective_passenger_capacity: zero callers, inline calculations used instead
DROP FUNCTION IF EXISTS public.calculate_effective_passenger_capacity(integer, integer, integer, integer);

COMMIT;
