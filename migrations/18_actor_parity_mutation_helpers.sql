-- ============================================================================
-- Migration 18: Actor parity — shared mutation helpers
-- Goal:
--   route bot acquisition and route mutations through the same authoritative
--   helper layer used by player-facing fleet and route actions.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_actor_fleet_aircraft(
    p_user_id uuid,
    p_model_id uuid,
    p_nickname character varying,
    p_acquisition_type character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0,
    p_charge_amount numeric DEFAULT 0::numeric,
    p_ifrs_category character varying DEFAULT NULL::character varying,
    p_ifrs_subcategory character varying DEFAULT NULL::character varying,
    p_description text DEFAULT NULL::text,
    p_game_time timestamp with time zone DEFAULT NULL::timestamp with time zone
)
RETURNS TABLE(
    success boolean,
    message character varying,
    new_cash numeric,
    fleet_id uuid,
    tail_number character varying
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_hq_iata VARCHAR(3);
    v_effective_game_time TIMESTAMPTZ;
    v_model_name VARCHAR;
    v_capacity INT;
    v_economy INT;
    v_business INT;
    v_first INT;
    v_slots_used INT;
    v_tail VARCHAR(20);
    v_attempts INT := 0;
    v_inserted_id UUID;
    v_new_cash NUMERIC;
BEGIN
    IF COALESCE(p_acquisition_type, '') NOT IN ('purchase', 'lease', 'finance') THEN
        RETURN QUERY
        SELECT FALSE, 'Unsupported acquisition type.'::VARCHAR, 0.00::NUMERIC, NULL::UUID, NULL::VARCHAR;
        RETURN;
    END IF;

    SELECT hq_airport_iata, game_current_time
    INTO v_hq_iata, v_effective_game_time
    FROM users
    WHERE id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC, NULL::UUID, NULL::VARCHAR;
        RETURN;
    END IF;

    IF p_game_time IS NOT NULL THEN
        v_effective_game_time := p_game_time;
    END IF;

    SELECT model_name, capacity
    INTO v_model_name, v_capacity
    FROM aircraft_models
    WHERE id = p_model_id;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, 'Aircraft model not found.'::VARCHAR, get_user_balance(p_user_id), NULL::UUID, NULL::VARCHAR;
        RETURN;
    END IF;

    v_economy := COALESCE(p_economy_seats, v_capacity);
    v_business := COALESCE(p_business_seats, 0);
    v_first := COALESCE(p_first_class_seats, 0);
    v_slots_used := v_economy + (v_business * 2) + (v_first * 3);

    IF v_economy < 0
       OR v_business < 0
       OR v_first < 0
       OR v_slots_used <= 0
       OR v_slots_used > v_capacity THEN
        RETURN QUERY
        SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, get_user_balance(p_user_id), NULL::UUID, NULL::VARCHAR;
        RETURN;
    END IF;

    WHILE v_attempts < 20 LOOP
        v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
        BEGIN
            INSERT INTO fleet_aircraft (
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
            )
            VALUES (
                p_user_id,
                p_model_id,
                TRIM(COALESCE(p_nickname, v_model_name)),
                p_acquisition_type,
                100.00,
                'active',
                v_tail,
                v_economy,
                v_business,
                v_first
            )
            RETURNING id INTO v_inserted_id;

            EXIT;
        EXCEPTION WHEN unique_violation THEN
            v_attempts := v_attempts + 1;
        END;
    END LOOP;

    IF v_inserted_id IS NULL THEN
        RETURN QUERY
        SELECT FALSE, 'Failed to allocate a unique tail number.'::VARCHAR, get_user_balance(p_user_id), NULL::UUID, NULL::VARCHAR;
        RETURN;
    END IF;

    IF COALESCE(p_charge_amount, 0) > 0 THEN
        PERFORM debit_bank_account(
            p_user_id,
            p_charge_amount,
            COALESCE(p_ifrs_category, 'investing'),
            COALESCE(
                p_ifrs_subcategory,
                CASE p_acquisition_type
                    WHEN 'lease' THEN 'aircraft_lease_deposit'
                    WHEN 'finance' THEN 'aircraft_financing'
                    ELSE 'aircraft_purchase'
                END
            ),
            COALESCE(
                p_description,
                CASE p_acquisition_type
                    WHEN 'lease' THEN 'Leased aircraft ' || v_model_name || ' deposit [' || v_tail || ']'
                    WHEN 'finance' THEN 'Financed aircraft ' || v_model_name || ' [' || v_tail || ']'
                    ELSE 'Purchased aircraft ' || v_model_name || ' [' || v_tail || ']'
                END
            ),
            v_effective_game_time
        );
    END IF;

    v_new_cash := get_user_balance(p_user_id);

    RETURN QUERY
    SELECT TRUE, 'Aircraft created successfully.'::VARCHAR, v_new_cash, v_inserted_id, v_tail;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_actor_route_assignment(
    p_user_id uuid,
    p_origin_iata character varying,
    p_destination_iata character varying,
    p_distance_km numeric,
    p_ticket_price numeric,
    p_flights_per_week integer,
    p_assigned_aircraft_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(
    success boolean,
    message character varying,
    route_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_actual_distance NUMERIC;
    v_effective_threshold NUMERIC(5,2);
    v_aircraft_range_km INT;
    v_aircraft_speed_kmh INT;
    v_max_weekly_flights INT;
    v_inserted_route_id UUID;
BEGIN
    IF p_origin_iata = p_destination_iata THEN
        RETURN QUERY SELECT FALSE, 'Origin and destination must be different.'::VARCHAR, NULL::UUID;
        RETURN;
    END IF;

    IF p_distance_km <= 0
       OR p_ticket_price <= 0
       OR p_flights_per_week < 1
       OR p_flights_per_week > 168 THEN
        RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR, NULL::UUID;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::UUID;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_origin_iata)
       OR NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_destination_iata) THEN
        RETURN QUERY SELECT FALSE, 'Route airport not found.'::VARCHAR, NULL::UUID;
        RETURN;
    END IF;

    SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude)
    INTO v_actual_distance
    FROM airports o, airports d
    WHERE o.iata = p_origin_iata
      AND d.iata = p_destination_iata;

    IF v_actual_distance > 0
       AND ABS(p_distance_km - v_actual_distance) / v_actual_distance > 0.10 THEN
        RETURN QUERY
        SELECT FALSE, ('Distance validation failed. Expected ~' || ROUND(v_actual_distance, 1)::TEXT || ' km.')::VARCHAR, NULL::UUID;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM route_assignments
        WHERE user_id = p_user_id
          AND origin_iata = p_origin_iata
          AND destination_iata = p_destination_iata
    ) THEN
        RETURN QUERY SELECT FALSE, 'Route already exists.'::VARCHAR, NULL::UUID;
        RETURN;
    END IF;

    IF p_assigned_aircraft_id IS NOT NULL THEN
        SELECT GREATEST(
            COALESCE(u.auto_grounding_threshold, 40.00),
            COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00)
        )
        INTO v_effective_threshold
        FROM users u
        WHERE u.id = p_user_id
        LIMIT 1;

        SELECT m.range_km, m.speed_kmh
        INTO v_aircraft_range_km, v_aircraft_speed_kmh
        FROM fleet_aircraft f
        JOIN aircraft_models m ON m.id = f.aircraft_model_id
        WHERE f.id = p_assigned_aircraft_id
          AND f.user_id = p_user_id
          AND f.condition >= COALESCE(v_effective_threshold, 40.00);

        IF NOT FOUND THEN
            RETURN QUERY SELECT FALSE, 'Aircraft is unavailable or below the safety threshold.'::VARCHAR, NULL::UUID;
            RETURN;
        END IF;

        IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(p_distance_km, 0.0)) THEN
            RETURN QUERY SELECT FALSE, 'Aircraft range is insufficient for this route.'::VARCHAR, NULL::UUID;
            RETURN;
        END IF;

        v_max_weekly_flights := calculate_route_max_weekly_flights(p_distance_km, v_aircraft_speed_kmh);
        IF v_max_weekly_flights > 0 AND p_flights_per_week > v_max_weekly_flights THEN
            RETURN QUERY SELECT FALSE, 'Route frequency exceeds this aircraft''s weekly operating capacity.'::VARCHAR, NULL::UUID;
            RETURN;
        END IF;

        IF EXISTS (
            SELECT 1
            FROM route_assignments
            WHERE user_id = p_user_id
              AND assigned_aircraft_id = p_assigned_aircraft_id
        ) THEN
            RETURN QUERY SELECT FALSE, 'Aircraft is already assigned to another route.'::VARCHAR, NULL::UUID;
            RETURN;
        END IF;
    END IF;

    INSERT INTO route_assignments (
        user_id,
        origin_iata,
        destination_iata,
        distance_km,
        ticket_price,
        flights_per_week,
        assigned_aircraft_id
    )
    VALUES (
        p_user_id,
        p_origin_iata,
        p_destination_iata,
        p_distance_km,
        p_ticket_price,
        p_flights_per_week,
        p_assigned_aircraft_id
    )
    RETURNING id INTO v_inserted_route_id;

    IF p_assigned_aircraft_id IS NOT NULL THEN
        UPDATE fleet_aircraft
        SET status = 'active'
        WHERE id = p_assigned_aircraft_id
          AND user_id = p_user_id;
    END IF;

    RETURN QUERY SELECT TRUE, 'Route established successfully!'::VARCHAR, v_inserted_route_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_actor_route_economics(
    p_user_id uuid,
    p_route_id uuid,
    p_ticket_price numeric,
    p_flights_per_week integer
)
RETURNS TABLE(
    success boolean,
    message character varying
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_route_distance_km DOUBLE PRECISION;
    v_assigned_aircraft_id UUID;
    v_aircraft_range_km INT;
    v_aircraft_speed_kmh INT;
    v_max_weekly_flights INT;
BEGIN
    IF p_ticket_price <= 0 OR p_flights_per_week < 1 OR p_flights_per_week > 168 THEN
        RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR;
        RETURN;
    END IF;

    SELECT distance_km, assigned_aircraft_id
    INTO v_route_distance_km, v_assigned_aircraft_id
    FROM route_assignments
    WHERE id = p_route_id
      AND user_id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR;
        RETURN;
    END IF;

    IF v_assigned_aircraft_id IS NOT NULL THEN
        SELECT m.range_km, m.speed_kmh
        INTO v_aircraft_range_km, v_aircraft_speed_kmh
        FROM fleet_aircraft f
        JOIN aircraft_models m ON m.id = f.aircraft_model_id
        WHERE f.id = v_assigned_aircraft_id
          AND f.user_id = p_user_id;

        IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN
            RETURN QUERY SELECT FALSE, 'Assigned aircraft range is insufficient for this route.'::VARCHAR;
            RETURN;
        END IF;

        v_max_weekly_flights := calculate_route_max_weekly_flights(v_route_distance_km, v_aircraft_speed_kmh);
        IF v_max_weekly_flights > 0 AND p_flights_per_week > v_max_weekly_flights THEN
            RETURN QUERY SELECT FALSE, 'Route frequency exceeds the assigned aircraft''s weekly operating capacity.'::VARCHAR;
            RETURN;
        END IF;
    END IF;

    UPDATE route_assignments
    SET ticket_price = p_ticket_price,
        flights_per_week = p_flights_per_week
    WHERE id = p_route_id
      AND user_id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Route frequency and pricing adjusted!'::VARCHAR;
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_actor_route_assignment(
    p_user_id uuid,
    p_route_id uuid,
    p_cancel_instead boolean DEFAULT false
)
RETURNS TABLE(
    success boolean,
    message character varying
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_assigned_aircraft_id UUID;
BEGIN
    SELECT assigned_aircraft_id
    INTO v_assigned_aircraft_id
    FROM route_assignments
    WHERE id = p_route_id
      AND user_id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR;
        RETURN;
    END IF;

    IF p_cancel_instead THEN
        UPDATE route_assignments
        SET status = 'cancelled'
        WHERE id = p_route_id
          AND user_id = p_user_id;

        RETURN QUERY SELECT TRUE, 'Route cancelled successfully.'::VARCHAR;
        RETURN;
    END IF;

    IF v_assigned_aircraft_id IS NOT NULL THEN
        UPDATE fleet_aircraft
        SET status = 'grounded'
        WHERE id = v_assigned_aircraft_id
          AND user_id = p_user_id;
    END IF;

    DELETE FROM route_assignments
    WHERE id = p_route_id
      AND user_id = p_user_id;

    RETURN QUERY SELECT TRUE, 'Route closed and aircraft grounded successfully!'::VARCHAR;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_route(
    p_user_id uuid,
    p_origin_iata character varying,
    p_destination_iata character varying,
    p_distance_km numeric,
    p_ticket_price numeric,
    p_flights_per_week integer
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    RETURN QUERY
    SELECT h.success, h.message
    FROM create_actor_route_assignment(
        p_user_id,
        p_origin_iata,
        p_destination_iata,
        p_distance_km,
        p_ticket_price,
        p_flights_per_week,
        NULL
    ) h;
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_route(
    p_user_id uuid,
    p_route_id uuid
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    RETURN QUERY
    SELECT h.success, h.message
    FROM delete_actor_route_assignment(p_user_id, p_route_id, FALSE) h;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_route_frequency_and_price(
    p_user_id uuid,
    p_route_id uuid,
    p_ticket_price numeric,
    p_flights_per_week integer
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    RETURN QUERY
    SELECT h.success, h.message
    FROM update_actor_route_economics(
        p_user_id,
        p_route_id,
        p_ticket_price,
        p_flights_per_week
    ) h;
END;
$function$;

CREATE OR REPLACE FUNCTION public.purchase_aircraft(
    p_user_id uuid,
    p_model_id uuid,
    p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_cash NUMERIC;
    v_price NUMERIC;
    v_model_name VARCHAR;
    v_helper_success BOOLEAN;
    v_helper_message VARCHAR;
    v_helper_cash NUMERIC;
    v_tail VARCHAR(20);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    v_cash := get_user_balance(p_user_id);

    SELECT purchase_price, model_name
    INTO v_price, v_model_name
    FROM aircraft_models
    WHERE id = p_model_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash;
        RETURN;
    END IF;

    IF v_cash < v_price THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds to purchase ' || v_model_name || '.')::VARCHAR, v_cash;
        RETURN;
    END IF;

    SELECT h.success, h.message, h.new_cash, h.tail_number
    INTO v_helper_success, v_helper_message, v_helper_cash, v_tail
    FROM create_actor_fleet_aircraft(
        p_user_id,
        p_model_id,
        p_nickname,
        'purchase',
        p_economy_seats,
        p_business_seats,
        p_first_class_seats,
        v_price,
        'investing',
        'aircraft_purchase',
        NULL,
        NULL
    ) h;

    IF COALESCE(v_helper_success, FALSE) THEN
        RETURN QUERY
        SELECT TRUE, ('Successfully purchased ' || v_model_name || ' [' || v_tail || ']')::VARCHAR, v_helper_cash;
    ELSE
        RETURN QUERY
        SELECT FALSE, COALESCE(v_helper_message, 'Aircraft purchase failed.')::VARCHAR, COALESCE(v_helper_cash, v_cash);
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.lease_aircraft(
    p_user_id uuid,
    p_model_id uuid,
    p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_cash NUMERIC;
    v_lease_price NUMERIC;
    v_purchase_price NUMERIC;
    v_model_name VARCHAR;
    v_lease_deposit NUMERIC;
    v_helper_success BOOLEAN;
    v_helper_message VARCHAR;
    v_helper_cash NUMERIC;
    v_tail VARCHAR(20);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    v_cash := get_user_balance(p_user_id);

    SELECT lease_price_per_month, purchase_price, model_name
    INTO v_lease_price, v_purchase_price, v_model_name
    FROM aircraft_models
    WHERE id = p_model_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash;
        RETURN;
    END IF;

    v_lease_deposit := calculate_required_lease_deposit(v_purchase_price, v_lease_price);

    IF v_cash < v_lease_deposit THEN
        RETURN QUERY
        SELECT FALSE, ('Insufficient funds for lease deposit of ' || v_model_name || '. Required: $' || ROUND(v_lease_deposit, 2))::VARCHAR, v_cash;
        RETURN;
    END IF;

    SELECT h.success, h.message, h.new_cash, h.tail_number
    INTO v_helper_success, v_helper_message, v_helper_cash, v_tail
    FROM create_actor_fleet_aircraft(
        p_user_id,
        p_model_id,
        p_nickname,
        'lease',
        p_economy_seats,
        p_business_seats,
        p_first_class_seats,
        v_lease_deposit,
        'investing',
        'aircraft_lease_deposit',
        NULL,
        NULL
    ) h;

    IF COALESCE(v_helper_success, FALSE) THEN
        RETURN QUERY
        SELECT TRUE, ('Successfully leased ' || v_model_name || ' [' || v_tail || ']')::VARCHAR, v_helper_cash;
    ELSE
        RETURN QUERY
        SELECT FALSE, COALESCE(v_helper_message, 'Aircraft lease failed.')::VARCHAR, COALESCE(v_helper_cash, v_cash);
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
r_bot RECORD; v_model_id UUID; v_model_name VARCHAR; v_lease_price NUMERIC; v_purchase_price NUMERIC; v_capacity INT; v_speed_kmh NUMERIC; v_range_km NUMERIC; v_deposit_amount NUMERIC; v_tail VARCHAR(20); v_origin_iata VARCHAR(3); v_dest_iata VARCHAR(3); v_distance DOUBLE PRECISION; v_fleet_count INT; v_route_count INT; v_idle_aircraft_count INT; v_idle_aircraft_id UUID; v_idle_tail VARCHAR(20); v_idle_condition NUMERIC; v_idle_model_name VARCHAR; v_idle_capacity INT; v_idle_speed NUMERIC; v_idle_range NUMERIC; v_grounded_aircraft_id UUID; v_grounded_condition NUMERIC; v_grounded_acquisition_type VARCHAR; v_grounded_model_name VARCHAR; v_grounded_lease_price NUMERIC; v_grounded_purchase_price NUMERIC; v_repair_cost NUMERIC; v_target_fleet_cap INT; v_min_cash_reserve NUMERIC; v_growth_chance NUMERIC; v_target_distance DOUBLE PRECISION; v_target_price_multiplier NUMERIC; v_target_schedule_ratio NUMERIC; v_effective_threshold NUMERIC(5,2); v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00; v_selected_route_id UUID; v_selected_flights INT; v_selected_base_fare NUMERIC; v_max_weekly_flights INT; v_target_flights INT; v_target_price NUMERIC; v_bot_cash NUMERIC; v_starting_cash NUMERIC; v_attempts INT; v_inserted BOOLEAN; v_economy INT; v_business INT; v_first INT; r_route RECORD; v_human_competitors INT; v_new_price NUMERIC; v_base_fare NUMERIC; v_purchase_capacity INT; v_purchase_model_name VARCHAR; v_active_loans INT; v_game_time TIMESTAMPTZ;
v_archetype VARCHAR(30);
v_ticket_base_fare NUMERIC;
v_ticket_per_km_rate NUMERIC;
v_bankruptcy_threshold NUMERIC;
v_spawned_id UUID;
v_requested_loan NUMERIC;
v_cash_ratio NUMERIC;
v_distress_stage VARCHAR(20);
v_route_change_allowed BOOLEAN;
v_growth_allowed BOOLEAN;
v_pricing_allowed BOOLEAN;
v_repair_allowed BOOLEAN;
v_growth_roll NUMERIC;
v_price_adjustment NUMERIC;
v_route_trim_threshold INT;
v_route_floor INT;
v_route_reduction INT;
v_lease_growth_bias NUMERIC;
v_purchase_growth_bias NUMERIC;
v_route_creation_bias NUMERIC;
v_loan_request_bias NUMERIC;
v_action_success BOOLEAN;
v_action_message VARCHAR;
v_action_cash NUMERIC;
v_created_route_id UUID;
v_created_fleet_id UUID;
BEGIN
v_ticket_base_fare := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
v_ticket_per_km_rate := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);
v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);

FOR r_bot IN
SELECT u.*, COALESCE(bp.archetype, 'Balanced') AS archetype,
       bp.last_growth_action_at,
       bp.last_route_change_at,
       bp.last_pricing_review_at,
       bp.last_repair_action_at,
       COALESCE(bp.distress_stage, 'stable') AS profile_distress_stage
FROM users u
LEFT JOIN bot_profiles bp ON bp.user_id = u.id
WHERE u.actor_type = 'AI'
  AND u.operational_status != 'Bankrupt'
LOOP
v_archetype := r_bot.archetype;
v_bot_cash := get_user_balance(r_bot.id);
v_game_time := r_bot.game_current_time;
v_origin_iata := r_bot.hq_airport_iata;
v_effective_threshold := GREATEST(v_absolute_minimum_safety_limit, COALESCE(r_bot.auto_grounding_threshold, 40.00));
v_cash_ratio := CASE
    WHEN v_starting_cash > 0 THEN v_bot_cash / v_starting_cash
    ELSE 0
END;
v_route_change_allowed := r_bot.last_route_change_at IS NULL
    OR r_bot.last_route_change_at <= v_game_time - INTERVAL '8 hours';
v_growth_allowed := r_bot.last_growth_action_at IS NULL
    OR r_bot.last_growth_action_at <= v_game_time - INTERVAL '18 hours';
v_pricing_allowed := r_bot.last_pricing_review_at IS NULL
    OR r_bot.last_pricing_review_at <= v_game_time - INTERVAL '6 hours';
v_repair_allowed := r_bot.last_repair_action_at IS NULL
    OR r_bot.last_repair_action_at <= v_game_time - INTERVAL '12 hours';

IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < v_bankruptcy_threshold THEN
  UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
  UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id;
  UPDATE loans SET status = 'defaulted', remaining_balance = 0 WHERE user_id = r_bot.id AND status = 'active';
  UPDATE route_assignments SET status = 'cancelled' WHERE user_id = r_bot.id AND status = 'active';
  UPDATE bot_profiles SET distress_stage = 'desperate' WHERE user_id = r_bot.id;
  CONTINUE;
END IF;

v_distress_stage := CASE
  WHEN COALESCE(r_bot.consecutive_negative_days, 0) >= 5 OR v_cash_ratio < 0.18 THEN 'desperate'
  WHEN COALESCE(r_bot.consecutive_negative_days, 0) >= 3 OR v_cash_ratio < 0.30 THEN 'defensive'
  WHEN COALESCE(r_bot.consecutive_negative_days, 0) >= 1 OR v_cash_ratio < 0.50 THEN 'cautious'
  ELSE 'stable'
END;

UPDATE bot_profiles
SET distress_stage = v_distress_stage
WHERE user_id = r_bot.id;

CASE v_archetype
  WHEN 'Regional' THEN
    v_target_fleet_cap := 8;
    v_min_cash_reserve := 3500000.00;
    v_growth_chance := 0.20;
    v_target_distance := 900.0;
    v_target_price_multiplier := 0.95;
    v_target_schedule_ratio := 0.72;
  WHEN 'Aggressive' THEN
    v_target_fleet_cap := 14;
    v_min_cash_reserve := 4500000.00;
    v_growth_chance := 0.26;
    v_target_distance := 1800.0;
    v_target_price_multiplier := 1.02;
    v_target_schedule_ratio := 0.82;
  ELSE
    v_target_fleet_cap := 10;
    v_min_cash_reserve := 7000000.00;
    v_growth_chance := 0.16;
    v_target_distance := 4200.0;
    v_target_price_multiplier := 1.18;
    v_target_schedule_ratio := 0.58;
END CASE;

IF COALESCE(r_bot.recovery_streak_days, 0) >= 3 THEN
    v_growth_chance := LEAST(0.35, v_growth_chance + 0.04);
END IF;

IF v_distress_stage = 'cautious' THEN
    v_growth_chance := v_growth_chance * 0.60;
    v_min_cash_reserve := v_min_cash_reserve * 1.10;
ELSIF v_distress_stage = 'defensive' THEN
    v_growth_chance := v_growth_chance * 0.25;
    v_min_cash_reserve := v_min_cash_reserve * 1.30;
ELSIF v_distress_stage = 'desperate' THEN
    v_growth_chance := 0;
    v_min_cash_reserve := v_min_cash_reserve * 1.50;
END IF;

SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id;
SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
SELECT COUNT(*)::INT INTO v_idle_aircraft_count
FROM fleet_aircraft f
WHERE f.user_id = r_bot.id
  AND f.status = 'active'
  AND f.condition >= v_effective_threshold
  AND NOT EXISTS (
      SELECT 1
      FROM route_assignments r
      WHERE r.assigned_aircraft_id = f.id
  );

SELECT f.id, f.condition, f.acquisition_type, m.model_name, m.lease_price_per_month, m.purchase_price
INTO v_grounded_aircraft_id, v_grounded_condition, v_grounded_acquisition_type, v_grounded_model_name, v_grounded_lease_price, v_grounded_purchase_price
FROM fleet_aircraft f
JOIN aircraft_models m ON f.aircraft_model_id = m.id
WHERE f.user_id = r_bot.id
  AND (f.status = 'grounded' OR f.condition < v_effective_threshold)
ORDER BY f.condition DESC
LIMIT 1;

IF v_grounded_aircraft_id IS NOT NULL AND v_repair_allowed THEN
    v_repair_cost := CASE
        WHEN v_grounded_acquisition_type = 'lease' THEN (100.00 - v_grounded_condition) * (COALESCE(v_grounded_lease_price, 0.00) * 0.50)
        ELSE (100.00 - v_grounded_condition) * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005)
    END;

    IF v_repair_cost > 0
       AND v_bot_cash >= (v_repair_cost + 500000.00)
       AND (v_distress_stage IN ('stable', 'cautious') OR (v_distress_stage = 'defensive' AND v_grounded_condition >= 45)) THEN
        PERFORM debit_bank_account(r_bot.id, v_repair_cost, 'cogs', 'maintenance', 'Bot maintenance recovery: ' || v_grounded_model_name, v_game_time);
        UPDATE fleet_aircraft
        SET condition = 100.00,
            status = 'active'
        WHERE id = v_grounded_aircraft_id;
        UPDATE bot_profiles
        SET last_repair_action_at = v_game_time
        WHERE user_id = r_bot.id;
        v_bot_cash := v_bot_cash - v_repair_cost;
    END IF;
END IF;

IF v_route_change_allowed AND (v_distress_stage IN ('defensive', 'desperate') OR (v_distress_stage = 'cautious' AND random() < 0.45)) THEN
    SELECT r.id,
           r.flights_per_week,
           (v_ticket_base_fare + (r.distance_km * v_ticket_per_km_rate))::NUMERIC
    INTO v_selected_route_id, v_selected_flights, v_selected_base_fare
    FROM route_assignments r
    WHERE r.user_id = r_bot.id
    ORDER BY (r.ticket_price / NULLIF((v_ticket_base_fare + (r.distance_km * v_ticket_per_km_rate)), 0)) DESC,
             r.flights_per_week DESC
    LIMIT 1;

    IF v_selected_route_id IS NOT NULL THEN
        v_route_trim_threshold := CASE
            WHEN v_distress_stage = 'desperate' THEN 6
            WHEN v_distress_stage = 'defensive' THEN 8
            ELSE 10
        END;
        v_route_floor := CASE
            WHEN v_distress_stage = 'desperate' THEN 4
            ELSE 6
        END;
        v_route_reduction := CASE
            WHEN v_distress_stage = 'desperate' THEN 6
            WHEN v_distress_stage = 'defensive' THEN 4
            ELSE 2
        END;

        v_action_success := FALSE;

        IF v_selected_flights > v_route_trim_threshold THEN
            SELECT h.success, h.message
            INTO v_action_success, v_action_message
            FROM update_actor_route_economics(
                r_bot.id,
                v_selected_route_id,
                LEAST(
                    ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2),
                    ROUND(((
                        SELECT ticket_price
                        FROM route_assignments
                        WHERE id = v_selected_route_id
                    ) * CASE
                        WHEN v_distress_stage = 'desperate' THEN 0.88
                        WHEN v_distress_stage = 'defensive' THEN 0.92
                        ELSE 0.96
                    END)::numeric, 2)
                ),
                GREATEST(v_route_floor, v_selected_flights - v_route_reduction)
            ) h;
        ELSIF v_distress_stage = 'desperate' THEN
            SELECT h.success, h.message
            INTO v_action_success, v_action_message
            FROM delete_actor_route_assignment(r_bot.id, v_selected_route_id, FALSE) h;
        END IF;

        IF COALESCE(v_action_success, FALSE) THEN
            UPDATE bot_profiles
            SET last_route_change_at = v_game_time
            WHERE user_id = r_bot.id;
        END IF;
    END IF;
END IF;

IF v_growth_allowed
   AND v_fleet_count < v_target_fleet_cap
   AND v_bot_cash > v_min_cash_reserve
   AND COALESCE(r_bot.consecutive_negative_days, 0) = 0
   AND v_idle_aircraft_count = 0
   AND v_route_count >= v_fleet_count THEN
    v_growth_roll := random();
    IF v_growth_roll < v_growth_chance THEN
        v_model_id := NULL; v_model_name := NULL; v_lease_price := NULL; v_purchase_price := NULL; v_capacity := NULL;
        IF v_archetype = 'Regional' THEN
            SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
            INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
            FROM aircraft_models
            WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600'
            LIMIT 1;
        ELSIF v_archetype = 'Aggressive' THEN
            SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
            INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
            FROM aircraft_models
            WHERE manufacturer = 'Airbus' AND model_name = 'A320neo'
            LIMIT 1;
        ELSE
            SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
            INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
            FROM aircraft_models
            WHERE manufacturer = 'Boeing' AND model_name = '787-9'
            LIMIT 1;
        END IF;

        IF v_model_id IS NULL THEN
            SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km
            INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
            FROM aircraft_models
            WHERE range_km >= v_target_distance
            ORDER BY purchase_price ASC
            LIMIT 1;
        END IF;

        v_deposit_amount := calculate_required_lease_deposit(v_purchase_price, v_lease_price);
        v_lease_growth_bias := CASE
            WHEN v_archetype = 'Aggressive' THEN 0.70
            ELSE 0.50
        END;

        IF v_model_id IS NOT NULL
           AND v_bot_cash >= v_deposit_amount
           AND v_distress_stage IN ('stable', 'cautious')
           AND random() < v_lease_growth_bias THEN
            IF v_archetype = 'Regional' THEN
                v_economy := FLOOR(v_capacity * 0.80);
                v_business := FLOOR(v_capacity * 0.15);
            ELSIF v_archetype = 'Aggressive' THEN
                v_economy := FLOOR(v_capacity * 0.70);
                v_business := FLOOR(v_capacity * 0.20);
            ELSE
                v_economy := FLOOR(v_capacity * 0.50);
                v_business := FLOOR(v_capacity * 0.30);
            END IF;
            v_first := v_capacity - v_economy - v_business;

            SELECT h.success, h.message, h.new_cash, h.fleet_id, h.tail_number
            INTO v_action_success, v_action_message, v_action_cash, v_created_fleet_id, v_tail
            FROM create_actor_fleet_aircraft(
                r_bot.id,
                v_model_id,
                v_model_name,
                'lease',
                v_economy,
                v_business,
                v_first,
                v_deposit_amount,
                'investing',
                'aircraft_lease_deposit',
                NULL,
                v_game_time
            ) h;

            IF COALESCE(v_action_success, FALSE) THEN
                UPDATE bot_profiles
                SET last_growth_action_at = v_game_time
                WHERE user_id = r_bot.id;
                v_bot_cash := v_action_cash;
            END IF;
        END IF;
    END IF;
END IF;

v_purchase_growth_bias := CASE
    WHEN COALESCE(r_bot.recovery_streak_days, 0) >= 5 THEN 0.35
    ELSE 0.18
END;

IF v_distress_stage = 'stable'
   AND v_growth_allowed
   AND v_bot_cash > (v_starting_cash * 3)
   AND v_fleet_count < v_target_fleet_cap
   AND random() < v_purchase_growth_bias THEN
  v_model_id := NULL; v_purchase_price := NULL; v_purchase_capacity := NULL; v_purchase_model_name := NULL;
  IF v_archetype = 'Regional' THEN
    SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name
    FROM aircraft_models WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600' LIMIT 1;
  ELSIF v_archetype = 'Aggressive' THEN
    SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name
    FROM aircraft_models WHERE manufacturer = 'Airbus' AND model_name = 'A320neo' LIMIT 1;
  ELSE
    SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name
    FROM aircraft_models WHERE manufacturer = 'Boeing' AND model_name = '787-9' LIMIT 1;
  END IF;
  IF v_model_id IS NULL THEN
    SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name
    FROM aircraft_models WHERE range_km >= v_target_distance ORDER BY purchase_price ASC LIMIT 1;
  END IF;
  IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN
    IF v_archetype = 'Regional' THEN
      v_economy := FLOOR(v_purchase_capacity * 0.80); v_business := FLOOR(v_purchase_capacity * 0.15);
    ELSIF v_archetype = 'Aggressive' THEN
      v_economy := FLOOR(v_purchase_capacity * 0.70); v_business := FLOOR(v_purchase_capacity * 0.20);
    ELSE
      v_economy := FLOOR(v_purchase_capacity * 0.50); v_business := FLOOR(v_purchase_capacity * 0.30);
    END IF;
    v_first := v_purchase_capacity - v_economy - v_business;

    SELECT h.success, h.message, h.new_cash, h.fleet_id, h.tail_number
    INTO v_action_success, v_action_message, v_action_cash, v_created_fleet_id, v_tail
    FROM create_actor_fleet_aircraft(
        r_bot.id,
        v_model_id,
        v_purchase_model_name,
        'purchase',
        v_economy,
        v_business,
        v_first,
        v_purchase_price,
        'investing',
        'aircraft_purchase',
        NULL,
        v_game_time
    ) h;

    IF COALESCE(v_action_success, FALSE) THEN
      UPDATE bot_profiles
      SET last_growth_action_at = v_game_time
      WHERE user_id = r_bot.id;
      v_bot_cash := v_action_cash;
    END IF;
  END IF;
END IF;

SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id;
SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
SELECT f.id, f.tail_number, f.condition, m.model_name, m.capacity, m.speed_kmh, m.range_km
INTO v_idle_aircraft_id, v_idle_tail, v_idle_condition, v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range
FROM fleet_aircraft f
JOIN aircraft_models m ON f.aircraft_model_id = m.id
WHERE f.user_id = r_bot.id
  AND f.status = 'active'
  AND f.condition >= v_effective_threshold
  AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id)
ORDER BY f.condition DESC
LIMIT 1;

v_route_creation_bias := CASE
    WHEN v_distress_stage = 'cautious' THEN 0.45
    ELSE 0.70
END;

IF v_idle_aircraft_id IS NOT NULL
   AND v_route_count < v_target_fleet_cap
   AND v_route_change_allowed
   AND v_distress_stage <> 'desperate'
   AND random() < v_route_creation_bias THEN
  v_attempts := 0;
  v_inserted := false;
  WHILE v_attempts < 20 AND NOT v_inserted LOOP
    SELECT iata
    INTO v_dest_iata
    FROM airports
    WHERE iata != v_origin_iata
      AND haversine_distance(
            (SELECT latitude FROM airports WHERE iata = v_origin_iata),
            (SELECT longitude FROM airports WHERE iata = v_origin_iata),
            latitude,
            longitude
          ) <= v_idle_range
    ORDER BY demand_index DESC, random()
    LIMIT 1;
    IF v_dest_iata IS NULL THEN
        EXIT;
    END IF;
    SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude)
    INTO v_distance
    FROM airports o, airports d
    WHERE o.iata = v_origin_iata AND d.iata = v_dest_iata;
    IF v_distance > 0 AND v_distance <= v_idle_range THEN
      v_base_fare := v_ticket_base_fare + (v_distance * v_ticket_per_km_rate);
      v_target_price := ROUND(v_base_fare * v_target_price_multiplier, 2);
      v_max_weekly_flights := calculate_route_max_weekly_flights(v_distance, v_idle_speed::INT);
      v_target_flights := GREATEST(
          1,
          FLOOR(v_max_weekly_flights * CASE
              WHEN v_distress_stage = 'cautious' THEN v_target_schedule_ratio * 0.85
              ELSE v_target_schedule_ratio
          END)
      );

      SELECT h.success, h.message, h.route_id
      INTO v_action_success, v_action_message, v_created_route_id
      FROM create_actor_route_assignment(
          r_bot.id,
          v_origin_iata,
          v_dest_iata,
          v_distance,
          v_target_price,
          v_target_flights,
          v_idle_aircraft_id
      ) h;

      v_inserted := COALESCE(v_action_success, FALSE);
      IF NOT v_inserted THEN
          v_attempts := v_attempts + 1;
      END IF;
    ELSE
      v_attempts := v_attempts + 1;
    END IF;
  END LOOP;

  IF v_inserted THEN
      UPDATE bot_profiles
      SET last_route_change_at = v_game_time
      WHERE user_id = r_bot.id;
  END IF;
END IF;

IF v_pricing_allowed THEN
    FOR r_route IN
        SELECT ra.*, m.speed_kmh, m.range_km, m.turnaround_hours
        FROM route_assignments ra
        JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id
        JOIN aircraft_models m ON m.id = fa.aircraft_model_id
        WHERE ra.user_id = r_bot.id
          AND ra.status = 'active'
    LOOP
        SELECT COUNT(*)
        INTO v_human_competitors
        FROM route_assignments
        WHERE origin_iata = r_route.origin_iata
          AND destination_iata = r_route.destination_iata
          AND status = 'active'
          AND user_id != r_bot.id;

        IF v_human_competitors > 0 OR random() < 0.20 THEN
            v_base_fare := v_ticket_base_fare + (r_route.distance_km * v_ticket_per_km_rate);
            v_price_adjustment := CASE
                WHEN v_distress_stage = 'desperate' THEN 0.90
                WHEN v_distress_stage = 'defensive' THEN 0.95
                WHEN v_distress_stage = 'cautious' THEN 0.98
                ELSE CASE
                    WHEN v_archetype = 'Aggressive' THEN 1.01
                    WHEN v_archetype = 'Balanced' THEN 1.03
                    ELSE 0.97
                END
            END;
            v_new_price := ROUND(
                (
                    (r_route.ticket_price * 0.55) +
                    (v_base_fare * v_target_price_multiplier * v_price_adjustment * 0.45)
                )::numeric,
                2
            );
            IF ABS(v_new_price - r_route.ticket_price) / NULLIF(r_route.ticket_price, 0) >= 0.03 THEN
                PERFORM success
                FROM update_actor_route_economics(
                    r_bot.id,
                    r_route.id,
                    v_new_price,
                    r_route.flights_per_week
                );
            END IF;
        END IF;
    END LOOP;

    UPDATE bot_profiles
    SET last_pricing_review_at = v_game_time
    WHERE user_id = r_bot.id;
END IF;

SELECT COUNT(*) INTO v_active_loans
FROM loans
WHERE user_id = r_bot.id
  AND status = 'active';

v_loan_request_bias := CASE
    WHEN v_distress_stage = 'defensive' THEN 0.65
    ELSE 0.35
END;

IF v_active_loans = 0
   AND v_bot_cash < v_starting_cash * 0.5
   AND v_bot_cash > 1000000
   AND v_distress_stage IN ('cautious', 'defensive')
   AND random() < v_loan_request_bias THEN
  v_requested_loan := LEAST(5000000, v_starting_cash - v_bot_cash);
  PERFORM success
  FROM take_loan(r_bot.id, v_requested_loan, 52, 'unsecured', NULL);
END IF;

UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;
END LOOP;

IF (SELECT COUNT(*) FROM users WHERE actor_type = 'AI' AND COALESCE(operational_status, 'Active') != 'Bankrupt') <
   COALESCE(get_config_int('max_bot_count'), 5)
THEN
    v_spawned_id := spawn_bot();
END IF;
END;
$function$;
