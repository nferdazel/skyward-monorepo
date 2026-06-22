-- ============================================================================
-- FIX OWNER OPTIMIZER OUTPUT COLUMN AMBIGUITY
-- ============================================================================
-- In PL/pgSQL, RETURNS TABLE column names become visible variables. The owner
-- optimizer reused names like economy_seats/business_seats/first_class_seats
-- internally, which caused ambiguous-column failures at runtime.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_owner_route_optimizer(
    p_user_id UUID,
    p_origin_iata VARCHAR DEFAULT NULL,
    p_destination_iata VARCHAR DEFAULT NULL,
    p_limit INT DEFAULT 25,
    p_include_assigned BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    aircraft_id UUID,
    tail_number VARCHAR,
    aircraft_model VARCHAR,
    acquisition_type VARCHAR,
    currently_assigned BOOLEAN,
    route_origin_iata VARCHAR,
    route_destination_iata VARCHAR,
    route_already_exists BOOLEAN,
    distance_km NUMERIC,
    ticket_price NUMERIC,
    weekly_flights INT,
    recommended_economy_seats INT,
    recommended_business_seats INT,
    recommended_first_class_seats INT,
    effective_passenger_capacity INT,
    expected_passengers_per_flight INT,
    load_factor NUMERIC,
    direct_cost_per_flight NUMERIC,
    revenue_per_flight NUMERIC,
    contribution_per_flight NUMERIC,
    weekly_contribution NUMERIC,
    maintenance_impact_per_week NUMERIC
) AS $$
DECLARE
    v_origin_iata VARCHAR(3);
    v_player_schema TEXT;
    v_player_relation TEXT;
BEGIN
    SELECT
        ns.nspname,
        cls.relname
    INTO v_player_schema, v_player_relation
    FROM pg_catalog.pg_class cls
    JOIN pg_catalog.pg_namespace ns
      ON ns.oid = cls.relnamespace
    JOIN pg_catalog.pg_attribute att_id
      ON att_id.attrelid = cls.oid
     AND att_id.attname = 'id'
     AND att_id.attnum > 0
     AND NOT att_id.attisdropped
    JOIN pg_catalog.pg_attribute att_hq
      ON att_hq.attrelid = cls.oid
     AND att_hq.attname = 'hq_airport_iata'
     AND att_hq.attnum > 0
     AND NOT att_hq.attisdropped
    WHERE cls.relkind IN ('r', 'p', 'v', 'm')
      AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
    ORDER BY
        CASE
            WHEN ns.nspname = 'public' AND cls.relname = 'users' THEN 0
            WHEN cls.relname = 'users' THEN 1
            ELSE 2
        END,
        ns.nspname,
        cls.relname
    LIMIT 1;

    IF v_player_schema IS NULL OR v_player_relation IS NULL THEN
        RETURN;
    END IF;

    EXECUTE format(
        'select coalesce($1, hq_airport_iata) from %I.%I where id = $2',
        v_player_schema,
        v_player_relation
    )
    INTO v_origin_iata
    USING p_origin_iata, p_user_id;

    IF v_origin_iata IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH origin_airport AS (
        SELECT a.*
        FROM public.airports a
        WHERE a.iata = v_origin_iata
        LIMIT 1
    ),
    settings AS (
        SELECT COALESCE(MAX(ggs.fuel_price_per_liter), 0.85) AS fuel_price_per_liter
        FROM public.global_game_settings ggs
    ),
    aircraft_candidates AS (
        SELECT
            f.id AS candidate_aircraft_id,
            f.tail_number AS candidate_tail_number,
            f.acquisition_type AS candidate_acquisition_type,
            f.economy_seats AS configured_economy_seats,
            f.business_seats AS configured_business_seats,
            f.first_class_seats AS configured_first_class_seats,
            m.model_name AS candidate_model_name,
            m.capacity AS model_capacity,
            m.range_km AS model_range_km,
            m.speed_kmh AS model_speed_kmh,
            m.fuel_burn_per_km AS model_fuel_burn_per_km,
            m.maintenance_cost_per_hour AS model_maintenance_cost_per_hour,
            EXISTS (
                SELECT 1
                FROM public.user_routes r
                WHERE r.user_id = p_user_id
                  AND r.assigned_aircraft_id = f.id
            ) AS candidate_currently_assigned
        FROM public.user_fleet f
        JOIN public.aircraft_models m ON m.id = f.aircraft_model_id
        WHERE f.user_id = p_user_id
          AND (
              p_include_assigned
              OR NOT EXISTS (
                  SELECT 1
                  FROM public.user_routes r
                  WHERE r.user_id = p_user_id
                    AND r.assigned_aircraft_id = f.id
              )
          )
    ),
    destination_candidates AS (
        SELECT
            dst.iata AS destination_iata,
            dst.demand_index AS destination_demand_index,
            dst.airport_tax AS destination_airport_tax,
            ROUND(
                (
                    6371.0 * 2.0 * ASIN(
                        SQRT(
                            POWER(SIN(RADIANS(dst.latitude - org.latitude) / 2.0), 2) +
                            COS(RADIANS(org.latitude)) *
                            COS(RADIANS(dst.latitude)) *
                            POWER(SIN(RADIANS(dst.longitude - org.longitude) / 2.0), 2)
                        )
                    )
                )::NUMERIC,
                2
            ) AS route_distance_km
        FROM public.airports dst
        CROSS JOIN origin_airport org
        WHERE dst.iata <> org.iata
          AND (p_destination_iata IS NULL OR dst.iata = p_destination_iata)
    ),
    candidate_pairs AS (
        SELECT
            ac.*,
            dc.destination_iata,
            dc.destination_demand_index,
            dc.destination_airport_tax,
            dc.route_distance_km,
            org.iata AS origin_iata,
            org.demand_index AS origin_demand_index,
            org.airport_tax AS origin_airport_tax
        FROM aircraft_candidates ac
        CROSS JOIN destination_candidates dc
        CROSS JOIN origin_airport org
        WHERE dc.route_distance_km <= ac.model_range_km
    ),
    seat_presets AS (
        SELECT
            cp.*,
            seat_profile.profile_name,
            seat_profile.preset_economy_seats,
            seat_profile.preset_business_seats,
            seat_profile.preset_first_class_seats,
            GREATEST(
                0,
                COALESCE(
                    NULLIF(
                        COALESCE(seat_profile.preset_economy_seats, 0) +
                        COALESCE(seat_profile.preset_business_seats, 0) +
                        COALESCE(seat_profile.preset_first_class_seats, 0),
                        0
                    ),
                    COALESCE(cp.model_capacity, 0)
                )
            )::INT AS passenger_capacity
        FROM candidate_pairs cp
        CROSS JOIN LATERAL (
            VALUES
                ('all_economy'::VARCHAR, cp.model_capacity, 0, 0),
                (
                    'balanced'::VARCHAR,
                    GREATEST(1, cp.model_capacity - (2 * FLOOR(cp.model_capacity * 0.18 / 2.0)::INT) - (3 * FLOOR(cp.model_capacity * 0.06 / 3.0)::INT)),
                    FLOOR(cp.model_capacity * 0.18 / 2.0)::INT,
                    FLOOR(cp.model_capacity * 0.06 / 3.0)::INT
                ),
                (
                    'premium'::VARCHAR,
                    GREATEST(1, cp.model_capacity - (2 * FLOOR(cp.model_capacity * 0.24 / 2.0)::INT) - (3 * FLOOR(cp.model_capacity * 0.12 / 3.0)::INT)),
                    FLOOR(cp.model_capacity * 0.24 / 2.0)::INT,
                    FLOOR(cp.model_capacity * 0.12 / 3.0)::INT
                )
        ) AS seat_profile(profile_name, preset_economy_seats, preset_business_seats, preset_first_class_seats)
    ),
    fare_points AS (
        SELECT
            sp.*,
            ROUND((50.00 + (COALESCE(sp.route_distance_km, 0.0)::NUMERIC * 0.12)) * fare.multiplier, 2) AS evaluated_ticket_price
        FROM seat_presets sp
        CROSS JOIN LATERAL (
            VALUES (0.95::NUMERIC), (1.00::NUMERIC), (1.05::NUMERIC), (1.10::NUMERIC), (1.20::NUMERIC), (1.35::NUMERIC)
        ) AS fare(multiplier)
    ),
    scored AS (
        SELECT
            fp.candidate_aircraft_id,
            fp.candidate_tail_number,
            fp.candidate_model_name,
            fp.candidate_acquisition_type,
            fp.candidate_currently_assigned,
            fp.origin_iata,
            fp.destination_iata,
            EXISTS (
                SELECT 1
                FROM public.user_routes existing_route
                WHERE existing_route.user_id = p_user_id
                  AND existing_route.origin_iata = fp.origin_iata
                  AND existing_route.destination_iata = fp.destination_iata
            ) AS candidate_route_already_exists,
            fp.route_distance_km,
            fp.evaluated_ticket_price,
            CASE
                WHEN COALESCE(fp.route_distance_km, 0.0) <= 0.0 OR COALESCE(fp.model_speed_kmh, 0) <= 0 THEN 0
                ELSE FLOOR(
                    168.0 /
                    NULLIF((COALESCE(fp.route_distance_km, 0.0) / fp.model_speed_kmh::DOUBLE PRECISION) + 1.0, 0.0)
                )::INT
            END AS computed_weekly_flights,
            fp.preset_economy_seats,
            fp.preset_business_seats,
            fp.preset_first_class_seats,
            fp.passenger_capacity,
            GREATEST(
                0,
                LEAST(
                    COALESCE(fp.passenger_capacity, 0),
                    FLOOR(
                        COALESCE(fp.passenger_capacity, 0) *
                        0.95 *
                        GREATEST(
                            0.55,
                            LEAST(
                                1.00,
                                0.55 + (((((COALESCE(fp.origin_demand_index, 50) + COALESCE(fp.destination_demand_index, 50))::NUMERIC) / 2.0) / 100.0) * 0.45)
                            )
                        ) *
                        GREATEST(
                            0.00,
                            LEAST(
                                1.50,
                                1.5 - 0.8 * POWER(
                                    COALESCE(fp.evaluated_ticket_price, 0.00) /
                                    NULLIF(50.00 + (COALESCE(fp.route_distance_km, 0.0)::NUMERIC * 0.12), 0.00),
                                    2
                                )
                            )
                        )
                    )::INT
                )
            ) AS computed_expected_passengers_per_flight,
            ROUND(
                (
                    fp.route_distance_km * fp.model_fuel_burn_per_km * s.fuel_price_per_liter +
                    (((fp.route_distance_km / NULLIF(fp.model_speed_kmh::DOUBLE PRECISION, 0.0)) + 1.0) * fp.model_maintenance_cost_per_hour) +
                    fp.origin_airport_tax +
                    fp.destination_airport_tax
                )::NUMERIC,
                2
            ) AS computed_direct_cost_per_flight
        FROM fare_points fp
        CROSS JOIN settings s
    )
    SELECT
        s.candidate_aircraft_id,
        s.candidate_tail_number,
        s.candidate_model_name,
        s.candidate_acquisition_type,
        s.candidate_currently_assigned,
        s.origin_iata,
        s.destination_iata,
        s.candidate_route_already_exists,
        s.route_distance_km,
        s.evaluated_ticket_price,
        s.computed_weekly_flights,
        s.preset_economy_seats,
        s.preset_business_seats,
        s.preset_first_class_seats,
        s.passenger_capacity,
        s.computed_expected_passengers_per_flight,
        ROUND(
            CASE
                WHEN s.passenger_capacity <= 0 THEN 0.00
                ELSE (s.computed_expected_passengers_per_flight::NUMERIC / s.passenger_capacity::NUMERIC) * 100.00
            END,
            2
        ) AS computed_load_factor,
        s.computed_direct_cost_per_flight,
        ROUND((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price)::NUMERIC, 2) AS computed_revenue_per_flight,
        ROUND(((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price) - s.computed_direct_cost_per_flight)::NUMERIC, 2) AS computed_contribution_per_flight,
        ROUND((((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price) - s.computed_direct_cost_per_flight) * s.computed_weekly_flights)::NUMERIC, 2) AS computed_weekly_contribution,
        ROUND(
            CASE
                WHEN s.candidate_acquisition_type = 'lease' THEN s.computed_weekly_flights * 0.70
                ELSE s.computed_weekly_flights * 0.50
            END::NUMERIC,
            2
        ) AS computed_maintenance_impact_per_week
    FROM scored s
    WHERE s.computed_weekly_flights > 0
    ORDER BY
        computed_weekly_contribution DESC,
        computed_contribution_per_flight DESC,
        computed_load_factor DESC,
        route_distance_km ASC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION public.get_owner_route_optimizer(UUID, VARCHAR, VARCHAR, INT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_owner_route_optimizer(UUID, VARCHAR, VARCHAR, INT, BOOLEAN) TO service_role;

COMMENT ON FUNCTION public.get_owner_route_optimizer(UUID, VARCHAR, VARCHAR, INT, BOOLEAN) IS
'Returns ranked route, fare, and cabin-layout opportunities for the owner without PL/pgSQL output-column ambiguity.';
