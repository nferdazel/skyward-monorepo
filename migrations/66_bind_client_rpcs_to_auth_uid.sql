-- ============================================================================
-- SKYWARD SECURITY PHASE 4: BIND CLIENT RPCS TO AUTH UID
-- ============================================================================
-- Adds authenticated client-facing RPC wrappers that resolve the current actor
-- from auth.uid() instead of trusting p_user_id from the frontend.
--
-- Existing UUID-accepting functions are retained as internal/service-role
-- implementations, but direct execute permissions are removed from client roles.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.require_current_user_id()
RETURNS UUID AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.get_current_user_id();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authenticated Skyward user profile not found.'
            USING ERRCODE = 'P0001';
    END IF;

    RETURN v_user_id;
END;
$$ LANGUAGE plpgsql
STABLE
SET search_path = public, auth, pg_catalog;


CREATE OR REPLACE FUNCTION purchase_aircraft(
    p_model_id UUID,
    p_nickname VARCHAR,
    p_economy_seats INT DEFAULT NULL,
    p_business_seats INT DEFAULT 0,
    p_first_class_seats INT DEFAULT 0
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM purchase_aircraft(
        v_user_id,
        p_model_id,
        p_nickname,
        p_economy_seats,
        p_business_seats,
        p_first_class_seats
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION lease_aircraft(
    p_model_id UUID,
    p_nickname VARCHAR,
    p_economy_seats INT DEFAULT NULL,
    p_business_seats INT DEFAULT 0,
    p_first_class_seats INT DEFAULT 0
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM lease_aircraft(
        v_user_id,
        p_model_id,
        p_nickname,
        p_economy_seats,
        p_business_seats,
        p_first_class_seats
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION configure_aircraft_seats(
    p_fleet_id UUID,
    p_economy_seats INT,
    p_business_seats INT,
    p_first_class_seats INT
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM configure_aircraft_seats(
        v_user_id,
        p_fleet_id,
        p_economy_seats,
        p_business_seats,
        p_first_class_seats
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION repair_aircraft(
    p_fleet_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM repair_aircraft(v_user_id, p_fleet_id);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION create_route(
    p_origin_iata VARCHAR,
    p_destination_iata VARCHAR,
    p_distance_km NUMERIC,
    p_ticket_price NUMERIC,
    p_flights_per_week INT
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM create_route(
        v_user_id,
        p_origin_iata,
        p_destination_iata,
        p_distance_km,
        p_ticket_price,
        p_flights_per_week
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION assign_aircraft_to_route(
    p_route_id UUID,
    p_aircraft_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM assign_aircraft_to_route(
        v_user_id,
        p_route_id,
        p_aircraft_id
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION update_route_frequency_and_price(
    p_route_id UUID,
    p_ticket_price NUMERIC,
    p_flights_per_week INT
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM update_route_frequency_and_price(
        v_user_id,
        p_route_id,
        p_ticket_price,
        p_flights_per_week
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION delete_route(
    p_route_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM delete_route(v_user_id, p_route_id);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION save_airline_settings(
    p_company_name VARCHAR,
    p_auto_grounding_threshold NUMERIC,
    p_hq_airport_iata VARCHAR
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM save_airline_settings(
        v_user_id,
        p_company_name,
        p_auto_grounding_threshold,
        p_hq_airport_iata
    );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION sell_aircraft(
    p_fleet_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM sell_aircraft(v_user_id, p_fleet_id);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION terminate_aircraft_lease(
    p_fleet_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    message VARCHAR,
    new_cash NUMERIC
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM terminate_aircraft_lease(v_user_id, p_fleet_id);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION process_simulation_delta()
RETURNS TABLE (
    cash_before NUMERIC,
    cash_after NUMERIC,
    elapsed_real_sec DOUBLE PRECISION,
    elapsed_game_days DOUBLE PRECISION,
    flights_run INT
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM process_simulation_delta(v_user_id);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION reset_user_airline()
RETURNS TABLE (
    success BOOLEAN,
    message TEXT
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM reset_user_airline(v_user_id);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION get_finance_snapshot()
RETURNS TABLE (
    actor_id UUID,
    is_bot BOOLEAN,
    company_name VARCHAR,
    cash NUMERIC,
    net_worth NUMERIC,
    owned_aircraft_asset_value NUMERIC,
    leased_aircraft_monthly_exposure NUMERIC,
    fleet_count INT,
    owned_fleet_count INT,
    leased_fleet_count INT,
    active_route_count INT,
    rolling_revenue_30d NUMERIC,
    rolling_expense_30d NUMERIC,
    rolling_net_30d NUMERIC,
    ledger_window_days INT
) AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM get_finance_snapshot(v_user_id, FALSE);
END;
$$ LANGUAGE plpgsql STABLE;


REVOKE ALL ON FUNCTION public.require_current_user_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.require_current_user_id() TO authenticated, service_role;

REVOKE ALL ON FUNCTION purchase_aircraft(UUID, UUID, VARCHAR, INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION purchase_aircraft(UUID, UUID, VARCHAR, INT, INT, INT) TO service_role;
REVOKE ALL ON FUNCTION purchase_aircraft(UUID, VARCHAR, INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION purchase_aircraft(UUID, VARCHAR, INT, INT, INT) TO authenticated, service_role;

REVOKE ALL ON FUNCTION lease_aircraft(UUID, UUID, VARCHAR, INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION lease_aircraft(UUID, UUID, VARCHAR, INT, INT, INT) TO service_role;
REVOKE ALL ON FUNCTION lease_aircraft(UUID, VARCHAR, INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION lease_aircraft(UUID, VARCHAR, INT, INT, INT) TO authenticated, service_role;

REVOKE ALL ON FUNCTION configure_aircraft_seats(UUID, UUID, INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION configure_aircraft_seats(UUID, UUID, INT, INT, INT) TO service_role;
REVOKE ALL ON FUNCTION configure_aircraft_seats(UUID, INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION configure_aircraft_seats(UUID, INT, INT, INT) TO authenticated, service_role;

REVOKE ALL ON FUNCTION repair_aircraft(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION repair_aircraft(UUID, UUID) TO service_role;
REVOKE ALL ON FUNCTION repair_aircraft(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION repair_aircraft(UUID) TO authenticated, service_role;

REVOKE ALL ON FUNCTION create_route(UUID, VARCHAR, VARCHAR, NUMERIC, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_route(UUID, VARCHAR, VARCHAR, NUMERIC, NUMERIC, INT) TO service_role;
REVOKE ALL ON FUNCTION create_route(VARCHAR, VARCHAR, NUMERIC, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_route(VARCHAR, VARCHAR, NUMERIC, NUMERIC, INT) TO authenticated, service_role;

REVOKE ALL ON FUNCTION assign_aircraft_to_route(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION assign_aircraft_to_route(UUID, UUID, UUID) TO service_role;
REVOKE ALL ON FUNCTION assign_aircraft_to_route(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION assign_aircraft_to_route(UUID, UUID) TO authenticated, service_role;

REVOKE ALL ON FUNCTION update_route_frequency_and_price(UUID, UUID, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_route_frequency_and_price(UUID, UUID, NUMERIC, INT) TO service_role;
REVOKE ALL ON FUNCTION update_route_frequency_and_price(UUID, NUMERIC, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_route_frequency_and_price(UUID, NUMERIC, INT) TO authenticated, service_role;

REVOKE ALL ON FUNCTION delete_route(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delete_route(UUID, UUID) TO service_role;
REVOKE ALL ON FUNCTION delete_route(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delete_route(UUID) TO authenticated, service_role;

REVOKE ALL ON FUNCTION save_airline_settings(UUID, VARCHAR, NUMERIC, VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_airline_settings(UUID, VARCHAR, NUMERIC, VARCHAR) TO service_role;
REVOKE ALL ON FUNCTION save_airline_settings(VARCHAR, NUMERIC, VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_airline_settings(VARCHAR, NUMERIC, VARCHAR) TO authenticated, service_role;

REVOKE ALL ON FUNCTION sell_aircraft(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sell_aircraft(UUID, UUID) TO service_role;
REVOKE ALL ON FUNCTION sell_aircraft(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sell_aircraft(UUID) TO authenticated, service_role;

REVOKE ALL ON FUNCTION terminate_aircraft_lease(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION terminate_aircraft_lease(UUID, UUID) TO service_role;
REVOKE ALL ON FUNCTION terminate_aircraft_lease(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION terminate_aircraft_lease(UUID) TO authenticated, service_role;

REVOKE ALL ON FUNCTION process_simulation_delta(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_simulation_delta(UUID) TO service_role;
REVOKE ALL ON FUNCTION process_simulation_delta() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_simulation_delta() TO authenticated, service_role;

REVOKE ALL ON FUNCTION reset_user_airline(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reset_user_airline(UUID) TO service_role;
REVOKE ALL ON FUNCTION reset_user_airline() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reset_user_airline() TO authenticated, service_role;

REVOKE ALL ON FUNCTION get_finance_snapshot(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_finance_snapshot(UUID, BOOLEAN) TO service_role;
REVOKE ALL ON FUNCTION get_finance_snapshot() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_finance_snapshot() TO authenticated, service_role;

COMMENT ON FUNCTION public.require_current_user_id() IS
'Returns the current public.users.id resolved from auth.uid(), or raises if the authenticated caller is not mapped to a Skyward player row.';
