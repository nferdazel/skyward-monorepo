-- ============================================================================
-- SKYWARD FLEET DISPOSAL AND OWNER OPERATOR TOOLS
-- ============================================================================
-- 1. Adds player-facing owned-aircraft sale and lease-termination RPCs.
-- 2. Adds a service-role-only route optimizer surface for operator use.
-- ============================================================================

CREATE OR REPLACE FUNCTION calculate_owned_aircraft_sale_value(
    p_purchase_price NUMERIC,
    p_condition NUMERIC
)
RETURNS NUMERIC AS $$
    SELECT ROUND(
        COALESCE(p_purchase_price, 0.00) *
        0.72 *
        GREATEST(0.00, LEAST(COALESCE(p_condition, 0.00), 100.00)) / 100.00,
        2
    );
$$ LANGUAGE sql IMMUTABLE;


CREATE OR REPLACE FUNCTION calculate_lease_termination_fee(
    p_lease_price_per_month NUMERIC
)
RETURNS NUMERIC AS $$
    SELECT ROUND(COALESCE(p_lease_price_per_month, 0.00) * 0.25, 2);
$$ LANGUAGE sql IMMUTABLE;


CREATE OR REPLACE FUNCTION sell_aircraft(
    p_user_id UUID,
    p_fleet_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_user RECORD;
    v_fleet RECORD;
    v_sale_value NUMERIC(20,2);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT *
    INTO v_user
    FROM users
    WHERE id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    SELECT
        f.*,
        m.model_name,
        m.purchase_price
    INTO v_fleet
    FROM user_fleet f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id
      AND f.user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'purchase' THEN
        RETURN QUERY SELECT FALSE, 'Only owned aircraft can be sold.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM user_routes
        WHERE user_id = p_user_id
          AND assigned_aircraft_id = p_fleet_id
    ) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    v_sale_value := calculate_owned_aircraft_sale_value(
        v_fleet.purchase_price,
        v_fleet.condition
    );

    UPDATE users
    SET cash = cash + v_sale_value
    WHERE id = p_user_id
    RETURNING cash INTO new_cash;

    INSERT INTO financial_ledger (
        user_id,
        transaction_type,
        category,
        amount,
        description,
        game_date
    )
    VALUES (
        p_user_id,
        'revenue',
        'aircraft_sale',
        v_sale_value,
        'Sold owned aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
        date_trunc('day', v_user.game_current_time)
    );

    DELETE FROM user_fleet
    WHERE id = p_fleet_id
      AND user_id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Aircraft sold successfully!'::VARCHAR, new_cash;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION terminate_aircraft_lease(
    p_user_id UUID,
    p_fleet_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_user RECORD;
    v_fleet RECORD;
    v_exit_fee NUMERIC(20,2);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT *
    INTO v_user
    FROM users
    WHERE id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    SELECT
        f.*,
        m.model_name,
        m.lease_price_per_month
    INTO v_fleet
    FROM user_fleet f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id
      AND f.user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'lease' THEN
        RETURN QUERY SELECT FALSE, 'Only leased aircraft can be terminated through this action.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM user_routes
        WHERE user_id = p_user_id
          AND assigned_aircraft_id = p_fleet_id
    ) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    v_exit_fee := calculate_lease_termination_fee(v_fleet.lease_price_per_month);

    UPDATE users
    SET cash = cash - v_exit_fee
    WHERE id = p_user_id
    RETURNING cash INTO new_cash;

    IF v_exit_fee > 0 THEN
        INSERT INTO financial_ledger (
            user_id,
            transaction_type,
            category,
            amount,
            description,
            game_date
        )
        VALUES (
            p_user_id,
            'expense',
            'aircraft_lease_exit',
            v_exit_fee,
            'Terminated leased aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
            date_trunc('day', v_user.game_current_time)
        );
    END IF;

    DELETE FROM user_fleet
    WHERE id = p_fleet_id
      AND user_id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Lease terminated successfully!'::VARCHAR, new_cash;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION get_owner_route_optimizer(
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
BEGIN
    SELECT COALESCE(p_origin_iata, u.hq_airport_iata)
    INTO v_origin_iata
    FROM users u
    WHERE u.id = p_user_id;

    IF v_origin_iata IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH origin_airport AS (
        SELECT a.*
        FROM airports a
        WHERE a.iata = v_origin_iata
        LIMIT 1
    ),
    settings AS (
        SELECT COALESCE(fuel_price_per_liter, 0.85) AS fuel_price_per_liter
        FROM global_game_settings
        LIMIT 1
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
                FROM user_routes r
                WHERE r.user_id = p_user_id
                  AND r.assigned_aircraft_id = f.id
            ) AS currently_assigned
        FROM user_fleet f
        JOIN aircraft_models m ON m.id = f.aircraft_model_id
        WHERE f.user_id = p_user_id
          AND (
              p_include_assigned
              OR NOT EXISTS (
                  SELECT 1
                  FROM user_routes r
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
        FROM airports dst
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
            calculate_effective_passenger_capacity(
                cp.capacity,
                seat_profile.economy_seats,
                seat_profile.business_seats,
                seat_profile.first_class_seats
            ) AS passenger_capacity
        FROM candidate_pairs cp
        CROSS JOIN LATERAL (
            VALUES
                (
                    'all_economy'::VARCHAR,
                    cp.capacity,
                    0,
                    0
                ),
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
            ROUND(calculate_route_base_fare(sp.distance_km) * fare.multiplier, 2) AS ticket_price,
            fare.multiplier
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
                FROM user_routes existing_route
                WHERE existing_route.user_id = p_user_id
                  AND existing_route.origin_iata = fp.origin_iata
                  AND existing_route.destination_iata = fp.destination_iata
            ) AS route_already_exists,
            fp.distance_km,
            fp.ticket_price,
            calculate_route_max_weekly_flights(fp.distance_km::DOUBLE PRECISION, fp.speed_kmh) AS weekly_flights,
            fp.economy_seats,
            fp.business_seats,
            fp.first_class_seats,
            fp.passenger_capacity,
            calculate_route_expected_passengers(
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
                    calculate_route_expected_passengers(
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
                    THEN calculate_route_max_weekly_flights(fp.distance_km::DOUBLE PRECISION, fp.speed_kmh) * 0.70
                    ELSE calculate_route_max_weekly_flights(fp.distance_km::DOUBLE PRECISION, fp.speed_kmh) * 0.50
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
                ELSE (s.expected_passengers_per_flight::NUMERIC / s.passenger_capacity::NUMERIC) * 100.0
            END,
            2
        ) AS load_factor,
        s.direct_cost_per_flight,
        s.revenue_per_flight,
        ROUND((s.revenue_per_flight - s.direct_cost_per_flight)::NUMERIC, 2) AS contribution_per_flight,
        ROUND(((s.revenue_per_flight - s.direct_cost_per_flight) * s.weekly_flights)::NUMERIC, 2) AS weekly_contribution,
        s.maintenance_impact_per_week
    FROM scored s
    WHERE s.weekly_flights > 0
    ORDER BY weekly_contribution DESC, contribution_per_flight DESC, distance_km ASC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;


REVOKE ALL ON FUNCTION sell_aircraft(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sell_aircraft(UUID, UUID) TO authenticated, service_role;

REVOKE ALL ON FUNCTION terminate_aircraft_lease(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION terminate_aircraft_lease(UUID, UUID) TO authenticated, service_role;

REVOKE ALL ON FUNCTION get_owner_route_optimizer(UUID, VARCHAR, VARCHAR, INT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_owner_route_optimizer(UUID, VARCHAR, VARCHAR, INT, BOOLEAN) TO service_role;

COMMENT ON FUNCTION sell_aircraft(UUID, UUID) IS
'Sells one owned player aircraft if it is not assigned to a route, credits cash, writes ledger revenue, and removes the fleet row.';

COMMENT ON FUNCTION terminate_aircraft_lease(UUID, UUID) IS
'Terminates one leased player aircraft if it is not assigned to a route, charges an exit fee, writes ledger expense, and removes the fleet row.';

COMMENT ON FUNCTION get_owner_route_optimizer(UUID, VARCHAR, VARCHAR, INT, BOOLEAN) IS
'Service-role-only operator optimizer that ranks route, fare, and seat-layout combinations across one player fleet.';
