-- FIX: Replace functions that still reference dropped global_game_settings table
-- These functions exist in production but were updated in the baseline.

CREATE OR REPLACE FUNCTION public.assign_aircraft_to_route(p_route_id uuid, p_aircraft_id uuid)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM assign_aircraft_to_route(v_user_id, p_route_id, p_aircraft_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.assign_aircraft_to_route(p_user_id uuid, p_route_id uuid, p_aircraft_id uuid)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_current_aircraft_id UUID; v_effective_threshold NUMERIC(5,2); v_route_distance_km DOUBLE PRECISION; v_route_flights_per_week INT; v_aircraft_range_km INT; v_aircraft_speed_kmh INT; v_max_weekly_flights INT;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
SELECT assigned_aircraft_id, distance_km, flights_per_week INTO v_current_aircraft_id, v_route_distance_km, v_route_flights_per_week FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR; RETURN; END IF;
IF p_aircraft_id IS NOT NULL THEN
SELECT GREATEST(COALESCE(u.auto_grounding_threshold, 40.00), COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00)) INTO v_effective_threshold FROM users u WHERE u.id = p_user_id LIMIT 1;
SELECT m.range_km, m.speed_kmh INTO v_aircraft_range_km, v_aircraft_speed_kmh FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = p_aircraft_id AND f.user_id = p_user_id AND f.condition >= COALESCE(v_effective_threshold, 40.00);
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft is unavailable or below the safety threshold.'::VARCHAR; RETURN; END IF;
IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN RETURN QUERY SELECT FALSE, 'Aircraft range is insufficient for this route.'::VARCHAR; RETURN; END IF;
v_max_weekly_flights := calculate_route_max_weekly_flights(v_route_distance_km, v_aircraft_speed_kmh);
IF v_max_weekly_flights > 0 AND COALESCE(v_route_flights_per_week, 0) > v_max_weekly_flights THEN RETURN QUERY SELECT FALSE, 'Route frequency exceeds this aircraft''s weekly operating capacity.'::VARCHAR; RETURN; END IF;
IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_aircraft_id AND id <> p_route_id) THEN RETURN QUERY SELECT FALSE, 'Aircraft is already assigned to another route.'::VARCHAR; RETURN; END IF;
END IF;
UPDATE route_assignments SET assigned_aircraft_id = p_aircraft_id WHERE id = p_route_id AND user_id = p_user_id;
IF p_aircraft_id IS NOT NULL THEN UPDATE fleet_aircraft SET status = 'active' WHERE id = p_aircraft_id AND user_id = p_user_id; END IF;
RETURN QUERY SELECT TRUE, 'Aircraft assignment updated successfully!'::VARCHAR;
END;
$function$;

CREATE OR REPLACE FUNCTION public.lease_aircraft(p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM lease_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;

CREATE OR REPLACE FUNCTION public.lease_aircraft(p_user_id uuid, p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_cash NUMERIC; v_lease_price NUMERIC; v_model_name VARCHAR; v_capacity INT;
v_hq_iata VARCHAR(3); v_tail VARCHAR(20); v_deposit_pct NUMERIC; v_lease_deposit NUMERIC;
v_economy INT; v_business INT; v_first INT; v_slots_used INT; v_game_time TIMESTAMPTZ;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
v_cash := get_user_balance(p_user_id);
SELECT hq_airport_iata, game_current_time INTO v_hq_iata, v_game_time
FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC; RETURN; END IF;
SELECT lease_price_per_month, model_name, capacity INTO v_lease_price, v_model_name, v_capacity
FROM aircraft_models WHERE id = p_model_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash; RETURN; END IF;
v_deposit_pct := COALESCE(get_config_numeric('base_lease_deposit_percentage'), 0.10);
v_lease_deposit := v_lease_price * v_deposit_pct;
v_economy := COALESCE(p_economy_seats, v_capacity);
v_business := COALESCE(p_business_seats, 0);
v_first := COALESCE(p_first_class_seats, 0);
v_slots_used := v_economy + (v_business * 2) + (v_first * 3);
IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash; RETURN;
END IF;
IF v_cash < v_lease_deposit THEN
RETURN QUERY SELECT FALSE, ('Insufficient funds for lease down payment of ' || v_model_name || '. Required: $' || ROUND(v_lease_deposit, 2))::VARCHAR, v_cash; RETURN;
END IF;
LOOP v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
EXIT WHEN NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_tail);
END LOOP;
PERFORM debit_bank_account(p_user_id, v_lease_deposit, 'investing', 'aircraft_lease_deposit',
'Leased aircraft ' || v_model_name || ' deposit [' || v_tail || ']', v_game_time);
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, 'Successfully leased ' || v_model_name || ' [' || v_tail || ']'::VARCHAR, v_cash;
END;
$function$;

CREATE OR REPLACE FUNCTION public.purchase_aircraft(p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM purchase_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;

CREATE OR REPLACE FUNCTION public.purchase_aircraft(p_user_id uuid, p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.get_owner_route_optimizer(p_user_id uuid, p_origin_iata character varying DEFAULT NULL::character varying, p_destination_iata character varying DEFAULT NULL::character varying, p_limit integer DEFAULT 25, p_include_assigned boolean DEFAULT false, p_exclude_existing_routes boolean DEFAULT true)
RETURNS TABLE(aircraft_id uuid, tail_number character varying, aircraft_model character varying, acquisition_type character varying, currently_assigned boolean, route_origin_iata character varying, route_destination_iata character varying, route_already_exists boolean, distance_km numeric, ticket_price numeric, weekly_flights integer, recommended_economy_seats integer, recommended_business_seats integer, recommended_first_class_seats integer, effective_passenger_capacity integer, expected_passengers_per_flight integer, load_factor numeric, direct_cost_per_flight numeric, revenue_per_flight numeric, contribution_per_flight numeric, weekly_contribution numeric, maintenance_impact_per_week numeric)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
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
$function$;
