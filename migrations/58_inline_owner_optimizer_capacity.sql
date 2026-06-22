-- ============================================================================
-- INLINE OWNER OPTIMIZER CAPACITY CALCULATION
-- ============================================================================
-- Some live environments are missing calculate_effective_passenger_capacity()
-- even after route-hardening rollout. Inline the same formula inside the owner
-- optimizer so the tool no longer depends on that helper being present.
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
            f.id AS aircraft_id,
            f.tail_number,
            f.acquisition_type,
            f.economy_seats,
            f.business_seats,
            f.first_class_seats,
            m.model_name,
            m.capacity,
            m.range_km,
            m.speed_kmh,
            m.fuel_burn_per_km,
            m.maintenance_cost_per_hour,
            EXISTS (
                SELECT 1
                FROM public.user_routes r
                WHERE r.user_id = p_user_id
                  AND r.assigned_aircraft_id = f.id
            ) AS currently_assigned
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
            dst.iata,
            dst.demand_index,
            dst.airport_tax,
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
            ) AS distance_km
        FROM public.airports dst
        CROSS JOIN origin_airport org
        WHERE dst.iata <> org.iata
          AND (p_destination_iata IS NULL OR dst.iata = p_destination_iata)
    ),
    candidate_pairs AS (
        SELECT
            ac.*,
            dc.iata AS destination_iata,
            dc.demand_index AS dst_demand,
            dc.airport_tax AS dst_tax,
            dc.distance_km,
            org.iata AS origin_iata,
            org.demand_index AS org_demand,
            org.airport_tax AS org_tax
        FROM aircraft_candidates ac
        CROSS JOIN destination_candidates dc
        CROSS JOIN origin_airport org
        WHERE dc.distance_km <= ac.range_km
    ),
    seat_presets AS (
        SELECT
            cp.*,
            seat_profile.profile_name,
            seat_profile.economy_seats,
            seat_profile.business_seats,
            seat_profile.first_class_seats,
            GREATEST(
                0,
                COALESCE(
                    NULLIF(
                        COALESCE(seat_profile.economy_seats, 0) +
                        COALESCE(seat_profile.business_seats, 0) +
                        COALESCE(seat_profile.first_class_seats, 0),
                        0
                    ),
                    COALESCE(cp.capacity, 0)
                )
            )::INT AS passenger_capacity
        FROM candidate_pairs cp
        CROSS JOIN LATERAL (
            VALUES
                ('all_economy'::VARCHAR, cp.capacity, 0, 0),
                (
                    'balanced'::VARCHAR,
                    GREATEST(1, cp.capacity - (2 * FLOOR(cp.capacity * 0.18 / 2.0)::INT) - (3 * FLOOR(cp.capacity * 0.06 / 3.0)::INT)),
                    FLOOR(cp.capacity * 0.18 / 2.0)::INT,
                    FLOOR(cp.capacity * 0.06 / 3.0)::INT
                ),
                (
                    'premium'::VARCHAR,
                    GREATEST(1, cp.capacity - (2 * FLOOR(cp.capacity * 0.24 / 2.0)::INT) - (3 * FLOOR(cp.capacity * 0.12 / 3.0)::INT)),
                    FLOOR(cp.capacity * 0.24 / 2.0)::INT,
                    FLOOR(cp.capacity * 0.12 / 3.0)::INT
                )
        ) AS seat_profile(profile_name, economy_seats, business_seats, first_class_seats)
    ),
    fare_points AS (
        SELECT
            sp.*,
            ROUND(public.calculate_route_base_fare(sp.distance_km::DOUBLE PRECISION) * fare.multiplier, 2) AS ticket_price
        FROM seat_presets sp
        CROSS JOIN LATERAL (
            VALUES (0.95::NUMERIC), (1.00::NUMERIC), (1.05::NUMERIC), (1.10::NUMERIC), (1.20::NUMERIC), (1.35::NUMERIC)
        ) AS fare(multiplier)
    ),
    scored AS (
        SELECT
            fp.aircraft_id,
            fp.tail_number,
            fp.model_name AS aircraft_model,
            fp.acquisition_type,
            fp.currently_assigned,
            fp.origin_iata,
            fp.destination_iata,
            EXISTS (
                SELECT 1
                FROM public.user_routes existing_route
                WHERE existing_route.user_id = p_user_id
                  AND existing_route.origin_iata = fp.origin_iata
                  AND existing_route.destination_iata = fp.destination_iata
            ) AS route_already_exists,
            fp.distance_km,
            fp.ticket_price,
            public.calculate_route_max_weekly_flights(fp.distance_km::DOUBLE PRECISION, fp.speed_kmh) AS weekly_flights,
            fp.economy_seats,
            fp.business_seats,
            fp.first_class_seats,
            fp.passenger_capacity,
            public.calculate_route_expected_passengers(
                fp.passenger_capacity,
                fp.distance_km::DOUBLE PRECISION,
                fp.ticket_price,
                fp.org_demand,
                fp.dst_demand
            ) AS expected_passengers_per_flight,
            ROUND(
                (
                    fp.distance_km * fp.fuel_burn_per_km * s.fuel_price_per_liter +
                    (((fp.distance_km / NULLIF(fp.speed_kmh::DOUBLE PRECISION, 0.0)) + 1.0) * fp.maintenance_cost_per_hour) +
                    fp.org_tax +
                    fp.dst_tax
                )::NUMERIC,
                2
            ) AS direct_cost_per_flight,
            ROUND(
                (
                    public.calculate_route_expected_passengers(
                        fp.passenger_capacity,
                        fp.distance_km::DOUBLE PRECISION,
                        fp.ticket_price,
                        fp.org_demand,
                        fp.dst_demand
                    ) * fp.ticket_price
                )::NUMERIC,
                2
            ) AS revenue_per_flight,
            ROUND(
                CASE
                    WHEN fp.acquisition_type = 'lease'
                    THEN public.calculate_route_max_weekly_flights(fp.distance_km::DOUBLE PRECISION, fp.speed_kmh) * 0.70
                    ELSE public.calculate_route_max_weekly_flights(fp.distance_km::DOUBLE PRECISION, fp.speed_kmh) * 0.50
                END::NUMERIC,
                2
            ) AS maintenance_impact_per_week
        FROM fare_points fp
        CROSS JOIN settings s
    )
    SELECT
        s.aircraft_id,
        s.tail_number,
        s.aircraft_model,
        s.acquisition_type,
        s.currently_assigned,
        s.origin_iata,
        s.destination_iata,
        s.route_already_exists,
        s.distance_km,
        s.ticket_price,
        s.weekly_flights,
        s.economy_seats,
        s.business_seats,
        s.first_class_seats,
        s.passenger_capacity,
        s.expected_passengers_per_flight,
        ROUND(
            CASE
                WHEN s.passenger_capacity <= 0 THEN 0.00
                ELSE (s.expected_passengers_per_flight::NUMERIC / s.passenger_capacity::NUMERIC) * 100.00
            END,
            2
        ) AS load_factor,
        s.direct_cost_per_flight,
        s.revenue_per_flight,
        ROUND(s.revenue_per_flight - s.direct_cost_per_flight, 2) AS contribution_per_flight,
        ROUND((s.revenue_per_flight - s.direct_cost_per_flight) * s.weekly_flights, 2) AS weekly_contribution,
        s.maintenance_impact_per_week
    FROM scored s
    WHERE s.weekly_flights > 0
    ORDER BY
        weekly_contribution DESC,
        contribution_per_flight DESC,
        load_factor DESC,
        distance_km ASC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION public.get_owner_route_optimizer(UUID, VARCHAR, VARCHAR, INT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_owner_route_optimizer(UUID, VARCHAR, VARCHAR, INT, BOOLEAN) TO service_role;

COMMENT ON FUNCTION public.get_owner_route_optimizer(UUID, VARCHAR, VARCHAR, INT, BOOLEAN) IS
'Returns ranked route, fare, and cabin-layout opportunities for the owner without requiring calculate_effective_passenger_capacity().';
