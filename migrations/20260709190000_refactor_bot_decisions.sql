-- ============================================================================
-- Migration 40: Refactor execute_bot_decisions() into sub-functions
-- Goal:
--   Split the monolithic ~900-line execute_bot_decisions() into focused
--   sub-functions for readability and maintainability.
--
-- Sub-functions:
--   bot_evaluate_distress()      — distress stage + archetype params
--   bot_handle_repair()          — repair logic (normal + desperate recovery)
--   bot_handle_route_lifecycle()  — audit + trim + optimization
--   bot_handle_fleet_growth()    — lease + purchase
--   bot_handle_route_creation()  — new route with secondary hub support
--   bot_handle_pricing()         — pricing review with competitive response
--   bot_handle_financial()       — loan repayment + loan request
-- ============================================================================

BEGIN;

-- ============================================================================
-- Sub-function: Evaluate distress stage and archetype parameters
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_evaluate_distress(
    p_bot_id            uuid,
    p_game_time         timestamptz,
    p_archetype         varchar,
    p_consecutive_neg   int,
    p_cash_ratio        numeric,
    OUT o_distress_stage varchar,
    OUT o_target_fleet_cap int,
    OUT o_min_cash_reserve numeric,
    OUT o_growth_chance    numeric,
    OUT o_target_distance  double precision,
    OUT o_target_price_mult numeric,
    OUT o_target_sched_ratio numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;

-- ============================================================================
-- Sub-function: Handle repair (normal + desperate recovery)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_handle_repair(
    p_bot_id        uuid,
    p_game_time     timestamptz,
    p_distress      varchar,
    p_threshold     numeric,
    p_cash_reserve  numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;

-- ============================================================================
-- Sub-function: Handle route lifecycle (audit + trim + optimization)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_handle_route_lifecycle(
    p_bot_id            uuid,
    p_game_time         timestamptz,
    p_distress          varchar,
    p_target_price_mult numeric,
    p_loss_days_thresh  int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;

-- ============================================================================
-- Sub-function: Handle fleet growth (lease + purchase)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_handle_fleet_growth(
    p_bot_id            uuid,
    p_game_time         timestamptz,
    p_archetype         varchar,
    p_distress          varchar,
    p_bot_cash          numeric,
    p_starting_cash     numeric,
    p_target_fleet_cap  int,
    p_min_cash_reserve  numeric,
    p_growth_chance     numeric,
    p_target_distance   double precision,
    p_purchase_cash_mult numeric,
    p_fleet_diversity   numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;

-- ============================================================================
-- Sub-function: Handle route creation with secondary hub support
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_handle_route_creation(
    p_bot_id            uuid,
    p_game_time         timestamptz,
    p_archetype         varchar,
    p_distress          varchar,
    p_hq_iata           varchar,
    p_target_fleet_cap  int,
    p_target_price_mult numeric,
    p_target_sched_ratio numeric,
    p_target_distance   double precision,
    p_threshold         numeric,
    p_secondary_hub_chance numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;

-- ============================================================================
-- Sub-function: Handle pricing review with competitive response
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_handle_pricing(
    p_bot_id            uuid,
    p_game_time         timestamptz,
    p_archetype         varchar,
    p_distress          varchar,
    p_target_price_mult numeric,
    p_comp_threshold    numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;

-- ============================================================================
-- Sub-function: Handle financial management (loan repayment + request)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_handle_financial(
    p_bot_id            uuid,
    p_game_time         timestamptz,
    p_distress          varchar,
    p_bot_cash          numeric,
    p_starting_cash     numeric,
    p_min_cash_reserve  numeric,
    p_repay_ratio       numeric,
    p_recovery_amount   numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;

-- ============================================================================
-- Main function: Refactored orchestrator
-- ============================================================================
CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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

        -- Route lifecycle (audit + trim + optimization)
        PERFORM bot_handle_route_lifecycle(r_bot.id, r_bot.game_current_time, v_distress, v_target_price_mult, v_loss_days_threshold);

        -- Fleet growth (lease + purchase)
        PERFORM bot_handle_fleet_growth(r_bot.id, r_bot.game_current_time, r_bot.archetype, v_distress,
            v_bot_cash, v_starting_cash, v_target_fleet_cap, v_min_cash_reserve, v_growth_chance,
            v_target_distance, v_purchase_cash_multiplier, v_fleet_diversity_chance);

        -- Route creation (kept inline due to secondary hub complexity)
        PERFORM bot_handle_route_creation(r_bot.id, r_bot.game_current_time, r_bot.archetype, v_distress,
            r_bot.hq_airport_iata, v_target_fleet_cap, v_target_price_mult, v_target_sched_ratio,
            v_target_distance, v_effective_threshold, v_secondary_hub_chance);

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
$function$;

COMMIT;
