-- ============================================================================
-- SKYWARD SCHEDULED MAINTENANCE REGRESSION AUDIT
-- ============================================================================
-- Validates three critical cases:
-- 1. active slack-scheduled aircraft can offset in-loop wear with maintenance slots
-- 2. active max-scheduled aircraft still takes wear
-- 3. grounded aircraft do not receive free self-healing
--
-- Safe manual audit: runs inside a transaction and rolls back.
-- ============================================================================

BEGIN;

DO $$
DECLARE
    v_user_id UUID;
    v_username VARCHAR := 'maint_audit_' || floor(extract(epoch FROM now()))::bigint::text;
    v_company_name VARCHAR := 'Maintenance Audit ' || floor(extract(epoch FROM now()))::bigint::text;

    v_owned_model_id UUID;
    v_owned_capacity INT;
    v_leased_model_id UUID;
    v_leased_capacity INT;

    v_owned_fleet_id UUID := gen_random_uuid();
    v_leased_fleet_id UUID := gen_random_uuid();
    v_grounded_fleet_id UUID := gen_random_uuid();

    v_flight_duration DOUBLE PRECISION;
    v_max_weekly_flights INT;

    v_owned_condition NUMERIC(10,4);
    v_leased_condition NUMERIC(10,4);
    v_grounded_condition NUMERIC(10,4);
BEGIN
    SELECT user_id
    INTO v_user_id
    FROM register_company(
        v_username,
        'auditpass123',
        v_company_name,
        'Maintenance Auditor',
        'CGK'
    )
    WHERE success = TRUE;

    ASSERT v_user_id IS NOT NULL, 'register_company did not create an audit user.';

    SELECT id, capacity
    INTO v_owned_model_id, v_owned_capacity
    FROM aircraft_models
    WHERE model_name = 'A320neo'
    LIMIT 1;

    SELECT id, capacity
    INTO v_leased_model_id, v_leased_capacity
    FROM aircraft_models
    WHERE model_name = 'ATR 72-600'
    LIMIT 1;

    ASSERT v_owned_model_id IS NOT NULL, 'A320neo model not found.';
    ASSERT v_leased_model_id IS NOT NULL, 'ATR 72-600 model not found.';

    INSERT INTO user_fleet (
        id,
        user_id,
        aircraft_model_id,
        nickname,
        acquisition_type,
        condition,
        status,
        tail_number,
        economy_seats,
        business_seats,
        first_class_seats
    ) VALUES
    (
        v_owned_fleet_id,
        v_user_id,
        v_owned_model_id,
        'Slack Schedule Audit',
        'purchase',
        100.00,
        'active',
        'PK-MTA',
        v_owned_capacity,
        0,
        0
    ),
    (
        v_leased_fleet_id,
        v_user_id,
        v_leased_model_id,
        'Max Schedule Audit',
        'lease',
        100.00,
        'active',
        'PK-MTB',
        v_leased_capacity,
        0,
        0
    ),
    (
        v_grounded_fleet_id,
        v_user_id,
        v_leased_model_id,
        'Grounded Audit',
        'lease',
        28.00,
        'grounded',
        'PK-MTC',
        v_leased_capacity,
        0,
        0
    );

    SELECT (884.0 / speed_kmh) + 1.0
    INTO v_flight_duration
    FROM aircraft_models
    WHERE id = v_owned_model_id;

    v_max_weekly_flights := floor(168.0 / v_flight_duration);
    ASSERT v_max_weekly_flights > 14, 'Expected max weekly flights to exceed slack schedule.';

    INSERT INTO user_routes (
        user_id,
        origin_iata,
        destination_iata,
        distance_km,
        ticket_price,
        assigned_aircraft_id,
        flights_per_week
    ) VALUES
    (v_user_id, 'CGK', 'SIN', 884.0, 175.0, v_owned_fleet_id, 14),
    (v_user_id, 'SIN', 'CGK', 884.0, 175.0, v_leased_fleet_id, v_max_weekly_flights),
    (v_user_id, 'CGK', 'KUL', 1124.0, 165.0, v_grounded_fleet_id, 7);

    UPDATE users
    SET game_current_time = '2020-01-01 00:00:00+00'::timestamptz,
        last_active_at = NOW() - INTERVAL '1 hour',
        auto_grounding_threshold = 40.00,
        buffered_revenue = 0.00,
        buffered_ops_cost = 0.00,
        buffered_lease_cost = 0.00
    WHERE id = v_user_id;

    PERFORM process_simulation_delta(v_user_id);

    SELECT condition INTO v_owned_condition FROM user_fleet WHERE id = v_owned_fleet_id;
    SELECT condition INTO v_leased_condition FROM user_fleet WHERE id = v_leased_fleet_id;
    SELECT condition INTO v_grounded_condition FROM user_fleet WHERE id = v_grounded_fleet_id;

    ASSERT v_owned_condition = 100.00,
        'Slack-scheduled owned aircraft should fully offset in-loop wear.';

    ASSERT v_leased_condition < 100.00,
        'Max-scheduled leased aircraft should take wear when no maintenance slots remain.';

    ASSERT v_grounded_condition = 28.00,
        'Grounded aircraft should not receive free self-healing.';

    RAISE NOTICE 'Scheduled maintenance audit passed. Owned slack condition=%, leased max condition=%, grounded condition=%',
        v_owned_condition, v_leased_condition, v_grounded_condition;
END $$;

ROLLBACK;
