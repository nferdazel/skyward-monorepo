-- Skyward Consolidated Baseline Migration
-- Generated: 2026-07-22 from live Supabase database
--
-- This is a single consolidated baseline that replaces58 individual migration
-- files (00_baseline.sql through 20260710250000_fix_performance_indexes.sql).
--
-- The schema was dumped directly from the linked Supabase project using:
--   supabase db dump --linked --schema public
--
-- Previous migrations are archived in migrations_old/ for reference.
--
-- Extensions required: pg_cron, pgcrypto, uuid-ossp
--

Initialising login role...
Dumping schemas from remote database...



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."apply_actor_bankruptcy_state"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    UPDATE users
    SET operational_status = 'Bankrupt'
    WHERE id = p_user_id;

    UPDATE fleet_aircraft
    SET status = 'grounded'
    WHERE user_id = p_user_id;

    UPDATE loans
    SET status = 'defaulted',
        remaining_balance = 0
    WHERE user_id = p_user_id
      AND status = 'active';

    UPDATE route_assignments
    SET status = 'cancelled'
    WHERE user_id = p_user_id
      AND status = 'active';
END;
$$;


ALTER FUNCTION "public"."apply_actor_bankruptcy_state"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_actor_aircraft_to_route"("p_user_id" "uuid", "p_route_id" "uuid", "p_aircraft_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_current_aircraft_id UUID;
    v_effective_threshold NUMERIC(5,2);
    v_route_distance_km DOUBLE PRECISION;
    v_route_flights_per_week INT;
    v_aircraft_range_km INT;
    v_aircraft_speed_kmh INT;
    v_max_weekly_flights INT;
BEGIN
    -- Look up the route
    SELECT assigned_aircraft_id, distance_km, flights_per_week
    INTO v_current_aircraft_id, v_route_distance_km, v_route_flights_per_week
    FROM route_assignments
    WHERE id = p_route_id AND user_id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR;
        RETURN;
    END IF;

    -- If assigning an aircraft (not unassigning), validate it
    IF p_aircraft_id IS NOT NULL THEN
        -- Safety threshold
        SELECT GREATEST(
            COALESCE(u.auto_grounding_threshold, 40.00),
            COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00)
        ) INTO v_effective_threshold
        FROM users u WHERE u.id = p_user_id LIMIT 1;

        -- Aircraft existence, condition, and model data
        SELECT m.range_km, m.speed_kmh
        INTO v_aircraft_range_km, v_aircraft_speed_kmh
        FROM fleet_aircraft f
        JOIN aircraft_models m ON m.id = f.aircraft_model_id
        WHERE f.id = p_aircraft_id
          AND f.user_id = p_user_id
          AND f.condition >= COALESCE(v_effective_threshold, 40.00);
        IF NOT FOUND THEN
            RETURN QUERY SELECT FALSE, 'Aircraft is unavailable or below the safety threshold.'::VARCHAR;
            RETURN;
        END IF;

        -- Range check
        IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN
            RETURN QUERY SELECT FALSE, 'Aircraft range is insufficient for this route.'::VARCHAR;
            RETURN;
        END IF;

        -- Capacity check
        v_max_weekly_flights := calculate_route_max_weekly_flights(v_route_distance_km, v_aircraft_speed_kmh);
        IF v_max_weekly_flights > 0 AND COALESCE(v_route_flights_per_week, 0) > v_max_weekly_flights THEN
            RETURN QUERY SELECT FALSE, 'Route frequency exceeds this aircraft''s weekly operating capacity.'::VARCHAR;
            RETURN;
        END IF;

        -- Double-assignment check
        IF EXISTS (
            SELECT 1 FROM route_assignments
            WHERE user_id = p_user_id AND assigned_aircraft_id = p_aircraft_id AND id <> p_route_id
        ) THEN
            RETURN QUERY SELECT FALSE, 'Aircraft is already assigned to another route.'::VARCHAR;
            RETURN;
        END IF;
    END IF;

    -- Perform the assignment
    UPDATE route_assignments
    SET assigned_aircraft_id = p_aircraft_id
    WHERE id = p_route_id AND user_id = p_user_id;

    -- Activate the aircraft if assigning
    IF p_aircraft_id IS NOT NULL THEN
        UPDATE fleet_aircraft SET status = 'active' WHERE id = p_aircraft_id AND user_id = p_user_id;
    END IF;

    RETURN QUERY SELECT TRUE, 'Aircraft assignment updated successfully!'::VARCHAR;
END;
$$;


ALTER FUNCTION "public"."assign_actor_aircraft_to_route"("p_user_id" "uuid", "p_route_id" "uuid", "p_aircraft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_aircraft_to_route"("p_route_id" "uuid", "p_aircraft_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM assign_aircraft_to_route(v_user_id, p_route_id, p_aircraft_id);
END;
$$;


ALTER FUNCTION "public"."assign_aircraft_to_route"("p_route_id" "uuid", "p_aircraft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_aircraft_to_route"("p_user_id" "uuid", "p_route_id" "uuid", "p_aircraft_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    RETURN QUERY SELECT * FROM assign_actor_aircraft_to_route(p_user_id, p_route_id, p_aircraft_id);
END;
$$;


ALTER FUNCTION "public"."assign_aircraft_to_route"("p_user_id" "uuid", "p_route_id" "uuid", "p_aircraft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bot_evaluate_distress"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_consecutive_neg" integer, "p_cash_ratio" numeric, OUT "o_distress_stage" character varying, OUT "o_target_fleet_cap" integer, OUT "o_min_cash_reserve" numeric, OUT "o_growth_chance" numeric, OUT "o_target_distance" double precision, OUT "o_target_price_mult" numeric, OUT "o_target_sched_ratio" numeric) RETURNS "record"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    -- Distress stage calculation
    o_distress_stage := CASE
        WHEN COALESCE(p_consecutive_neg, 0) >= 5 OR p_cash_ratio < 0.18 THEN 'desperate'
        WHEN COALESCE(p_consecutive_neg, 0) >= 3 OR p_cash_ratio < 0.30 THEN 'defensive'
        WHEN COALESCE(p_consecutive_neg, 0) >= 1 OR p_cash_ratio < 0.50 THEN 'cautious'
        ELSE 'stable'
    END;

    -- Write distress stage back
    UPDATE bot_profiles SET distress_stage = o_distress_stage WHERE user_id = p_bot_id;

    -- Archetype parameters
    CASE p_archetype
        WHEN 'Regional' THEN
            o_target_fleet_cap := 8; o_min_cash_reserve := 3500000.00;
            o_growth_chance := 0.20; o_target_distance := 900.0;
            o_target_price_mult := 0.95; o_target_sched_ratio := 0.72;
        WHEN 'Aggressive' THEN
            o_target_fleet_cap := 14; o_min_cash_reserve := 4500000.00;
            o_growth_chance := 0.26; o_target_distance := 1800.0;
            o_target_price_mult := 1.02; o_target_sched_ratio := 0.82;
        ELSE
            o_target_fleet_cap := 10; o_min_cash_reserve := 7000000.00;
            o_growth_chance := 0.16; o_target_distance := 4200.0;
            o_target_price_mult := 1.18; o_target_sched_ratio := 0.58;
    END CASE;

    -- Recovery streak bonus
    IF (SELECT COALESCE(recovery_streak_days, 0) FROM users WHERE id = p_bot_id) >= 3 THEN
        o_growth_chance := LEAST(0.35, o_growth_chance + 0.04);
    END IF;

    -- Distress modifiers
    IF o_distress_stage = 'cautious' THEN
        o_growth_chance := o_growth_chance * 0.60;
        o_min_cash_reserve := o_min_cash_reserve * 1.10;
    ELSIF o_distress_stage = 'defensive' THEN
        o_growth_chance := o_growth_chance * 0.25;
        o_min_cash_reserve := o_min_cash_reserve * 1.30;
    ELSIF o_distress_stage = 'desperate' THEN
        o_growth_chance := 0;
        o_min_cash_reserve := o_min_cash_reserve * 1.50;
    END IF;
END;
$$;


ALTER FUNCTION "public"."bot_evaluate_distress"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_consecutive_neg" integer, "p_cash_ratio" numeric, OUT "o_distress_stage" character varying, OUT "o_target_fleet_cap" integer, OUT "o_min_cash_reserve" numeric, OUT "o_growth_chance" numeric, OUT "o_target_distance" double precision, OUT "o_target_price_mult" numeric, OUT "o_target_sched_ratio" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bot_handle_financial"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_bot_cash" numeric, "p_starting_cash" numeric, "p_min_cash_reserve" numeric, "p_repay_ratio" numeric, "p_recovery_amount" numeric) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_allowed BOOLEAN;
    v_active_loans INT;
    v_loan_id UUID;
    v_balance NUMERIC;
    v_repay_amount NUMERIC;
    v_recovery_taken BOOLEAN;
    v_loan_request_bias NUMERIC;
BEGIN
    SELECT last_financial_action_at IS NULL OR last_financial_action_at <= p_game_time - INTERVAL '12 hours'
    INTO v_allowed FROM bot_profiles WHERE user_id = p_bot_id;

    -- Loan repayment
    IF v_allowed AND p_distress NOT IN ('desperate') THEN
        SELECT COUNT(*)::INT INTO v_active_loans FROM loans WHERE user_id = p_bot_id AND status = 'active';

        IF v_active_loans > 0 AND p_bot_cash > (p_min_cash_reserve * 1.5) THEN
            SELECT id, remaining_balance INTO v_loan_id, v_balance
            FROM loans WHERE user_id = p_bot_id AND status = 'active'
            ORDER BY interest_rate DESC LIMIT 1;

            IF v_loan_id IS NOT NULL AND v_balance > 0 THEN
                v_repay_amount := LEAST(v_balance * p_repay_ratio, p_bot_cash - p_min_cash_reserve);
                IF v_repay_amount > 0 THEN
                    PERFORM repay_loan(v_loan_id, v_repay_amount);
                    UPDATE bot_profiles SET last_financial_action_at = p_game_time WHERE user_id = p_bot_id;
                END IF;
            END IF;
        END IF;
    END IF;

    -- Loan request
    SELECT COUNT(*)::INT INTO v_active_loans FROM loans WHERE user_id = p_bot_id AND status = 'active';

    IF v_active_loans = 0 THEN
        -- Normal loan
        IF p_bot_cash < p_starting_cash * 0.5 AND p_bot_cash > 1000000
           AND p_distress IN ('cautious', 'defensive') THEN
            v_loan_request_bias := CASE WHEN p_distress = 'defensive' THEN 0.65 ELSE 0.35 END;
            IF random() < v_loan_request_bias THEN
                PERFORM take_loan(p_bot_id, LEAST(5000000, p_starting_cash - p_bot_cash), 52, 'unsecured', NULL);
            END IF;
        END IF;

        -- Desperate recovery loan
        SELECT recovery_loan_taken INTO v_recovery_taken FROM bot_profiles WHERE user_id = p_bot_id;
        IF p_distress = 'desperate' AND NOT COALESCE(v_recovery_taken, false)
           AND p_bot_cash > 500000 AND p_bot_cash < p_starting_cash * 0.3 THEN
            PERFORM take_loan(p_bot_id, p_recovery_amount, 26, 'unsecured', NULL);
            UPDATE bot_profiles SET recovery_loan_taken = true WHERE user_id = p_bot_id;
        END IF;
    END IF;

    -- Reset recovery flag if recovered
    IF p_distress = 'stable' AND (SELECT COALESCE(recovery_loan_taken, false) FROM bot_profiles WHERE user_id = p_bot_id) THEN
        UPDATE bot_profiles SET recovery_loan_taken = false WHERE user_id = p_bot_id;
    END IF;
END;
$$;


ALTER FUNCTION "public"."bot_handle_financial"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_bot_cash" numeric, "p_starting_cash" numeric, "p_min_cash_reserve" numeric, "p_repay_ratio" numeric, "p_recovery_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bot_handle_fleet_growth"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_bot_cash" numeric, "p_starting_cash" numeric, "p_target_fleet_cap" integer, "p_min_cash_reserve" numeric, "p_growth_chance" numeric, "p_target_distance" double precision, "p_purchase_cash_mult" numeric, "p_fleet_diversity" numeric) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_fleet_count INT;
    v_route_count INT;
    v_idle_count INT;
    v_owned_count INT;
    v_leased_count INT;
    v_consecutive_neg INT;
    v_growth_allowed BOOLEAN;
    v_model_id UUID;
    v_model_name VARCHAR;
    v_lease_price NUMERIC;
    v_purchase_price NUMERIC;
    v_capacity INT;
    v_speed_kmh NUMERIC;
    v_range_km NUMERIC;
    v_economy INT;
    v_business INT;
    v_first INT;
    v_lease_bias NUMERIC;
    v_purchase_bias NUMERIC;
    v_effective_threshold NUMERIC;
BEGIN
    v_effective_threshold := GREATEST(30.00, COALESCE((SELECT auto_grounding_threshold FROM users WHERE id = p_bot_id), 40.00));

    SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = p_bot_id;
    SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = p_bot_id AND status = 'active';
    SELECT COUNT(*)::INT INTO v_owned_count FROM fleet_aircraft WHERE user_id = p_bot_id AND acquisition_type = 'purchase';
    SELECT COUNT(*)::INT INTO v_leased_count FROM fleet_aircraft WHERE user_id = p_bot_id AND acquisition_type = 'lease';
    SELECT COALESCE(consecutive_negative_days, 0) INTO v_consecutive_neg FROM users WHERE id = p_bot_id;

    SELECT COUNT(*)::INT INTO v_idle_count
    FROM fleet_aircraft f
    WHERE f.user_id = p_bot_id AND f.status = 'active' AND f.condition >= v_effective_threshold
      AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);

    SELECT last_growth_action_at IS NULL OR last_growth_action_at <= p_game_time - INTERVAL '18 hours'
    INTO v_growth_allowed FROM bot_profiles WHERE user_id = p_bot_id;

    -- Gate checks
    IF NOT v_growth_allowed OR v_fleet_count >= p_target_fleet_cap OR v_bot_cash <= p_min_cash_reserve
       OR v_consecutive_neg > 0 OR v_idle_count > 0 OR v_route_count < v_fleet_count
       OR random() >= p_growth_chance THEN
        RETURN;
    END IF;

    -- Model selection with fleet diversity
    IF random() < p_fleet_diversity THEN
        SELECT m.id, m.model_name, m.lease_price_per_month, m.purchase_price, m.capacity, m.speed_kmh, m.range_km
        INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
        FROM aircraft_models m
        WHERE m.range_km >= p_target_distance * 0.7 AND m.range_km <= p_target_distance * 1.5
        ORDER BY m.lease_price_per_month ASC LIMIT 1;
    ELSE
        CASE p_archetype
            WHEN 'Regional' THEN
                SELECT m.id, m.model_name, m.lease_price_per_month, m.purchase_price, m.capacity, m.speed_kmh, m.range_km
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                FROM aircraft_models m WHERE m.model_name ILIKE '%ATR%' OR m.model_name ILIKE '%72-600%'
                ORDER BY m.lease_price_per_month ASC LIMIT 1;
            WHEN 'Aggressive' THEN
                SELECT m.id, m.model_name, m.lease_price_per_month, m.purchase_price, m.capacity, m.speed_kmh, m.range_km
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                FROM aircraft_models m WHERE m.model_name ILIKE '%A320%' OR m.model_name ILIKE '%neo%'
                ORDER BY m.lease_price_per_month ASC LIMIT 1;
            ELSE
                SELECT m.id, m.model_name, m.lease_price_per_month, m.purchase_price, m.capacity, m.speed_kmh, m.range_km
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                FROM aircraft_models m WHERE m.model_name ILIKE '%787%' OR m.model_name ILIKE '%Boeing%'
                ORDER BY m.lease_price_per_month ASC LIMIT 1;
        END CASE;
    END IF;

    -- Fallback
    IF v_model_id IS NULL THEN
        SELECT m.id, m.model_name, m.lease_price_per_month, m.purchase_price, m.capacity, m.speed_kmh, m.range_km
        INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
        FROM aircraft_models m WHERE m.range_km >= p_target_distance
        ORDER BY m.lease_price_per_month ASC LIMIT 1;
    END IF;

    IF v_model_id IS NULL THEN RETURN; END IF;

    -- Lease decision
    v_lease_bias := CASE WHEN p_archetype = 'Aggressive' THEN 0.70 ELSE 0.50 END;
    IF p_distress IN ('stable', 'cautious') AND random() < v_lease_bias THEN
        SELECT m.economy_seats, m.business_seats, m.first_class_seats
        INTO v_economy, v_business, v_first FROM aircraft_models m WHERE m.id = v_model_id;

        PERFORM create_actor_fleet_aircraft(p_bot_id, v_model_id, NULL, 'lease',
            COALESCE(v_economy, 0), COALESCE(v_business, 0), COALESCE(v_first, 0));
        UPDATE bot_profiles SET last_growth_action_at = p_game_time WHERE user_id = p_bot_id;
        RETURN;
    END IF;

    -- Purchase decision
    IF p_distress = 'stable' AND v_bot_cash > (p_starting_cash * p_purchase_cash_mult) THEN
        v_purchase_bias := CASE
            WHEN (SELECT COALESCE(recovery_streak_days, 0) FROM users WHERE id = p_bot_id) >= 5 THEN 0.35
            WHEN v_owned_count = 0 THEN 0.28
            WHEN v_leased_count > v_owned_count THEN 0.23
            ELSE 0.18
        END;

        IF random() < v_purchase_bias AND v_bot_cash > v_purchase_price THEN
            SELECT m.economy_seats, m.business_seats, m.first_class_seats
            INTO v_economy, v_business, v_first FROM aircraft_models m WHERE m.id = v_model_id;

            PERFORM create_actor_fleet_aircraft(p_bot_id, v_model_id, NULL, 'purchase',
                COALESCE(v_economy, 0), COALESCE(v_business, 0), COALESCE(v_first, 0));
            UPDATE bot_profiles SET last_growth_action_at = p_game_time WHERE user_id = p_bot_id;
        END IF;
    END IF;
END;
$$;


ALTER FUNCTION "public"."bot_handle_fleet_growth"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_bot_cash" numeric, "p_starting_cash" numeric, "p_target_fleet_cap" integer, "p_min_cash_reserve" numeric, "p_growth_chance" numeric, "p_target_distance" double precision, "p_purchase_cash_mult" numeric, "p_fleet_diversity" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bot_handle_pricing"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_target_price_mult" numeric, "p_comp_threshold" numeric) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_allowed BOOLEAN;
    v_ticket_base_fare NUMERIC;
    v_ticket_per_km_rate NUMERIC;
    v_route RECORD;
    v_base_fare NUMERIC;
    v_price_adj NUMERIC;
    v_new_price NUMERIC;
    v_avg_comp_price NUMERIC;
    v_comp_count INT;
BEGIN
    SELECT last_pricing_review_at IS NULL OR last_pricing_review_at <= p_game_time - INTERVAL '6 hours'
    INTO v_allowed FROM bot_profiles WHERE user_id = p_bot_id;

    IF NOT v_allowed THEN RETURN; END IF;

    v_ticket_base_fare := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
    v_ticket_per_km_rate := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);

    FOR v_route IN
        SELECT r.id, r.ticket_price, r.flights_per_week, r.distance_km, r.origin_iata, r.destination_iata
        FROM route_assignments r WHERE r.user_id = p_bot_id AND r.status = 'active'
    LOOP
        SELECT COUNT(*), COALESCE(AVG(r2.ticket_price), 0)
        INTO v_comp_count, v_avg_comp_price
        FROM route_assignments r2
        WHERE r2.origin_iata = v_route.origin_iata AND r2.destination_iata = v_route.destination_iata
          AND r2.user_id <> p_bot_id AND r2.status = 'active';

        IF v_comp_count > 0 OR random() < 0.20 THEN
            v_base_fare := v_ticket_base_fare + (v_route.distance_km * v_ticket_per_km_rate);

            v_price_adj := CASE
                WHEN p_distress = 'desperate' THEN 0.90
                WHEN p_distress = 'defensive' THEN 0.95
                WHEN p_distress = 'cautious' THEN 0.98
                WHEN p_archetype = 'Aggressive' THEN 1.01
                WHEN p_archetype = 'Balanced' THEN 1.03
                ELSE 0.97
            END;

            -- Competitive response
            IF v_comp_count > 0 AND v_avg_comp_price > 0 AND p_distress IN ('stable', 'cautious') THEN
                IF v_route.ticket_price > v_avg_comp_price * (1 + p_comp_threshold) THEN
                    v_price_adj := v_price_adj * 0.95;
                ELSIF v_route.ticket_price < v_avg_comp_price * (1 - p_comp_threshold) THEN
                    v_price_adj := v_price_adj * 1.03;
                END IF;
            END IF;

            v_new_price := (v_route.ticket_price * 0.55) + ((v_base_fare * p_target_price_mult * v_price_adj) * 0.45);

            IF ABS(v_new_price - v_route.ticket_price) / GREATEST(v_route.ticket_price, 1) >= 0.03 THEN
                PERFORM update_actor_route_economics(p_bot_id, v_route.id, v_new_price, v_route.flights_per_week);
            END IF;
        END IF;
    END LOOP;

    UPDATE bot_profiles SET last_pricing_review_at = p_game_time WHERE user_id = p_bot_id;
END;
$$;


ALTER FUNCTION "public"."bot_handle_pricing"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_target_price_mult" numeric, "p_comp_threshold" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bot_handle_repair"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_threshold" numeric, "p_cash_reserve" numeric) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_aircraft_id UUID;
    v_condition NUMERIC;
    v_allowed BOOLEAN;
BEGIN
    -- Check repair cooldown
    SELECT last_repair_action_at IS NULL OR last_repair_action_at <= p_game_time - INTERVAL '12 hours'
    INTO v_allowed FROM bot_profiles WHERE user_id = p_bot_id;

    IF NOT v_allowed THEN RETURN; END IF;

    IF p_distress <> 'desperate' THEN
        -- Normal repair: any grounded or below-threshold aircraft
        SELECT f.id, f.condition INTO v_aircraft_id, v_condition
        FROM fleet_aircraft f
        WHERE f.user_id = p_bot_id
          AND (f.status = 'grounded' OR f.condition < p_threshold)
        ORDER BY f.condition ASC LIMIT 1;
    ELSE
        -- Desperate recovery: only grounded aircraft with condition >= 60
        SELECT f.id, f.condition INTO v_aircraft_id, v_condition
        FROM fleet_aircraft f
        WHERE f.user_id = p_bot_id
          AND f.status = 'grounded' AND f.condition >= 60
        ORDER BY f.condition DESC LIMIT 1;
    END IF;

    IF v_aircraft_id IS NOT NULL THEN
        PERFORM perform_actor_aircraft_repair(p_bot_id, v_aircraft_id, p_cash_reserve, p_game_time, 'Bot repair');
        UPDATE bot_profiles SET last_repair_action_at = p_game_time WHERE user_id = p_bot_id;
    END IF;
END;
$$;


ALTER FUNCTION "public"."bot_handle_repair"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_threshold" numeric, "p_cash_reserve" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bot_handle_route_creation"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_hq_iata" character varying, "p_target_fleet_cap" integer, "p_target_price_mult" numeric, "p_target_sched_ratio" numeric, "p_target_distance" double precision, "p_threshold" numeric, "p_secondary_hub_chance" numeric) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_idle_id UUID;
    v_idle_range NUMERIC;
    v_speed NUMERIC;
    v_capacity INT;
    v_economy INT;
    v_business INT;
    v_first INT;
    v_route_count INT;
    v_idle_count INT;
    v_change_allowed BOOLEAN;
    v_origin_iata VARCHAR(3);
    v_dest_iata VARCHAR(3);
    v_distance DOUBLE PRECISION;
    v_base_fare NUMERIC;
    v_target_price NUMERIC;
    v_max_flights INT;
    v_target_flights INT;
    v_attempts INT;
    v_inserted BOOLEAN;
    v_creation_bias NUMERIC;
    v_ticket_base_fare NUMERIC;
    v_ticket_per_km_rate NUMERIC;
BEGIN
    SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = p_bot_id AND status = 'active';

    SELECT COUNT(*)::INT INTO v_idle_count
    FROM fleet_aircraft f
    WHERE f.user_id = p_bot_id AND f.status = 'active' AND f.condition >= p_threshold
      AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);

    SELECT last_route_change_at IS NULL OR last_route_change_at <= p_game_time - INTERVAL '8 hours'
    INTO v_change_allowed FROM bot_profiles WHERE user_id = p_bot_id;

    v_creation_bias := CASE WHEN p_distress = 'cautious' THEN 0.45 ELSE 0.70 END;

    IF v_idle_count = 0 OR v_route_count >= p_target_fleet_cap
       OR NOT v_change_allowed OR p_distress = 'desperate'
       OR random() >= v_creation_bias THEN
        RETURN;
    END IF;

    v_ticket_base_fare := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
    v_ticket_per_km_rate := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);

    -- Select idle aircraft
    SELECT f.id, m.range_km, m.speed_kmh, m.capacity, m.economy_seats, m.business_seats, m.first_class_seats
    INTO v_idle_id, v_idle_range, v_speed, v_capacity, v_economy, v_business, v_first
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.user_id = p_bot_id AND f.status = 'active' AND f.condition >= p_threshold
      AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id)
    LIMIT 1;

    IF v_idle_id IS NULL THEN RETURN; END IF;

    -- Secondary hub logic
    IF v_route_count >= 3 AND random() < p_secondary_hub_chance THEN
        SELECT r.destination_iata INTO v_origin_iata
        FROM route_assignments r WHERE r.user_id = p_bot_id AND r.status = 'active'
        ORDER BY random() LIMIT 1;
    ELSE
        v_origin_iata := p_hq_iata;
    END IF;

    -- Find destination
    v_inserted := false;
    v_attempts := 0;
    WHILE NOT v_inserted AND v_attempts < 20 LOOP
        v_attempts := v_attempts + 1;

        SELECT a.iata, haversine_distance(
            (SELECT latitude FROM airports WHERE iata = v_origin_iata),
            (SELECT longitude FROM airports WHERE iata = v_origin_iata),
            a.latitude, a.longitude
        ) INTO v_dest_iata, v_distance
        FROM airports a
        WHERE a.iata <> v_origin_iata
          AND haversine_distance(
              (SELECT latitude FROM airports WHERE iata = v_origin_iata),
              (SELECT longitude FROM airports WHERE iata = v_origin_iata),
              a.latitude, a.longitude
          ) <= v_idle_range
        ORDER BY a.demand_index DESC, random() LIMIT 1;

        IF v_dest_iata IS NOT NULL THEN
            v_base_fare := v_ticket_base_fare + (v_distance * v_ticket_per_km_rate);
            v_target_price := v_base_fare * p_target_price_mult;
            v_max_flights := calculate_route_max_weekly_flights(v_distance, v_speed);
            v_target_flights := GREATEST(1, FLOOR(v_max_flights * p_target_sched_ratio));
            IF p_distress = 'cautious' THEN
                v_target_flights := GREATEST(1, FLOOR(v_target_flights * 0.85));
            END IF;

            PERFORM create_actor_route_assignment(p_bot_id, v_origin_iata, v_dest_iata, v_distance,
                v_target_price, v_target_flights, v_idle_id);

            IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_bot_id AND origin_iata = v_origin_iata AND destination_iata = v_dest_iata AND status = 'active') THEN
                v_inserted := true;
                UPDATE bot_profiles SET last_route_change_at = p_game_time WHERE user_id = p_bot_id;
            END IF;
        END IF;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."bot_handle_route_creation"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_hq_iata" character varying, "p_target_fleet_cap" integer, "p_target_price_mult" numeric, "p_target_sched_ratio" numeric, "p_target_distance" double precision, "p_threshold" numeric, "p_secondary_hub_chance" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bot_handle_route_lifecycle"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_target_price_mult" numeric, "p_loss_days_thresh" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_route_count INT;
    v_route_change_allowed BOOLEAN;
    v_route_audit_allowed BOOLEAN;
    v_route_opt_allowed BOOLEAN;
    v_all_profitable BOOLEAN;
    v_any_profitable BOOLEAN;
    v_loss_days INT;
    v_worst_id UUID;
    v_worst_profit NUMERIC;
    v_selected_id UUID;
    v_selected_flights INT;
    v_selected_base_fare NUMERIC;
    v_trim_threshold INT;
    v_floor INT;
    v_reduction INT;
    v_price_adj NUMERIC;
    v_ticket_base_fare NUMERIC;
    v_ticket_per_km_rate NUMERIC;
    v_target_price NUMERIC;
    v_target_flights INT;
BEGIN
    SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = p_bot_id AND status = 'active';
    IF v_route_count = 0 THEN RETURN; END IF;

    -- Check cooldowns
    SELECT
        last_route_change_at IS NULL OR last_route_change_at <= p_game_time - INTERVAL '8 hours',
        last_route_audit_at IS NULL OR last_route_audit_at <= p_game_time - INTERVAL '4 hours',
        last_route_optimization_at IS NULL OR last_route_optimization_at <= p_game_time - INTERVAL '24 hours'
    INTO v_route_change_allowed, v_route_audit_allowed, v_route_opt_allowed
    FROM bot_profiles WHERE user_id = p_bot_id;

    v_ticket_base_fare := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
    v_ticket_per_km_rate := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);

    -- Phase A: Route audit (smart deletion based on performance)
    IF v_route_audit_allowed THEN
        v_all_profitable := true;
        v_any_profitable := false;

        FOR v_worst_id, v_worst_profit IN
            SELECT route_id, weekly_profit FROM get_route_performance(p_bot_id)
        LOOP
            IF v_worst_profit < 0 THEN v_all_profitable := false;
            ELSE v_any_profitable := true; END IF;
        END LOOP;

        IF v_all_profitable AND v_route_count > 0 THEN
            UPDATE bot_profiles SET consecutive_loss_days = 0 WHERE user_id = p_bot_id;
        ELSIF NOT v_any_profitable AND v_route_count > 0 THEN
            UPDATE bot_profiles SET consecutive_loss_days = consecutive_loss_days + 1 WHERE user_id = p_bot_id;
        END IF;

        SELECT consecutive_loss_days INTO v_loss_days FROM bot_profiles WHERE user_id = p_bot_id;
        IF COALESCE(v_loss_days, 0) >= p_loss_days_thresh AND v_route_change_allowed THEN
            SELECT route_id INTO v_worst_id FROM get_route_performance(p_bot_id) ORDER BY weekly_profit ASC LIMIT 1;
            IF v_worst_id IS NOT NULL THEN
                PERFORM delete_actor_route_assignment(p_bot_id, v_worst_id, false);
                UPDATE bot_profiles SET last_route_change_at = p_game_time, consecutive_loss_days = 0 WHERE user_id = p_bot_id;
            END IF;
        END IF;

        UPDATE bot_profiles SET last_route_audit_at = p_game_time WHERE user_id = p_bot_id;
    END IF;

    -- Phase B: Distress-driven route trim/delete
    IF p_distress IN ('cautious', 'defensive', 'desperate') AND v_route_change_allowed THEN
        IF p_distress = 'desperate' OR p_distress = 'defensive' OR (p_distress = 'cautious' AND random() < 0.45) THEN
            SELECT r.id, r.flights_per_week,
                   COALESCE(calculate_route_base_fare(r.distance_km), v_ticket_base_fare + r.distance_km * v_ticket_per_km_rate)
            INTO v_selected_id, v_selected_flights, v_selected_base_fare
            FROM route_assignments r
            WHERE r.user_id = p_bot_id AND r.status = 'active'
            ORDER BY (r.ticket_price / GREATEST(COALESCE(calculate_route_base_fare(r.distance_km), 1), 1)) DESC,
                     r.flights_per_week DESC LIMIT 1;

            IF v_selected_id IS NOT NULL THEN
                IF p_distress = 'desperate' THEN
                    v_trim_threshold := 6; v_floor := 4; v_reduction := 6; v_price_adj := 0.88;
                ELSIF p_distress = 'defensive' THEN
                    v_trim_threshold := 8; v_floor := 6; v_reduction := 4; v_price_adj := 0.92;
                ELSE
                    v_trim_threshold := 10; v_floor := 6; v_reduction := 2; v_price_adj := 0.96;
                END IF;

                IF v_selected_flights > v_trim_threshold THEN
                    v_target_price := LEAST(v_selected_base_fare * p_target_price_mult,
                        (SELECT ticket_price FROM route_assignments WHERE id = v_selected_id) * v_price_adj);
                    v_target_flights := GREATEST(v_floor, v_selected_flights - v_reduction);
                    PERFORM update_actor_route_economics(p_bot_id, v_selected_id, v_target_price, v_target_flights);
                    UPDATE bot_profiles SET last_route_change_at = p_game_time WHERE user_id = p_bot_id;
                ELSIF v_selected_flights <= v_trim_threshold AND p_distress = 'desperate' THEN
                    PERFORM delete_actor_route_assignment(p_bot_id, v_selected_id, false);
                    UPDATE bot_profiles SET last_route_change_at = p_game_time WHERE user_id = p_bot_id;
                END IF;
            END IF;
        END IF;
    END IF;

    -- Phase C: Route optimization (reassign underperforming aircraft)
    IF v_route_opt_allowed AND p_distress NOT IN ('desperate') THEN
        SELECT route_id, weekly_profit INTO v_worst_id, v_worst_profit
        FROM get_route_performance(p_bot_id) ORDER BY weekly_profit ASC LIMIT 1;

        IF v_worst_id IS NOT NULL AND v_worst_profit < 0 THEN
            PERFORM delete_actor_route_assignment(p_bot_id, v_worst_id, false);
            UPDATE bot_profiles SET last_route_optimization_at = p_game_time WHERE user_id = p_bot_id;
        END IF;
    END IF;
END;
$$;


ALTER FUNCTION "public"."bot_handle_route_lifecycle"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_target_price_mult" numeric, "p_loss_days_thresh" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_synthetic_auth_email"("p_username" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
    SELECT public.normalize_username(p_username) || '@skyward.sachiel.id';
$$;


ALTER FUNCTION "public"."build_synthetic_auth_email"("p_username" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."build_synthetic_auth_email"("p_username" "text") IS 'Builds the synthetic Supabase Auth email address used by the planned username-only login flow.';



CREATE OR REPLACE FUNCTION "public"."calculate_airport_congestion_factor"("p_origin_iata" character varying) RETURNS numeric
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE v_total_flights INT;
BEGIN
    SELECT COALESCE(SUM(flights_per_week), 0) INTO v_total_flights FROM route_assignments WHERE origin_iata = p_origin_iata AND status = 'active';
    IF v_total_flights > 50 THEN RETURN GREATEST(0.50, 1.0 - ((v_total_flights - 50) * 0.005)); END IF;
    RETURN 1.0;
END;
$$;


ALTER FUNCTION "public"."calculate_airport_congestion_factor"("p_origin_iata" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_airport_demand_factor"("p_origin_demand" integer, "p_destination_demand" integer) RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
    SELECT GREATEST(
        COALESCE(get_config_numeric('min_airport_demand_factor'), 0.55),
        LEAST(
            COALESCE(get_config_numeric('max_airport_demand_factor'), 1.00),
            COALESCE(get_config_numeric('min_airport_demand_factor'), 0.55) + (
                ((((COALESCE(p_origin_demand, 50) + COALESCE(p_destination_demand, 50))::NUMERIC) / 2.0) / 100.0)
                * (COALESCE(get_config_numeric('max_airport_demand_factor'), 1.00) - COALESCE(get_config_numeric('min_airport_demand_factor'), 0.55))
            )
        )
    );
$$;


ALTER FUNCTION "public"."calculate_airport_demand_factor"("p_origin_demand" integer, "p_destination_demand" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_credit_score"("p_user_id" "uuid") RETURNS TABLE("total_score" integer, "tier" character varying, "fleet_health" integer, "revenue_stability" integer, "debt_ratio" integer, "cash_reserve" integer, "profit_history" integer)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_user              RECORD;
    v_fleet_count       INT     := 0;
    v_avg_condition     NUMERIC := 100.0;
    v_grounded_ratio    NUMERIC := 0.0;
    v_fleet_health      NUMERIC := 140.0;
    v_revenue_stability NUMERIC := 140.0;
    v_total_debt        NUMERIC := 0.0;
    v_net_worth         NUMERIC := 0.0;
    v_debt_ratio        NUMERIC := 140.0;
    v_cash              NUMERIC := 0.0;
    v_starting_cash     NUMERIC := 15000000.0;
    v_cash_reserve      NUMERIC := 140.0;
    v_total_revenue_30d NUMERIC := 0.0;
    v_total_expense_30d NUMERIC := 0.0;
    v_profit_margin     NUMERIC := 0.0;
    v_profit_history    NUMERIC := 140.0;
    v_total_score       INT;
    v_revenue_stddev    NUMERIC := 0.0;
    v_revenue_avg       NUMERIC := 0.0;
BEGIN
    SELECT u.net_worth, u.game_current_time
      INTO v_user FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        total_score := 500; tier := 'Standard';
        fleet_health := 100; revenue_stability := 100;
        debt_ratio := 100; cash_reserve := 100;
        profit_history := 100;
        RETURN NEXT; RETURN;
    END IF;

    v_cash := get_user_balance(p_user_id);
    v_net_worth := COALESCE(v_user.net_worth, 0.0);
    v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.0);

    SELECT COUNT(*)::INT, COALESCE(AVG(condition), 100.0),
           COALESCE(COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC / NULLIF(COUNT(*), 0), 0.0)
      INTO v_fleet_count, v_avg_condition, v_grounded_ratio
      FROM fleet_aircraft
     WHERE user_id = p_user_id;

    IF v_fleet_count > 0 THEN
        v_fleet_health := LEAST(
            200.0,
            (v_avg_condition / 100.0) * 130.0
            + 50.0 * (1.0 - v_grounded_ratio)
            + LEAST(20.0, v_fleet_count * 2.0)
        );
    ELSE
        v_fleet_health := 70.0;
    END IF;

    SELECT COALESCE(STDDEV(daily_revenue), 0),
           COALESCE(AVG(daily_revenue), 0)
      INTO v_revenue_stddev, v_revenue_avg
      FROM (
          SELECT SUM(amount) AS daily_revenue
          FROM bank_transactions
          WHERE user_id = p_user_id
            AND ifrs_category = 'revenue'
            AND game_date >= v_user.game_current_time - INTERVAL '30 days'
          GROUP BY (game_date AT TIME ZONE 'UTC')::DATE
      ) daily;

    SELECT COALESCE(SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END), 0),
           ABS(COALESCE(SUM(CASE WHEN transaction_type = 'debit' THEN amount ELSE 0 END), 0))
      INTO v_total_revenue_30d, v_total_expense_30d
      FROM bank_transactions
     WHERE user_id = p_user_id
       AND game_date >= v_user.game_current_time - INTERVAL '30 days'
       AND ifrs_category IN ('revenue', 'cogs', 'opex');

    IF v_revenue_avg > 0 THEN
        v_revenue_stability := GREATEST(
            0,
            LEAST(200.0, 170.0 - (v_revenue_stddev / v_revenue_avg * 100.0))
        );
    ELSE
        v_revenue_stability := 60.0;
    END IF;

    SELECT COALESCE(SUM(remaining_balance), 0)
      INTO v_total_debt
      FROM loans
     WHERE user_id = p_user_id
       AND status = 'active';

    IF v_total_debt <= 0 THEN
        IF v_total_revenue_30d > 0 OR v_fleet_count > 0 THEN
            v_debt_ratio := 180.0;
        ELSE
            v_debt_ratio := 130.0;
        END IF;
    ELSIF v_net_worth > 0 THEN
        v_debt_ratio := GREATEST(0, 180.0 - ((v_total_debt / v_net_worth) * 180.0));
    ELSE
        v_debt_ratio := 0.0;
    END IF;

    IF v_starting_cash > 0 THEN
        v_cash_reserve := GREATEST(
            0,
            LEAST(180.0, 60.0 + ((v_cash / v_starting_cash) * 60.0))
        );
    ELSE
        v_cash_reserve := 80.0;
    END IF;
    IF v_total_revenue_30d <= 0 THEN
        v_cash_reserve := LEAST(v_cash_reserve, 130.0);
    END IF;

    IF v_total_revenue_30d > 0 THEN
        v_profit_margin := (v_total_revenue_30d - v_total_expense_30d)
                         / NULLIF(v_total_revenue_30d, 0);
        v_profit_history := LEAST(200.0, GREATEST(20.0, 90.0 + (v_profit_margin * 140.0)));
    ELSE
        v_profit_history := 60.0;
    END IF;

    v_total_score := GREATEST(0, LEAST(1000,
        ROUND(v_fleet_health)
      + ROUND(v_revenue_stability)
      + ROUND(v_debt_ratio)
      + ROUND(v_cash_reserve)
      + ROUND(v_profit_history)
    ));

    total_score := v_total_score;
    tier := resolve_credit_tier(v_total_score);
    fleet_health := ROUND(v_fleet_health)::INT;
    revenue_stability := ROUND(v_revenue_stability)::INT;
    debt_ratio := ROUND(v_debt_ratio)::INT;
    cash_reserve := ROUND(v_cash_reserve)::INT;
    profit_history := ROUND(v_profit_history)::INT;
    RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."calculate_credit_score"("p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."calculate_credit_score"("p_user_id" "uuid") IS 'Computes a 0-1000 credit score. Bot (actor_type=AI) uses same 5-component scoring. Returns total_score, tier, and component breakdown.';



CREATE OR REPLACE FUNCTION "public"."calculate_hub_bonus"("p_origin_iata" character varying, "p_user_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    v_hub_routes_count INT;
BEGIN
    SELECT COUNT(*) INTO v_hub_routes_count
    FROM route_assignments
    WHERE origin_iata = p_origin_iata
      AND user_id = p_user_id
      AND status = 'active';

    IF v_hub_routes_count > 1 THEN
        RETURN 1.0 + LEAST((v_hub_routes_count - 1) * 0.02, 0.20);
    END IF;
    RETURN 1.0;
END;
$$;


ALTER FUNCTION "public"."calculate_hub_bonus"("p_origin_iata" character varying, "p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."calculate_hub_bonus"("p_origin_iata" character varying, "p_user_id" "uuid") IS 'Returns a demand multiplier (1.0–1.20) based on hub-and-spoke effect. 2% bonus per additional active route sharing the same origin, capped at 20%.';



CREATE OR REPLACE FUNCTION "public"."calculate_lease_termination_fee"("p_lease_price_per_month" numeric) RETURNS numeric
    LANGUAGE "sql" IMMUTABLE
    AS $$
    SELECT ROUND(COALESCE(p_lease_price_per_month, 0.00) * 0.25, 2);
$$;


ALTER FUNCTION "public"."calculate_lease_termination_fee"("p_lease_price_per_month" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_required_lease_deposit"("p_purchase_price" numeric, "p_lease_price_per_month" numeric) RETURNS numeric
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_base_pct NUMERIC := COALESCE(get_config_numeric('base_lease_deposit_percentage'), 0.10);
    v_monthly_floor NUMERIC;
    v_asset_pct NUMERIC;
BEGIN
    v_monthly_floor := COALESCE(p_lease_price_per_month, 0) * GREATEST(2.0, v_base_pct * 20.0);

    v_asset_pct := CASE
        WHEN COALESCE(p_purchase_price, 0) < 25000000 THEN 0.02
        WHEN COALESCE(p_purchase_price, 0) < 60000000 THEN 0.03
        WHEN COALESCE(p_purchase_price, 0) < 120000000 THEN 0.05
        ELSE 0.08
    END;

    RETURN ROUND(
        GREATEST(
            v_monthly_floor,
            COALESCE(p_purchase_price, 0) * v_asset_pct
        ),
        2
    );
END;
$$;


ALTER FUNCTION "public"."calculate_required_lease_deposit"("p_purchase_price" numeric, "p_lease_price_per_month" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_route_base_fare"("p_distance_km" double precision) RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
    SELECT COALESCE(get_config_numeric('ticket_base_fare'), 50.0)
         + (COALESCE(p_distance_km, 0.0)::NUMERIC * COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12));
$$;


ALTER FUNCTION "public"."calculate_route_base_fare"("p_distance_km" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_route_demand_multiplier"("p_distance_km" double precision, "p_ticket_price" numeric) RETURNS numeric
    LANGUAGE "sql" IMMUTABLE
    AS $$
    SELECT GREATEST(
        0.00,
        LEAST(
            1.50,
            1.5 - 0.8 * POWER(
                COALESCE(p_ticket_price, 0.00) /
                NULLIF(calculate_route_base_fare(p_distance_km), 0.00),
                2
            )
        )
    );
$$;


ALTER FUNCTION "public"."calculate_route_demand_multiplier"("p_distance_km" double precision, "p_ticket_price" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_route_expected_passengers"("p_capacity" integer, "p_distance_km" double precision, "p_ticket_price" numeric, "p_origin_demand" integer, "p_destination_demand" integer) RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $$
    SELECT GREATEST(
        0,
        LEAST(
            COALESCE(p_capacity, 0),
            FLOOR(
                COALESCE(p_capacity, 0) *
                0.95 *
                calculate_airport_demand_factor(p_origin_demand, p_destination_demand) *
                calculate_route_demand_multiplier(p_distance_km, p_ticket_price)
            )::INT
        )
    );
$$;


ALTER FUNCTION "public"."calculate_route_expected_passengers"("p_capacity" integer, "p_distance_km" double precision, "p_ticket_price" numeric, "p_origin_demand" integer, "p_destination_demand" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_route_expected_passengers"("p_capacity" integer, "p_distance_km" double precision, "p_ticket_price" numeric, "p_origin_demand" integer, "p_destination_demand" integer, "p_origin_iata" character varying, "p_destination_iata" character varying, "p_user_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    v_base_passengers INT;
    v_competitor_count INT;
    v_my_frequency INT;
    v_total_frequency INT;
    v_competition_factor NUMERIC := 1.0;
    v_congestion_factor NUMERIC := 1.0;
    v_hub_bonus NUMERIC := 1.0;
BEGIN
    v_base_passengers := GREATEST(0, LEAST(
        COALESCE(p_capacity, 0),
        FLOOR(COALESCE(p_capacity, 0) * 0.95 *
            calculate_airport_demand_factor(p_origin_demand, p_destination_demand) *
            calculate_route_demand_multiplier(p_distance_km, p_ticket_price)
        )::INT
    ));

    SELECT COUNT(*) INTO v_competitor_count
    FROM route_assignments
    WHERE origin_iata = p_origin_iata
      AND destination_iata = p_destination_iata
      AND status = 'active';

    IF v_competitor_count > 1 THEN
        SELECT COALESCE(flights_per_week, 0) INTO v_my_frequency
        FROM route_assignments
        WHERE origin_iata = p_origin_iata
          AND destination_iata = p_destination_iata
          AND user_id = p_user_id
          AND status = 'active'
        LIMIT 1;

        SELECT COALESCE(SUM(flights_per_week), 1) INTO v_total_frequency
        FROM route_assignments
        WHERE origin_iata = p_origin_iata
          AND destination_iata = p_destination_iata
          AND status = 'active';

        IF v_total_frequency > 0 THEN
            v_competition_factor := v_my_frequency::NUMERIC / v_total_frequency;
        END IF;
    END IF;

    v_congestion_factor := calculate_airport_congestion_factor(p_origin_iata);
    v_hub_bonus := calculate_hub_bonus(p_origin_iata, p_user_id);

    RETURN GREATEST(0, FLOOR(v_base_passengers * v_competition_factor * v_congestion_factor * v_hub_bonus)::INT);
END;
$$;


ALTER FUNCTION "public"."calculate_route_expected_passengers"("p_capacity" integer, "p_distance_km" double precision, "p_ticket_price" numeric, "p_origin_demand" integer, "p_destination_demand" integer, "p_origin_iata" character varying, "p_destination_iata" character varying, "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer) RETURNS integer
    LANGUAGE "sql" STABLE
    AS $$
    SELECT CASE WHEN COALESCE(p_distance_km, 0.0) <= 0.0 OR COALESCE(p_speed_kmh, 0) <= 0 THEN 0
        ELSE FLOOR(COALESCE(get_config_numeric('max_weekly_flights'), 168.0) / ((p_distance_km / p_speed_kmh) + 1.0))::INT END;
$$;


ALTER FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer, "p_turnaround_hours" numeric) RETURNS integer
    LANGUAGE "sql" STABLE
    AS $$
    SELECT CASE WHEN COALESCE(p_distance_km, 0.0) <= 0.0 OR COALESCE(p_speed_kmh, 0) <= 0 THEN 0
        ELSE FLOOR(COALESCE(get_config_numeric('max_weekly_flights'), 168.0) / NULLIF((COALESCE(p_distance_km, 0.0) / p_speed_kmh::DOUBLE PRECISION) + COALESCE(p_turnaround_hours, 1.0), 0.0))::INT END;
$$;


ALTER FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer, "p_turnaround_hours" numeric) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer, "p_turnaround_hours" numeric) IS '3-param overload that accepts per-aircraft turnaround_hours. Used by simulation engine for accurate scheduling capacity.';



CREATE OR REPLACE FUNCTION "public"."calculate_user_net_worth"("p_user_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_cash NUMERIC := 0;
    v_owned_asset_value NUMERIC := 0;
    v_open_loan_balance NUMERIC := 0;
BEGIN
    v_cash := COALESCE(get_user_balance(p_user_id), 0);

    SELECT COALESCE(
        SUM(
            CASE
                WHEN f.acquisition_type IN ('purchase', 'finance')
                    THEN m.purchase_price * (f.condition / 100.00)
                ELSE 0
            END
        ),
        0
    )
    INTO v_owned_asset_value
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.user_id = p_user_id;

    SELECT COALESCE(SUM(l.remaining_balance), 0)
    INTO v_open_loan_balance
    FROM loans l
    WHERE l.user_id = p_user_id
      AND COALESCE(l.remaining_balance, 0) > 0
      AND COALESCE(l.status, 'active') <> 'paid_off';

    RETURN v_cash + v_owned_asset_value - v_open_loan_balance;
END;
$$;


ALTER FUNCTION "public"."calculate_user_net_worth"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_achievements"("p_user_id" "uuid", "p_game_time" timestamp with time zone) RETURNS TABLE("achievement_name" character varying, "achievement_type" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
v_cash NUMERIC; v_net_worth NUMERIC; v_fleet_count INT; v_route_count INT;
v_hub_routes INT; v_has_first_class BOOLEAN; v_distress_recovered BOOLEAN;
BEGIN
v_cash := get_user_balance(p_user_id);
v_net_worth := calculate_user_net_worth(p_user_id);
SELECT COUNT(*) INTO v_fleet_count FROM fleet_aircraft WHERE user_id = p_user_id AND status = 'active';
SELECT COUNT(*) INTO v_route_count FROM route_assignments WHERE user_id = p_user_id AND status = 'active';
SELECT COUNT(*) INTO v_hub_routes FROM route_assignments ra
JOIN users u ON u.id = ra.user_id
WHERE ra.user_id = p_user_id AND ra.origin_iata = u.hq_airport_iata AND ra.status = 'active';
SELECT EXISTS(SELECT 1 FROM fleet_aircraft WHERE user_id = p_user_id AND first_class_seats > 0 AND status = 'active')
INTO v_has_first_class;
SELECT EXISTS(SELECT 1 FROM users WHERE id = p_user_id AND consecutive_negative_days >= 7 AND recovery_streak_days >= 30)
INTO v_distress_recovered;
IF v_cash >= 1000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'cash_millionaire', 'Cash Millionaire', 'Reach $1M in liquid cash', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_net_worth >= 1000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'millionaire', 'Millionaire', 'Net worth exceeds $1M', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_net_worth >= 10000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'multi_millionaire', 'Multi-Millionaire', 'Net worth exceeds $10M', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_net_worth >= 100000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'hundred_million', 'Aviation Mogul', 'Net worth exceeds $100M', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_net_worth >= 1000000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'billionaire', 'Aviation Billionaire', 'Net worth exceeds $1B', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_fleet_count >= 5 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'fleet_builder', 'Fleet Builder', 'Operate 5 active aircraft', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_fleet_count >= 20 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'fleet_empire', 'Fleet Empire', 'Operate 20 active aircraft', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_route_count >= 10 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'network_starter', 'Network Starter', 'Launch 10 active routes', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_route_count >= 50 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'network_empire', 'Network Empire', 'Launch 50 active routes', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_hub_routes >= 8 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'hub_operator', 'Hub Operator', 'Operate 8 routes from your home hub', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_has_first_class THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'premium_service', 'Premium Service', 'Operate an aircraft with first class seats', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_distress_recovered THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'comeback_story', 'Comeback Story', 'Recover from 7 days of distress and sustain 30 days positive operations', p_game_time) ON CONFLICT DO NOTHING; END IF;
RETURN QUERY
SELECT a.achievement_name::VARCHAR, a.achievement_type::VARCHAR
FROM achievements a
WHERE a.user_id = p_user_id
AND a.game_date = p_game_time;
END;
$_$;


ALTER FUNCTION "public"."check_achievements"("p_user_id" "uuid", "p_game_time" timestamp with time zone) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."check_achievements"("p_user_id" "uuid", "p_game_time" timestamp with time zone) IS 'Evaluates all achievement conditions for a player and inserts newly unlocked achievements. Called at the game-day boundary in process_player_simulation_to_time.';



CREATE OR REPLACE FUNCTION "public"."configure_aircraft_seats"("p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM configure_aircraft_seats(v_user_id, p_fleet_id, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$$;


ALTER FUNCTION "public"."configure_aircraft_seats"("p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."configure_aircraft_seats"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_capacity INT; v_slots_used INT;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT m.capacity INTO v_capacity FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = p_fleet_id AND f.user_id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR; RETURN; END IF;
    v_slots_used := p_economy_seats + (p_business_seats * 2) + (p_first_class_seats * 3);
    IF p_economy_seats < 0 OR p_business_seats < 0 OR p_first_class_seats < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR; RETURN; END IF;
    UPDATE fleet_aircraft SET economy_seats = p_economy_seats, business_seats = p_business_seats, first_class_seats = p_first_class_seats WHERE id = p_fleet_id AND user_id = p_user_id;
    RETURN QUERY SELECT TRUE, 'Successfully updated seat configuration!'::VARCHAR;
END;
$$;


ALTER FUNCTION "public"."configure_aircraft_seats"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_route"("p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM create_route(v_user_id, p_origin_iata, p_destination_iata, p_distance_km, p_ticket_price, p_flights_per_week);
END;
$$;


ALTER FUNCTION "public"."create_route"("p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_route"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_actual_distance NUMERIC;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    IF p_origin_iata = p_destination_iata THEN RETURN QUERY SELECT FALSE, 'Origin and destination must be different.'::VARCHAR; RETURN; END IF;
    IF p_distance_km <= 0 OR p_ticket_price <= 0 OR p_flights_per_week < 1 OR p_flights_per_week > 168 THEN RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR; RETURN; END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR; RETURN; END IF;
    IF NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_origin_iata) OR NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_destination_iata) THEN RETURN QUERY SELECT FALSE, 'Route airport not found.'::VARCHAR; RETURN; END IF;
    SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude) INTO v_actual_distance FROM airports o, airports d WHERE o.iata = p_origin_iata AND d.iata = p_destination_iata;
    IF v_actual_distance > 0 AND ABS(p_distance_km - v_actual_distance) / v_actual_distance > 0.10 THEN RETURN QUERY SELECT FALSE, ('Distance validation failed. Expected ~' || ROUND(v_actual_distance, 1)::TEXT || ' km.')::VARCHAR; RETURN; END IF;
    IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND origin_iata = p_origin_iata AND destination_iata = p_destination_iata) THEN RETURN QUERY SELECT FALSE, 'Route already exists.'::VARCHAR; RETURN; END IF;
    INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, flights_per_week) VALUES (p_user_id, p_origin_iata, p_destination_iata, p_distance_km, p_ticket_price, p_flights_per_week);
    RETURN QUERY SELECT TRUE, 'Route established successfully!'::VARCHAR;
END;
$$;


ALTER FUNCTION "public"."create_route"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."credit_bank_account"("p_user_id" "uuid", "p_amount" numeric, "p_ifrs_category" character varying, "p_ifrs_subcategory" character varying, "p_description" "text", "p_game_date" timestamp with time zone) RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
v_account_id UUID;
v_new_balance NUMERIC;
BEGIN
IF COALESCE(p_amount, 0) < 0 THEN
    RAISE EXCEPTION 'Amount must be non-negative: %', p_amount;
END IF;
SELECT id INTO v_account_id
FROM bank_accounts
WHERE user_id = p_user_id AND account_type = 'operating'
LIMIT 1;
IF v_account_id IS NULL THEN
RAISE EXCEPTION 'No operating bank account for user %', p_user_id;
END IF;
IF COALESCE(p_amount, 0) = 0 THEN
    SELECT balance INTO v_new_balance
    FROM bank_accounts
    WHERE id = v_account_id;
    RETURN v_new_balance;
END IF;
UPDATE bank_accounts
SET balance = balance + p_amount
WHERE id = v_account_id
RETURNING balance INTO v_new_balance;
INSERT INTO bank_transactions (
account_id, user_id, transaction_type, amount, balance_after,
description, game_date, ifrs_category, ifrs_subcategory
) VALUES (
v_account_id, p_user_id, 'credit', p_amount, v_new_balance,
p_description, p_game_date, p_ifrs_category, p_ifrs_subcategory
);
RETURN v_new_balance;
END;
$$;


ALTER FUNCTION "public"."credit_bank_account"("p_user_id" "uuid", "p_amount" numeric, "p_ifrs_category" character varying, "p_ifrs_subcategory" character varying, "p_description" "text", "p_game_date" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deactivate_expired_events"("p_game_time" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE game_events
    SET is_active = false
    WHERE is_active = true
      AND end_game_time <= p_game_time;
END;
$$;


ALTER FUNCTION "public"."deactivate_expired_events"("p_game_time" timestamp with time zone) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."deactivate_expired_events"("p_game_time" timestamp with time zone) IS 'Marks expired game_events as inactive. Called from process_world_tick after advancing the clock.';



CREATE OR REPLACE FUNCTION "public"."debit_bank_account"("p_user_id" "uuid", "p_amount" numeric, "p_ifrs_category" character varying, "p_ifrs_subcategory" character varying, "p_description" "text", "p_game_date" timestamp with time zone) RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
v_account_id UUID;
v_new_balance NUMERIC;
BEGIN
IF COALESCE(p_amount, 0) < 0 THEN
    RAISE EXCEPTION 'Amount must be non-negative: %', p_amount;
END IF;
SELECT id INTO v_account_id
FROM bank_accounts
WHERE user_id = p_user_id AND account_type = 'operating'
LIMIT 1;
IF v_account_id IS NULL THEN
RAISE EXCEPTION 'No operating bank account for user %', p_user_id;
END IF;
IF COALESCE(p_amount, 0) = 0 THEN
    SELECT balance INTO v_new_balance
    FROM bank_accounts
    WHERE id = v_account_id;
    RETURN v_new_balance;
END IF;
UPDATE bank_accounts
SET balance = balance - p_amount
WHERE id = v_account_id
RETURNING balance INTO v_new_balance;
INSERT INTO bank_transactions (
account_id, user_id, transaction_type, amount, balance_after,
description, game_date, ifrs_category, ifrs_subcategory
) VALUES (
v_account_id, p_user_id, 'debit', -p_amount, v_new_balance,
p_description, p_game_date, p_ifrs_category, p_ifrs_subcategory
);
RETURN v_new_balance;
END;
$$;


ALTER FUNCTION "public"."debit_bank_account"("p_user_id" "uuid", "p_amount" numeric, "p_ifrs_category" character varying, "p_ifrs_subcategory" character varying, "p_description" "text", "p_game_date" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_account"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
v_user_id UUID;
BEGIN
v_user_id := require_current_user_id();
DELETE FROM bank_transactions WHERE user_id = v_user_id;
DELETE FROM bank_accounts WHERE user_id = v_user_id;
DELETE FROM achievements WHERE user_id = v_user_id;
DELETE FROM credit_score_history WHERE user_id = v_user_id;
DELETE FROM credit_scores WHERE user_id = v_user_id;
DELETE FROM route_assignments WHERE user_id = v_user_id;
DELETE FROM loans WHERE user_id = v_user_id;
DELETE FROM fleet_aircraft WHERE user_id = v_user_id;
DELETE FROM bot_profiles WHERE user_id = v_user_id;
DELETE FROM users WHERE id = v_user_id;
RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."delete_account"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_route"("p_route_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM delete_route(v_user_id, p_route_id);
END;
$$;


ALTER FUNCTION "public"."delete_route"("p_route_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_route"("p_user_id" "uuid", "p_route_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_assigned_aircraft_id UUID;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT assigned_aircraft_id INTO v_assigned_aircraft_id FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR; RETURN; END IF;
    IF v_assigned_aircraft_id IS NOT NULL THEN UPDATE fleet_aircraft SET status = 'grounded' WHERE id = v_assigned_aircraft_id AND user_id = p_user_id; END IF;
    DELETE FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id;
    RETURN QUERY SELECT TRUE, 'Route closed and aircraft grounded successfully!'::VARCHAR;
END;
$$;


ALTER FUNCTION "public"."delete_route"("p_user_id" "uuid", "p_route_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_world_current"("p_season_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("season_id" "uuid", "ticks_processed" integer, "game_time_after" timestamp with time zone, "players_processed" integer, "bots_processed" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_season_id UUID;
    v_ticks INT := 0;
    r_result RECORD;
    v_current_game_time TIMESTAMPTZ;
BEGIN
    IF p_season_id IS NOT NULL THEN v_season_id := p_season_id;
    ELSE SELECT id INTO v_season_id FROM season_clock WHERE status = 'active' ORDER BY created_at ASC LIMIT 1;
    END IF;
    IF v_season_id IS NULL THEN RETURN; END IF;

    LOOP
        SELECT * INTO r_result FROM process_world_tick(v_season_id, 1) LIMIT 1;
        v_ticks := v_ticks + 1;
        IF v_ticks >= 100 THEN EXIT; END IF;
        SELECT current_game_time INTO v_current_game_time FROM season_clock WHERE id = v_season_id;
        EXIT WHEN v_current_game_time >= now();
    END LOOP;

    IF r_result IS NOT NULL THEN
        season_id := r_result.season_id;
        ticks_processed := r_result.ticks_processed;
        game_time_after := r_result.game_time_after;
        players_processed := r_result.players_processed;
        bots_processed := r_result.bots_processed;
        RETURN NEXT;
    END IF;
END;
$$;


ALTER FUNCTION "public"."ensure_world_current"("p_season_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."execute_bot_decisions"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    r_bot RECORD;
    v_bot_cash NUMERIC;
    v_starting_cash NUMERIC;
    v_bankruptcy_threshold NUMERIC;
    v_bot_repair_cash_reserve NUMERIC;
    v_purchase_cash_multiplier NUMERIC;
    v_competitive_price_threshold NUMERIC;
    v_recovery_loan_amount NUMERIC;
    v_loan_repayment_ratio NUMERIC;
    v_loss_days_threshold INT;
    v_secondary_hub_chance NUMERIC;
    v_fleet_diversity_chance NUMERIC;
    v_effective_threshold NUMERIC;

    -- Sub-function outputs
    v_distress VARCHAR;
    v_target_fleet_cap INT;
    v_min_cash_reserve NUMERIC;
    v_growth_chance NUMERIC;
    v_target_distance DOUBLE PRECISION;
    v_target_price_mult NUMERIC;
    v_target_sched_ratio NUMERIC;

    v_error_msg TEXT;
    v_bot_season_id UUID;
    v_spawned_id UUID;
BEGIN
    -- Load global config
    v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
    v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);
    v_bot_repair_cash_reserve := COALESCE(get_config_numeric('bot_repair_cash_reserve'), 500000.00);
    v_purchase_cash_multiplier := COALESCE(get_config_numeric('bot_purchase_cash_multiplier'), 1.5);
    v_competitive_price_threshold := COALESCE(get_config_numeric('bot_competitive_price_threshold'), 0.20);
    v_recovery_loan_amount := COALESCE(get_config_numeric('bot_recovery_loan_amount'), 2000000.0);
    v_loan_repayment_ratio := COALESCE(get_config_numeric('bot_loan_repayment_ratio'), 0.20);
    v_loss_days_threshold := COALESCE(get_config_numeric('bot_consecutive_loss_days_threshold'), 7)::INT;
    v_secondary_hub_chance := COALESCE(get_config_numeric('bot_secondary_hub_chance'), 0.20);
    v_fleet_diversity_chance := COALESCE(get_config_numeric('bot_fleet_diversity_chance'), 0.30);

    SELECT id INTO v_bot_season_id FROM season_clock WHERE status = 'active' LIMIT 1;

    FOR r_bot IN
        SELECT u.*, COALESCE(bp.archetype, 'Balanced') AS archetype,
               bp.consecutive_loss_days, bp.secondary_hub_iata, bp.recovery_loan_taken,
               COALESCE(bp.distress_stage, 'stable') AS profile_distress_stage
        FROM users u
        LEFT JOIN bot_profiles bp ON bp.user_id = u.id
        WHERE u.actor_type = 'AI' AND u.operational_status != 'Bankrupt'
    LOOP
    BEGIN
        v_bot_cash := get_user_balance(r_bot.id);
        v_effective_threshold := GREATEST(30.00, COALESCE(r_bot.auto_grounding_threshold, 40.00));

        -- Bankruptcy check
        IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < v_bankruptcy_threshold THEN
            PERFORM apply_actor_bankruptcy_state(r_bot.id);
            UPDATE bot_profiles SET distress_stage = 'desperate' WHERE user_id = r_bot.id;
            CONTINUE;
        END IF;

        -- Evaluate distress + archetype params
        SELECT * INTO v_distress, v_target_fleet_cap, v_min_cash_reserve,
            v_growth_chance, v_target_distance, v_target_price_mult, v_target_sched_ratio
        FROM bot_evaluate_distress(r_bot.id, r_bot.game_current_time, r_bot.archetype,
            COALESCE(r_bot.consecutive_negative_days, 0),
            CASE WHEN v_starting_cash > 0 THEN v_bot_cash / v_starting_cash ELSE 0 END);

        -- Repair
        PERFORM bot_handle_repair(r_bot.id, r_bot.game_current_time, v_distress, v_effective_threshold, v_bot_repair_cash_reserve);
        v_bot_cash := get_user_balance(r_bot.id);

        -- Route lifecycle (audit + trim + optimization)
        PERFORM bot_handle_route_lifecycle(r_bot.id, r_bot.game_current_time, v_distress, v_target_price_mult, v_loss_days_threshold);

        -- Fleet growth (lease + purchase)
        PERFORM bot_handle_fleet_growth(r_bot.id, r_bot.game_current_time, r_bot.archetype, v_distress,
            v_bot_cash, v_starting_cash, v_target_fleet_cap, v_min_cash_reserve, v_growth_chance,
            v_target_distance, v_purchase_cash_multiplier, v_fleet_diversity_chance);
        v_bot_cash := get_user_balance(r_bot.id);

        -- Route creation (kept inline due to secondary hub complexity)
        PERFORM bot_handle_route_creation(r_bot.id, r_bot.game_current_time, r_bot.archetype, v_distress,
            r_bot.hq_airport_iata, v_target_fleet_cap, v_target_price_mult, v_target_sched_ratio,
            v_target_distance, v_effective_threshold, v_secondary_hub_chance);
        v_bot_cash := get_user_balance(r_bot.id);

        -- Pricing review
        PERFORM bot_handle_pricing(r_bot.id, r_bot.game_current_time, r_bot.archetype, v_distress,
            v_target_price_mult, v_competitive_price_threshold);

        -- Financial management (loan repayment + request)
        PERFORM bot_handle_financial(r_bot.id, r_bot.game_current_time, v_distress, v_bot_cash,
            v_starting_cash, v_min_cash_reserve, v_loan_repayment_ratio, v_recovery_loan_amount);

        -- Last active timestamp
        UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;

    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error_msg = MESSAGE_TEXT;
        INSERT INTO world_tick_log (season_id, status, message, started_at, finished_at)
        VALUES (v_bot_season_id, 'bot_error', 'Bot ' || r_bot.id || ' error: ' || v_error_msg, now(), now());
    END;
    END LOOP;

    -- Post-loop: spawn replacement if needed
    IF (SELECT COUNT(*) FROM users WHERE actor_type = 'AI'
        AND COALESCE(operational_status, 'Active') != 'Bankrupt') <
       COALESCE(get_config_int('max_bot_count'), 5) THEN
        v_spawned_id := spawn_bot();
    END IF;
END;
$$;


ALTER FUNCTION "public"."execute_bot_decisions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."finance_aircraft"("p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric DEFAULT 0.20, "p_term_months" integer DEFAULT 36) RETURNS TABLE("success" boolean, "message" "text", "new_cash" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := require_current_user_id();
    RETURN QUERY SELECT * FROM finance_aircraft(v_user_id, p_aircraft_model_id, p_down_payment_pct, p_term_months);
END;
$$;


ALTER FUNCTION "public"."finance_aircraft"("p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."finance_aircraft"("p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) IS 'Finance an aircraft purchase with a down payment and monthly installments. Creates fleet entry and financing record. Credit tier determines rate and limits.';



CREATE OR REPLACE FUNCTION "public"."finance_aircraft"("p_user_id" "uuid", "p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric DEFAULT 0.20, "p_term_months" integer DEFAULT 36) RETURNS TABLE("success" boolean, "message" "text", "new_cash" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
    v_actor_type VARCHAR(10);
    v_model RECORD;
    v_credit_score INT;
    v_score_record RECORD;
    v_tier VARCHAR(10);
    v_tier_cfg JSONB;
    v_purchase_price NUMERIC;
    v_down_payment NUMERIC;
    v_principal NUMERIC;
    v_interest_rate NUMERIC;
    v_monthly_payment NUMERIC;
    v_weekly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_fleet_id UUID;
    v_hq_iata VARCHAR(3);
    v_max_financing NUMERIC;
    v_economy_seats INT;
    v_business_seats INT;
    v_first_seats INT;
    v_archetype VARCHAR(30);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT *
    INTO v_model
    FROM aircraft_models
    WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_purchase_price := v_model.purchase_price;

    SELECT u.actor_type, u.game_current_time, u.hq_airport_iata
    INTO v_actor_type, v_game_time, v_hq_iata
    FROM users u
    WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    IF v_actor_type = 'AI' THEN
        SELECT COALESCE(bp.archetype, 'Balanced')
        INTO v_archetype
        FROM bot_profiles bp
        WHERE bp.user_id = p_user_id;
        IF NOT FOUND THEN
            v_archetype := 'Balanced';
        END IF;
    END IF;

    v_cash := get_user_balance(p_user_id);
    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
    v_credit_score := COALESCE(v_credit_score, 500);

    SELECT * INTO v_score_record FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF FOUND THEN
        v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE
        v_tier := resolve_credit_tier(v_credit_score);
    END IF;
    v_tier := COALESCE(v_tier, 'Standard');
    v_tier_cfg := get_credit_tier_policy(v_tier);

    v_max_financing := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
    v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.10);

    IF v_purchase_price > v_max_financing THEN
        RETURN QUERY SELECT false, 'Aircraft price ($' || v_purchase_price::TEXT || ') exceeds your financing limit ($' || v_max_financing::TEXT || ') for tier ' || v_tier || '.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;
    IF p_term_months NOT IN (12, 24, 36, 48, 60) THEN
        RETURN QUERY SELECT false, 'Financing term must be 12, 24, 36, 48, or 60 months.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;
    IF p_down_payment_pct < 0.10 OR p_down_payment_pct > 0.50 THEN
        RETURN QUERY SELECT false, 'Down payment must be between 10% and 50%.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_total_repayable := v_principal * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;
    v_weekly_payment := v_monthly_payment / 4.33;

    IF v_cash < v_down_payment THEN
        RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    PERFORM debit_bank_account(
        p_user_id,
        v_down_payment,
        'investing',
        'aircraft_purchase_deposit',
        'Aircraft financing down payment — ' || v_model.model_name,
        v_game_time
    );

    IF v_actor_type = 'AI' THEN
        v_economy_seats := CASE
            WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.80)::INT
            WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)::INT
            ELSE FLOOR(v_model.capacity * 0.50)::INT
        END;
        v_business_seats := CASE
            WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.15)::INT
            WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)::INT
            ELSE FLOOR(v_model.capacity * 0.30)::INT
        END;
        v_first_seats := v_model.capacity - v_economy_seats - v_business_seats;

        INSERT INTO fleet_aircraft (
            user_id, aircraft_model_id, nickname, tail_number, acquisition_type,
            condition, status, economy_seats, business_seats, first_class_seats
        )
        VALUES (
            p_user_id,
            p_aircraft_model_id,
            v_model.model_name,
            generate_tail_number(COALESCE(v_hq_iata, 'CGK')),
            'finance',
            100.00,
            'active',
            v_economy_seats,
            v_business_seats,
            v_first_seats
        )
        RETURNING id INTO v_fleet_id;

        INSERT INTO loans (
            user_id, principal, interest_rate, remaining_balance, weekly_payment,
            status, loan_type, collateral_aircraft_id, term_months, monthly_payment,
            originated_game_date
        )
        VALUES (
            p_user_id,
            v_principal,
            v_interest_rate,
            v_total_repayable,
            v_weekly_payment,
            'active',
            'aircraft_financing',
            v_fleet_id,
            p_term_months,
            v_monthly_payment,
            v_game_time
        );

        v_cash := get_user_balance(p_user_id);
        RETURN QUERY SELECT true, 'Aircraft financed (bot).'::TEXT, v_cash;
        RETURN;
    END IF;

    INSERT INTO fleet_aircraft (
        user_id, aircraft_model_id, nickname, tail_number, acquisition_type,
        condition, status, economy_seats, business_seats, first_class_seats
    )
    VALUES (
        p_user_id,
        p_aircraft_model_id,
        v_model.model_name,
        generate_tail_number(COALESCE(v_hq_iata, 'CGK')),
        'finance',
        100.00,
        'active',
        v_model.capacity,
        0,
        0
    )
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance, weekly_payment,
        status, loan_type, collateral_aircraft_id, term_months, monthly_payment,
        originated_game_date
    )
    VALUES (
        p_user_id,
        v_principal,
        v_interest_rate,
        v_total_repayable,
        v_weekly_payment,
        'active',
        'aircraft_financing',
        v_fleet_id,
        p_term_months,
        v_monthly_payment,
        v_game_time
    );

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$_$;


ALTER FUNCTION "public"."finance_aircraft"("p_user_id" "uuid", "p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."finance_aircraft"("p_user_id" "uuid", "p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) IS 'Finance an aircraft for a specific user. Bot (actor_type=AI) uses simplified 5% rate. Player uses credit-tier logic.';



CREATE OR REPLACE FUNCTION "public"."generate_ceo_name"() RETURNS character varying
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_first_names TEXT[] := ARRAY[
        'James', 'Maria', 'Chen', 'Ahmed', 'Yuki', 'Carlos', 'Priya', 'David',
        'Sophie', 'Kim', 'Rafael', 'Aisha', 'Hans', 'Mei', 'Diego', 'Fatima',
        'Erik', 'Sakura', 'Omar', 'Isabella', 'Ravi', 'Anna', 'Wei', 'Hassan',
        'Elena', 'Takeshi', 'Marco', 'Lina', 'Viktor', 'Nadia'
    ];
    v_last_names TEXT[] := ARRAY[
        'Anderson', 'Tanaka', 'Müller', 'Santos', 'Park', 'Singh', 'Chen', 'Ali',
        'Sato', 'Garcia', 'Kim', 'Patel', 'Fischer', 'Nakamura', 'Silva', 'Hassan',
        'Bergström', 'Yamamoto', 'Fernandez', 'Lee', 'Sharma', 'Petrov', 'Wang',
        'Ibrahim', 'Johansson', 'Kobayashi', 'Rossi', 'Zhang', 'Nguyen', 'Cohen'
    ];
BEGIN
    RETURN v_first_names[1 + floor(random() * array_length(v_first_names, 1))] || ' ' ||
           v_last_names[1 + floor(random() * array_length(v_last_names, 1))];
END;
$$;


ALTER FUNCTION "public"."generate_ceo_name"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_company_name"("p_archetype" character varying) RETURNS character varying
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_prefixes TEXT[] := ARRAY[
        'Pacific', 'Atlas', 'Eagle', 'Nova', 'Apex', 'Summit', 'Horizon', 'Zenith',
        'Sterling', 'Phoenix', 'Titan', 'Vanguard', 'Sovereign', 'Pinnacle', 'Crest',
        'Falcon', 'Meridian', 'Aurora', 'Comet', 'Star', 'Sky', 'Air', 'Jet', 'Swift'
    ];
    v_suffixes TEXT[] := ARRAY[
        'Airways', 'Air', 'Airlines', 'Aviation', 'Air Lines', 'Express', 'Air Services'
    ];
    v_regional_suffixes TEXT[] := ARRAY[
        'Regional', 'Air Express', 'Commuter', 'Air Link', 'Connect'
    ];
    v_premium_suffixes TEXT[] := ARRAY[
        'International', 'World', 'Global', 'Airways International', 'Premium'
    ];
    v_name VARCHAR;
BEGIN
    v_name := v_prefixes[1 + floor(random() * array_length(v_prefixes, 1))];

    CASE p_archetype
        WHEN 'Regional' THEN
            v_name := v_name || ' ' || v_regional_suffixes[1 + floor(random() * array_length(v_regional_suffixes, 1))];
        WHEN 'Aggressive' THEN
            v_name := v_name || ' ' || v_suffixes[1 + floor(random() * array_length(v_suffixes, 1))];
        WHEN 'Balanced' THEN
            v_name := v_name || ' ' || v_premium_suffixes[1 + floor(random() * array_length(v_premium_suffixes, 1))];
        ELSE
            v_name := v_name || ' ' || v_suffixes[1 + floor(random() * array_length(v_suffixes, 1))];
    END CASE;

    RETURN v_name;
END;
$$;


ALTER FUNCTION "public"."generate_company_name"("p_archetype" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_game_events"("p_game_time" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."generate_game_events"("p_game_time" timestamp with time zone) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."generate_game_events"("p_game_time" timestamp with time zone) IS 'Generates random game events with 5% probability per tick. Called from process_world_tick after advancing the clock.';



CREATE OR REPLACE FUNCTION "public"."generate_tail_number"("p_airport_iata" character varying) RETURNS character varying
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_prefix VARCHAR;
    v_rand VARCHAR := '';
    v_chars VARCHAR := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
BEGIN
    v_prefix := get_hq_prefix(p_airport_iata);
    FOR i IN 1..3 LOOP
        v_rand := v_rand || substr(v_chars, floor(random() * 26 + 1)::int, 1);
    END LOOP;
    RETURN v_prefix || v_rand;
END;
$$;


ALTER FUNCTION "public"."generate_tail_number"("p_airport_iata" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_bot_health"() RETURNS TABLE("bot_id" "uuid", "username" character varying, "archetype" character varying, "bot_status" character varying, "cash" numeric, "fleet_count" bigint, "route_count" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        u.id,
        u.username,
        COALESCE(bp.archetype, 'Unknown')::VARCHAR,
        COALESCE(u.operational_status, 'Active')::VARCHAR,
        COALESCE(get_user_balance(u.id), 0),
        (SELECT COUNT(*) FROM fleet_aircraft fa WHERE fa.user_id = u.id),
        (SELECT COUNT(*) FROM route_assignments ra WHERE ra.user_id = u.id AND ra.status = 'active')
    FROM users u
    LEFT JOIN bot_profiles bp ON bp.user_id = u.id
    WHERE u.actor_type = 'AI'
    ORDER BY COALESCE(u.operational_status, 'Active'), u.username;
END;
$$;


ALTER FUNCTION "public"."get_bot_health"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_competitor_insights"("p_id" "uuid", "p_is_bot" boolean DEFAULT false) RETURNS TABLE("company_name" character varying, "ceo_name" character varying, "net_worth" numeric, "fleet_size" integer, "route_count" integer, "monthly_revenue" numeric, "operational_status" character varying, "hq_airport_iata" character varying, "distress_stage" character varying, "consecutive_negative_days" integer, "recovery_streak_days" integer)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        u.company_name,
        u.ceo_name,
        calculate_user_net_worth(u.id) AS net_worth,
        (SELECT COUNT(*)::INT FROM fleet_aircraft f WHERE f.user_id = u.id) AS fleet_size,
        (SELECT COUNT(*)::INT FROM route_assignments r WHERE r.user_id = u.id AND r.status = 'active') AS route_count,
        0::NUMERIC AS monthly_revenue,
        u.operational_status,
        u.hq_airport_iata,
        COALESCE(bp.distress_stage, 'stable')::VARCHAR AS distress_stage,
        COALESCE(u.consecutive_negative_days, 0) AS consecutive_negative_days,
        COALESCE(u.recovery_streak_days, 0) AS recovery_streak_days
    FROM users u
    LEFT JOIN bot_profiles bp ON bp.user_id = u.id
    WHERE u.id = p_id;
END;
$$;


ALTER FUNCTION "public"."get_competitor_insights"("p_id" "uuid", "p_is_bot" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_config_int"("p_key" "text") RETURNS integer
    LANGUAGE "sql" STABLE
    AS $$
    SELECT (value #>> '{}')::int FROM game_config WHERE key = p_key;
$$;


ALTER FUNCTION "public"."get_config_int"("p_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_config_jsonb"("p_key" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
    SELECT value FROM game_config WHERE key = p_key;
$$;


ALTER FUNCTION "public"."get_config_jsonb"("p_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_config_numeric"("p_key" "text") RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
    SELECT (value #>> '{}')::numeric FROM game_config WHERE key = p_key;
$$;


ALTER FUNCTION "public"."get_config_numeric"("p_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_credit_report"() RETURNS TABLE("current_score" integer, "fleet_health" integer, "revenue_stability" integer, "debt_ratio" integer, "cash_reserve" integer, "profit_history" integer, "credit_tier" character varying, "max_unsecured_loan" numeric, "max_secured_loan" numeric, "max_financing_amount" numeric, "base_interest_rate" numeric, "unsecured_interest_rate" numeric, "secured_interest_rate" numeric, "min_loan_amount" numeric, "max_active_loans" integer, "suggestions" "text"[])
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_user_id UUID;
    v_score RECORD;
    v_tier_cfg JSONB;
    v_config JSONB;
BEGIN
    v_user_id := require_current_user_id();

    SELECT value INTO v_config
    FROM game_config
    WHERE key = 'credit_tier_config';

    SELECT * INTO v_score
    FROM calculate_credit_score(v_user_id)
    LIMIT 1;

    IF NOT FOUND THEN
        current_score := 500;
        fleet_health := 100;
        revenue_stability := 100;
        debt_ratio := 100;
        cash_reserve := 100;
        profit_history := 100;
        credit_tier := 'Standard';
        max_unsecured_loan := 5000000;
        max_secured_loan := 25000000;
        max_financing_amount := 25000000;
        base_interest_rate := 0.12;
        unsecured_interest_rate := 0.12;
        secured_interest_rate := 0.10;
        min_loan_amount := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
        max_active_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);
        suggestions := ARRAY['Build your fleet and routes to establish credit history.'];
        RETURN NEXT;
        RETURN;
    END IF;

    current_score := v_score.total_score;
    fleet_health := v_score.fleet_health;
    revenue_stability := v_score.revenue_stability;
    debt_ratio := v_score.debt_ratio;
    cash_reserve := v_score.cash_reserve;
    profit_history := v_score.profit_history;
    credit_tier := resolve_credit_tier(v_score.total_score);
    v_tier_cfg := get_credit_tier_policy(credit_tier);

    max_unsecured_loan := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
    max_secured_loan := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
    max_financing_amount := max_secured_loan;
    unsecured_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.12);
    secured_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.10);
    base_interest_rate := unsecured_interest_rate;
    min_loan_amount := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
    max_active_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);

    suggestions := ARRAY[]::TEXT[];
    IF fleet_health < 80 THEN
        suggestions := array_append(suggestions, 'Improve aircraft condition to strengthen fleet-health scoring.');
    END IF;
    IF revenue_stability < 80 THEN
        suggestions := array_append(suggestions, 'Stabilize route earnings to reduce revenue volatility.');
    END IF;
    IF debt_ratio < 80 THEN
        suggestions := array_append(suggestions, 'Reduce outstanding debt or grow assets to improve debt ratio.');
    END IF;
    IF cash_reserve < 80 THEN
        suggestions := array_append(suggestions, 'Increase cash reserves to improve lender confidence.');
    END IF;
    IF profit_history < 80 THEN
        suggestions := array_append(suggestions, 'Sustain positive operating profits to improve profit history.');
    END IF;
    IF array_length(suggestions, 1) IS NULL THEN
        suggestions := ARRAY['Your credit profile is healthy. Maintain payment discipline and operating profitability.'];
    END IF;

    RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."get_credit_report"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_credit_tier_policy"("p_tier" character varying) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_config JSONB;
    v_policy JSONB;
BEGIN
    SELECT value INTO v_config
    FROM game_config
    WHERE key = 'credit_tier_config';

    IF v_config IS NULL THEN
        RETURN '{}'::JSONB;
    END IF;

    v_policy := v_config -> COALESCE(p_tier, 'Standard');
    IF v_policy IS NULL OR jsonb_typeof(v_policy) <> 'object' THEN
        v_policy := v_config -> 'Standard';
    END IF;

    RETURN COALESCE(v_policy, '{}'::JSONB);
END;
$$;


ALTER FUNCTION "public"."get_credit_tier_policy"("p_tier" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_current_user_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT public.get_user_id_for_auth_uid(auth.uid());
$$;


ALTER FUNCTION "public"."get_current_user_id"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_current_user_id"() IS 'Convenience helper for future authenticated RPCs to resolve auth.uid() to public.users.id.';



CREATE OR REPLACE FUNCTION "public"."get_database_size_report"() RETURNS TABLE("metric" "text", "value" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_db_size_mb NUMERIC;
    v_warn_mb NUMERIC;
    v_critical_mb NUMERIC;
    v_free_quota_mb NUMERIC;
BEGIN
    v_warn_mb := COALESCE(get_config_numeric('database_warn_mb'), 350);
    v_critical_mb := COALESCE(get_config_numeric('database_critical_mb'), 425);
    v_free_quota_mb := COALESCE(get_config_numeric('database_free_quota_mb'), 500);

    SELECT ROUND((pg_database_size(current_database()) / 1024.0 / 1024.0)::NUMERIC, 2) INTO v_db_size_mb;

    metric := 'database_size_mb'; value := v_db_size_mb::TEXT; RETURN NEXT;
    metric := 'free_quota_mb'; value := v_free_quota_mb::TEXT; RETURN NEXT;
    metric := 'usage_pct'; value := ROUND((v_db_size_mb / v_free_quota_mb * 100)::NUMERIC, 1)::TEXT || '%'; RETURN NEXT;
    metric := 'warn_threshold_mb'; value := v_warn_mb::TEXT; RETURN NEXT;
    metric := 'critical_threshold_mb'; value := v_critical_mb::TEXT; RETURN NEXT;
    metric := 'status'; value := CASE
        WHEN v_db_size_mb >= v_critical_mb THEN 'CRITICAL'
        WHEN v_db_size_mb >= v_warn_mb THEN 'WARNING'
        ELSE 'OK'
    END; RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."get_database_size_report"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_finance_snapshot"() RETURNS TABLE("actor_id" "uuid", "is_bot" boolean, "company_name" character varying, "cash" numeric, "net_worth" numeric, "owned_aircraft_asset_value" numeric, "leased_aircraft_monthly_exposure" numeric, "fleet_count" integer, "owned_fleet_count" integer, "leased_fleet_count" integer, "active_route_count" integer, "rolling_revenue_30d" numeric, "rolling_expense_30d" numeric, "rolling_net_30d" numeric, "ledger_window_days" integer)
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM get_finance_snapshot(v_user_id, FALSE);
END;
$$;


ALTER FUNCTION "public"."get_finance_snapshot"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_finance_snapshot"("p_id" "uuid", "p_is_bot" boolean DEFAULT false) RETURNS TABLE("actor_id" "uuid", "is_bot" boolean, "company_name" character varying, "cash" numeric, "net_worth" numeric, "owned_aircraft_asset_value" numeric, "leased_aircraft_monthly_exposure" numeric, "fleet_count" integer, "owned_fleet_count" integer, "leased_fleet_count" integer, "active_route_count" integer, "rolling_revenue_30d" numeric, "rolling_expense_30d" numeric, "rolling_net_30d" numeric, "ledger_window_days" integer)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_company_name VARCHAR;
    v_cash NUMERIC := 0.00;
    v_net_worth NUMERIC := 0.00;
    v_owned_asset_value NUMERIC := 0.00;
    v_leased_monthly_exposure NUMERIC := 0.00;
    v_fleet_count INT := 0;
    v_owned_fleet_count INT := 0;
    v_leased_fleet_count INT := 0;
    v_active_route_count INT := 0;
    v_revenue_30d NUMERIC := 0.00;
    v_expense_30d NUMERIC := 0.00;
    v_ledger_window_days INT := 30;
    v_game_current_time TIMESTAMPTZ;
BEGIN
    SELECT u.company_name, u.game_current_time
    INTO v_company_name, v_game_current_time
    FROM users u
    WHERE u.id = p_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_cash := get_user_balance(p_id);
    v_net_worth := calculate_user_net_worth(p_id);

    SELECT
        COUNT(*)::INT,
        COUNT(*) FILTER (
            WHERE f.acquisition_type IN ('purchase', 'finance')
        )::INT,
        COUNT(*) FILTER (WHERE f.acquisition_type = 'lease')::INT,
        COALESCE(
            SUM(
                CASE
                    WHEN f.acquisition_type IN ('purchase', 'finance')
                        THEN m.purchase_price * (f.condition / 100.00)
                    ELSE 0
                END
            ),
            0.00
        ),
        COALESCE(
            SUM(
                CASE
                    WHEN f.acquisition_type = 'lease'
                        THEN m.lease_price_per_month
                    ELSE 0
                END
            ),
            0.00
        )
    INTO
        v_fleet_count,
        v_owned_fleet_count,
        v_leased_fleet_count,
        v_owned_asset_value,
        v_leased_monthly_exposure
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.user_id = p_id;

    SELECT COUNT(*)::INT
    INTO v_active_route_count
    FROM route_assignments r
    WHERE r.user_id = p_id
      AND COALESCE(r.status, 'active') = 'active';

    SELECT
        COALESCE(
            SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END),
            0.00
        ),
        COALESCE(
            SUM(CASE WHEN transaction_type = 'debit' THEN ABS(amount) ELSE 0 END),
            0.00
        )
    INTO v_revenue_30d, v_expense_30d
    FROM bank_transactions
    WHERE user_id = p_id
      AND game_date >= v_game_current_time - INTERVAL '30 days';

    RETURN QUERY
    SELECT
        p_id,
        p_is_bot,
        v_company_name::VARCHAR,
        v_cash,
        v_net_worth,
        v_owned_asset_value,
        v_leased_monthly_exposure,
        v_fleet_count,
        v_owned_fleet_count,
        v_leased_fleet_count,
        v_active_route_count,
        v_revenue_30d,
        v_expense_30d,
        v_revenue_30d - v_expense_30d,
        v_ledger_window_days;
END;
$$;


ALTER FUNCTION "public"."get_finance_snapshot"("p_id" "uuid", "p_is_bot" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_finance_snapshot"("p_id" "uuid", "p_is_bot" boolean) IS 'Returns current balance-sheet and rolling 30-day finance metrics for one human player or AI competitor.';



CREATE OR REPLACE FUNCTION "public"."get_global_leaderboard"() RETURNS TABLE("id" "uuid", "company_name" character varying, "ceo_name" character varying, "is_bot" boolean, "archetype" character varying, "cash" numeric, "net_worth" numeric, "fleet_size" integer, "monthly_revenue" numeric, "status" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        u.id,
        u.company_name::VARCHAR,
        u.ceo_name::VARCHAR,
        (u.actor_type = 'AI')::BOOLEAN,
        COALESCE(bp.archetype, 'Player')::VARCHAR,
        get_user_balance(u.id),
        calculate_user_net_worth(u.id),
        (
            SELECT COUNT(*)::INT
            FROM fleet_aircraft f
            WHERE f.user_id = u.id
              AND f.status = 'active'
        ),
        COALESCE(
            (
                SELECT SUM(bt.amount)
                FROM bank_transactions bt
                WHERE bt.user_id = u.id
                  AND bt.transaction_type = 'credit'
                  AND bt.game_date >= u.game_current_time - INTERVAL '30 days'
            ),
            0.00
        )::NUMERIC,
        COALESCE(u.operational_status, 'Active')::VARCHAR
    FROM users u
    LEFT JOIN bot_profiles bp ON bp.user_id = u.id;
END;
$$;


ALTER FUNCTION "public"."get_global_leaderboard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_hq_prefix"("p_airport_iata" character varying) RETURNS character varying
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_country VARCHAR;
BEGIN
    SELECT country INTO v_country FROM airports WHERE iata = p_airport_iata;
    
    RETURN CASE 
        WHEN v_country = 'Indonesia' THEN 'PK-'
        WHEN v_country = 'Singapore' THEN '9V-'
        WHEN v_country = 'United Kingdom' OR v_country = 'UK' THEN 'G-'
        WHEN v_country = 'Malaysia' THEN '9M-'
        WHEN v_country = 'Thailand' THEN 'HS-'
        WHEN v_country = 'Philippines' THEN 'RP-'
        WHEN v_country = 'Vietnam' THEN 'VN-'
        WHEN v_country = 'Japan' THEN 'JA-'
        WHEN v_country = 'Germany' THEN 'D-'
        WHEN v_country = 'France' THEN 'F-'
        WHEN v_country = 'United States' OR v_country = 'USA' THEN 'N-'
        ELSE '9V-'
    END;
END;
$$;


ALTER FUNCTION "public"."get_hq_prefix"("p_airport_iata" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_owner_route_optimizer"("p_user_id" "uuid", "p_origin_iata" character varying DEFAULT NULL::character varying, "p_destination_iata" character varying DEFAULT NULL::character varying, "p_limit" integer DEFAULT 25, "p_include_assigned" boolean DEFAULT false, "p_exclude_existing_routes" boolean DEFAULT true) RETURNS TABLE("aircraft_id" "uuid", "tail_number" character varying, "aircraft_model" character varying, "acquisition_type" character varying, "currently_assigned" boolean, "route_origin_iata" character varying, "route_destination_iata" character varying, "route_already_exists" boolean, "distance_km" numeric, "ticket_price" numeric, "weekly_flights" integer, "recommended_economy_seats" integer, "recommended_business_seats" integer, "recommended_first_class_seats" integer, "effective_passenger_capacity" integer, "expected_passengers_per_flight" integer, "load_factor" numeric, "direct_cost_per_flight" numeric, "revenue_per_flight" numeric, "contribution_per_flight" numeric, "weekly_contribution" numeric, "maintenance_impact_per_week" numeric)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE v_origin_iata VARCHAR(3); v_player_schema TEXT; v_player_relation TEXT;
BEGIN
SELECT ns.nspname, cls.relname INTO v_player_schema, v_player_relation
FROM pg_catalog.pg_class cls JOIN pg_catalog.pg_namespace ns ON ns.oid = cls.relnamespace
JOIN pg_catalog.pg_attribute att_id ON att_id.attrelid = cls.oid AND att_id.attname = 'id' AND att_id.attnum > 0 AND NOT att_id.attisdropped
JOIN pg_catalog.pg_attribute att_hq ON att_hq.attrelid = cls.oid AND att_hq.attname = 'hq_airport_iata' AND att_hq.attnum > 0 AND NOT att_hq.attisdropped
WHERE cls.relkind IN ('r', 'p', 'v', 'm') AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY CASE WHEN ns.nspname = 'public' AND cls.relname = 'users' THEN 0 WHEN cls.relname = 'users' THEN 1 ELSE 2 END, ns.nspname, cls.relname LIMIT 1;
IF v_player_schema IS NULL OR v_player_relation IS NULL THEN RETURN; END IF;
EXECUTE format('select coalesce($1, hq_airport_iata) from %I.%I where id = $2', v_player_schema, v_player_relation) INTO v_origin_iata USING p_origin_iata, p_user_id;
IF v_origin_iata IS NULL THEN RETURN; END IF;
RETURN QUERY
WITH origin_airport AS (SELECT a.* FROM public.airports a WHERE a.iata = v_origin_iata LIMIT 1),
settings AS (SELECT COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85) AS fuel_price_per_liter),
aircraft_candidates AS (
SELECT f.id AS candidate_aircraft_id, f.tail_number AS candidate_tail_number, f.acquisition_type AS candidate_acquisition_type,
m.model_name AS candidate_model_name, m.capacity AS model_capacity, m.range_km AS model_range_km, m.speed_kmh AS model_speed_kmh,
m.fuel_burn_per_km AS model_fuel_burn_per_km, m.maintenance_cost_per_hour AS model_maintenance_cost_per_hour,
EXISTS (SELECT 1 FROM public.route_assignments r WHERE r.user_id = p_user_id AND r.assigned_aircraft_id = f.id) AS candidate_currently_assigned
FROM public.fleet_aircraft f JOIN public.aircraft_models m ON m.id = f.aircraft_model_id
WHERE f.user_id = p_user_id AND (p_include_assigned OR NOT EXISTS (SELECT 1 FROM public.route_assignments r WHERE r.user_id = p_user_id AND r.assigned_aircraft_id = f.id))),
destination_candidates AS (
SELECT dst.iata AS destination_iata, dst.demand_index AS destination_demand_index,
ROUND((6371.0 * 2.0 * ASIN(SQRT(POWER(SIN(RADIANS(dst.latitude - org.latitude) / 2.0), 2) + COS(RADIANS(org.latitude)) * COS(RADIANS(dst.latitude)) * POWER(SIN(RADIANS(dst.longitude - org.longitude) / 2.0), 2))))::NUMERIC, 2) AS route_distance_km
FROM public.airports dst CROSS JOIN origin_airport org WHERE dst.iata <> org.iata AND (p_destination_iata IS NULL OR dst.iata = p_destination_iata)),
candidate_pairs AS (
SELECT ac.*, dc.destination_iata, dc.destination_demand_index, dc.route_distance_km, org.iata AS origin_iata, org.demand_index AS origin_demand_index
FROM aircraft_candidates ac CROSS JOIN destination_candidates dc CROSS JOIN origin_airport org WHERE dc.route_distance_km <= ac.model_range_km),
seat_presets AS (
SELECT cp.*, seat_profile.preset_economy_seats, seat_profile.preset_business_seats, seat_profile.preset_first_class_seats,
GREATEST(0, COALESCE(NULLIF(COALESCE(seat_profile.preset_economy_seats, 0) + COALESCE(seat_profile.preset_business_seats, 0) + COALESCE(seat_profile.preset_first_class_seats, 0), 0), COALESCE(cp.model_capacity, 0)))::INT AS passenger_capacity
FROM candidate_pairs cp CROSS JOIN LATERAL (VALUES (cp.model_capacity, 0, 0), (GREATEST(1, cp.model_capacity - (2 * FLOOR(cp.model_capacity * 0.18 / 2.0)::INT) - (3 * FLOOR(cp.model_capacity * 0.06 / 3.0)::INT)), FLOOR(cp.model_capacity * 0.18 / 2.0)::INT, FLOOR(cp.model_capacity * 0.06 / 3.0)::INT), (GREATEST(1, cp.model_capacity - (2 * FLOOR(cp.model_capacity * 0.24 / 2.0)::INT) - (3 * FLOOR(cp.model_capacity * 0.12 / 3.0)::INT)), FLOOR(cp.model_capacity * 0.24 / 2.0)::INT, FLOOR(cp.model_capacity * 0.12 / 3.0)::INT)) AS seat_profile(preset_economy_seats, preset_business_seats, preset_first_class_seats)),
fare_points AS (
SELECT sp.*, ROUND((50.00 + (COALESCE(sp.route_distance_km, 0.0)::NUMERIC * 0.12)) * fare.multiplier, 2) AS evaluated_ticket_price
FROM seat_presets sp CROSS JOIN LATERAL (VALUES (0.95::NUMERIC), (1.00::NUMERIC), (1.05::NUMERIC), (1.10::NUMERIC), (1.20::NUMERIC), (1.35::NUMERIC)) AS fare(multiplier)),
scored AS (
SELECT fp.candidate_aircraft_id, fp.candidate_tail_number, fp.candidate_model_name, fp.candidate_acquisition_type, fp.candidate_currently_assigned,
fp.origin_iata, fp.destination_iata,
EXISTS (SELECT 1 FROM public.route_assignments existing_route WHERE existing_route.user_id = p_user_id AND existing_route.origin_iata = fp.origin_iata AND existing_route.destination_iata = fp.destination_iata) AS candidate_route_already_exists,
fp.route_distance_km, fp.evaluated_ticket_price,
CASE WHEN COALESCE(fp.route_distance_km, 0.0) <= 0.0 OR COALESCE(fp.model_speed_kmh, 0) <= 0 THEN 0 ELSE FLOOR(168.0 / NULLIF((COALESCE(fp.route_distance_km, 0.0) / fp.model_speed_kmh::DOUBLE PRECISION) + 1.0, 0.0))::INT END AS computed_weekly_flights,
fp.preset_economy_seats, fp.preset_business_seats, fp.preset_first_class_seats, fp.passenger_capacity,
GREATEST(0, LEAST(COALESCE(fp.passenger_capacity, 0), FLOOR(COALESCE(fp.passenger_capacity, 0) * 0.95 * GREATEST(0.55, LEAST(1.00, 0.55 + (((((COALESCE(fp.origin_demand_index, 50) + COALESCE(fp.destination_demand_index, 50))::NUMERIC) / 2.0) / 100.0) * 0.45))) * GREATEST(0.00, LEAST(1.50, 1.5 - 0.8 * POWER(COALESCE(fp.evaluated_ticket_price, 0.00) / NULLIF(50.00 + (COALESCE(fp.route_distance_km, 0.0)::NUMERIC * 0.12), 0.00), 2))))::INT)) AS computed_expected_passengers_per_flight,
ROUND((fp.route_distance_km * fp.model_fuel_burn_per_km * s.fuel_price_per_liter + (((fp.route_distance_km / NULLIF(fp.model_speed_kmh::DOUBLE PRECISION, 0.0)) + 1.0) * fp.model_maintenance_cost_per_hour))::NUMERIC, 2) AS computed_direct_cost_per_flight
FROM fare_points fp CROSS JOIN settings s),
ranked AS (
SELECT s.candidate_aircraft_id, s.candidate_tail_number, s.candidate_model_name, s.candidate_acquisition_type, s.candidate_currently_assigned,
s.origin_iata, s.destination_iata, s.candidate_route_already_exists, s.route_distance_km, s.evaluated_ticket_price, s.computed_weekly_flights,
s.preset_economy_seats, s.preset_business_seats, s.preset_first_class_seats, s.passenger_capacity, s.computed_expected_passengers_per_flight,
ROUND(CASE WHEN s.passenger_capacity <= 0 THEN 0.00 ELSE (s.computed_expected_passengers_per_flight::NUMERIC / s.passenger_capacity::NUMERIC) * 100.00 END, 2) AS computed_load_factor,
s.computed_direct_cost_per_flight,
ROUND((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price)::NUMERIC, 2) AS computed_revenue_per_flight,
ROUND(((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price) - s.computed_direct_cost_per_flight)::NUMERIC, 2) AS computed_contribution_per_flight,
ROUND((((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price) - s.computed_direct_cost_per_flight) * s.computed_weekly_flights * CASE WHEN s.candidate_route_already_exists THEN 0.72 ELSE 1.00 END)::NUMERIC, 2) AS adjusted_weekly_contribution,
ROUND(CASE WHEN s.candidate_acquisition_type = 'lease' THEN s.computed_weekly_flights * 0.70 ELSE s.computed_weekly_flights * 0.50 END::NUMERIC, 2) AS computed_maintenance_impact_per_week,
ROW_NUMBER() OVER (PARTITION BY s.origin_iata, s.destination_iata, s.candidate_model_name, s.candidate_acquisition_type, s.preset_economy_seats, s.preset_business_seats, s.preset_first_class_seats, s.evaluated_ticket_price ORDER BY s.candidate_currently_assigned ASC, s.candidate_tail_number ASC, s.candidate_aircraft_id ASC) AS route_model_rank
FROM scored s WHERE s.computed_weekly_flights > 0 AND (NOT p_exclude_existing_routes OR NOT s.candidate_route_already_exists))
SELECT r.candidate_aircraft_id, r.candidate_tail_number, r.candidate_model_name, r.candidate_acquisition_type, r.candidate_currently_assigned,
r.origin_iata, r.destination_iata, r.candidate_route_already_exists, r.route_distance_km, r.evaluated_ticket_price, r.computed_weekly_flights,
r.preset_economy_seats, r.preset_business_seats, r.preset_first_class_seats, r.passenger_capacity, r.computed_expected_passengers_per_flight,
r.computed_load_factor, r.computed_direct_cost_per_flight, r.computed_revenue_per_flight, r.computed_contribution_per_flight,
r.adjusted_weekly_contribution, r.computed_maintenance_impact_per_week
FROM ranked r WHERE r.route_model_rank = 1 ORDER BY r.adjusted_weekly_contribution DESC, r.computed_contribution_per_flight DESC, r.computed_load_factor DESC, r.route_distance_km ASC LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
END;
$_$;


ALTER FUNCTION "public"."get_owner_route_optimizer"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_limit" integer, "p_include_assigned" boolean, "p_exclude_existing_routes" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_owner_route_optimizer"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_limit" integer, "p_include_assigned" boolean, "p_exclude_existing_routes" boolean) IS 'Returns deduplicated ranked route, fare, and cabin-layout opportunities for the owner, excluding existing routes by default and applying a simple served-route penalty when included.';



CREATE OR REPLACE FUNCTION "public"."get_route_performance"("p_user_id" "uuid") RETURNS TABLE("route_id" "uuid", "origin_iata" character varying, "destination_iata" character varying, "distance_km" double precision, "ticket_price" numeric, "flights_per_week" integer, "assigned_aircraft" character varying, "effective_capacity" integer, "expected_passengers" integer, "load_factor" numeric, "revenue_per_flight" numeric, "cost_per_flight" numeric, "profit_per_flight" numeric, "weekly_profit" numeric)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_route_performance"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_table_size_report"() RETURNS TABLE("schema_name" "text", "table_name" "text", "row_estimate" bigint, "total_size_bytes" bigint, "total_size_pretty" "text", "table_size_pretty" "text", "index_size_pretty" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        stat.schemaname::TEXT,
        stat.relname::TEXT,
        stat.n_live_tup::BIGINT,
        pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)::BIGINT,
        pg_size_pretty(pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)),
        pg_size_pretty(pg_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)),
        pg_size_pretty(pg_indexes_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS))
    FROM pg_stat_user_tables stat
    WHERE stat.schemaname = 'public'
    ORDER BY pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS) DESC;
END;
$$;


ALTER FUNCTION "public"."get_table_size_report"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_table_size_report"() IS 'Returns approximate row counts and relation/index sizes for public user tables without requiring extension schema access.';



CREATE OR REPLACE FUNCTION "public"."get_tail_suffix"("p_tail" character varying) RETURNS character varying
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF position('-' in p_tail) > 0 THEN
        RETURN split_part(p_tail, '-', 2);
    ELSE
        -- Fallback to last 3 characters
        RETURN right(p_tail, 3);
    END IF;
END;
$$;


ALTER FUNCTION "public"."get_tail_suffix"("p_tail" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_balance"("p_user_id" "uuid") RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
    SELECT COALESCE(balance, 0)
    FROM bank_accounts
    WHERE user_id = p_user_id AND account_type = 'operating'
    LIMIT 1;
$$;


ALTER FUNCTION "public"."get_user_balance"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_id_for_auth_uid"("p_auth_user_id" "uuid" DEFAULT "auth"."uid"()) RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT u.id
    FROM public.users u
    WHERE u.auth_user_id = p_auth_user_id
    LIMIT 1;
$$;


ALTER FUNCTION "public"."get_user_id_for_auth_uid"("p_auth_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_user_id_for_auth_uid"("p_auth_user_id" "uuid") IS 'Resolves a Supabase Auth user id to the matching public.users actor row.';



CREATE OR REPLACE FUNCTION "public"."get_world_tick_guardrail_report"() RETURNS TABLE("check_name" "text", "check_status" "text", "details" "text")
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    r_season RECORD;
    r_latest_success RECORD;
    v_lagging_actors INT := 0;
    v_ahead_actors INT := 0;
    v_backwards_logs INT := 0;
BEGIN
    SELECT * INTO r_season
    FROM season_clock
    WHERE status = 'active'
    ORDER BY created_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 'active_season_exists', 'fail', 'No active season_clock row exists.';
        RETURN;
    END IF;

    RETURN QUERY SELECT
        'active_season_exists', 'pass',
        'Active season ' || r_season.id || ' at ' || r_season.current_game_time || '.';

    SELECT COUNT(*)::INT INTO v_lagging_actors
    FROM users u
    WHERE u.season_id = r_season.id
      AND u.game_current_time < r_season.current_game_time;

    RETURN QUERY SELECT
        'actors_not_lagging',
        CASE WHEN v_lagging_actors = 0 THEN 'pass' ELSE 'fail' END,
        'lagging_actors=' || v_lagging_actors || '.';

    SELECT COUNT(*)::INT INTO v_ahead_actors
    FROM users u
    WHERE u.season_id = r_season.id
      AND u.game_current_time > r_season.current_game_time;

    RETURN QUERY SELECT
        'actors_not_ahead',
        CASE WHEN v_ahead_actors = 0 THEN 'pass' ELSE 'fail' END,
        'ahead_actors=' || v_ahead_actors || '.';

    SELECT COUNT(*)::INT INTO v_backwards_logs
    FROM world_tick_log wtl
    WHERE wtl.status = 'success'
      AND wtl.game_time_after < wtl.game_time_before;

    RETURN QUERY SELECT
        'no_backwards_world_ticks',
        CASE WHEN v_backwards_logs = 0 THEN 'pass' ELSE 'fail' END,
        'backwards_success_logs=' || v_backwards_logs || '.';

    SELECT * INTO r_latest_success
    FROM world_tick_log wtl
    WHERE wtl.season_id = r_season.id AND wtl.status = 'success'
    ORDER BY wtl.started_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 'recent_successful_world_tick', 'fail',
            'No successful world_tick_log rows exist for active season.';
        RETURN;
    END IF;

    RETURN QUERY SELECT
        'recent_successful_world_tick',
        CASE WHEN r_latest_success.started_at >= NOW() - INTERVAL '10 minutes' THEN 'pass' ELSE 'warn' END,
        'latest_success=' || r_latest_success.started_at
            || ', ticks=' || r_latest_success.ticks_processed
            || ', players=' || r_latest_success.players_processed
            || ', bots=' || r_latest_success.bots_processed || '.';
END;
$$;


ALTER FUNCTION "public"."get_world_tick_guardrail_report"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_world_tick_guardrail_report"() IS 'Read-only live audit report for world-clock health, actor lag, and backwards tick regressions.';



CREATE OR REPLACE FUNCTION "public"."get_world_tick_scheduler_health"() RETURNS TABLE("season_id" "uuid", "season_status" character varying, "current_game_time" timestamp with time zone, "season_last_tick_at" timestamp with time zone, "seconds_since_last_tick" numeric, "latest_log_started_at" timestamp with time zone, "latest_log_status" character varying, "latest_log_message" "text", "latest_ticks_processed" integer, "scheduler_job_exists" boolean, "scheduler_job_active" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'cron', 'extensions'
    AS $$
DECLARE
    r_season RECORD;
    r_log RECORD;
    r_job RECORD;
BEGIN
    SELECT *
    INTO r_season
    FROM public.season_clock
    WHERE status = 'active'
    ORDER BY created_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT *
    INTO r_log
    FROM public.world_tick_log
    WHERE world_tick_log.season_id = r_season.id
    ORDER BY started_at DESC
    LIMIT 1;

    SELECT *
    INTO r_job
    FROM cron.job
    WHERE jobname = 'skyward_world_tick'
    LIMIT 1;

    RETURN QUERY SELECT
        r_season.id,
        r_season.status::VARCHAR,
        r_season.current_game_time,
        r_season.last_tick_at,
        EXTRACT(EPOCH FROM (NOW() - r_season.last_tick_at))::NUMERIC,
        r_log.started_at,
        r_log.status::VARCHAR,
        r_log.message,
        COALESCE(r_log.ticks_processed, 0),
        (r_job.jobid IS NOT NULL),
        COALESCE(r_job.active, FALSE);
END;
$$;


ALTER FUNCTION "public"."get_world_tick_scheduler_health"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_world_tick_scheduler_health"() IS 'Returns active season clock health and pg_cron job status without granting direct cron schema access.';



CREATE OR REPLACE FUNCTION "public"."handle_new_auth_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_username TEXT;
    v_expected_email TEXT;
    v_company_name TEXT;
    v_ceo_name TEXT;
    v_starting_cash NUMERIC;
BEGIN
    IF EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = NEW.id) THEN
        RETURN NEW;
    END IF;

    v_username := public.normalize_username(NEW.raw_user_meta_data ->> 'username');
    v_company_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'company_name', '')), '');
    v_ceo_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'ceo_name', '')), '');

    IF v_username IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.username';
    END IF;
    IF v_company_name IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.company_name';
    END IF;
    IF v_ceo_name IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.ceo_name';
    END IF;

    v_expected_email := public.build_synthetic_auth_email(v_username);
    IF lower(COALESCE(NEW.email, '')) <> v_expected_email THEN
        RAISE EXCEPTION 'Auth bootstrap email mismatch for username %', v_username;
    END IF;

    IF EXISTS (SELECT 1 FROM public.users u WHERE u.username = v_username) THEN
        RAISE EXCEPTION 'Username % is already registered.', v_username;
    END IF;
    IF EXISTS (SELECT 1 FROM public.users u WHERE u.company_name = v_company_name) THEN
        RAISE EXCEPTION 'Company name % is already registered.', v_company_name;
    END IF;

    SELECT COALESCE(get_config_numeric('starting_cash'), 15000000.00)
    INTO v_starting_cash;

    INSERT INTO public.users (
        auth_user_id, username, company_name, ceo_name, net_worth,
        game_current_time, last_active_at, operational_status,
        consecutive_negative_days, recovery_streak_days, auto_grounding_threshold,
        actor_type, hq_airport_iata
    ) VALUES (
        NEW.id, v_username, v_company_name, v_ceo_name, v_starting_cash,
        '2020-01-01 00:00:00+00', NOW(), 'Active',
        0, 0, 40.00,
        'REAL', 'CGK'
    );
    -- trg_create_default_bank_account trigger handles creating the operating account
    -- credit_scores entry is created by update_credit_score on day boundary

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_auth_user"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."handle_new_auth_user"() IS 'Bootstraps a public.users actor row from a newly-created auth.users identity using normalized username metadata and the synthetic Skyward auth email convention. Uses a non-crypto legacy placeholder password_hash because Supabase Auth is now the real identity source.';



CREATE OR REPLACE FUNCTION "public"."haversine_distance"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) RETURNS double precision
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    R DOUBLE PRECISION := 6371.0;
    dlat DOUBLE PRECISION;
    dlon DOUBLE PRECISION;
    a DOUBLE PRECISION;
    c DOUBLE PRECISION;
BEGIN
    dlat := radians(lat2 - lat1);
    dlon := radians(lon2 - lon1);
    a := sin(dlat / 2) ^ 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ^ 2;
    c := 2 * atan2(sqrt(a), sqrt(1 - a));
    RETURN R * c;
END;
$$;


ALTER FUNCTION "public"."haversine_distance"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."haversine_distance"("lat1" numeric, "lon1" numeric, "lat2" numeric, "lon2" numeric) RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    R NUMERIC := 6371; -- Earth radius in km
    dlat NUMERIC;
    dlon NUMERIC;
    a NUMERIC;
    c NUMERIC;
BEGIN
    dlat := radians(lat2 - lat1);
    dlon := radians(lon2 - lon1);
    a := sin(dlat/2)^2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon/2)^2;
    c := 2 * atan2(sqrt(a), sqrt(1-a));
    RETURN R * c;
END;
$$;


ALTER FUNCTION "public"."haversine_distance"("lat1" numeric, "lon1" numeric, "lat2" numeric, "lon2" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lease_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer DEFAULT NULL::integer, "p_business_seats" integer DEFAULT 0, "p_first_class_seats" integer DEFAULT 0) RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM lease_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$$;


ALTER FUNCTION "public"."lease_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lease_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer DEFAULT NULL::integer, "p_business_seats" integer DEFAULT 0, "p_first_class_seats" integer DEFAULT 0) RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
v_cash NUMERIC; v_lease_price NUMERIC; v_model_name VARCHAR; v_capacity INT;
v_purchase_price NUMERIC;
v_hq_iata VARCHAR(3); v_tail VARCHAR(20); v_lease_deposit NUMERIC;
v_economy INT; v_business INT; v_first INT; v_slots_used INT; v_game_time TIMESTAMPTZ;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
v_cash := get_user_balance(p_user_id);
SELECT hq_airport_iata, game_current_time INTO v_hq_iata, v_game_time
FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC; RETURN; END IF;
SELECT lease_price_per_month, purchase_price, model_name, capacity
INTO v_lease_price, v_purchase_price, v_model_name, v_capacity
FROM aircraft_models WHERE id = p_model_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash; RETURN; END IF;
v_lease_deposit := calculate_required_lease_deposit(v_purchase_price, v_lease_price);
v_economy := COALESCE(p_economy_seats, v_capacity);
v_business := COALESCE(p_business_seats, 0);
v_first := COALESCE(p_first_class_seats, 0);
v_slots_used := v_economy + (v_business * 2) + (v_first * 3);
IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash; RETURN;
END IF;
IF v_cash < v_lease_deposit THEN
RETURN QUERY SELECT FALSE, ('Insufficient funds for lease deposit of ' || v_model_name || '. Required: $' || ROUND(v_lease_deposit, 2))::VARCHAR, v_cash; RETURN;
END IF;
LOOP v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
EXIT WHEN NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_tail);
END LOOP;
PERFORM debit_bank_account(p_user_id, v_lease_deposit, 'investing', 'aircraft_lease_deposit',
'Leased aircraft ' || v_model_name || ' deposit [' || v_tail || ']', v_game_time);
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, ('Successfully leased ' || v_model_name || ' [' || v_tail || ']')::VARCHAR, v_cash;
END;
$_$;


ALTER FUNCTION "public"."lease_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_username"("p_username" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
    SELECT NULLIF(
        trim(both '-' from regexp_replace(
            lower(trim(COALESCE(p_username, ''))),
            '[^a-z0-9._-]+', '-', 'g'
        )),
        ''
    );
$$;


ALTER FUNCTION "public"."normalize_username"("p_username" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."normalize_username"("p_username" "text") IS 'Normalizes a user-facing username into a lowercase slug-safe identifier for future auth and uniqueness workflows.';



CREATE OR REPLACE FUNCTION "public"."perform_actor_aircraft_repair"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_min_cash_reserve" numeric DEFAULT 0, "p_game_time" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_description" "text" DEFAULT NULL::"text") RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric, "repair_cost" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
    v_cash NUMERIC;
    v_condition NUMERIC;
    v_purchase_price NUMERIC;
    v_lease_price NUMERIC;
    v_model_name VARCHAR;
    v_repair_cost NUMERIC;
    v_acquisition_type VARCHAR;
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

    SELECT f.condition, f.acquisition_type, m.purchase_price, m.lease_price_per_month, m.model_name
      INTO v_condition, v_acquisition_type, v_purchase_price, v_lease_price, v_model_name
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

    v_repair_cost := CASE
        WHEN v_acquisition_type = 'lease' THEN (100.00 - v_condition) * (COALESCE(v_lease_price, 0.00) * 0.50)
        ELSE (100.00 - v_condition) * (COALESCE(v_purchase_price, 0.00) * 0.0005)
    END;

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
        'Maintenance completed for ' || v_model_name || ' - restored from ' || ROUND(v_condition::numeric, 2) || '% to 100%'
    );

    PERFORM debit_bank_account(
        p_user_id,
        v_repair_cost,
        'cogs',
        'maintenance',
        v_description,
        v_effective_game_time
    );

    UPDATE fleet_aircraft
    SET condition = 100.00,
        status = 'active'
    WHERE id = p_fleet_id;

    v_cash := get_user_balance(p_user_id);

    RETURN QUERY
    SELECT TRUE,
           'Aircraft maintenance complete. Health restored to 100%!'::VARCHAR,
           v_cash,
           v_repair_cost;
END;
$_$;


ALTER FUNCTION "public"."perform_actor_aircraft_repair"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_min_cash_reserve" numeric, "p_game_time" timestamp with time zone, "p_description" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_actor_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone, "p_elapsed_days" numeric DEFAULT 1.0) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_cash_after                NUMERIC;
    v_bankruptcy_days_threshold INTEGER;
    v_payment_periods           INTEGER;
    v_i                         INTEGER;
BEGIN
    v_payment_periods := GREATEST(1, FLOOR(p_elapsed_days / 7.0))::INTEGER;

    PERFORM process_credit_at_day_boundary(p_user_id, p_game_date);

    FOR v_i IN 1..v_payment_periods LOOP
        PERFORM process_loan_payments(p_user_id, p_game_date);
        PERFORM process_aircraft_financing_payments(p_user_id, p_game_date);
    END LOOP;

    v_cash_after := get_user_balance(p_user_id);
    v_bankruptcy_days_threshold := COALESCE(
        get_config_numeric('bankruptcy_negative_days_threshold'), 30
    )::INTEGER;

    IF v_cash_after < 0 THEN
        UPDATE users
        SET consecutive_negative_days = consecutive_negative_days + 1,
            recovery_streak_days = 0
        WHERE id = p_user_id;

        IF (SELECT consecutive_negative_days FROM users WHERE id = p_user_id)
           >= v_bankruptcy_days_threshold THEN
            PERFORM apply_actor_bankruptcy_state(p_user_id);
        END IF;
    ELSE
        UPDATE users
        SET consecutive_negative_days = 0,
            recovery_streak_days = recovery_streak_days + 1
        WHERE id = p_user_id;
    END IF;
END;
$$;


ALTER FUNCTION "public"."process_actor_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone, "p_elapsed_days" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_aircraft_financing_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
v_loan RECORD;
v_cash NUMERIC;
v_payment NUMERIC;
v_late_fee NUMERIC;
BEGIN
v_cash := get_user_balance(p_user_id);

FOR v_loan IN
    SELECT *
    FROM loans
    WHERE user_id = p_user_id
      AND loan_type = 'aircraft_financing'
      AND status = 'active'
LOOP
    IF COALESCE(v_loan.weekly_payment, 0) > 0 THEN
        v_payment := v_loan.weekly_payment;
    ELSIF COALESCE(v_loan.monthly_payment, 0) > 0 THEN
        v_payment := v_loan.monthly_payment / 4.33;
    ELSE
        CONTINUE;
    END IF;

    IF v_cash >= v_payment THEN
        PERFORM debit_bank_account(
            p_user_id,
            v_payment,
            'financing',
            'financing_payment',
            'Aircraft financing payment',
            p_game_date
        );
        v_cash := v_cash - v_payment;

        UPDATE loans
        SET remaining_balance = remaining_balance - v_payment
        WHERE id = v_loan.id;

        IF (SELECT remaining_balance FROM loans WHERE id = v_loan.id) <= 0 THEN
            UPDATE loans
            SET status = 'paid_off',
                remaining_balance = 0
            WHERE id = v_loan.id;
        END IF;
    ELSE
        v_late_fee := v_payment * 0.05;

        UPDATE loans
        SET remaining_balance = remaining_balance + v_late_fee,
            missed_payments = missed_payments + 1
        WHERE id = v_loan.id;

        IF (SELECT missed_payments FROM loans WHERE id = v_loan.id) >= 3 THEN
            UPDATE loans
            SET status = 'repossessed'
            WHERE id = v_loan.id;

            IF v_loan.collateral_aircraft_id IS NOT NULL THEN
                UPDATE fleet_aircraft
                SET status = 'grounded'
                WHERE id = v_loan.collateral_aircraft_id;
            END IF;
        END IF;
    END IF;
END LOOP;
END;
$$;


ALTER FUNCTION "public"."process_aircraft_financing_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."process_aircraft_financing_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) IS 'Monthly aircraft financing payment processor. Tracks missed payments; repossesses aircraft after 3 consecutive misses.';



CREATE OR REPLACE FUNCTION "public"."process_all_bots_simulation_to_time"("p_target_game_time" timestamp with time zone, "p_season_id" "uuid" DEFAULT NULL::"uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    r_bot                           RECORD;
    v_route                         RECORD;
    v_flights                       DOUBLE PRECISION;
    v_revenue                       NUMERIC(20,2) := 0;
    v_fuel_cost                     NUMERIC(20,2) := 0;
    v_maint_cost                    NUMERIC(20,2) := 0;
    v_crew_cost                     NUMERIC(20,2) := 0;
    v_passengers                    INT;
    v_flight_duration               DOUBLE PRECISION;
    v_turnaround_hours              NUMERIC;
    v_lease_cost                    NUMERIC(20,2) := 0;
    v_idle_lease_cost               NUMERIC(20,2) := 0;
    v_fuel_price                    NUMERIC;
    v_fuel_price_multiplier         NUMERIC;
    v_crew_cost_per_hour            NUMERIC;
    v_absolute_minimum_safety_limit NUMERIC(5,2);
    v_effective_grounding_threshold NUMERIC(5,2);
    v_max_weekly_flights            INT;
    v_wear_per_cycle                NUMERIC(8,4);
    v_gross_damage                  NUMERIC(20,4);
    v_self_healing_credit           NUMERIC(20,4);
    v_net_damage                    NUMERIC(20,4);
    v_cargo_rev                     NUMERIC(20,2);
    v_processed                     INT := 0;
    v_demand_multiplier             NUMERIC;
    v_airport_demand                NUMERIC;
    v_seasonal_multiplier           NUMERIC;
    v_owned_wear                    NUMERIC;
    v_leased_wear                   NUMERIC;
    v_auto_repair_rate              NUMERIC;
    v_maintenance_multiplier        NUMERIC;
    v_route_demand_event            NUMERIC;
    v_route_capacity_event          NUMERIC;
    v_effective_capacity            NUMERIC;
    v_game_days                     DOUBLE PRECISION;
    v_time_fraction                 NUMERIC;
    v_effective_season_id           UUID;
BEGIN
    v_fuel_price := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_absolute_minimum_safety_limit := COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00);
    v_crew_cost_per_hour := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
    v_effective_season_id := resolve_active_season_id(p_season_id);

    SELECT COALESCE(effect_value, 1.0) INTO v_fuel_price_multiplier
    FROM game_events
    WHERE event_type = 'fuel_shock' AND is_active = true
      AND effect_type = 'fuel_price'
      AND start_game_time <= p_target_game_time
      AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC
    LIMIT 1;
    IF NOT FOUND THEN
        v_fuel_price_multiplier := 1.0;
    END IF;

    SELECT COALESCE(effect_value, 1.0) INTO v_maintenance_multiplier
    FROM game_events
    WHERE event_type = 'maintenance_shock' AND is_active = true
      AND effect_type = 'maintenance_cost'
      AND start_game_time <= p_target_game_time
      AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC
    LIMIT 1;
    IF NOT FOUND THEN
        v_maintenance_multiplier := 1.0;
    END IF;

    v_seasonal_multiplier := 1.0;

    FOR r_bot IN
        SELECT *
        FROM users
        WHERE actor_type = 'AI'
          AND COALESCE(operational_status, 'Active') != 'Bankrupt'
          AND (v_effective_season_id IS NULL OR season_id = v_effective_season_id)
    LOOP
        v_effective_grounding_threshold := GREATEST(
            COALESCE(r_bot.auto_grounding_threshold, 40.00),
            v_absolute_minimum_safety_limit
        );

        v_game_days := EXTRACT(EPOCH FROM (p_target_game_time - r_bot.game_current_time)) / 86400.0;
        v_time_fraction := LEAST(v_game_days / 7.0, 1.0);
        IF v_game_days <= 0 THEN
            CONTINUE;
        END IF;

        FOR v_route IN
            SELECT ra.*, am.fuel_burn_per_km, am.speed_kmh, am.capacity,
                   am.turnaround_hours, am.maintenance_cost_per_hour,
                   am.lease_price_per_month, fa.acquisition_type,
                   a1.demand_index AS origin_demand,
                   a2.demand_index AS dest_demand
            FROM route_assignments ra
            JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id
            JOIN aircraft_models am ON am.id = fa.aircraft_model_id
            JOIN airports a1 ON a1.iata = ra.origin_iata
            JOIN airports a2 ON a2.iata = ra.destination_iata
            WHERE ra.user_id = r_bot.id
              AND ra.status = 'active'
              AND fa.status = 'active'
              AND fa.condition >= v_effective_grounding_threshold
        LOOP
            v_route_demand_event := 1.0;
            SELECT COALESCE(effect_value, 1.0) INTO v_route_demand_event
            FROM game_events
            WHERE event_type = 'demand_surge' AND is_active = true
              AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
              AND start_game_time <= p_target_game_time
              AND end_game_time > p_target_game_time
            ORDER BY start_game_time DESC
            LIMIT 1;
            IF NOT FOUND THEN
                v_route_demand_event := 1.0;
            END IF;

            v_route_capacity_event := 1.0;
            SELECT COALESCE(effect_value, 1.0) INTO v_route_capacity_event
            FROM game_events
            WHERE event_type = 'weather_disruption' AND is_active = true
              AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
              AND start_game_time <= p_target_game_time
              AND end_game_time > p_target_game_time
            ORDER BY start_game_time DESC
            LIMIT 1;
            IF NOT FOUND THEN
                v_route_capacity_event := 1.0;
            END IF;

            v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
            v_flight_duration := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0))
                               + v_turnaround_hours;
            IF v_flight_duration <= 0 THEN
                CONTINUE;
            END IF;

            v_max_weekly_flights := FLOOR(168.0 / v_flight_duration)::INT;
            v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);
            v_airport_demand := calculate_airport_demand_factor(
                v_route.origin_demand,
                v_route.dest_demand
            );
            v_demand_multiplier := calculate_route_demand_multiplier(
                v_route.distance_km,
                v_route.ticket_price
            ) * v_route_demand_event;
            v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);
            v_passengers := LEAST(
                v_effective_capacity,
                FLOOR(
                    v_effective_capacity * 0.95
                    * v_airport_demand
                    * v_demand_multiplier
                    * v_seasonal_multiplier
                )
            );

            v_revenue := v_flights * v_route.ticket_price * v_passengers * v_time_fraction;
            v_fuel_cost := v_flights * v_route.distance_km
                         * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier
                         * v_time_fraction;
            v_crew_cost := v_flights * v_flight_duration * v_crew_cost_per_hour * v_time_fraction;
            v_maint_cost := v_flights * v_route.distance_km
                          * v_route.maintenance_cost_per_hour
                          * COALESCE(v_maintenance_multiplier, 1.0)
                          / NULLIF(v_route.speed_kmh, 0)
                          * v_time_fraction;
            v_cargo_rev := v_revenue * COALESCE(get_config_numeric('cargo_revenue_percentage'), 0.05);
            v_lease_cost := CASE
                WHEN EXISTS (
                    SELECT 1
                    FROM fleet_aircraft fa2
                    WHERE fa2.id = v_route.assigned_aircraft_id
                      AND fa2.acquisition_type = 'lease'
                ) THEN COALESCE(v_route.lease_price_per_month, 0) * (v_game_days / 30.0)
                ELSE 0
            END;

            PERFORM credit_bank_account(
                r_bot.id,
                v_revenue,
                'revenue',
                'ticket_revenue',
                'Bot route ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM credit_bank_account(
                r_bot.id,
                v_cargo_rev,
                'revenue',
                'cargo_revenue',
                'Bot cargo: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_fuel_cost,
                'cogs',
                'fuel_cost',
                'Bot fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_crew_cost,
                'cogs',
                'crew_cost',
                'Bot crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_maint_cost,
                'cogs',
                'maintenance_cost',
                'Bot maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            IF v_lease_cost > 0 THEN
                PERFORM debit_bank_account(
                    r_bot.id,
                    v_lease_cost,
                    'opex',
                    'aircraft_lease',
                    'Bot lease: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                    p_target_game_time
                );
            END IF;

            v_wear_per_cycle := CASE
                WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
                ELSE v_owned_wear
            END + (v_route.distance_km * 0.0001);
            v_gross_damage := v_wear_per_cycle * v_flights * v_time_fraction;
            v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
            v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

            UPDATE fleet_aircraft
            SET condition = GREATEST(0, condition - v_net_damage)
            WHERE id = v_route.assigned_aircraft_id;
        END LOOP;

        SELECT COALESCE(SUM(am.lease_price_per_month * (v_game_days / 30.0)), 0)
        INTO v_idle_lease_cost
        FROM fleet_aircraft fa
        JOIN aircraft_models am ON am.id = fa.aircraft_model_id
        WHERE fa.user_id = r_bot.id
          AND fa.acquisition_type = 'lease'
          AND NOT EXISTS (
              SELECT 1
              FROM route_assignments ra
              WHERE ra.assigned_aircraft_id = fa.id
                AND ra.status = 'active'
          );

        IF v_idle_lease_cost > 0 THEN
            PERFORM debit_bank_account(
                r_bot.id,
                v_idle_lease_cost,
                'opex',
                'aircraft_lease_idle',
                'Bot idle lease carrying cost',
                p_target_game_time
            );
        END IF;

        IF date_trunc('day', r_bot.game_current_time)::DATE <>
           date_trunc('day', p_target_game_time)::DATE THEN
            PERFORM process_actor_day_boundary(r_bot.id, p_target_game_time);
            PERFORM check_achievements(r_bot.id, p_target_game_time);
        END IF;

        UPDATE users
        SET game_current_time = p_target_game_time,
            last_active_at = NOW()
        WHERE id = r_bot.id;

        v_processed := v_processed + 1;
    END LOOP;

    RETURN v_processed;
END;
$$;


ALTER FUNCTION "public"."process_all_bots_simulation_to_time"("p_target_game_time" timestamp with time zone, "p_season_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."process_all_bots_simulation_to_time"("p_target_game_time" timestamp with time zone, "p_season_id" "uuid") IS 'Simulates all AI bots forward to the given game time. Fixed: uses m.capacity (not m.passenger_capacity) for aircraft_models.';



CREATE OR REPLACE FUNCTION "public"."process_credit_at_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
    PERFORM update_credit_score(p_user_id, p_game_date);

    INSERT INTO credit_score_history (
        user_id, game_date, score, tier,
        fleet_health_score, revenue_stability_score,
        debt_ratio_score, cash_reserves_score, profit_history_score
    )
    SELECT
        p_user_id,
        p_game_date,
        cs.score,
        cs.tier,
        cs.fleet_health_score,
        cs.revenue_stability_score,
        cs.debt_ratio_score,
        cs.cash_reserves_score,
        cs.profit_history_score
    FROM credit_scores cs
    WHERE cs.user_id = p_user_id
    ON CONFLICT (user_id, game_date) DO NOTHING;
END;
$$;


ALTER FUNCTION "public"."process_credit_at_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_loan_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
    v_actor_type       VARCHAR(10);
    r_loan             RECORD;
    v_cash             NUMERIC;
    v_payment          NUMERIC;
    v_late_fee         NUMERIC;
    v_effective_weekly NUMERIC;
BEGIN
    SELECT actor_type INTO v_actor_type FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN; END IF;

    v_cash := get_user_balance(p_user_id);

    FOR r_loan IN
        SELECT *
        FROM loans
        WHERE user_id = p_user_id
          AND status = 'active'
          AND loan_type != 'aircraft_financing'
        ORDER BY taken_at ASC
    LOOP
        IF COALESCE(r_loan.weekly_payment, 0) > 0 THEN
            v_effective_weekly := r_loan.weekly_payment;
        ELSIF COALESCE(r_loan.monthly_payment, 0) > 0 THEN
            v_effective_weekly := r_loan.monthly_payment / 4.33;
        ELSE
            CONTINUE;
        END IF;

        IF v_actor_type = 'AI' THEN
            IF v_cash >= v_effective_weekly THEN
                PERFORM debit_bank_account(
                    p_user_id,
                    v_effective_weekly,
                    'financing',
                    'loan_payment',
                    'Weekly loan payment',
                    p_game_date
                );
                v_cash := v_cash - v_effective_weekly;

                UPDATE loans
                SET remaining_balance = remaining_balance - v_effective_weekly
                WHERE id = r_loan.id;

                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans
                    SET status = 'paid_off',
                        remaining_balance = 0
                    WHERE id = r_loan.id;
                END IF;
            ELSE
                v_late_fee := v_effective_weekly * 0.10;

                UPDATE loans
                SET remaining_balance = remaining_balance + v_late_fee,
                    missed_payments = missed_payments + 1
                WHERE id = r_loan.id;

                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans
                    SET status = 'defaulted'
                    WHERE id = r_loan.id;
                END IF;
            END IF;
        ELSE
            v_payment := v_effective_weekly;

            IF v_cash >= v_payment THEN
                PERFORM debit_bank_account(
                    p_user_id,
                    v_payment,
                    'financing',
                    'loan_payment',
                    'Weekly loan payment',
                    p_game_date
                );
                v_cash := v_cash - v_payment;

                UPDATE loans
                SET remaining_balance = remaining_balance - v_payment
                WHERE id = r_loan.id;

                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans
                    SET status = 'paid_off',
                        remaining_balance = 0
                    WHERE id = r_loan.id;
                END IF;
            ELSE
                v_late_fee := v_payment * 0.10;

                UPDATE loans
                SET remaining_balance = remaining_balance + v_late_fee,
                    missed_payments = missed_payments + 1
                WHERE id = r_loan.id;

                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans
                    SET status = 'defaulted'
                    WHERE id = r_loan.id;

                    IF r_loan.collateral_aircraft_id IS NOT NULL THEN
                        UPDATE fleet_aircraft
                        SET status = 'grounded'
                        WHERE id = r_loan.collateral_aircraft_id;
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."process_loan_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."process_loan_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) IS 'Process loan payments. Bot (actor_type=AI) uses simplified 10% penalty. Player uses tier-based late fees with collateral seizure.';



CREATE OR REPLACE FUNCTION "public"."process_player_simulation_to_time"("p_user_id" "uuid", "p_target_game_time" timestamp with time zone) RETURNS TABLE("game_time" timestamp with time zone, "cash" numeric, "flights_run" integer, "elapsed_days" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    r_user                RECORD;
    v_route               RECORD;
    v_flight_hours        NUMERIC;
    v_revenue             NUMERIC;
    v_ops_cost            NUMERIC;
    v_lease_cost          NUMERIC;
    v_idle_lease_cost     NUMERIC := 0;
    v_cash_after          NUMERIC;
    v_elapsed_days        NUMERIC;
    v_wear_per_cycle      NUMERIC(8,4);
    v_gross_damage        NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage          NUMERIC(20,4);
    v_cargo_rev           NUMERIC(20,2);
    v_turnaround_hours    NUMERIC;
    v_demand_multiplier   NUMERIC;
    v_crew_cost           NUMERIC;
    v_fuel_price          NUMERIC;
    v_seasonal_factor     NUMERIC;
    v_fuel_price_multiplier   NUMERIC := 1.0;
    v_maintenance_multiplier  NUMERIC := 1.0;
    v_route_demand_event      NUMERIC;
    v_route_capacity_event    NUMERIC;
    v_effective_capacity      NUMERIC;
    v_time_fraction           NUMERIC;
    v_fuel_cost               NUMERIC;
    v_crew_cost_total         NUMERIC;
    v_maint_cost              NUMERIC;
    v_owned_wear              NUMERIC;
    v_leased_wear             NUMERIC;
    v_auto_repair_rate        NUMERIC;
    v_bankruptcy_threshold    NUMERIC;
    v_airport_demand          NUMERIC;
    v_flights_run             INT := 0;
    v_total_revenue           NUMERIC;
    v_total_fuel_cost         NUMERIC;
    v_total_crew_cost         NUMERIC;
    v_total_maint_cost        NUMERIC;
    v_max_weekly_flights      INT;
    v_flights                 INT;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    v_fuel_price := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_crew_cost := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
    v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);

    SELECT COALESCE(effect_value, 1.0) INTO v_fuel_price_multiplier
    FROM game_events
    WHERE event_type = 'fuel_shock' AND is_active = true
      AND effect_type = 'fuel_price'
      AND start_game_time <= p_target_game_time
      AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC
    LIMIT 1;
    IF NOT FOUND THEN
        v_fuel_price_multiplier := 1.0;
    END IF;

    SELECT COALESCE(effect_value, 1.0) INTO v_maintenance_multiplier
    FROM game_events
    WHERE event_type = 'maintenance_shock' AND is_active = true
      AND effect_type = 'maintenance_cost'
      AND start_game_time <= p_target_game_time
      AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC
    LIMIT 1;
    IF NOT FOUND THEN
        v_maintenance_multiplier := 1.0;
    END IF;

    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;

    -- Migration 21: zero-interval guard — skip simulation when no time elapsed
    IF COALESCE(v_elapsed_days, 0) <= 0 THEN
        UPDATE users u
        SET last_active_at = NOW()
        WHERE u.id = p_user_id;

        game_time := r_user.game_current_time;
        cash := get_user_balance(p_user_id);
        flights_run := 0;
        elapsed_days := 0;
        RETURN NEXT;
        RETURN;
    END IF;

    v_time_fraction := LEAST(v_elapsed_days / 7.0, 1.0);

    FOR v_route IN
        SELECT ur.*, am.fuel_burn_per_km, am.speed_kmh, am.turnaround_hours,
               am.capacity, am.lease_price_per_month, am.maintenance_cost_per_hour,
               fa.acquisition_type,
               a1.demand_index AS origin_demand, a2.demand_index AS dest_demand
        FROM route_assignments ur
        JOIN fleet_aircraft fa ON fa.id = ur.assigned_aircraft_id
        JOIN aircraft_models am ON am.id = fa.aircraft_model_id
        JOIN airports a1 ON a1.iata = ur.origin_iata
        JOIN airports a2 ON a2.iata = ur.destination_iata
        WHERE ur.user_id = p_user_id
          AND ur.status = 'active'
          AND fa.status = 'active'
          -- Migration 20260710190000: respect absolute_minimum_safety_limit
          AND fa.condition >= GREATEST(COALESCE(r_user.auto_grounding_threshold, 40.00), COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00))
    LOOP
        v_route_demand_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_demand_event
        FROM game_events
        WHERE event_type = 'demand_surge' AND is_active = true
          AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
          AND start_game_time <= p_target_game_time
          AND end_game_time > p_target_game_time
        ORDER BY start_game_time DESC
        LIMIT 1;
        IF NOT FOUND THEN
            v_route_demand_event := 1.0;
        END IF;

        v_route_capacity_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_capacity_event
        FROM game_events
        WHERE event_type = 'weather_disruption' AND is_active = true
          AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
          AND start_game_time <= p_target_game_time
          AND end_game_time > p_target_game_time
        ORDER BY start_game_time DESC
        LIMIT 1;
        IF NOT FOUND THEN
            v_route_capacity_event := 1.0;
        END IF;

        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
        v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
        IF v_flight_hours <= 0 THEN
            CONTINUE;
        END IF;

        -- Migration 20260710190000: cap flights at physical maximum
        v_max_weekly_flights := FLOOR(168.0 / v_flight_hours)::INT;
        v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);

        v_airport_demand := calculate_airport_demand_factor(
            v_route.origin_demand,
            v_route.dest_demand
        );
        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price)
                             * v_route_demand_event;
        v_seasonal_factor := 1.0;
        v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);

        -- Use v_flights (capped) instead of raw flights_per_week
        v_revenue := v_flights * v_route.ticket_price
                   * LEAST(
                        v_effective_capacity,
                        FLOOR(
                            v_effective_capacity * 0.95
                            * v_airport_demand
                            * v_demand_multiplier
                            * v_seasonal_factor
                        )
                     );

        v_fuel_cost := v_flights * v_route.distance_km
                     * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
        v_crew_cost_total := v_flights * v_flight_hours * v_crew_cost;
        v_maint_cost := v_flights * v_route.distance_km
                      * COALESCE(v_route.maintenance_cost_per_hour, 0)
                      * COALESCE(v_maintenance_multiplier, 1.0)
                      / NULLIF(v_route.speed_kmh, 0);
        v_ops_cost := v_fuel_cost + v_crew_cost_total + v_maint_cost;
        v_lease_cost := CASE
            WHEN EXISTS (
                SELECT 1
                FROM fleet_aircraft fa2
                WHERE fa2.id = v_route.assigned_aircraft_id
                  AND fa2.acquisition_type = 'lease'
            ) THEN COALESCE(v_route.lease_price_per_month, 0) * (v_elapsed_days / 30.0)
            ELSE 0
        END;

        v_revenue := v_revenue * v_time_fraction;
        v_ops_cost := v_ops_cost * v_time_fraction;
        -- Migration 33: cargo revenue percentage from game_config
        v_cargo_rev := v_revenue * COALESCE(get_config_numeric('cargo_revenue_percentage'), 0.05);
        -- Migration 20260710150000: cargo split out of ticket revenue
        v_total_revenue := v_revenue;
        v_total_fuel_cost := v_fuel_cost * v_time_fraction;
        v_total_crew_cost := v_crew_cost_total * v_time_fraction;
        v_total_maint_cost := v_maint_cost * v_time_fraction;

        IF v_total_revenue > 0 THEN
            PERFORM credit_bank_account(
                p_user_id,
                v_total_revenue,
                'revenue',
                'ticket_revenue',
                'Route ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
        END IF;
        -- Migration 20260710150000: separate cargo revenue credit
        IF v_cargo_rev > 0 THEN
            PERFORM credit_bank_account(
                p_user_id,
                v_cargo_rev,
                'revenue',
                'cargo_revenue',
                'Cargo: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
        END IF;
        -- Migration 20260710150000: IFRS subcategories use _cost suffix
        IF v_total_fuel_cost > 0 THEN
            PERFORM debit_bank_account(
                p_user_id,
                v_total_fuel_cost,
                'cogs',
                'fuel_cost',
                'Fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
        END IF;
        IF v_total_crew_cost > 0 THEN
            PERFORM debit_bank_account(
                p_user_id,
                v_total_crew_cost,
                'cogs',
                'crew_cost',
                'Crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
        END IF;
        IF v_total_maint_cost > 0 THEN
            PERFORM debit_bank_account(
                p_user_id,
                v_total_maint_cost,
                'cogs',
                'maintenance_cost',
                'Maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
        END IF;
        IF v_lease_cost > 0 THEN
            PERFORM debit_bank_account(
                p_user_id,
                v_lease_cost,
                'opex',
                'aircraft_lease',
                'Lease: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
        END IF;

        v_wear_per_cycle := CASE
            WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
            ELSE v_owned_wear
        END + (v_route.distance_km * 0.0001);
        -- Migration 20260710120000: wear uses v_time_fraction; migration 20260710190000: uses v_flights
        v_gross_damage := v_wear_per_cycle * v_flights * v_time_fraction;
        v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
        v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

        UPDATE fleet_aircraft
        SET condition = GREATEST(0, condition - v_net_damage)
        WHERE id = v_route.assigned_aircraft_id;

        v_flights_run := v_flights_run + (v_flights * v_elapsed_days / 7.0)::INT;
    END LOOP;

    SELECT COALESCE(SUM(am.lease_price_per_month * (v_elapsed_days / 30.0)), 0)
    INTO v_idle_lease_cost
    FROM fleet_aircraft fa
    JOIN aircraft_models am ON am.id = fa.aircraft_model_id
    WHERE fa.user_id = p_user_id
      AND fa.acquisition_type = 'lease'
      AND NOT EXISTS (
          SELECT 1
          FROM route_assignments ra
          WHERE ra.assigned_aircraft_id = fa.id
            AND ra.status = 'active'
      );

    IF v_idle_lease_cost > 0 THEN
        PERFORM debit_bank_account(
            p_user_id,
            v_idle_lease_cost,
            'opex',
            'aircraft_lease_idle',
            'Idle lease carrying cost',
            p_target_game_time
        );
    END IF;

    v_cash_after := get_user_balance(p_user_id);

    UPDATE users u
    SET game_current_time = p_target_game_time,
        last_active_at = NOW()
    WHERE u.id = p_user_id;

    -- Migration 22: consolidated bankruptcy via helper
    IF v_cash_after <= v_bankruptcy_threshold THEN
        PERFORM apply_actor_bankruptcy_state(p_user_id);
    END IF;

    IF date_trunc('day', r_user.game_current_time)::DATE <>
       date_trunc('day', p_target_game_time)::DATE THEN
        -- Migration 34: pass elapsed_days for multi-week payment catch-up
        PERFORM process_actor_day_boundary(p_user_id, p_target_game_time, v_elapsed_days);
        PERFORM check_achievements(p_user_id, p_target_game_time);
    END IF;

    game_time := p_target_game_time;
    cash := get_user_balance(p_user_id);
    flights_run := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."process_player_simulation_to_time"("p_user_id" "uuid", "p_target_game_time" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_simulation_delta"() RETURNS TABLE("cash_before" numeric, "cash_after" numeric, "elapsed_real_sec" double precision, "elapsed_game_days" double precision, "flights_run" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();

    RETURN QUERY
    SELECT *
    FROM process_simulation_delta(v_user_id);
END;
$$;


ALTER FUNCTION "public"."process_simulation_delta"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_simulation_delta"("p_user_id" "uuid") RETURNS TABLE("cash_before" numeric, "cash_after" numeric, "elapsed_real_sec" double precision, "elapsed_game_days" double precision, "flights_run" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
    v_season_time TIMESTAMPTZ;
    v_result RECORD;
BEGIN
    SELECT current_game_time INTO v_season_time
    FROM season_clock WHERE status = 'active' LIMIT 1;

    IF v_season_time IS NULL THEN
        RAISE EXCEPTION 'No active season found';
    END IF;

    SELECT * INTO v_result
    FROM process_player_simulation_to_time(p_user_id, v_season_time);

    cash_before := 0;
    cash_after := v_result.cash;
    elapsed_real_sec := 0;
    elapsed_game_days := v_result.elapsed_days;
    flights_run := v_result.flights_run;
    RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."process_simulation_delta"("p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."process_simulation_delta"("p_user_id" "uuid") IS 'Compatibility RPC for Flutter. Ensures the world clock is current via ensure_world_current → process_world_tick, then syncs the player actor to season_clock. Bot simulation runs ONLY inside process_world_tick; this function must never call execute_bot_decisions or process_all_bots_simulation directly.';



CREATE OR REPLACE FUNCTION "public"."process_world_tick"("p_season_id" "uuid" DEFAULT NULL::"uuid", "p_max_ticks" integer DEFAULT 10) RETURNS TABLE("season_id" "uuid", "ticks_processed" integer, "game_time_after" timestamp with time zone, "players_processed" integer, "bots_processed" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
    r_season RECORD;
    v_game_time_before TIMESTAMPTZ;
    v_game_time_after TIMESTAMPTZ;
    v_ticks_processed INT := 0;
    v_players_processed INT := 0;
    v_bots_processed INT := 0;
    r_user RECORD;
    r_player_result RECORD;
    v_lock_key BIGINT;
    v_error_msg TEXT;
    v_start_time TIMESTAMPTZ;
BEGIN
    v_start_time := NOW();

    IF p_season_id IS NOT NULL THEN
        SELECT * INTO r_season FROM season_clock WHERE id = p_season_id;
    ELSE
        SELECT * INTO r_season FROM season_clock WHERE status = 'active' LIMIT 1;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active season found';
    END IF;

    v_lock_key := hashtext(r_season.id::text);
    IF NOT pg_try_advisory_xact_lock(v_lock_key) THEN
        RAISE EXCEPTION 'World tick already in progress for season %', r_season.id;
    END IF;

    v_game_time_before := r_season.current_game_time;
    v_game_time_after := r_season.current_game_time
        + (r_season.tick_interval_seconds * r_season.time_scale_multiplier * INTERVAL '1 second');

    PERFORM generate_game_events(v_game_time_after);
    PERFORM deactivate_expired_events(v_game_time_after);

    FOR r_user IN
        SELECT u.id, u.game_current_time
        FROM users u
        WHERE u.season_id = r_season.id
          AND u.actor_type = 'REAL'
          AND COALESCE(u.operational_status, 'Active') != 'Bankrupt'
    LOOP
        BEGIN
            SELECT * INTO r_player_result
            FROM process_player_simulation_to_time(r_user.id, v_game_time_after)
            LIMIT 1;

            IF COALESCE(r_player_result.elapsed_days, 0.0) > 0.0 THEN
                v_players_processed := v_players_processed + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_error_msg = MESSAGE_TEXT;
            INSERT INTO world_tick_log (season_id, status, message, started_at, finished_at)
            VALUES (
                r_season.id,
                'player_error',
                'Player ' || r_user.id || ': ' || v_error_msg,
                NOW(),
                NOW()
            );
        END;
    END LOOP;

    v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);

    -- Humanized bot behavior uses sub-day cooldowns, so decisions must be tick-based.
    PERFORM execute_bot_decisions();

    UPDATE season_clock
    SET current_game_time = v_game_time_after,
        last_tick_at = NOW(),
        updated_at = NOW()
    WHERE id = r_season.id;

    v_ticks_processed := 1;

    INSERT INTO world_tick_log (
        season_id,
        started_at,
        finished_at,
        game_time_before,
        game_time_after,
        ticks_processed,
        players_processed,
        bots_processed,
        status,
        message
    ) VALUES (
        r_season.id,
        v_start_time,
        NOW(),
        v_game_time_before,
        v_game_time_after,
        1,
        v_players_processed,
        v_bots_processed,
        'success',
        'Tick completed successfully'
    );

    season_id := r_season.id;
    ticks_processed := v_ticks_processed;
    game_time_after := v_game_time_after;
    players_processed := v_players_processed;
    bots_processed := v_bots_processed;
    RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."process_world_tick"("p_season_id" "uuid", "p_max_ticks" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prune_bank_transactions"("p_dry_run" boolean DEFAULT true) RETURNS TABLE("action" "text", "detail" "text", "row_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
v_retention_days INT;
v_season_game_time TIMESTAMPTZ;
v_cutoff TIMESTAMPTZ;
v_count BIGINT := 0;
BEGIN
SELECT current_game_time
  INTO v_season_game_time
  FROM season_clock
 WHERE status = 'active'
 ORDER BY created_at ASC
 LIMIT 1;

IF v_season_game_time IS NULL THEN
  action := 'skip';
  detail := 'No active season clock found';
  row_count := 0;
  RETURN NEXT;
  RETURN;
END IF;

v_retention_days := COALESCE(
  get_config_int('bank_txn_raw_retention_game_days'),
  180
);
v_cutoff := v_season_game_time - (v_retention_days || ' days')::INTERVAL;

SELECT COUNT(*)
  INTO v_count
  FROM bank_transactions
 WHERE game_date IS NOT NULL
   AND game_date < v_cutoff;

IF NOT p_dry_run AND v_count > 0 THEN
  DELETE FROM bank_transactions
   WHERE game_date IS NOT NULL
     AND game_date < v_cutoff;
END IF;

action := 'delete';
detail := CASE
  WHEN p_dry_run THEN 'Rows that would be deleted'
  ELSE 'Rows deleted'
END;
row_count := v_count;
RETURN NEXT;
END;
$$;


ALTER FUNCTION "public"."prune_bank_transactions"("p_dry_run" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prune_world_tick_log"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_retention_days INT;
    v_cutoff TIMESTAMPTZ;
BEGIN
    v_retention_days := COALESCE(get_config_int('world_tick_log_raw_real_days'), 7);
    v_cutoff := NOW() - (v_retention_days || ' days')::INTERVAL;
    DELETE FROM world_tick_log WHERE started_at < v_cutoff;
END;
$$;


ALTER FUNCTION "public"."prune_world_tick_log"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."purchase_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer DEFAULT NULL::integer, "p_business_seats" integer DEFAULT 0, "p_first_class_seats" integer DEFAULT 0) RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM purchase_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$$;


ALTER FUNCTION "public"."purchase_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."purchase_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer DEFAULT NULL::integer, "p_business_seats" integer DEFAULT 0, "p_first_class_seats" integer DEFAULT 0) RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
v_cash NUMERIC; v_price NUMERIC; v_model_name VARCHAR; v_capacity INT;
v_hq_iata VARCHAR(3); v_tail VARCHAR(20); v_economy INT; v_business INT; v_first INT; v_slots_used INT;
v_game_time TIMESTAMPTZ;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
v_cash := get_user_balance(p_user_id);
SELECT hq_airport_iata, game_current_time INTO v_hq_iata, v_game_time
FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC; RETURN; END IF;
SELECT purchase_price, model_name, capacity INTO v_price, v_model_name, v_capacity
FROM aircraft_models WHERE id = p_model_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash; RETURN; END IF;
v_economy := COALESCE(p_economy_seats, v_capacity);
v_business := COALESCE(p_business_seats, 0);
v_first := COALESCE(p_first_class_seats, 0);
v_slots_used := v_economy + (v_business * 2) + (v_first * 3);
IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash; RETURN;
END IF;
IF v_cash < v_price THEN
RETURN QUERY SELECT FALSE, ('Insufficient funds to purchase ' || v_model_name || '.')::VARCHAR, v_cash; RETURN;
END IF;
LOOP v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
EXIT WHEN NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_tail);
END LOOP;
PERFORM debit_bank_account(p_user_id, v_price, 'investing', 'aircraft_purchase',
'Purchased aircraft ' || v_model_name || ' [' || v_tail || ']', v_game_time);
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'purchase', 100.00, 'active', v_tail, v_economy, v_business, v_first);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, ('Successfully purchased ' || v_model_name || ' [' || v_tail || ']')::VARCHAR, v_cash;
END;
$$;


ALTER FUNCTION "public"."purchase_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refinance_loan"("p_loan_id" "uuid") RETURNS TABLE("success" boolean, "message" "text", "new_rate" numeric, "savings" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_user_id UUID;
    v_loan RECORD;
    v_tier VARCHAR(10);
    v_tier_cfg JSONB;
    v_new_rate NUMERIC;
    v_old_total NUMERIC;
    v_outstanding_principal NUMERIC;
    v_new_total NUMERIC;
    v_savings NUMERIC;
    v_remaining_periods NUMERIC;
    v_weekly_payment NUMERIC;
    v_monthly_payment NUMERIC;
    v_game_time TIMESTAMPTZ;
BEGIN
    v_user_id := require_current_user_id();

    SELECT *
    INTO v_loan
    FROM loans
    WHERE id = p_loan_id
      AND user_id = v_user_id
      AND status = 'active';
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Loan not found or not active.'::TEXT, 0::NUMERIC, 0::NUMERIC;
        RETURN;
    END IF;

    -- Game-clock lookup (migration 31 pattern)
    SELECT game_current_time INTO v_game_time
    FROM users
    WHERE id = v_user_id
    FOR UPDATE;

    -- Use shared tier policy for rate determination (migration 10 approach)
    SELECT tier INTO v_tier FROM credit_scores WHERE user_id = v_user_id;
    v_tier := COALESCE(v_tier, 'Standard');
    v_tier_cfg := get_credit_tier_policy(v_tier);

    IF v_loan.loan_type IN ('secured', 'aircraft_financing') THEN
        v_new_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
    ELSIF v_loan.loan_type = 'credit_line' THEN
        v_new_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07) + 0.02;
    ELSE
        v_new_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
    END IF;

    IF v_new_rate >= v_loan.interest_rate THEN
        RETURN QUERY SELECT false, 'Current rate is not better than existing rate.'::TEXT, 0::NUMERIC, 0::NUMERIC;
        RETURN;
    END IF;

    -- Derive outstanding principal from remaining_balance (migration 10 fix)
    v_old_total := COALESCE(v_loan.remaining_balance, 0);
    v_outstanding_principal := v_old_total / (1 + COALESCE(v_loan.interest_rate, 0));

    IF COALESCE(v_loan.term_months, 0) > 0 THEN
        v_remaining_periods := GREATEST(
            1,
            CEIL(
                v_old_total / NULLIF(COALESCE(v_loan.monthly_payment, v_loan.weekly_payment * 4.33), 0)
            )
        );
        v_new_total := v_outstanding_principal * (1 + v_new_rate);
        v_monthly_payment := v_new_total / v_remaining_periods;
        v_weekly_payment := v_monthly_payment / 4.33;
    ELSE
        v_remaining_periods := GREATEST(
            1,
            CEIL(v_old_total / NULLIF(COALESCE(v_loan.weekly_payment, 0), 0))
        );
        v_new_total := v_outstanding_principal * (1 + v_new_rate);
        v_weekly_payment := v_new_total / v_remaining_periods;
        v_monthly_payment := v_weekly_payment * 4.33;
    END IF;

    v_savings := GREATEST(0, v_old_total - v_new_total);

    UPDATE loans
    SET interest_rate = v_new_rate,
        remaining_balance = v_new_total,
        weekly_payment = v_weekly_payment,
        monthly_payment = v_monthly_payment
    WHERE id = p_loan_id;

    RETURN QUERY SELECT true, 'Loan refinanced successfully.'::TEXT, v_new_rate, v_savings;
END;
$$;


ALTER FUNCTION "public"."refinance_loan"("p_loan_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."repair_aircraft"("p_fleet_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM repair_aircraft(v_user_id, p_fleet_id);
END;
$$;


ALTER FUNCTION "public"."repair_aircraft"("p_fleet_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."repair_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_success BOOLEAN;
    v_message VARCHAR;
    v_new_cash NUMERIC;
    v_repair_cost NUMERIC;
BEGIN
    PERFORM 1
      FROM process_simulation_delta(p_user_id);

    SELECT h.success, h.message, h.new_cash, h.repair_cost
      INTO v_success, v_message, v_new_cash, v_repair_cost
      FROM perform_actor_aircraft_repair(
          p_user_id,
          p_fleet_id
      ) h;

    RETURN QUERY
    SELECT v_success, v_message, v_new_cash;
END;
$$;


ALTER FUNCTION "public"."repair_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."repay_loan"("p_loan_id" "uuid", "p_amount" numeric DEFAULT NULL::numeric) RETURNS TABLE("success" boolean, "message" "text", "new_cash" numeric, "paid_off" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  v_user_id UUID; v_loan RECORD; v_payment NUMERIC; v_cash NUMERIC;
  v_is_paid_off BOOLEAN := false; v_game_time TIMESTAMPTZ;
BEGIN
  v_user_id := require_current_user_id();
  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';
  IF NOT FOUND THEN RETURN QUERY SELECT false, 'Loan not found or already paid off.'::TEXT, 0::NUMERIC, false; RETURN; END IF;
  IF p_amount IS NULL THEN v_payment := v_loan.remaining_balance;
  ELSE v_payment := LEAST(p_amount, v_loan.remaining_balance); END IF;
  IF v_payment <= 0 THEN RETURN QUERY SELECT false, 'Payment amount must be positive.'::TEXT, 0::NUMERIC, false; RETURN; END IF;
  v_cash := get_user_balance(v_user_id);
  SELECT game_current_time INTO v_game_time
  FROM users
  WHERE id = v_user_id;
  IF v_cash < v_payment THEN
    RETURN QUERY SELECT false, 'Insufficient cash. Need $' || v_payment::TEXT || ', have $' || v_cash::TEXT || '.'::TEXT, v_cash, false; RETURN;
  END IF;
  PERFORM debit_bank_account(v_user_id, v_payment, 'financing', 'loan_repayment',
    CASE WHEN v_loan.remaining_balance - v_payment <= 0 THEN 'Loan fully repaid' ELSE 'Loan partial repayment' END,
    v_game_time);
  UPDATE loans
  SET remaining_balance = remaining_balance - v_payment,
      status = CASE WHEN remaining_balance - v_payment <= 0 THEN 'paid_off'::VARCHAR ELSE status END
  WHERE id = p_loan_id;
  v_is_paid_off := (SELECT remaining_balance <= 0 FROM loans WHERE id = p_loan_id);
  -- Transition financed aircraft to owned when loan is fully repaid
  IF v_is_paid_off AND v_loan.loan_type = 'aircraft_financing' AND v_loan.collateral_aircraft_id IS NOT NULL THEN
    UPDATE fleet_aircraft
    SET acquisition_type = 'purchase'
    WHERE id = v_loan.collateral_aircraft_id
      AND user_id = v_user_id
      AND acquisition_type = 'finance';
  END IF;
  v_cash := get_user_balance(v_user_id);
  RETURN QUERY SELECT true,
    CASE WHEN v_is_paid_off THEN 'Loan fully repaid!'
    ELSE 'Payment of $' || v_payment::TEXT || ' applied.' END::TEXT,
    v_cash, v_is_paid_off;
END;
$_$;


ALTER FUNCTION "public"."repay_loan"("p_loan_id" "uuid", "p_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."require_current_user_id"() RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
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
$$;


ALTER FUNCTION "public"."require_current_user_id"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."require_current_user_id"() IS 'Returns the current public.users.id resolved from auth.uid(), or raises if the authenticated caller is not mapped to a Skyward player row.';



CREATE OR REPLACE FUNCTION "public"."reset_user_airline"() RETURNS TABLE("success" boolean, "message" "text")
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM reset_user_airline(v_user_id);
END;
$$;


ALTER FUNCTION "public"."reset_user_airline"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_user_airline"("p_user_id" "uuid") RETURNS TABLE("success" boolean, "message" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RETURN QUERY SELECT FALSE, 'User not found'; RETURN;
    END IF;

    DELETE FROM bank_transactions WHERE user_id = p_user_id;
    DELETE FROM bank_accounts WHERE user_id = p_user_id;
    DELETE FROM loans WHERE user_id = p_user_id;
    DELETE FROM credit_scores WHERE user_id = p_user_id;
    DELETE FROM credit_score_history WHERE user_id = p_user_id;
    DELETE FROM route_assignments WHERE user_id = p_user_id;
    DELETE FROM fleet_aircraft WHERE user_id = p_user_id;
    DELETE FROM achievements WHERE user_id = p_user_id;

    UPDATE users SET
        net_worth = 15000000.00,
        game_current_time = TIMESTAMP WITH TIME ZONE '2020-01-01 00:00:00+00',
        hq_airport_iata = 'SIN',
        auto_grounding_threshold = 40.00,
        operational_status = 'Active',
        consecutive_negative_days = 0,
        recovery_streak_days = 0,
        last_active_at = NOW(),
        onboarding_completed = false
    WHERE id = p_user_id;

    INSERT INTO bank_accounts (user_id, account_type, balance)
    VALUES (p_user_id, 'operating', 15000000.00);

    RETURN QUERY SELECT TRUE, 'Airline reset successfully';
END;
$$;


ALTER FUNCTION "public"."reset_user_airline"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_active_season_id"("p_season_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    v_season_id UUID;
BEGIN
    IF p_season_id IS NOT NULL THEN
        RETURN p_season_id;
    END IF;

    SELECT id
    INTO v_season_id
    FROM season_clock
    WHERE status = 'active'
    ORDER BY created_at ASC
    LIMIT 1;

    RETURN v_season_id;
END;
$$;


ALTER FUNCTION "public"."resolve_active_season_id"("p_season_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_credit_tier"("p_score" integer) RETURNS character varying
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_config     JSONB;
    v_tier_name  TEXT;
    v_tier_data  JSONB;
    v_best_tier  TEXT := 'Subprime';
    v_best_min   INT  := 0;
BEGIN
    SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';

    -- If no config found, use hardcoded defaults
    IF v_config IS NULL THEN
        RETURN CASE
            WHEN p_score >= 900 THEN 'Platinum'
            WHEN p_score >= 750 THEN 'Gold'
            WHEN p_score >= 600 THEN 'Silver'
            WHEN p_score >= 400 THEN 'Standard'
            ELSE 'Subprime'
        END;
    END IF;

    -- Iterate tier definitions at root level of the config JSONB.
    -- Seed data shape: {"Platinum":{"min":800,"max":1000,"rate":0.03}, ...}
    FOR v_tier_name, v_tier_data IN SELECT key, value FROM jsonb_each(v_config)
    LOOP
        -- Skip non-object entries (safety)
        IF jsonb_typeof(v_tier_data) != 'object' THEN
            CONTINUE;
        END IF;

        -- Use 'min' key (matches seed data); fall back to 'min_score' for
        -- backwards-compatibility with any future config changes.
        IF p_score >= COALESCE((v_tier_data->>'min')::INT, (v_tier_data->>'min_score')::INT, 0) THEN
            IF COALESCE((v_tier_data->>'min')::INT, (v_tier_data->>'min_score')::INT, 0) >= v_best_min THEN
                v_best_tier := v_tier_name;
                v_best_min  := COALESCE((v_tier_data->>'min')::INT, (v_tier_data->>'min_score')::INT, 0);
            END IF;
        END IF;
    END LOOP;

    RETURN v_best_tier;
END;
$$;


ALTER FUNCTION "public"."resolve_credit_tier"("p_score" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_airline_settings"("p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM save_airline_settings(v_user_id, p_company_name, p_auto_grounding_threshold, p_hq_airport_iata);
END;
$$;


ALTER FUNCTION "public"."save_airline_settings"("p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_airline_settings"("p_user_id" "uuid", "p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    IF p_auto_grounding_threshold < 30.00 OR p_auto_grounding_threshold > 100.00 THEN
        RETURN QUERY SELECT FALSE, 'Safety threshold must be between 30 and 100.'::VARCHAR;
        RETURN;
    END IF;

    IF p_hq_airport_iata IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_hq_airport_iata) THEN
        RETURN QUERY SELECT FALSE, 'HQ airport not found.'::VARCHAR;
        RETURN;
    END IF;

    UPDATE users
    SET company_name = TRIM(p_company_name),
        auto_grounding_threshold = p_auto_grounding_threshold,
        hq_airport_iata = p_hq_airport_iata
    WHERE id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR;
        RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, 'Settings saved successfully.'::VARCHAR;
END;
$$;


ALTER FUNCTION "public"."save_airline_settings"("p_user_id" "uuid", "p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sell_actor_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_game_time" timestamp with time zone) RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
    v_fleet RECORD;
    v_base_value NUMERIC(20,2);
    v_age_years NUMERIC;
    v_depreciation_factor NUMERIC;
    v_sale_value NUMERIC(20,2);
BEGIN
    PERFORM 1 FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;
    SELECT f.*, m.model_name, m.purchase_price
    INTO v_fleet
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;
    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'purchase' THEN
        RETURN QUERY SELECT FALSE, 'Only owned aircraft can be sold.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;
    v_base_value := v_fleet.purchase_price * (v_fleet.condition / 100.00);
    IF v_fleet.acquired_game_date IS NOT NULL AND p_game_time IS NOT NULL THEN
        v_age_years := EXTRACT(EPOCH FROM (p_game_time - v_fleet.acquired_game_date)) / (365.25 * 86400.0);
        v_depreciation_factor := GREATEST(0.10, 1.0 - (0.05 * COALESCE(v_age_years, 0)));
        v_sale_value := ROUND(v_base_value * v_depreciation_factor, 2);
    ELSE
        v_sale_value := v_base_value;
    END IF;
    PERFORM credit_bank_account(
        p_user_id, v_sale_value, 'investing', 'aircraft_sale',
        'Sold aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
        p_game_time
    );
    DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;
    new_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT TRUE, ('Aircraft sold for $' || ROUND(v_sale_value, 2)::TEXT || '.')::VARCHAR, new_cash;
END;
$_$;


ALTER FUNCTION "public"."sell_actor_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_game_time" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sell_aircraft"("p_fleet_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM sell_aircraft(v_user_id, p_fleet_id);
END;
$$;


ALTER FUNCTION "public"."sell_aircraft"("p_fleet_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sell_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_game_time TIMESTAMPTZ;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
    RETURN QUERY SELECT * FROM sell_actor_aircraft(p_user_id, p_fleet_id, v_game_time);
END;
$$;


ALTER FUNCTION "public"."sell_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."sell_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") IS 'Sells owned aircraft. Sale value depreciated 5% per game-year of age (floor 10% of base value). Not SECURITY DEFINER — called from SD wrapper.';



CREATE OR REPLACE FUNCTION "public"."spawn_bot"() RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_bot_id        UUID;
    v_archetype     VARCHAR(30);
    v_hq            VARCHAR(3);
    v_bot_count     INT;
    v_max_bots      INT;
    v_username      VARCHAR(50);
    v_ceo_name      VARCHAR(100);
    v_company_name  VARCHAR(100);
    v_game_time     TIMESTAMPTZ;
    v_attempts      INT;
    v_inserted      BOOLEAN;
BEGIN
    -- Check active bot count vs configured max
    SELECT COUNT(*) INTO v_bot_count
      FROM users
     WHERE actor_type = 'AI'
       AND COALESCE(operational_status, 'Active') != 'Bankrupt';
    v_max_bots := COALESCE(get_config_int('max_bot_count'), 5);
    IF v_bot_count >= v_max_bots THEN
        RETURN NULL;
    END IF;

    -- Pick random archetype (weighted equally)
    v_archetype := (ARRAY['Regional', 'Aggressive', 'Balanced'])[1 + floor(random() * 3)];

    -- Pick random HQ from top-demand airports
    SELECT iata INTO v_hq
      FROM airports
     ORDER BY demand_index DESC, random()
     LIMIT 1;

    -- Get current game time from active season
    SELECT current_game_time INTO v_game_time
      FROM season_clock
     WHERE status = 'active'
     LIMIT 1;
    v_game_time := COALESCE(v_game_time, '2020-01-01 00:00:00+00');

    -- Generate unique username (internal identifier, not shown to players)
    v_username := 'bot_' || left(gen_random_uuid()::text, 8);

    -- Generate human-like names
    v_ceo_name := generate_ceo_name();

    -- FIX 9: Retry loop for company_name INSERT to handle UNIQUE collisions.
    -- Generate a new company_name on each attempt.
    v_attempts := 0;
    v_inserted := false;
    WHILE v_attempts < 10 AND NOT v_inserted LOOP
        v_company_name := generate_company_name(v_archetype);
        BEGIN
            INSERT INTO users (
                username, company_name, ceo_name, actor_type,
                hq_airport_iata, game_current_time, operational_status,
                net_worth, consecutive_negative_days, recovery_streak_days,
                auto_grounding_threshold
            ) VALUES (
                v_username,
                v_company_name,
                v_ceo_name,
                'AI',
                v_hq,
                v_game_time,
                'Active',
                15000000.00,
                0,
                0,
                40.00
            ) RETURNING id INTO v_bot_id;
            v_inserted := true;
        EXCEPTION
            WHEN unique_violation THEN
                -- Company name collided; regenerate a new one and retry.
                -- Also regenerate username in case that was the collision.
                v_username := 'bot_' || left(gen_random_uuid()::text, 8);
                v_attempts := v_attempts + 1;
        END;
    END LOOP;

    IF NOT v_inserted THEN
        RAISE NOTICE 'Failed to spawn bot after % attempts (company name collisions)', v_attempts;
        RETURN NULL;
    END IF;

    -- Create bot profile with archetype
    INSERT INTO bot_profiles (user_id, archetype)
    VALUES (v_bot_id, v_archetype);

    RAISE NOTICE 'Spawned bot "%" (CEO: %, Archetype: %, HQ: %)',
        v_company_name, v_ceo_name, v_archetype, v_hq;
    RETURN v_bot_id;
END;
$$;


ALTER FUNCTION "public"."spawn_bot"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."take_loan"("p_principal" numeric, "p_term_weeks" integer DEFAULT 52, "p_loan_type" character varying DEFAULT 'unsecured'::character varying, "p_collateral_aircraft_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("success" boolean, "message" "text", "new_cash" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := require_current_user_id();
    RETURN QUERY SELECT * FROM take_loan(v_user_id, p_principal, p_term_weeks, p_loan_type, p_collateral_aircraft_id);
END;
$$;


ALTER FUNCTION "public"."take_loan"("p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."take_loan"("p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") IS 'Process a loan application. Limits and rates read from global_game_settings.credit_tier_config.';



CREATE OR REPLACE FUNCTION "public"."take_loan"("p_user_id" "uuid", "p_principal" numeric, "p_term_weeks" integer DEFAULT 52, "p_loan_type" character varying DEFAULT 'unsecured'::character varying, "p_collateral_aircraft_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("success" boolean, "message" "text", "new_cash" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
    v_actor_type VARCHAR(10);
    v_existing_loans INT;
    v_credit_score INT;
    v_score_record RECORD;
    v_tier VARCHAR(10);
    v_config JSONB;
    v_tier_cfg JSONB;
    v_min_loan NUMERIC;
    v_max_loans INT;
    v_interest_rate NUMERIC;
    v_weekly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_max_principal NUMERIC;
    v_loan_id UUID;
BEGIN
    SELECT u.actor_type, u.game_current_time
    INTO v_actor_type, v_game_time
    FROM users u
    WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';
    v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
    v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);

    SELECT COUNT(*) INTO v_existing_loans
    FROM loans
    WHERE user_id = p_user_id
      AND status = 'active';
    IF v_existing_loans >= v_max_loans THEN
        RETURN QUERY SELECT false, 'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        v_credit_score := 500;
    END IF;

    SELECT * INTO v_score_record FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF FOUND THEN
        v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE
        v_tier := resolve_credit_tier(v_credit_score);
    END IF;
    v_tier := COALESCE(v_tier, 'Standard');
    v_tier_cfg := get_credit_tier_policy(v_tier);

    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
        RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    IF p_loan_type = 'unsecured' THEN
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
    ELSE
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000) * 0.5;
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07) + 0.02;
    END IF;

    IF p_principal < v_min_loan THEN
        RETURN QUERY SELECT false, 'Minimum loan amount is $' || v_min_loan::TEXT || '.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;
    IF p_principal > v_max_principal THEN
        RETURN QUERY SELECT false, 'Maximum for ' || v_tier || ' tier ' || p_loan_type || ' loan is $' || v_max_principal::TEXT || '.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance, weekly_payment,
        status, loan_type, collateral_aircraft_id, originated_game_date
    )
    VALUES (
        p_user_id,
        p_principal,
        v_interest_rate,
        v_total_repayable,
        v_weekly_payment,
        'active',
        p_loan_type,
        p_collateral_aircraft_id,
        v_game_time
    )
    RETURNING id INTO v_loan_id;

    PERFORM credit_bank_account(
        p_user_id,
        p_principal,
        'financing',
        'loan_disbursement',
        'Loan disbursement',
        v_game_time
    );

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Loan disbursed at ' || ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT, v_cash;
END;
$_$;


ALTER FUNCTION "public"."take_loan"("p_user_id" "uuid", "p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."take_loan"("p_user_id" "uuid", "p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") IS 'Process a loan for a specific user. Bot (actor_type=AI) uses simplified 5% rate / $5M max. Player uses credit-tier logic. Writes to bank_transactions.';



CREATE OR REPLACE FUNCTION "public"."terminate_actor_lease"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_game_time" timestamp with time zone) RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_fleet RECORD;
    v_exit_fee NUMERIC(20,2);
BEGIN
    -- Validate user exists
    PERFORM 1 FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Validate aircraft exists and belongs to user
    SELECT f.*, m.model_name, m.lease_price_per_month
    INTO v_fleet
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Must be a lease
    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'lease' THEN
        RETURN QUERY SELECT FALSE, 'Only leased aircraft can be terminated through this action.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Must not be assigned to a route
    IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC;
        RETURN;
    END IF;

    -- Calculate exit fee
    v_exit_fee := calculate_lease_termination_fee(v_fleet.lease_price_per_month);

    -- Check balance sufficiency
    IF v_exit_fee > 0 THEN
        DECLARE v_cash NUMERIC;
        BEGIN
            SELECT get_user_balance(p_user_id) INTO v_cash;
            IF v_cash < v_exit_fee THEN
                RETURN QUERY SELECT FALSE, 'Insufficient funds to pay lease termination fee.'::VARCHAR, NULL::NUMERIC;
                RETURN;
            END IF;
        END;
    END IF;

    -- Debit exit fee
    IF v_exit_fee > 0 THEN
        PERFORM debit_bank_account(
            p_user_id, v_exit_fee, 'opex', 'lease_termination',
            'Terminated leased aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
            p_game_time
        );
    END IF;

    -- Remove the aircraft
    DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;

    new_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT TRUE, 'Lease terminated successfully!'::VARCHAR, new_cash;
END;
$$;


ALTER FUNCTION "public"."terminate_actor_lease"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_game_time" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."terminate_aircraft_lease"("p_fleet_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM terminate_aircraft_lease(v_user_id, p_fleet_id);
END;
$$;


ALTER FUNCTION "public"."terminate_aircraft_lease"("p_fleet_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."terminate_aircraft_lease"("p_user_id" "uuid", "p_fleet_id" "uuid") RETURNS TABLE("success" boolean, "message" character varying, "new_cash" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_game_time TIMESTAMPTZ;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
    RETURN QUERY SELECT * FROM terminate_actor_lease(p_user_id, p_fleet_id, v_game_time);
END;
$$;


ALTER FUNCTION "public"."terminate_aircraft_lease"("p_user_id" "uuid", "p_fleet_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_bank_balance_reconcile_net_worth"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := COALESCE(NEW.user_id, OLD.user_id);

    UPDATE users
    SET net_worth = calculate_user_net_worth(v_user_id)
    WHERE id = v_user_id;

    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION "public"."trg_bank_balance_reconcile_net_worth"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_create_default_bank_account"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_starting_cash NUMERIC;
BEGIN
    v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
    INSERT INTO bank_accounts (user_id, account_type, balance)
    VALUES (NEW.id, 'operating', v_starting_cash)
    ON CONFLICT (user_id, account_type) DO NOTHING;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_create_default_bank_account"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fleet_reconcile_net_worth"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := COALESCE(NEW.user_id, OLD.user_id);

    UPDATE users
    SET net_worth = calculate_user_net_worth(v_user_id)
    WHERE id = v_user_id;

    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION "public"."trg_fleet_reconcile_net_worth"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_loan_reconcile_net_worth"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := COALESCE(NEW.user_id, OLD.user_id);

    UPDATE users
    SET net_worth = calculate_user_net_worth(v_user_id)
    WHERE id = v_user_id;

    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION "public"."trg_loan_reconcile_net_worth"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_sync_tail_numbers_on_hq_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE r_aircraft RECORD; v_prefix VARCHAR; v_suffix VARCHAR; v_new_tail VARCHAR;
BEGIN
    IF OLD.hq_airport_iata IS DISTINCT FROM NEW.hq_airport_iata THEN
        v_prefix := get_hq_prefix(NEW.hq_airport_iata);
        FOR r_aircraft IN SELECT id, tail_number FROM fleet_aircraft WHERE user_id = NEW.id LOOP
            v_suffix := get_tail_suffix(r_aircraft.tail_number); v_new_tail := v_prefix || v_suffix;
            IF EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_new_tail AND id != r_aircraft.id) THEN v_new_tail := generate_tail_number(NEW.hq_airport_iata); END IF;
            UPDATE fleet_aircraft SET tail_number = v_new_tail WHERE id = r_aircraft.id;
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_sync_tail_numbers_on_hq_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_update_user_net_worth"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.net_worth := calculate_user_net_worth(NEW.id);
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_update_user_net_worth"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_credit_score"("p_user_id" "uuid", "p_game_date" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_score RECORD;
    v_tier VARCHAR(10);
BEGIN
    SELECT * INTO v_score
    FROM calculate_credit_score(p_user_id)
    LIMIT 1;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_tier := resolve_credit_tier(v_score.total_score);

    INSERT INTO credit_scores (
        user_id, score, tier, fleet_health_score, revenue_stability_score,
        debt_ratio_score, cash_reserves_score, profit_history_score, computed_at
    )
    VALUES (
        p_user_id,
        v_score.total_score,
        v_tier,
        v_score.fleet_health,
        v_score.revenue_stability,
        v_score.debt_ratio,
        v_score.cash_reserve,
        v_score.profit_history,
        NOW()
    )
    ON CONFLICT (user_id) DO UPDATE
    SET score = EXCLUDED.score,
        tier = EXCLUDED.tier,
        fleet_health_score = EXCLUDED.fleet_health_score,
        revenue_stability_score = EXCLUDED.revenue_stability_score,
        debt_ratio_score = EXCLUDED.debt_ratio_score,
        cash_reserves_score = EXCLUDED.cash_reserves_score,
        profit_history_score = EXCLUDED.profit_history_score,
        computed_at = EXCLUDED.computed_at;
END;
$$;


ALTER FUNCTION "public"."update_credit_score"("p_user_id" "uuid", "p_game_date" timestamp with time zone) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_credit_score"("p_user_id" "uuid", "p_game_date" timestamp with time zone) IS 'Recalculates and persists a player''s credit score at each game-day boundary.';



CREATE OR REPLACE FUNCTION "public"."update_route_frequency_and_price"("p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql"
    AS $$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM update_route_frequency_and_price(v_user_id, p_route_id, p_ticket_price, p_flights_per_week);
END;
$$;


ALTER FUNCTION "public"."update_route_frequency_and_price"("p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_route_frequency_and_price"("p_user_id" "uuid", "p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) RETURNS TABLE("success" boolean, "message" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_route_distance_km DOUBLE PRECISION; v_assigned_aircraft_id UUID; v_aircraft_range_km INT; v_aircraft_speed_kmh INT; v_max_weekly_flights INT;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    IF p_ticket_price <= 0 OR p_flights_per_week < 1 OR p_flights_per_week > 168 THEN RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR; RETURN; END IF;
    SELECT distance_km, assigned_aircraft_id INTO v_route_distance_km, v_assigned_aircraft_id FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR; RETURN; END IF;
    IF v_assigned_aircraft_id IS NOT NULL THEN
        SELECT m.range_km, m.speed_kmh INTO v_aircraft_range_km, v_aircraft_speed_kmh FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = v_assigned_aircraft_id AND f.user_id = p_user_id;
        IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN RETURN QUERY SELECT FALSE, 'Assigned aircraft range is insufficient for this route.'::VARCHAR; RETURN; END IF;
        v_max_weekly_flights := calculate_route_max_weekly_flights(v_route_distance_km, v_aircraft_speed_kmh);
        IF v_max_weekly_flights > 0 AND p_flights_per_week > v_max_weekly_flights THEN RETURN QUERY SELECT FALSE, 'Route frequency exceeds the assigned aircraft''s weekly operating capacity.'::VARCHAR; RETURN; END IF;
    END IF;
    UPDATE route_assignments SET ticket_price = p_ticket_price, flights_per_week = p_flights_per_week WHERE id = p_route_id AND user_id = p_user_id;
    RETURN QUERY SELECT TRUE, 'Route frequency and pricing adjusted!'::VARCHAR;
END;
$$;


ALTER FUNCTION "public"."update_route_frequency_and_price"("p_user_id" "uuid", "p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."achievements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "achievement_type" character varying(50) NOT NULL,
    "achievement_name" character varying(100) NOT NULL,
    "description" "text",
    "unlocked_at" timestamp with time zone DEFAULT "now"(),
    "game_date" timestamp with time zone
);


ALTER TABLE "public"."achievements" OWNER TO "postgres";


COMMENT ON TABLE "public"."achievements" IS 'Achievement badges unlocked by players through gameplay milestones. One row per achievement type per user.';



CREATE TABLE IF NOT EXISTS "public"."aircraft_models" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "manufacturer" character varying(50) NOT NULL,
    "model_name" character varying(50) NOT NULL,
    "type" character varying(30) NOT NULL,
    "range_km" integer NOT NULL,
    "capacity" integer NOT NULL,
    "speed_kmh" integer DEFAULT 850 NOT NULL,
    "fuel_burn_per_km" numeric(8,3) NOT NULL,
    "maintenance_cost_per_hour" numeric(10,2) NOT NULL,
    "purchase_price" numeric(15,2) NOT NULL,
    "lease_price_per_month" numeric(15,2) NOT NULL,
    "turnaround_hours" numeric DEFAULT 1.0,
    CONSTRAINT "aircraft_models_type_check" CHECK ((("type")::"text" = ANY ((ARRAY['regional_turboprop'::character varying, 'regional_jet'::character varying, 'narrow_body_jet'::character varying, 'wide_body_jet'::character varying])::"text"[])))
);


ALTER TABLE "public"."aircraft_models" OWNER TO "postgres";


COMMENT ON COLUMN "public"."aircraft_models"."turnaround_hours" IS 'Ground-handling time in hours between landing and next takeoff. Set by aircraft size class (0.5–2.0 hrs).';



CREATE TABLE IF NOT EXISTS "public"."airports" (
    "iata" character varying(3) NOT NULL,
    "name" character varying(150) NOT NULL,
    "city" character varying(100) NOT NULL,
    "country" character varying(100) NOT NULL,
    "latitude" double precision NOT NULL,
    "longitude" double precision NOT NULL,
    "demand_index" integer DEFAULT 50 NOT NULL,
    CONSTRAINT "airports_demand_index_check" CHECK ((("demand_index" >= 1) AND ("demand_index" <= 100)))
);


ALTER TABLE "public"."airports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bank_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "account_type" character varying(20) DEFAULT 'operating'::character varying NOT NULL,
    "balance" numeric(20,2) DEFAULT 0.00 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bank_accounts_account_type_check" CHECK ((("account_type")::"text" = 'operating'::"text"))
);


ALTER TABLE "public"."bank_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bank_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "transaction_type" character varying(20) NOT NULL,
    "amount" numeric(20,2) NOT NULL,
    "balance_after" numeric(20,2) NOT NULL,
    "description" "text",
    "game_date" timestamp with time zone NOT NULL,
    "ifrs_category" character varying(30),
    "ifrs_subcategory" character varying(50),
    CONSTRAINT "bank_transactions_transaction_type_check" CHECK ((("transaction_type")::"text" = ANY ((ARRAY['debit'::character varying, 'credit'::character varying, 'payment'::character varying, 'deposit'::character varying, 'disbursement'::character varying, 'refinance'::character varying, 'late_fee'::character varying, 'accrual'::character varying, 'refund'::character varying])::"text"[])))
);


ALTER TABLE "public"."bank_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bot_profiles" (
    "user_id" "uuid" NOT NULL,
    "archetype" character varying(30) DEFAULT 'Balanced'::character varying NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_growth_action_at" timestamp with time zone,
    "last_route_change_at" timestamp with time zone,
    "last_pricing_review_at" timestamp with time zone,
    "last_repair_action_at" timestamp with time zone,
    "distress_stage" character varying(20) DEFAULT 'stable'::character varying NOT NULL,
    "consecutive_loss_days" integer DEFAULT 0 NOT NULL,
    "secondary_hub_iata" character varying(3),
    "last_route_optimization_at" timestamp with time zone,
    "last_route_audit_at" timestamp with time zone,
    "last_financial_action_at" timestamp with time zone,
    "recovery_loan_taken" boolean DEFAULT false NOT NULL,
    CONSTRAINT "bot_profiles_distress_stage_check" CHECK ((("distress_stage")::"text" = ANY ((ARRAY['stable'::character varying, 'cautious'::character varying, 'defensive'::character varying, 'desperate'::character varying])::"text"[])))
);


ALTER TABLE "public"."bot_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credit_score_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "score" integer NOT NULL,
    "tier" character varying(10) NOT NULL,
    "fleet_health_score" integer DEFAULT 0,
    "revenue_stability_score" integer DEFAULT 0,
    "debt_ratio_score" integer DEFAULT 0,
    "cash_reserves_score" integer DEFAULT 0,
    "profit_history_score" integer DEFAULT 0,
    "game_date" timestamp with time zone NOT NULL,
    "computed_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."credit_score_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credit_scores" (
    "user_id" "uuid" NOT NULL,
    "score" integer DEFAULT 500 NOT NULL,
    "tier" character varying(10) DEFAULT 'Standard'::character varying NOT NULL,
    "fleet_health_score" integer DEFAULT 0,
    "revenue_stability_score" integer DEFAULT 0,
    "debt_ratio_score" integer DEFAULT 0,
    "cash_reserves_score" integer DEFAULT 0,
    "profit_history_score" integer DEFAULT 0,
    "computed_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "credit_scores_score_check" CHECK ((("score" >= 0) AND ("score" <= 1000)))
);


ALTER TABLE "public"."credit_scores" OWNER TO "postgres";


COMMENT ON TABLE "public"."credit_scores" IS 'Current credit score snapshot per player. Updated at each game-day boundary.';



CREATE TABLE IF NOT EXISTS "public"."fleet_aircraft" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "aircraft_model_id" "uuid" NOT NULL,
    "acquisition_type" character varying(10) NOT NULL,
    "condition" numeric(5,2) DEFAULT 100.00 NOT NULL,
    "status" character varying(20) DEFAULT 'grounded'::character varying NOT NULL,
    "tail_number" character varying(20) NOT NULL,
    "economy_seats" integer DEFAULT 0,
    "business_seats" integer DEFAULT 0,
    "first_class_seats" integer DEFAULT 0,
    "nickname" character varying(100),
    "acquired_game_date" timestamp with time zone,
    CONSTRAINT "fleet_aircraft_acquisition_type_check" CHECK ((("acquisition_type")::"text" = ANY ((ARRAY['purchase'::character varying, 'lease'::character varying, 'finance'::character varying])::"text"[]))),
    CONSTRAINT "fleet_aircraft_condition_check" CHECK ((("condition" >= 0.00) AND ("condition" <= 100.00))),
    CONSTRAINT "fleet_aircraft_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['grounded'::character varying, 'active'::character varying, 'maintenance'::character varying])::"text"[])))
);


ALTER TABLE "public"."fleet_aircraft" OWNER TO "postgres";


COMMENT ON COLUMN "public"."fleet_aircraft"."acquired_game_date" IS 'Game-time timestamp when this aircraft was acquired. Used for age-based depreciation on resale.';



CREATE TABLE IF NOT EXISTS "public"."game_config" (
    "key" "text" NOT NULL,
    "value" "jsonb" NOT NULL,
    "category" "text" DEFAULT 'general'::"text" NOT NULL,
    "unit" "text",
    "description" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."game_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."game_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_type" character varying(50) NOT NULL,
    "title" character varying(200) NOT NULL,
    "description" "text",
    "effect_type" character varying(50) NOT NULL,
    "effect_target" "text",
    "effect_value" numeric NOT NULL,
    "start_game_time" timestamp with time zone NOT NULL,
    "end_game_time" timestamp with time zone NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."game_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."game_events" IS 'Time-bounded world events that modify simulation economics (fuel prices, demand, taxes).';



CREATE TABLE IF NOT EXISTS "public"."loans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "principal" numeric NOT NULL,
    "interest_rate" numeric DEFAULT 0.05 NOT NULL,
    "remaining_balance" numeric NOT NULL,
    "weekly_payment" numeric NOT NULL,
    "status" character varying(20) DEFAULT 'active'::character varying NOT NULL,
    "taken_at" timestamp with time zone DEFAULT "now"(),
    "loan_type" character varying(20) DEFAULT 'unsecured'::character varying NOT NULL,
    "collateral_aircraft_id" "uuid",
    "missed_payments" integer DEFAULT 0,
    "term_months" integer,
    "monthly_payment" numeric,
    "originated_game_date" timestamp with time zone,
    CONSTRAINT "loans_loan_type_check" CHECK ((("loan_type")::"text" = ANY ((ARRAY['unsecured'::character varying, 'secured'::character varying, 'credit_line'::character varying, 'aircraft_financing'::character varying])::"text"[]))),
    CONSTRAINT "loans_principal_check" CHECK (("principal" > (0)::numeric)),
    CONSTRAINT "loans_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['active'::character varying, 'paid_off'::character varying, 'defaulted'::character varying, 'repossessed'::character varying])::"text"[])))
);


ALTER TABLE "public"."loans" OWNER TO "postgres";


COMMENT ON TABLE "public"."loans" IS 'Bank loans taken by players for capital. Payments are auto-deducted at each game-day boundary.';



CREATE TABLE IF NOT EXISTS "public"."route_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "origin_iata" character varying(3) NOT NULL,
    "destination_iata" character varying(3) NOT NULL,
    "distance_km" double precision NOT NULL,
    "ticket_price" numeric(10,2) NOT NULL,
    "assigned_aircraft_id" "uuid",
    "flights_per_week" integer DEFAULT 7 NOT NULL,
    "status" character varying(20) DEFAULT 'active'::character varying NOT NULL,
    CONSTRAINT "route_assignments_flights_per_week_check" CHECK ((("flights_per_week" >= 1) AND ("flights_per_week" <= 168))),
    CONSTRAINT "route_assignments_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['active'::character varying, 'cancelled'::character varying])::"text"[]))),
    CONSTRAINT "route_assignments_ticket_price_check" CHECK (("ticket_price" > (0)::numeric))
);


ALTER TABLE "public"."route_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."season_clock" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "label" character varying(80) NOT NULL,
    "current_game_time" timestamp with time zone DEFAULT '2020-01-01 00:00:00+00'::timestamp with time zone NOT NULL,
    "last_tick_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "time_scale_multiplier" numeric(10,2) DEFAULT 60.00 NOT NULL,
    "tick_interval_seconds" integer DEFAULT 60 NOT NULL,
    "status" character varying(20) DEFAULT 'active'::character varying NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "season_clock_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['draft'::character varying, 'active'::character varying, 'paused'::character varying, 'completed'::character varying])::"text"[]))),
    CONSTRAINT "season_clock_tick_interval_seconds_check" CHECK (("tick_interval_seconds" > 0))
);


ALTER TABLE "public"."season_clock" OWNER TO "postgres";


COMMENT ON TABLE "public"."season_clock" IS 'Shared season clock foundation. Phase 2 only: actor game_current_time fields remain runtime authority until world ticking is introduced.';



COMMENT ON COLUMN "public"."season_clock"."current_game_time" IS 'Future authoritative season game time for world ticking. Not yet the source of runtime simulation truth in Phase 2.';



CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "username" character varying(50),
    "company_name" character varying(100) NOT NULL,
    "ceo_name" character varying(100) NOT NULL,
    "game_current_time" timestamp with time zone DEFAULT '2020-01-01 00:00:00+00'::timestamp with time zone NOT NULL,
    "last_active_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "net_worth" numeric(20,2) DEFAULT 15000000.00,
    "hq_airport_iata" character varying(3),
    "auto_grounding_threshold" numeric(5,2) DEFAULT 40.00,
    "operational_status" character varying(20) DEFAULT 'Active'::character varying NOT NULL,
    "consecutive_negative_days" integer DEFAULT 0 NOT NULL,
    "recovery_streak_days" integer DEFAULT 0 NOT NULL,
    "season_id" "uuid",
    "auth_user_id" "uuid",
    "onboarding_completed" boolean DEFAULT false,
    "actor_type" character varying(10) DEFAULT 'REAL'::character varying NOT NULL,
    CONSTRAINT "users_actor_type_check" CHECK ((("actor_type")::"text" = ANY ((ARRAY['REAL'::character varying, 'AI'::character varying])::"text"[]))),
    CONSTRAINT "users_operational_status_check" CHECK ((("operational_status")::"text" = ANY ((ARRAY['Active'::character varying, 'Bankrupt'::character varying])::"text"[])))
);


ALTER TABLE "public"."users" OWNER TO "postgres";


COMMENT ON COLUMN "public"."users"."season_id" IS 'Season membership for future shared-world simulation. users.game_current_time remains authoritative until later migration phases.';



COMMENT ON COLUMN "public"."users"."auth_user_id" IS 'Future Supabase Auth identity anchor. Custom sessions remain active until the auth cutover phases replace them.';



CREATE TABLE IF NOT EXISTS "public"."world_tick_log" (
    "id" bigint NOT NULL,
    "season_id" "uuid",
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    "game_time_before" timestamp with time zone,
    "game_time_after" timestamp with time zone,
    "ticks_processed" integer DEFAULT 0 NOT NULL,
    "real_seconds_processed" numeric(20,4) DEFAULT 0.0000 NOT NULL,
    "game_seconds_processed" numeric(20,4) DEFAULT 0.0000 NOT NULL,
    "players_processed" integer DEFAULT 0 NOT NULL,
    "bots_processed" integer DEFAULT 0 NOT NULL,
    "status" character varying(20) DEFAULT 'started'::character varying NOT NULL,
    "message" "text",
    CONSTRAINT "world_tick_log_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['started'::character varying, 'skipped'::character varying, 'success'::character varying, 'error'::character varying, 'player_error'::character varying, 'bot_error'::character varying])::"text"[])))
);


ALTER TABLE "public"."world_tick_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."world_tick_log" IS 'Audit log for scheduler-safe season clock ticks. Phase 3 logs season-clock advancement only; actor simulation migrates later.';



CREATE SEQUENCE IF NOT EXISTS "public"."world_tick_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."world_tick_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."world_tick_log_id_seq" OWNED BY "public"."world_tick_log"."id";



ALTER TABLE ONLY "public"."world_tick_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."world_tick_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."achievements"
    ADD CONSTRAINT "achievements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."achievements"
    ADD CONSTRAINT "achievements_user_id_achievement_type_key" UNIQUE ("user_id", "achievement_type");



ALTER TABLE ONLY "public"."aircraft_models"
    ADD CONSTRAINT "aircraft_models_model_name_key" UNIQUE ("model_name");



ALTER TABLE ONLY "public"."aircraft_models"
    ADD CONSTRAINT "aircraft_models_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."airports"
    ADD CONSTRAINT "airports_pkey" PRIMARY KEY ("iata");



ALTER TABLE ONLY "public"."bank_accounts"
    ADD CONSTRAINT "bank_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bank_accounts"
    ADD CONSTRAINT "bank_accounts_user_id_account_type_key" UNIQUE ("user_id", "account_type");



ALTER TABLE ONLY "public"."bank_transactions"
    ADD CONSTRAINT "bank_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bot_profiles"
    ADD CONSTRAINT "bot_profiles_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."credit_score_history"
    ADD CONSTRAINT "credit_score_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credit_score_history"
    ADD CONSTRAINT "credit_score_history_user_date_unique" UNIQUE ("user_id", "game_date");



ALTER TABLE ONLY "public"."credit_scores"
    ADD CONSTRAINT "credit_scores_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."game_config"
    ADD CONSTRAINT "game_config_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."game_events"
    ADD CONSTRAINT "game_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."loans"
    ADD CONSTRAINT "loans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."season_clock"
    ADD CONSTRAINT "season_clock_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fleet_aircraft"
    ADD CONSTRAINT "user_fleet_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."route_assignments"
    ADD CONSTRAINT "user_routes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_company_name_key" UNIQUE ("company_name");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."world_tick_log"
    ADD CONSTRAINT "world_tick_log_pkey" PRIMARY KEY ("id");



CREATE INDEX "bank_transactions_user_date_idx" ON "public"."bank_transactions" USING "btree" ("user_id", "game_date" DESC);



CREATE INDEX "credit_score_history_user_date_idx" ON "public"."credit_score_history" USING "btree" ("user_id", "game_date" DESC);



CREATE INDEX "credit_scores_tier_idx" ON "public"."credit_scores" USING "btree" ("tier");



CREATE UNIQUE INDEX "fleet_aircraft_tail_number_key" ON "public"."fleet_aircraft" USING "btree" ("tail_number");



CREATE INDEX "fleet_aircraft_user_id_idx" ON "public"."fleet_aircraft" USING "btree" ("user_id");



CREATE INDEX "game_events_active_lookup_idx" ON "public"."game_events" USING "btree" ("effect_type", "effect_target", "is_active", "start_game_time", "end_game_time") WHERE ("is_active" = true);



CREATE INDEX "idx_bank_transactions_game_date" ON "public"."bank_transactions" USING "btree" ("game_date");



CREATE INDEX "idx_bank_txn_ifrs" ON "public"."bank_transactions" USING "btree" ("user_id", "ifrs_category", "game_date");



CREATE INDEX "idx_bot_profiles_archetype" ON "public"."bot_profiles" USING "btree" ("archetype");



CREATE INDEX "idx_fleet_aircraft_model" ON "public"."fleet_aircraft" USING "btree" ("aircraft_model_id");



CREATE INDEX "idx_fleet_aircraft_user_status" ON "public"."fleet_aircraft" USING "btree" ("user_id", "status");



CREATE INDEX "idx_game_config_category" ON "public"."game_config" USING "btree" ("category");



CREATE INDEX "idx_game_events_active" ON "public"."game_events" USING "btree" ("event_type", "start_game_time", "end_game_time") WHERE ("is_active" = true);



CREATE INDEX "idx_route_assignments_origin_dest_status" ON "public"."route_assignments" USING "btree" ("origin_iata", "destination_iata") WHERE (("status")::"text" = 'active'::"text");



CREATE INDEX "idx_route_assignments_user_status" ON "public"."route_assignments" USING "btree" ("user_id") WHERE (("status")::"text" = 'active'::"text");



CREATE INDEX "idx_users_active_bots" ON "public"."users" USING "btree" ("id") WHERE (((COALESCE("operational_status", 'Active'::character varying))::"text" <> 'Bankrupt'::"text") AND (("actor_type")::"text" = 'AI'::"text"));



CREATE INDEX "idx_world_tick_log_started" ON "public"."world_tick_log" USING "btree" ("started_at");



CREATE INDEX "loans_collateral_idx" ON "public"."loans" USING "btree" ("collateral_aircraft_id") WHERE ("collateral_aircraft_id" IS NOT NULL);



CREATE INDEX "loans_user_status_idx" ON "public"."loans" USING "btree" ("user_id", "status");



CREATE INDEX "route_assignments_assigned_aircraft_id_idx" ON "public"."route_assignments" USING "btree" ("assigned_aircraft_id") WHERE ("assigned_aircraft_id" IS NOT NULL);



CREATE INDEX "route_assignments_user_id_iata_idx" ON "public"."route_assignments" USING "btree" ("user_id", "origin_iata", "destination_iata");



CREATE UNIQUE INDEX "season_clock_one_active_idx" ON "public"."season_clock" USING "btree" ("status") WHERE (("status")::"text" = 'active'::"text");



CREATE UNIQUE INDEX "unique_human_route" ON "public"."route_assignments" USING "btree" ("user_id", "origin_iata", "destination_iata") WHERE ("user_id" IS NOT NULL);



CREATE UNIQUE INDEX "users_auth_user_id_unique_idx" ON "public"."users" USING "btree" ("auth_user_id") WHERE ("auth_user_id" IS NOT NULL);



CREATE INDEX "users_season_id_idx" ON "public"."users" USING "btree" ("season_id");



CREATE INDEX "world_tick_log_season_started_idx" ON "public"."world_tick_log" USING "btree" ("season_id", "started_at" DESC);



CREATE OR REPLACE TRIGGER "create_default_bank_account" AFTER INSERT ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."trg_create_default_bank_account"();



CREATE OR REPLACE TRIGGER "fleet_reconcile_net_worth" AFTER INSERT OR DELETE OR UPDATE ON "public"."fleet_aircraft" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fleet_reconcile_net_worth"();



CREATE OR REPLACE TRIGGER "trg_bank_balance_reconcile_net_worth" AFTER INSERT OR DELETE OR UPDATE OF "balance", "user_id" ON "public"."bank_accounts" FOR EACH ROW EXECUTE FUNCTION "public"."trg_bank_balance_reconcile_net_worth"();



CREATE OR REPLACE TRIGGER "trg_loan_reconcile_net_worth" AFTER INSERT OR DELETE OR UPDATE OF "remaining_balance", "status", "user_id" ON "public"."loans" FOR EACH ROW EXECUTE FUNCTION "public"."trg_loan_reconcile_net_worth"();



CREATE OR REPLACE TRIGGER "trg_user_hq_change" AFTER UPDATE OF "hq_airport_iata" ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."trg_sync_tail_numbers_on_hq_change"();



ALTER TABLE ONLY "public"."achievements"
    ADD CONSTRAINT "achievements_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bank_accounts"
    ADD CONSTRAINT "bank_accounts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bank_transactions"
    ADD CONSTRAINT "bank_transactions_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."bank_accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bank_transactions"
    ADD CONSTRAINT "bank_transactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bot_profiles"
    ADD CONSTRAINT "bot_profiles_secondary_hub_iata_fkey" FOREIGN KEY ("secondary_hub_iata") REFERENCES "public"."airports"("iata");



ALTER TABLE ONLY "public"."bot_profiles"
    ADD CONSTRAINT "bot_profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."credit_score_history"
    ADD CONSTRAINT "credit_score_history_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."credit_scores"
    ADD CONSTRAINT "credit_scores_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fleet_aircraft"
    ADD CONSTRAINT "fleet_aircraft_aircraft_model_id_fkey" FOREIGN KEY ("aircraft_model_id") REFERENCES "public"."aircraft_models"("id");



ALTER TABLE ONLY "public"."fleet_aircraft"
    ADD CONSTRAINT "fleet_aircraft_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loans"
    ADD CONSTRAINT "loans_collateral_aircraft_id_fkey" FOREIGN KEY ("collateral_aircraft_id") REFERENCES "public"."fleet_aircraft"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."loans"
    ADD CONSTRAINT "loans_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."route_assignments"
    ADD CONSTRAINT "route_assignments_assigned_aircraft_id_fkey" FOREIGN KEY ("assigned_aircraft_id") REFERENCES "public"."fleet_aircraft"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."route_assignments"
    ADD CONSTRAINT "route_assignments_destination_iata_fkey" FOREIGN KEY ("destination_iata") REFERENCES "public"."airports"("iata");



ALTER TABLE ONLY "public"."route_assignments"
    ADD CONSTRAINT "route_assignments_origin_iata_fkey" FOREIGN KEY ("origin_iata") REFERENCES "public"."airports"("iata");



ALTER TABLE ONLY "public"."route_assignments"
    ADD CONSTRAINT "route_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_hq_airport_iata_fkey" FOREIGN KEY ("hq_airport_iata") REFERENCES "public"."airports"("iata");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_season_id_fkey" FOREIGN KEY ("season_id") REFERENCES "public"."season_clock"("id");



ALTER TABLE ONLY "public"."world_tick_log"
    ADD CONSTRAINT "world_tick_log_season_id_fkey" FOREIGN KEY ("season_id") REFERENCES "public"."season_clock"("id") ON DELETE CASCADE;



CREATE POLICY "Bot profiles viewable by everyone" ON "public"."bot_profiles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Game config viewable by everyone" ON "public"."game_config" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."achievements" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "achievements_select_own" ON "public"."achievements" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "users"."id"
   FROM "public"."users"
  WHERE ("users"."auth_user_id" = "auth"."uid"()))));



ALTER TABLE "public"."aircraft_models" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "aircraft_models_select_authenticated" ON "public"."aircraft_models" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."airports" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "airports_select_authenticated" ON "public"."airports" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."bank_accounts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bank_accounts_select_own" ON "public"."bank_accounts" FOR SELECT TO "authenticated" USING (("user_id" = "public"."get_current_user_id"()));



ALTER TABLE "public"."bank_transactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bank_transactions_select_own" ON "public"."bank_transactions" FOR SELECT TO "authenticated" USING (("user_id" = "public"."get_current_user_id"()));



ALTER TABLE "public"."bot_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."credit_score_history" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "credit_score_history_select_own" ON "public"."credit_score_history" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "users"."id"
   FROM "public"."users"
  WHERE ("users"."auth_user_id" = "auth"."uid"()))));



ALTER TABLE "public"."credit_scores" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "credit_scores_select_own" ON "public"."credit_scores" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "users"."id"
   FROM "public"."users"
  WHERE ("users"."auth_user_id" = "auth"."uid"()))));



ALTER TABLE "public"."fleet_aircraft" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "fleet_aircraft_select_own" ON "public"."fleet_aircraft" FOR SELECT TO "authenticated" USING (("user_id" = "public"."get_current_user_id"()));



ALTER TABLE "public"."game_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."game_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "game_events_select_authenticated" ON "public"."game_events" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."loans" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "loans_select_own" ON "public"."loans" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "users"."id"
   FROM "public"."users"
  WHERE ("users"."auth_user_id" = "auth"."uid"()))));



ALTER TABLE "public"."route_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "route_assignments_select_own" ON "public"."route_assignments" FOR SELECT TO "authenticated" USING (("user_id" = "public"."get_current_user_id"()));



ALTER TABLE "public"."season_clock" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "season_clock_select_authenticated" ON "public"."season_clock" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users_select_own" ON "public"."users" FOR SELECT TO "authenticated" USING ((("auth"."uid"() IS NOT NULL) AND ("auth"."uid"() = "auth_user_id")));



CREATE POLICY "users_update_own" ON "public"."users" FOR UPDATE TO "authenticated" USING ((("auth"."uid"() IS NOT NULL) AND ("auth"."uid"() = "auth_user_id"))) WITH CHECK ((("auth"."uid"() IS NOT NULL) AND ("auth"."uid"() = "auth_user_id")));



ALTER TABLE "public"."world_tick_log" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_actor_bankruptcy_state"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_actor_bankruptcy_state"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_actor_bankruptcy_state"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."assign_actor_aircraft_to_route"("p_user_id" "uuid", "p_route_id" "uuid", "p_aircraft_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."assign_actor_aircraft_to_route"("p_user_id" "uuid", "p_route_id" "uuid", "p_aircraft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_actor_aircraft_to_route"("p_user_id" "uuid", "p_route_id" "uuid", "p_aircraft_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."assign_aircraft_to_route"("p_route_id" "uuid", "p_aircraft_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."assign_aircraft_to_route"("p_route_id" "uuid", "p_aircraft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."assign_aircraft_to_route"("p_route_id" "uuid", "p_aircraft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_aircraft_to_route"("p_route_id" "uuid", "p_aircraft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."assign_aircraft_to_route"("p_user_id" "uuid", "p_route_id" "uuid", "p_aircraft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."assign_aircraft_to_route"("p_user_id" "uuid", "p_route_id" "uuid", "p_aircraft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_aircraft_to_route"("p_user_id" "uuid", "p_route_id" "uuid", "p_aircraft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."bot_evaluate_distress"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_consecutive_neg" integer, "p_cash_ratio" numeric, OUT "o_distress_stage" character varying, OUT "o_target_fleet_cap" integer, OUT "o_min_cash_reserve" numeric, OUT "o_growth_chance" numeric, OUT "o_target_distance" double precision, OUT "o_target_price_mult" numeric, OUT "o_target_sched_ratio" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."bot_evaluate_distress"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_consecutive_neg" integer, "p_cash_ratio" numeric, OUT "o_distress_stage" character varying, OUT "o_target_fleet_cap" integer, OUT "o_min_cash_reserve" numeric, OUT "o_growth_chance" numeric, OUT "o_target_distance" double precision, OUT "o_target_price_mult" numeric, OUT "o_target_sched_ratio" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bot_evaluate_distress"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_consecutive_neg" integer, "p_cash_ratio" numeric, OUT "o_distress_stage" character varying, OUT "o_target_fleet_cap" integer, OUT "o_min_cash_reserve" numeric, OUT "o_growth_chance" numeric, OUT "o_target_distance" double precision, OUT "o_target_price_mult" numeric, OUT "o_target_sched_ratio" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."bot_handle_financial"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_bot_cash" numeric, "p_starting_cash" numeric, "p_min_cash_reserve" numeric, "p_repay_ratio" numeric, "p_recovery_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."bot_handle_financial"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_bot_cash" numeric, "p_starting_cash" numeric, "p_min_cash_reserve" numeric, "p_repay_ratio" numeric, "p_recovery_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bot_handle_financial"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_bot_cash" numeric, "p_starting_cash" numeric, "p_min_cash_reserve" numeric, "p_repay_ratio" numeric, "p_recovery_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."bot_handle_fleet_growth"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_bot_cash" numeric, "p_starting_cash" numeric, "p_target_fleet_cap" integer, "p_min_cash_reserve" numeric, "p_growth_chance" numeric, "p_target_distance" double precision, "p_purchase_cash_mult" numeric, "p_fleet_diversity" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."bot_handle_fleet_growth"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_bot_cash" numeric, "p_starting_cash" numeric, "p_target_fleet_cap" integer, "p_min_cash_reserve" numeric, "p_growth_chance" numeric, "p_target_distance" double precision, "p_purchase_cash_mult" numeric, "p_fleet_diversity" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bot_handle_fleet_growth"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_bot_cash" numeric, "p_starting_cash" numeric, "p_target_fleet_cap" integer, "p_min_cash_reserve" numeric, "p_growth_chance" numeric, "p_target_distance" double precision, "p_purchase_cash_mult" numeric, "p_fleet_diversity" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."bot_handle_pricing"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_target_price_mult" numeric, "p_comp_threshold" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."bot_handle_pricing"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_target_price_mult" numeric, "p_comp_threshold" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bot_handle_pricing"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_target_price_mult" numeric, "p_comp_threshold" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."bot_handle_repair"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_threshold" numeric, "p_cash_reserve" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."bot_handle_repair"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_threshold" numeric, "p_cash_reserve" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bot_handle_repair"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_threshold" numeric, "p_cash_reserve" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."bot_handle_route_creation"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_hq_iata" character varying, "p_target_fleet_cap" integer, "p_target_price_mult" numeric, "p_target_sched_ratio" numeric, "p_target_distance" double precision, "p_threshold" numeric, "p_secondary_hub_chance" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."bot_handle_route_creation"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_hq_iata" character varying, "p_target_fleet_cap" integer, "p_target_price_mult" numeric, "p_target_sched_ratio" numeric, "p_target_distance" double precision, "p_threshold" numeric, "p_secondary_hub_chance" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bot_handle_route_creation"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_archetype" character varying, "p_distress" character varying, "p_hq_iata" character varying, "p_target_fleet_cap" integer, "p_target_price_mult" numeric, "p_target_sched_ratio" numeric, "p_target_distance" double precision, "p_threshold" numeric, "p_secondary_hub_chance" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."bot_handle_route_lifecycle"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_target_price_mult" numeric, "p_loss_days_thresh" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."bot_handle_route_lifecycle"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_target_price_mult" numeric, "p_loss_days_thresh" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bot_handle_route_lifecycle"("p_bot_id" "uuid", "p_game_time" timestamp with time zone, "p_distress" character varying, "p_target_price_mult" numeric, "p_loss_days_thresh" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."build_synthetic_auth_email"("p_username" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."build_synthetic_auth_email"("p_username" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_synthetic_auth_email"("p_username" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_airport_congestion_factor"("p_origin_iata" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_airport_congestion_factor"("p_origin_iata" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_airport_congestion_factor"("p_origin_iata" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_airport_demand_factor"("p_origin_demand" integer, "p_destination_demand" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_airport_demand_factor"("p_origin_demand" integer, "p_destination_demand" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_airport_demand_factor"("p_origin_demand" integer, "p_destination_demand" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."calculate_credit_score"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."calculate_credit_score"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_credit_score"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_credit_score"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_hub_bonus"("p_origin_iata" character varying, "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_hub_bonus"("p_origin_iata" character varying, "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_hub_bonus"("p_origin_iata" character varying, "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_lease_termination_fee"("p_lease_price_per_month" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_lease_termination_fee"("p_lease_price_per_month" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_lease_termination_fee"("p_lease_price_per_month" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_required_lease_deposit"("p_purchase_price" numeric, "p_lease_price_per_month" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_required_lease_deposit"("p_purchase_price" numeric, "p_lease_price_per_month" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_required_lease_deposit"("p_purchase_price" numeric, "p_lease_price_per_month" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_route_base_fare"("p_distance_km" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_route_base_fare"("p_distance_km" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_route_base_fare"("p_distance_km" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_route_demand_multiplier"("p_distance_km" double precision, "p_ticket_price" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_route_demand_multiplier"("p_distance_km" double precision, "p_ticket_price" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_route_demand_multiplier"("p_distance_km" double precision, "p_ticket_price" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_route_expected_passengers"("p_capacity" integer, "p_distance_km" double precision, "p_ticket_price" numeric, "p_origin_demand" integer, "p_destination_demand" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_route_expected_passengers"("p_capacity" integer, "p_distance_km" double precision, "p_ticket_price" numeric, "p_origin_demand" integer, "p_destination_demand" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_route_expected_passengers"("p_capacity" integer, "p_distance_km" double precision, "p_ticket_price" numeric, "p_origin_demand" integer, "p_destination_demand" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_route_expected_passengers"("p_capacity" integer, "p_distance_km" double precision, "p_ticket_price" numeric, "p_origin_demand" integer, "p_destination_demand" integer, "p_origin_iata" character varying, "p_destination_iata" character varying, "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_route_expected_passengers"("p_capacity" integer, "p_distance_km" double precision, "p_ticket_price" numeric, "p_origin_demand" integer, "p_destination_demand" integer, "p_origin_iata" character varying, "p_destination_iata" character varying, "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_route_expected_passengers"("p_capacity" integer, "p_distance_km" double precision, "p_ticket_price" numeric, "p_origin_demand" integer, "p_destination_demand" integer, "p_origin_iata" character varying, "p_destination_iata" character varying, "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer, "p_turnaround_hours" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer, "p_turnaround_hours" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_route_max_weekly_flights"("p_distance_km" double precision, "p_speed_kmh" integer, "p_turnaround_hours" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_user_net_worth"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_user_net_worth"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_user_net_worth"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_achievements"("p_user_id" "uuid", "p_game_time" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."check_achievements"("p_user_id" "uuid", "p_game_time" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_achievements"("p_user_id" "uuid", "p_game_time" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."configure_aircraft_seats"("p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."configure_aircraft_seats"("p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."configure_aircraft_seats"("p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."configure_aircraft_seats"("p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."configure_aircraft_seats"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."configure_aircraft_seats"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."configure_aircraft_seats"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."configure_aircraft_seats"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_route"("p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_route"("p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_route"("p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_route"("p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_route"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_route"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_route"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_route"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_distance_km" numeric, "p_ticket_price" numeric, "p_flights_per_week" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."credit_bank_account"("p_user_id" "uuid", "p_amount" numeric, "p_ifrs_category" character varying, "p_ifrs_subcategory" character varying, "p_description" "text", "p_game_date" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."credit_bank_account"("p_user_id" "uuid", "p_amount" numeric, "p_ifrs_category" character varying, "p_ifrs_subcategory" character varying, "p_description" "text", "p_game_date" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."credit_bank_account"("p_user_id" "uuid", "p_amount" numeric, "p_ifrs_category" character varying, "p_ifrs_subcategory" character varying, "p_description" "text", "p_game_date" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."deactivate_expired_events"("p_game_time" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."deactivate_expired_events"("p_game_time" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."debit_bank_account"("p_user_id" "uuid", "p_amount" numeric, "p_ifrs_category" character varying, "p_ifrs_subcategory" character varying, "p_description" "text", "p_game_date" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."debit_bank_account"("p_user_id" "uuid", "p_amount" numeric, "p_ifrs_category" character varying, "p_ifrs_subcategory" character varying, "p_description" "text", "p_game_date" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."debit_bank_account"("p_user_id" "uuid", "p_amount" numeric, "p_ifrs_category" character varying, "p_ifrs_subcategory" character varying, "p_description" "text", "p_game_date" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_account"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_account"() TO "anon";
GRANT ALL ON FUNCTION "public"."delete_account"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_account"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_route"("p_route_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_route"("p_route_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_route"("p_route_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_route"("p_route_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_route"("p_user_id" "uuid", "p_route_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_route"("p_user_id" "uuid", "p_route_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_route"("p_user_id" "uuid", "p_route_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_route"("p_user_id" "uuid", "p_route_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ensure_world_current"("p_season_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_world_current"("p_season_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_world_current"("p_season_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."execute_bot_decisions"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."execute_bot_decisions"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."finance_aircraft"("p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."finance_aircraft"("p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."finance_aircraft"("p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."finance_aircraft"("p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."finance_aircraft"("p_user_id" "uuid", "p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."finance_aircraft"("p_user_id" "uuid", "p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."finance_aircraft"("p_user_id" "uuid", "p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."finance_aircraft"("p_user_id" "uuid", "p_aircraft_model_id" "uuid", "p_down_payment_pct" numeric, "p_term_months" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_ceo_name"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_ceo_name"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_ceo_name"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_company_name"("p_archetype" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."generate_company_name"("p_archetype" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_company_name"("p_archetype" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_game_events"("p_game_time" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."generate_game_events"("p_game_time" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_tail_number"("p_airport_iata" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."generate_tail_number"("p_airport_iata" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_tail_number"("p_airport_iata" character varying) TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_bot_health"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_bot_health"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_bot_health"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_competitor_insights"("p_id" "uuid", "p_is_bot" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_competitor_insights"("p_id" "uuid", "p_is_bot" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_competitor_insights"("p_id" "uuid", "p_is_bot" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_config_int"("p_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_config_int"("p_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_config_int"("p_key" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_config_jsonb"("p_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_config_jsonb"("p_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_config_jsonb"("p_key" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_config_numeric"("p_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_config_numeric"("p_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_config_numeric"("p_key" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_credit_report"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_credit_report"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_credit_report"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_credit_tier_policy"("p_tier" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."get_credit_tier_policy"("p_tier" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_credit_tier_policy"("p_tier" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_current_user_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_current_user_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_current_user_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_database_size_report"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_database_size_report"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_database_size_report"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_finance_snapshot"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_finance_snapshot"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_finance_snapshot"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_finance_snapshot"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_finance_snapshot"("p_id" "uuid", "p_is_bot" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_finance_snapshot"("p_id" "uuid", "p_is_bot" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_finance_snapshot"("p_id" "uuid", "p_is_bot" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_finance_snapshot"("p_id" "uuid", "p_is_bot" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_global_leaderboard"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_global_leaderboard"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_global_leaderboard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_global_leaderboard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_hq_prefix"("p_airport_iata" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."get_hq_prefix"("p_airport_iata" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_hq_prefix"("p_airport_iata" character varying) TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_owner_route_optimizer"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_limit" integer, "p_include_assigned" boolean, "p_exclude_existing_routes" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_owner_route_optimizer"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_limit" integer, "p_include_assigned" boolean, "p_exclude_existing_routes" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_owner_route_optimizer"("p_user_id" "uuid", "p_origin_iata" character varying, "p_destination_iata" character varying, "p_limit" integer, "p_include_assigned" boolean, "p_exclude_existing_routes" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_route_performance"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_route_performance"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_route_performance"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_table_size_report"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_table_size_report"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_table_size_report"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_table_size_report"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_tail_suffix"("p_tail" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."get_tail_suffix"("p_tail" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_tail_suffix"("p_tail" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_balance"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_balance"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_balance"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_id_for_auth_uid"("p_auth_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_id_for_auth_uid"("p_auth_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_id_for_auth_uid"("p_auth_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_world_tick_guardrail_report"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_world_tick_guardrail_report"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_world_tick_guardrail_report"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_world_tick_scheduler_health"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_world_tick_scheduler_health"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_world_tick_scheduler_health"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_auth_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_auth_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_auth_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."haversine_distance"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."haversine_distance"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."haversine_distance"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."haversine_distance"("lat1" numeric, "lon1" numeric, "lat2" numeric, "lon2" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."haversine_distance"("lat1" numeric, "lon1" numeric, "lat2" numeric, "lon2" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."haversine_distance"("lat1" numeric, "lon1" numeric, "lat2" numeric, "lon2" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."lease_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."lease_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."lease_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."lease_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."lease_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."lease_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."lease_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."lease_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_username"("p_username" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_username"("p_username" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_username"("p_username" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."perform_actor_aircraft_repair"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_min_cash_reserve" numeric, "p_game_time" timestamp with time zone, "p_description" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."perform_actor_aircraft_repair"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_min_cash_reserve" numeric, "p_game_time" timestamp with time zone, "p_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."perform_actor_aircraft_repair"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_min_cash_reserve" numeric, "p_game_time" timestamp with time zone, "p_description" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."process_actor_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone, "p_elapsed_days" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."process_actor_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone, "p_elapsed_days" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_actor_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone, "p_elapsed_days" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."process_aircraft_financing_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."process_aircraft_financing_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."process_aircraft_financing_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_aircraft_financing_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."process_all_bots_simulation_to_time"("p_target_game_time" timestamp with time zone, "p_season_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."process_all_bots_simulation_to_time"("p_target_game_time" timestamp with time zone, "p_season_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."process_credit_at_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."process_credit_at_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."process_credit_at_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_credit_at_day_boundary"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."process_loan_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."process_loan_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."process_loan_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_loan_payments"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."process_player_simulation_to_time"("p_user_id" "uuid", "p_target_game_time" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."process_player_simulation_to_time"("p_user_id" "uuid", "p_target_game_time" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_player_simulation_to_time"("p_user_id" "uuid", "p_target_game_time" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."process_simulation_delta"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."process_simulation_delta"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_simulation_delta"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_simulation_delta"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."process_simulation_delta"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."process_simulation_delta"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."process_simulation_delta"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_simulation_delta"("p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."process_world_tick"("p_season_id" "uuid", "p_max_ticks" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."process_world_tick"("p_season_id" "uuid", "p_max_ticks" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_world_tick"("p_season_id" "uuid", "p_max_ticks" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."prune_bank_transactions"("p_dry_run" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prune_bank_transactions"("p_dry_run" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."prune_bank_transactions"("p_dry_run" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."prune_world_tick_log"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prune_world_tick_log"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prune_world_tick_log"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."purchase_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."purchase_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."purchase_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."purchase_aircraft"("p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."purchase_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."purchase_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."purchase_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."purchase_aircraft"("p_user_id" "uuid", "p_model_id" "uuid", "p_nickname" character varying, "p_economy_seats" integer, "p_business_seats" integer, "p_first_class_seats" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."refinance_loan"("p_loan_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refinance_loan"("p_loan_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refinance_loan"("p_loan_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."repair_aircraft"("p_fleet_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."repair_aircraft"("p_fleet_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."repair_aircraft"("p_fleet_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."repair_aircraft"("p_fleet_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."repair_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."repair_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."repair_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."repair_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."repay_loan"("p_loan_id" "uuid", "p_amount" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."repay_loan"("p_loan_id" "uuid", "p_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."repay_loan"("p_loan_id" "uuid", "p_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."repay_loan"("p_loan_id" "uuid", "p_amount" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."require_current_user_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."require_current_user_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."require_current_user_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."require_current_user_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."reset_user_airline"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reset_user_airline"() TO "anon";
GRANT ALL ON FUNCTION "public"."reset_user_airline"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_user_airline"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reset_user_airline"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reset_user_airline"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_user_airline"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."resolve_active_season_id"("p_season_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_active_season_id"("p_season_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_active_season_id"("p_season_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."resolve_credit_tier"("p_score" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resolve_credit_tier"("p_score" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_credit_tier"("p_score" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_credit_tier"("p_score" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."save_airline_settings"("p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_airline_settings"("p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."save_airline_settings"("p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_airline_settings"("p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) TO "service_role";



REVOKE ALL ON FUNCTION "public"."save_airline_settings"("p_user_id" "uuid", "p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_airline_settings"("p_user_id" "uuid", "p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."save_airline_settings"("p_user_id" "uuid", "p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_airline_settings"("p_user_id" "uuid", "p_company_name" character varying, "p_auto_grounding_threshold" numeric, "p_hq_airport_iata" character varying) TO "service_role";



REVOKE ALL ON FUNCTION "public"."sell_actor_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_game_time" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sell_actor_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_game_time" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sell_actor_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_game_time" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."sell_aircraft"("p_fleet_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sell_aircraft"("p_fleet_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."sell_aircraft"("p_fleet_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sell_aircraft"("p_fleet_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."sell_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sell_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."sell_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sell_aircraft"("p_user_id" "uuid", "p_fleet_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."spawn_bot"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."spawn_bot"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."spawn_bot"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."take_loan"("p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."take_loan"("p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."take_loan"("p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."take_loan"("p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."take_loan"("p_user_id" "uuid", "p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."take_loan"("p_user_id" "uuid", "p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."take_loan"("p_user_id" "uuid", "p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."take_loan"("p_user_id" "uuid", "p_principal" numeric, "p_term_weeks" integer, "p_loan_type" character varying, "p_collateral_aircraft_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."terminate_actor_lease"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_game_time" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."terminate_actor_lease"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_game_time" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."terminate_actor_lease"("p_user_id" "uuid", "p_fleet_id" "uuid", "p_game_time" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."terminate_aircraft_lease"("p_fleet_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."terminate_aircraft_lease"("p_fleet_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."terminate_aircraft_lease"("p_fleet_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."terminate_aircraft_lease"("p_fleet_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."terminate_aircraft_lease"("p_user_id" "uuid", "p_fleet_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."terminate_aircraft_lease"("p_user_id" "uuid", "p_fleet_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."terminate_aircraft_lease"("p_user_id" "uuid", "p_fleet_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."terminate_aircraft_lease"("p_user_id" "uuid", "p_fleet_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_bank_balance_reconcile_net_worth"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_bank_balance_reconcile_net_worth"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_bank_balance_reconcile_net_worth"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_create_default_bank_account"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_create_default_bank_account"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_create_default_bank_account"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fleet_reconcile_net_worth"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fleet_reconcile_net_worth"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fleet_reconcile_net_worth"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_loan_reconcile_net_worth"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_loan_reconcile_net_worth"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_loan_reconcile_net_worth"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_sync_tail_numbers_on_hq_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_sync_tail_numbers_on_hq_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_sync_tail_numbers_on_hq_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_update_user_net_worth"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_update_user_net_worth"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_update_user_net_worth"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_credit_score"("p_user_id" "uuid", "p_game_date" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_credit_score"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."update_credit_score"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_credit_score"("p_user_id" "uuid", "p_game_date" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_route_frequency_and_price"("p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_route_frequency_and_price"("p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."update_route_frequency_and_price"("p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_route_frequency_and_price"("p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_route_frequency_and_price"("p_user_id" "uuid", "p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_route_frequency_and_price"("p_user_id" "uuid", "p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."update_route_frequency_and_price"("p_user_id" "uuid", "p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_route_frequency_and_price"("p_user_id" "uuid", "p_route_id" "uuid", "p_ticket_price" numeric, "p_flights_per_week" integer) TO "service_role";



GRANT ALL ON TABLE "public"."achievements" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."achievements" TO "authenticated";
GRANT ALL ON TABLE "public"."achievements" TO "service_role";



GRANT ALL ON TABLE "public"."aircraft_models" TO "service_role";
GRANT SELECT ON TABLE "public"."aircraft_models" TO "authenticated";



GRANT ALL ON TABLE "public"."airports" TO "service_role";
GRANT SELECT ON TABLE "public"."airports" TO "authenticated";



GRANT ALL ON TABLE "public"."bank_accounts" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."bank_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."bank_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."bank_transactions" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."bank_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."bank_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."bot_profiles" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."bot_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."bot_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."credit_score_history" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."credit_score_history" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_score_history" TO "service_role";



GRANT ALL ON TABLE "public"."credit_scores" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."credit_scores" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_scores" TO "service_role";



GRANT ALL ON TABLE "public"."fleet_aircraft" TO "service_role";
GRANT SELECT ON TABLE "public"."fleet_aircraft" TO "authenticated";



GRANT ALL ON TABLE "public"."game_config" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."game_config" TO "authenticated";
GRANT ALL ON TABLE "public"."game_config" TO "service_role";



GRANT ALL ON TABLE "public"."game_events" TO "service_role";
GRANT SELECT ON TABLE "public"."game_events" TO "authenticated";



GRANT ALL ON TABLE "public"."loans" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."loans" TO "authenticated";
GRANT ALL ON TABLE "public"."loans" TO "service_role";



GRANT ALL ON TABLE "public"."route_assignments" TO "service_role";
GRANT SELECT ON TABLE "public"."route_assignments" TO "authenticated";



GRANT ALL ON TABLE "public"."season_clock" TO "service_role";
GRANT SELECT ON TABLE "public"."season_clock" TO "authenticated";



GRANT ALL ON TABLE "public"."users" TO "service_role";
GRANT SELECT,UPDATE ON TABLE "public"."users" TO "authenticated";



GRANT ALL ON TABLE "public"."world_tick_log" TO "service_role";
GRANT SELECT ON TABLE "public"."world_tick_log" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."world_tick_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."world_tick_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."world_tick_log_id_seq" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







