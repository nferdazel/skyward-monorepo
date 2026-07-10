-- Migration: Fix formula drift in get_route_performance()
-- Problem: get_route_performance() called calculate_route_expected_passengers() (8-param
-- version with competition/congestion/hub factors), while process_player_simulation_to_time()
-- uses a simpler inline formula with only airport_demand * demand_multiplier. The dashboard
-- showed different expected passengers than the simulation actually processed.
-- Fix: Align get_route_performance() with the simulation's inline formula.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_route_performance(p_user_id uuid)
RETURNS TABLE(
    route_id uuid,
    origin_iata character varying,
    destination_iata character varying,
    distance_km double precision,
    ticket_price numeric,
    flights_per_week integer,
    assigned_aircraft character varying,
    effective_capacity integer,
    expected_passengers integer,
    load_factor numeric,
    revenue_per_flight numeric,
    cost_per_flight numeric,
    profit_per_flight numeric,
    weekly_profit numeric
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
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
            -- Effective capacity (same as simulation)
            GREATEST(0, COALESCE(
                NULLIF(COALESCE(rd.economy_seats, 0) + COALESCE(rd.business_seats, 0) + COALESCE(rd.first_class_seats, 0), 0),
                COALESCE(rd.model_capacity, 0)
            ))::INT AS eff_capacity,
            -- Airport demand factor (matches simulation: calculate_airport_demand_factor)
            calculate_airport_demand_factor(rd.origin_demand, rd.dest_demand) AS v_airport_demand,
            -- Demand multiplier (matches simulation: calculate_route_demand_multiplier)
            calculate_route_demand_multiplier(rd.r_distance, rd.r_price) AS v_demand_multiplier,
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
        -- Expected passengers: match simulation inline formula exactly
        -- (process_player_simulation_to_time lines 163-181)
        LEAST(
            c.eff_capacity,
            FLOOR(c.eff_capacity * 0.95 * c.v_airport_demand * c.v_demand_multiplier)
        )::INT,
        -- Load factor
        CASE WHEN c.eff_capacity > 0
            THEN ROUND(LEAST(
                c.eff_capacity,
                FLOOR(c.eff_capacity * 0.95 * c.v_airport_demand * c.v_demand_multiplier)
            )::numeric / c.eff_capacity, 2)
            ELSE 0
        END,
        -- Revenue per flight (ticket + cargo)
        ROUND(LEAST(
            c.eff_capacity,
            FLOOR(c.eff_capacity * 0.95 * c.v_airport_demand * c.v_demand_multiplier)
        ) * c.r_price * (1 + v_cargo_revenue_pct), 2),
        -- Cost per flight (fuel + crew + maintenance) — now numeric, safe for ROUND
        ROUND(c.fuel_cost + c.crew_cost + c.maint_cost, 2),
        -- Profit per flight
        ROUND((LEAST(
            c.eff_capacity,
            FLOOR(c.eff_capacity * 0.95 * c.v_airport_demand * c.v_demand_multiplier)
        ) * c.r_price * (1 + v_cargo_revenue_pct)) - (c.fuel_cost + c.crew_cost + c.maint_cost), 2),
        -- Weekly profit
        ROUND(c.r_flights * ((LEAST(
            c.eff_capacity,
            FLOOR(c.eff_capacity * 0.95 * c.v_airport_demand * c.v_demand_multiplier)
        ) * c.r_price * (1 + v_cargo_revenue_pct)) - (c.fuel_cost + c.crew_cost + c.maint_cost)), 2)
    FROM computed c;
END;
$function$;

COMMIT;
