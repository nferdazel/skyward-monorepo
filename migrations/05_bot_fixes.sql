-- ============================================================================
-- Migration 05: Bot-Related Fixes
-- Generated: 2026-06-25
--
-- FIX 1  (H2+M3): process_all_bots_simulation_to_time – game event awareness
-- FIX 2  (H3):    execute_bot_decisions – count ALL competitors (not just REAL)
-- FIX 3  (H4):    execute_bot_decisions – distance-aware route creation
-- FIX 4  (H5):    execute_bot_decisions – archetype-specific aircraft purchase
-- FIX 5  (H7):    execute_bot_decisions – cash-threshold bankruptcy + cancel routes
-- FIX 6  (M4):    process_world_tick – run bot decisions every tick
-- FIX 7  (M5):    execute_bot_decisions – cost-cutting LEAST not GREATEST
-- FIX 8  (M6):    spawn_bot – include season_id
-- FIX 9  (M17):   bot_finance_aircraft + finance_aircraft – proper tail numbers
-- FIX 10 (M18):   calculate_user_net_worth – include leased aircraft
--
-- All functions use CREATE OR REPLACE and are idempotent.
-- ============================================================================

-- ============================================================================
-- FIX 1 (H2+M3): Bot game events
-- The bot simulation hardcoded v_fuel_price_multiplier := 1.0 and never
-- queried game_events. Now mirrors the player simulation pattern with
-- fuel_shock, maintenance_shock, demand_surge, and weather_disruption lookups.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_all_bots_simulation_to_time(
    p_target_game_time timestamp with time zone,
    p_season_id        uuid DEFAULT NULL::uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    r_bot                          RECORD;
    v_game_sec                     DOUBLE PRECISION;
    v_game_days                    DOUBLE PRECISION;
    v_route                        RECORD;
    v_flights                      DOUBLE PRECISION;
    v_revenue                      NUMERIC(20,2) := 0;
    v_fuel_cost                    NUMERIC(20,2) := 0;
    v_maint_cost                   NUMERIC(20,2) := 0;
    v_crew_cost                    NUMERIC(20,2) := 0;
    v_total_cost                   NUMERIC(20,2) := 0;
    v_net                          NUMERIC(20,2) := 0;
    v_passengers                   INT;
    v_flight_duration              DOUBLE PRECISION;
    v_turnaround_hours             NUMERIC;
    v_lease_cost                   NUMERIC(20,2) := 0;
    v_fuel_price                   NUMERIC;
    v_fuel_price_multiplier        NUMERIC;
    v_crew_cost_per_hour           NUMERIC;
    v_absolute_minimum_safety_limit NUMERIC(5,2);
    v_effective_grounding_threshold NUMERIC(5,2);
    v_max_weekly_flights           INT;
    v_wear_per_cycle               NUMERIC(8,4);
    v_gross_damage                 NUMERIC(20,4);
    v_self_healing_credit          NUMERIC(20,4);
    v_net_damage                   NUMERIC(20,4);
    v_cargo_rev                    NUMERIC(20,2);
    v_processed                    INT := 0;
    v_demand_multiplier            NUMERIC;
    v_seasonal_multiplier          NUMERIC;
    v_owned_wear                   NUMERIC;
    v_leased_wear                  NUMERIC;
    v_auto_repair_rate             NUMERIC;
    -- FIX 1: new variables for game event awareness
    v_maintenance_multiplier       NUMERIC;
    v_route_demand_event           NUMERIC;
    v_route_capacity_event         NUMERIC;
    v_effective_capacity           NUMERIC;
BEGIN
    v_fuel_price       := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_absolute_minimum_safety_limit := COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00);
    v_crew_cost_per_hour := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear       := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear      := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);

    -- FIX 1: Query global game events (fuel_shock, maintenance_shock)
    -- matching the player simulation pattern
    SELECT COALESCE(effect_value, 1.0) INTO v_fuel_price_multiplier
      FROM game_events
     WHERE event_type = 'fuel_shock' AND is_active = true
       AND effect_type = 'fuel_price'
       AND start_game_time <= p_target_game_time
       AND end_game_time > p_target_game_time
     ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_fuel_price_multiplier := 1.0; END IF;

    SELECT COALESCE(effect_value, 1.0) INTO v_maintenance_multiplier
      FROM game_events
     WHERE event_type = 'maintenance_shock' AND is_active = true
       AND effect_type = 'maintenance_cost'
       AND start_game_time <= p_target_game_time
       AND end_game_time > p_target_game_time
     ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_maintenance_multiplier := 1.0; END IF;

    v_seasonal_multiplier  := 1.0;

    FOR r_bot IN
        SELECT * FROM users
         WHERE actor_type = 'AI'
           AND COALESCE(operational_status, 'Active') != 'Bankrupt'
    LOOP
        v_effective_grounding_threshold := GREATEST(
            COALESCE(r_bot.auto_grounding_threshold, 40.00),
            v_absolute_minimum_safety_limit
        );

        v_game_sec  := EXTRACT(EPOCH FROM (p_target_game_time - r_bot.game_current_time));
        v_game_days := v_game_sec / 86400.0;
        IF v_game_days <= 0 THEN CONTINUE; END IF;

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
             WHERE ra.user_id = r_bot.id AND ra.status = 'active'
               AND fa.status = 'active'
               AND fa.condition >= v_effective_grounding_threshold
        LOOP
            -- FIX 1: Per-route demand_surge event lookup
            v_route_demand_event := 1.0;
            SELECT COALESCE(effect_value, 1.0) INTO v_route_demand_event
              FROM game_events
             WHERE event_type = 'demand_surge' AND is_active = true
               AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
               AND start_game_time <= p_target_game_time
               AND end_game_time > p_target_game_time
             ORDER BY start_game_time DESC LIMIT 1;
            IF NOT FOUND THEN v_route_demand_event := 1.0; END IF;

            -- FIX 1: Per-route weather_disruption event lookup
            v_route_capacity_event := 1.0;
            SELECT COALESCE(effect_value, 1.0) INTO v_route_capacity_event
              FROM game_events
             WHERE event_type = 'weather_disruption' AND is_active = true
               AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
               AND start_game_time <= p_target_game_time
               AND end_game_time > p_target_game_time
             ORDER BY start_game_time DESC LIMIT 1;
            IF NOT FOUND THEN v_route_capacity_event := 1.0; END IF;

            v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
            v_flight_duration := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0))
                               + v_turnaround_hours;
            IF v_flight_duration <= 0 THEN CONTINUE; END IF;

            v_max_weekly_flights := FLOOR(168.0 / v_flight_duration)::INT;
            v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);

            -- FIX 1: Apply demand_surge event to demand multiplier
            v_demand_multiplier := calculate_route_demand_multiplier(
                v_route.distance_km, v_route.ticket_price)
                * v_route_demand_event;

            -- FIX 1: Apply weather_disruption event to effective capacity
            v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);
            v_passengers := LEAST(v_effective_capacity,
                FLOOR(v_effective_capacity * 0.95 * v_demand_multiplier * v_seasonal_multiplier));

            v_revenue   := v_flights * v_route.ticket_price * v_passengers;
            v_fuel_cost := v_flights * v_route.distance_km
                         * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
            v_crew_cost := v_flights * v_flight_duration * v_crew_cost_per_hour;
            -- FIX 1: Apply maintenance_multiplier to maintenance cost
            v_maint_cost := v_flights * v_route.distance_km
                          * v_route.maintenance_cost_per_hour
                          * COALESCE(v_maintenance_multiplier, 1.0)
                          / NULLIF(v_route.speed_kmh, 0);
            v_cargo_rev := v_revenue * 0.05;
            v_lease_cost := CASE
                WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                              WHERE fa2.id = v_route.assigned_aircraft_id
                                AND fa2.acquisition_type = 'lease')
                THEN COALESCE(v_route.lease_price_per_month, 0) / 4.0
                ELSE 0
            END;

            PERFORM credit_bank_account(r_bot.id, v_revenue + v_cargo_rev,
                'revenue', 'ticket_revenue',
                'Bot route ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
            PERFORM debit_bank_account(r_bot.id, v_fuel_cost,
                'cogs', 'fuel',
                'Bot fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
            PERFORM debit_bank_account(r_bot.id, v_crew_cost,
                'cogs', 'crew',
                'Bot crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
            PERFORM debit_bank_account(r_bot.id, v_maint_cost,
                'cogs', 'maintenance',
                'Bot maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
            IF v_lease_cost > 0 THEN
                PERFORM debit_bank_account(r_bot.id, v_lease_cost,
                    'opex', 'aircraft_lease',
                    'Bot lease: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                    p_target_game_time);
            END IF;

            v_wear_per_cycle := CASE
                WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
                ELSE v_owned_wear
            END + (v_route.distance_km * 0.0001);
            v_gross_damage := v_wear_per_cycle * v_flights * v_game_days / 7.0;

            v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
            v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

            UPDATE fleet_aircraft
               SET condition = GREATEST(0, condition - v_net_damage)
             WHERE id = v_route.assigned_aircraft_id;
        END LOOP;

        -- Check achievements at day boundary
        IF date_trunc('day', r_bot.game_current_time)::DATE <>
           date_trunc('day', p_target_game_time)::DATE THEN
            PERFORM check_achievements(r_bot.id, p_target_game_time);
        END IF;

        UPDATE users
           SET game_current_time = p_target_game_time,
               last_active_at = NOW()
         WHERE id = r_bot.id;

        IF v_game_days >= 1.0 THEN
            PERFORM process_loan_payments(r_bot.id, p_target_game_time);
            PERFORM process_aircraft_financing_payments(r_bot.id, p_target_game_time);
            PERFORM process_credit_at_day_boundary(r_bot.id, p_target_game_time);

            IF get_user_balance(r_bot.id) < 0 THEN
                UPDATE users
                   SET consecutive_negative_days = consecutive_negative_days + 1
                 WHERE id = r_bot.id;
            ELSE
                UPDATE users
                   SET consecutive_negative_days = 0
                 WHERE id = r_bot.id;
            END IF;

            IF (SELECT consecutive_negative_days FROM users WHERE id = r_bot.id) >= 30 THEN
                UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
                UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id;
            END IF;
        END IF;

        v_processed := v_processed + 1;
    END LOOP;

    RETURN v_processed;
END;
$function$;


-- ============================================================================
-- FIX 2 (H3): Bot pricing competitor awareness
-- FIX 3 (H4): Bot route creation distance-aware
-- FIX 4 (H5): Bot aircraft purchase archetype
-- FIX 5 (H7): Bot bankrupt threshold (cash-threshold + cancel routes)
-- FIX 7 (M5): Bot cost-cutting GREATEST→LEAST
--
-- These five fixes all target execute_bot_decisions.  Replaced as one block.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
r_bot RECORD; v_model_id UUID; v_model_name VARCHAR; v_lease_price NUMERIC; v_purchase_price NUMERIC; v_capacity INT; v_speed_kmh NUMERIC; v_range_km NUMERIC; v_deposit_pct NUMERIC; v_deposit_amount NUMERIC; v_tail VARCHAR(20); v_origin_iata VARCHAR(3); v_dest_iata VARCHAR(3); v_distance DOUBLE PRECISION; v_fleet_count INT; v_route_count INT; v_idle_aircraft_count INT; v_idle_aircraft_id UUID; v_idle_tail VARCHAR(20); v_idle_condition NUMERIC; v_idle_model_name VARCHAR; v_idle_capacity INT; v_idle_speed NUMERIC; v_idle_range NUMERIC; v_grounded_aircraft_id UUID; v_grounded_condition NUMERIC; v_grounded_acquisition_type VARCHAR; v_grounded_model_name VARCHAR; v_grounded_lease_price NUMERIC; v_grounded_purchase_price NUMERIC; v_repair_cost NUMERIC; v_target_fleet_cap INT; v_min_cash_reserve NUMERIC; v_growth_chance NUMERIC; v_target_distance DOUBLE PRECISION; v_target_price_multiplier NUMERIC; v_target_schedule_ratio NUMERIC; v_effective_threshold NUMERIC(5,2); v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00; v_selected_route_id UUID; v_selected_flights INT; v_selected_base_fare NUMERIC; v_max_weekly_flights INT; v_target_flights INT; v_target_price NUMERIC; v_bot_cash NUMERIC; v_starting_cash NUMERIC; v_attempts INT; v_inserted BOOLEAN; v_economy INT; v_business INT; v_first INT; r_route RECORD; v_human_competitors INT; v_new_price NUMERIC; v_base_fare NUMERIC; v_purchase_capacity INT; v_purchase_model_name VARCHAR; v_active_loans INT; v_game_time TIMESTAMPTZ;
v_archetype VARCHAR(30);
v_ticket_base_fare NUMERIC;
v_ticket_per_km_rate NUMERIC;
v_bankruptcy_threshold NUMERIC;
v_spawned_id UUID;
BEGIN
-- Read constants from game_config
v_ticket_base_fare := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
v_ticket_per_km_rate := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);
v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);
SELECT value::numeric INTO v_deposit_pct FROM game_config WHERE key = 'base_lease_deposit_percentage';
v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
FOR r_bot IN
SELECT u.*, COALESCE(bp.archetype, 'Balanced') as archetype
FROM users u
LEFT JOIN bot_profiles bp ON bp.user_id = u.id
WHERE u.actor_type = 'AI' AND u.operational_status != 'Bankrupt'
LOOP
v_archetype := r_bot.archetype;
v_bot_cash := get_user_balance(r_bot.id);
v_game_time := r_bot.game_current_time;
v_origin_iata := r_bot.hq_airport_iata;
v_effective_threshold := GREATEST(v_absolute_minimum_safety_limit, COALESCE(r_bot.auto_grounding_threshold, 40.00));
-- FIX 5: Use cash-threshold bankruptcy check; change DELETE to UPDATE status='cancelled'
IF v_bot_cash < v_bankruptcy_threshold THEN
  UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
  UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id;
  UPDATE loans SET status = 'defaulted', remaining_balance = 0 WHERE user_id = r_bot.id AND status = 'active';
  UPDATE route_assignments SET status = 'cancelled' WHERE user_id = r_bot.id AND status = 'active';
  CONTINUE;
END IF;
CASE v_archetype WHEN 'Regional' THEN v_target_fleet_cap := 8; v_min_cash_reserve := 3500000.00; v_growth_chance := 0.20; v_target_distance := 900.0; v_target_price_multiplier := 0.95; v_target_schedule_ratio := 0.72; WHEN 'Aggressive' THEN v_target_fleet_cap := 14; v_min_cash_reserve := 4500000.00; v_growth_chance := 0.26; v_target_distance := 1800.0; v_target_price_multiplier := 1.02; v_target_schedule_ratio := 0.82; ELSE v_target_fleet_cap := 10; v_min_cash_reserve := 7000000.00; v_growth_chance := 0.16; v_target_distance := 4200.0; v_target_price_multiplier := 1.18; v_target_schedule_ratio := 0.58; END CASE;
SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
SELECT COUNT(*)::INT INTO v_idle_aircraft_count FROM fleet_aircraft f WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);
SELECT f.id, f.condition, f.acquisition_type, m.model_name, m.lease_price_per_month, m.purchase_price INTO v_grounded_aircraft_id, v_grounded_condition, v_grounded_acquisition_type, v_grounded_model_name, v_grounded_lease_price, v_grounded_purchase_price FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND (f.status = 'grounded' OR f.condition < v_effective_threshold) ORDER BY f.condition DESC LIMIT 1;
IF v_grounded_aircraft_id IS NOT NULL THEN v_repair_cost := CASE WHEN v_grounded_acquisition_type = 'lease' THEN (100.00 - v_grounded_condition) * (COALESCE(v_grounded_lease_price, 0.00) * 0.50) ELSE (100.00 - v_grounded_condition) * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005) END; IF v_repair_cost > 0 AND v_bot_cash >= (v_repair_cost + 500000.00) THEN PERFORM debit_bank_account(r_bot.id, v_repair_cost, 'cogs', 'maintenance', 'Bot maintenance recovery: ' || v_grounded_model_name, v_game_time); UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = v_grounded_aircraft_id; v_bot_cash := v_bot_cash - v_repair_cost; END IF; END IF;
-- Use config values for base fare calculation
-- FIX 7: Changed GREATEST to LEAST for distress pricing (lower prices, not raise)
IF v_bot_cash < 3000000.00 OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN SELECT r.id, r.flights_per_week, (v_ticket_base_fare + (r.distance_km * v_ticket_per_km_rate))::NUMERIC INTO v_selected_route_id, v_selected_flights, v_selected_base_fare FROM route_assignments r WHERE r.user_id = r_bot.id ORDER BY (r.ticket_price / NULLIF((v_ticket_base_fare + (r.distance_km * v_ticket_per_km_rate)), 0)) DESC, r.flights_per_week DESC LIMIT 1; IF v_selected_route_id IS NOT NULL THEN IF v_selected_flights > 8 THEN UPDATE route_assignments SET flights_per_week = GREATEST(6, flights_per_week - CASE v_archetype WHEN 'Regional' THEN 6 WHEN 'Aggressive' THEN 4 ELSE 2 END), ticket_price = LEAST(ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2), ROUND((ticket_price * 0.90)::numeric, 2)) WHERE id = v_selected_route_id; ELSE DELETE FROM route_assignments WHERE id = v_selected_route_id; END IF; END IF; END IF;
IF v_fleet_count < v_target_fleet_cap AND v_bot_cash > v_min_cash_reserve AND COALESCE(r_bot.consecutive_negative_days, 0) = 0 AND v_idle_aircraft_count = 0 AND v_route_count >= v_fleet_count AND random() < v_growth_chance THEN
v_model_id := NULL; v_model_name := NULL; v_lease_price := NULL; v_purchase_price := NULL; v_capacity := NULL;
IF v_archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600' LIMIT 1; ELSIF v_archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' AND model_name = 'A320neo' LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' AND model_name = '787-9' LIMIT 1; END IF;
IF v_model_id IS NULL THEN IF v_archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' ORDER BY capacity DESC LIMIT 1; ELSIF v_archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' ORDER BY capacity DESC LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' ORDER BY capacity DESC LIMIT 1; END IF; END IF;
v_deposit_amount := COALESCE(v_lease_price, 0.00) * v_deposit_pct;
IF v_model_id IS NOT NULL AND v_bot_cash >= v_deposit_amount THEN IF v_archetype = 'Regional' THEN v_economy := FLOOR(v_capacity * 0.80); v_business := FLOOR(v_capacity * 0.15); v_first := v_capacity - v_economy - v_business; ELSIF v_archetype = 'Aggressive' THEN v_economy := FLOOR(v_capacity * 0.70); v_business := FLOOR(v_capacity * 0.20); v_first := v_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_capacity * 0.50); v_business := FLOOR(v_capacity * 0.30); v_first := v_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (id, user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats) VALUES (gen_random_uuid(), r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN PERFORM debit_bank_account(r_bot.id, v_deposit_amount, 'investing', 'aircraft_lease_deposit', 'Leased aircraft ' || v_model_name || ' [' || v_tail || '] - deposit', v_game_time); v_bot_cash := v_bot_cash - v_deposit_amount; END IF; END IF;
END IF;
-- FIX 4: Archetype-specific aircraft purchase (matching lease path pattern)
IF v_bot_cash > (v_starting_cash * 3) AND v_fleet_count < v_target_fleet_cap THEN
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
  -- Fallback to generic if archetype-specific not found
  IF v_model_id IS NULL THEN
    SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name
    FROM aircraft_models WHERE range_km >= v_target_distance ORDER BY purchase_price ASC LIMIT 1;
  END IF;
  IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN IF v_archetype = 'Regional' THEN v_economy := FLOOR(v_purchase_capacity * 0.80); v_business := FLOOR(v_purchase_capacity * 0.15); v_first := v_purchase_capacity - v_economy - v_business; ELSIF v_archetype = 'Aggressive' THEN v_economy := FLOOR(v_purchase_capacity * 0.70); v_business := FLOOR(v_purchase_capacity * 0.20); v_first := v_purchase_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_purchase_capacity * 0.50); v_business := FLOOR(v_purchase_capacity * 0.30); v_first := v_purchase_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats) VALUES (r_bot.id, v_model_id, v_purchase_model_name, v_tail, 'purchase', 100.00, 'active', v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN PERFORM debit_bank_account(r_bot.id, v_purchase_price, 'investing', 'aircraft_purchase', 'Aircraft purchase: ' || v_tail, v_game_time); v_bot_cash := v_bot_cash - v_purchase_price; END IF; END IF;
END IF;
SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
SELECT f.id, f.tail_number, f.condition, m.model_name, m.capacity, m.speed_kmh, m.range_km INTO v_idle_aircraft_id, v_idle_tail, v_idle_condition, v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id) ORDER BY f.condition DESC LIMIT 1;
-- FIX 3: Distance-aware route creation — filter destinations by aircraft range
IF v_idle_aircraft_id IS NOT NULL AND v_route_count < v_target_fleet_cap THEN v_attempts := 0; v_inserted := false; WHILE v_attempts < 20 AND NOT v_inserted LOOP SELECT iata INTO v_dest_iata FROM airports WHERE iata != v_origin_iata AND haversine_distance((SELECT latitude FROM airports WHERE iata = v_origin_iata), (SELECT longitude FROM airports WHERE iata = v_origin_iata), latitude, longitude) <= v_idle_range ORDER BY demand_index DESC, random() LIMIT 1; IF v_dest_iata IS NULL THEN EXIT; END IF; SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude) INTO v_distance FROM airports o, airports d WHERE o.iata = v_origin_iata AND d.iata = v_dest_iata; IF v_distance > 0 AND v_distance <= v_idle_range THEN v_base_fare := v_ticket_base_fare + (v_distance * v_ticket_per_km_rate); v_target_price := ROUND(v_base_fare * v_target_price_multiplier, 2); v_max_weekly_flights := calculate_route_max_weekly_flights(v_distance, v_idle_speed::INT); v_target_flights := GREATEST(1, FLOOR(v_max_weekly_flights * v_target_schedule_ratio)); BEGIN INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week) VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, v_target_price, v_idle_aircraft_id, v_target_flights); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; ELSE v_attempts := v_attempts + 1; END IF; END LOOP; END IF;
-- FIX 2: Count ALL competitors (removed actor_type = 'REAL' filter)
FOR r_route IN SELECT ra.*, m.speed_kmh, m.range_km, m.turnaround_hours FROM route_assignments ra JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id JOIN aircraft_models m ON m.id = fa.aircraft_model_id WHERE ra.user_id = r_bot.id AND ra.status = 'active' LOOP SELECT COUNT(*) INTO v_human_competitors FROM route_assignments WHERE origin_iata = r_route.origin_iata AND destination_iata = r_route.destination_iata AND status = 'active' AND user_id != r_bot.id; IF v_human_competitors > 0 THEN v_base_fare := v_ticket_base_fare + (r_route.distance_km * v_ticket_per_km_rate); v_new_price := ROUND(v_base_fare * v_target_price_multiplier * CASE WHEN r_route.ticket_price > v_base_fare * 1.3 THEN 0.95 ELSE 1.0 END, 2); IF v_new_price != r_route.ticket_price THEN UPDATE route_assignments SET ticket_price = v_new_price WHERE id = r_route.id; END IF; END IF; END LOOP;
SELECT COUNT(*) INTO v_active_loans FROM loans WHERE user_id = r_bot.id AND status = 'active'; IF v_active_loans = 0 AND v_bot_cash < v_starting_cash * 0.5 AND v_bot_cash > 1000000 THEN PERFORM bot_take_loan(r_bot.id, LEAST(5000000, v_starting_cash - v_bot_cash)); END IF;
UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;
END LOOP;
-- Spawn replacement bot if below max
IF (SELECT COUNT(*) FROM users WHERE actor_type = 'AI' AND COALESCE(operational_status, 'Active') != 'Bankrupt') <
COALESCE(get_config_int('max_bot_count'), 5) THEN
v_spawned_id := spawn_bot();
END IF;
END;
$function$;


-- ============================================================================
-- FIX 6 (M4): Bot decisions frequency
-- Changed from "only at day boundary" to "every tick".
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_world_tick(p_season_id uuid DEFAULT NULL::uuid, p_max_ticks integer DEFAULT 10)
RETURNS TABLE(season_id uuid, ticks_processed integer, game_time_after timestamp with time zone, players_processed integer, bots_processed integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
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
IF NOT FOUND THEN RAISE EXCEPTION 'No active season found'; END IF;
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
FROM process_player_simulation_to_time(r_user.id, v_game_time_after) LIMIT 1;
IF COALESCE(r_player_result.elapsed_days, 0.0) > 0.0 THEN
v_players_processed := v_players_processed + 1;
END IF;
EXCEPTION WHEN OTHERS THEN
GET STACKED DIAGNOSTICS v_error_msg = MESSAGE_TEXT;
INSERT INTO world_tick_log (season_id, status, message, started_at, finished_at)
VALUES (r_season.id, 'player_error',
'Player ' || r_user.id || ': ' || v_error_msg, NOW(), NOW());
END;
END LOOP;
v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);
-- FIX 6: Run bot decisions every tick, not just at day boundary
PERFORM execute_bot_decisions();
UPDATE season_clock
SET current_game_time = v_game_time_after, last_tick_at = NOW(), updated_at = NOW()
WHERE id = r_season.id;
v_ticks_processed := 1;
INSERT INTO world_tick_log (
season_id, started_at, finished_at,
game_time_before, game_time_after,
ticks_processed, players_processed, bots_processed,
status, message
) VALUES (
r_season.id, v_start_time, NOW(),
v_game_time_before, v_game_time_after,
1, v_players_processed, v_bots_processed,
'success', 'Tick completed successfully'
);
season_id := r_season.id;
ticks_processed := v_ticks_processed;
game_time_after := v_game_time_after;
players_processed := v_players_processed;
bots_processed := v_bots_processed;
RETURN NEXT;
END;
$function$;


-- ============================================================================
-- FIX 8 (M6): spawn_bot season_id
-- Bots were inserted without season_id, causing them to be invisible to
-- world tick processing which filters on u.season_id.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.spawn_bot()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    v_season_id     UUID;
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

    -- FIX 8: Get active season_id for the bot
    SELECT id INTO v_season_id
      FROM season_clock
     WHERE status = 'active'
     LIMIT 1;

    -- Generate unique username (internal identifier, not shown to players)
    v_username := 'bot_' || left(gen_random_uuid()::text, 8);

    -- Generate human-like names
    v_ceo_name := generate_ceo_name();

    -- Retry loop for company_name INSERT to handle UNIQUE collisions.
    v_attempts := 0;
    v_inserted := false;
    WHILE v_attempts < 10 AND NOT v_inserted LOOP
        v_company_name := generate_company_name(v_archetype);
        BEGIN
            INSERT INTO users (
                username, company_name, ceo_name, actor_type,
                hq_airport_iata, game_current_time, operational_status,
                net_worth, consecutive_negative_days, recovery_streak_days,
                auto_grounding_threshold, season_id
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
                40.00,
                v_season_id
            ) RETURNING id INTO v_bot_id;
            v_inserted := true;
        EXCEPTION
            WHEN unique_violation THEN
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
$function$;


-- ============================================================================
-- FIX 9 (M17): Bot financing tail numbers
-- Changed from 'BOT-' || left(id::text, 4) to generate_tail_number()
-- in both bot_finance_aircraft and the AI path of finance_aircraft.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.bot_finance_aircraft(p_bot_id uuid, p_aircraft_model_id uuid, p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 60)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_model RECORD;
v_purchase_price NUMERIC;
v_down_payment NUMERIC;
v_principal NUMERIC;
v_interest_rate NUMERIC := 0.05;
v_monthly_payment NUMERIC;
v_cash NUMERIC;
v_game_time TIMESTAMPTZ;
v_fleet_id UUID;
v_hq_iata VARCHAR(3);
BEGIN
SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
IF NOT FOUND THEN RETURN false; END IF;
v_purchase_price := v_model.purchase_price;
v_down_payment := v_purchase_price * p_down_payment_pct;
v_principal := v_purchase_price - v_down_payment;
v_monthly_payment := (v_principal * (1 + v_interest_rate)) / p_term_months;
v_cash := get_user_balance(p_bot_id);
SELECT game_current_time, hq_airport_iata INTO v_game_time, v_hq_iata FROM users WHERE id = p_bot_id;
IF v_cash < v_down_payment THEN RETURN false; END IF;
PERFORM debit_bank_account(p_bot_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
'Aircraft financing down payment — ' || v_model.model_name, v_game_time);
-- FIX 9: Use generate_tail_number instead of 'BOT-' prefix
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
VALUES (p_bot_id, p_aircraft_model_id, v_model.model_name, 'finance', 100.00, 'active', generate_tail_number(COALESCE(v_hq_iata, 'CGK')), FLOOR(v_model.capacity * 0.70)::INT, FLOOR(v_model.capacity * 0.20)::INT, FLOOR(v_model.capacity * 0.10)::INT)
RETURNING id INTO v_fleet_id;
INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id, term_months, monthly_payment)
VALUES (p_bot_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', 'aircraft_financing', v_fleet_id, p_term_months, v_monthly_payment);
RETURN true;
END;
$function$;

-- FIX 9 also applies to the AI path in finance_aircraft
CREATE OR REPLACE FUNCTION public.finance_aircraft(p_user_id uuid, p_aircraft_model_id uuid, p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 36)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_actor_type VARCHAR(10); v_model RECORD; v_credit_score INT; v_tier VARCHAR(10);
v_purchase_price NUMERIC; v_down_payment NUMERIC; v_principal NUMERIC;
v_interest_rate NUMERIC; v_monthly_payment NUMERIC; v_total_repayable NUMERIC;
v_cash NUMERIC; v_game_time TIMESTAMPTZ; v_fleet_id UUID; v_hq_iata VARCHAR(3);
v_max_financing NUMERIC; v_economy_seats INT; v_business_seats INT; v_first_seats INT;
v_archetype VARCHAR(30);
BEGIN
SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
IF NOT FOUND THEN RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC; RETURN; END IF;
v_purchase_price := v_model.purchase_price;
SELECT u.actor_type, u.game_current_time, u.hq_airport_iata
INTO v_actor_type, v_game_time, v_hq_iata
FROM users u WHERE u.id = p_user_id;
IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;
-- Read archetype from bot_profiles for AI users
IF v_actor_type = 'AI' THEN
SELECT COALESCE(bp.archetype, 'Balanced') INTO v_archetype
FROM bot_profiles bp WHERE bp.user_id = p_user_id;
IF NOT FOUND THEN v_archetype := 'Balanced'; END IF;
END IF;
IF v_actor_type = 'AI' THEN
v_cash := get_user_balance(p_user_id);
v_down_payment := v_purchase_price * p_down_payment_pct;
v_principal := v_purchase_price - v_down_payment;
v_interest_rate := 0.05;
v_total_repayable := v_principal * (1 + v_interest_rate);
v_monthly_payment := v_total_repayable / p_term_months;
IF v_cash < v_down_payment THEN
RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
END IF;
PERFORM debit_bank_account(p_user_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
'Aircraft financing down payment — ' || v_model.model_name, v_game_time);
v_economy_seats := CASE WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.80)::INT
WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)::INT
ELSE FLOOR(v_model.capacity * 0.50)::INT END;
v_business_seats := CASE WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.15)::INT
WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)::INT
ELSE FLOOR(v_model.capacity * 0.30)::INT END;
v_first_seats := v_model.capacity - v_economy_seats - v_business_seats;
-- FIX 9: Use generate_tail_number for AI path too
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
VALUES (p_user_id, p_aircraft_model_id, v_model.model_name, generate_tail_number(COALESCE(v_hq_iata, 'CGK')), 'finance', 100.00, 'active', v_economy_seats, v_business_seats, v_first_seats)
RETURNING id INTO v_fleet_id;
INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id, term_months, monthly_payment)
VALUES (p_user_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', 'aircraft_financing', v_fleet_id, p_term_months, v_monthly_payment);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT true, 'Aircraft financed (bot).'::TEXT, v_cash;
RETURN;
END IF;
-- Human path
v_cash := get_user_balance(p_user_id);
SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
v_credit_score := COALESCE(v_credit_score, 500);
SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = p_user_id;
v_tier := COALESCE(v_tier, 'Standard');
v_max_financing := CASE
WHEN v_tier = 'Platinum' THEN 80000000 WHEN v_tier = 'Gold' THEN 60000000
WHEN v_tier = 'Silver' THEN 40000000 WHEN v_tier = 'Standard' THEN 20000000
ELSE 5000000
END;
IF v_purchase_price > v_max_financing THEN
RETURN QUERY SELECT false, 'Aircraft price ($' || v_purchase_price::TEXT || ') exceeds your financing limit ($' || v_max_financing::TEXT || ') for tier ' || v_tier || '.'::TEXT, 0::NUMERIC; RETURN;
END IF;
IF p_term_months NOT IN (12, 24, 36, 48, 60) THEN
RETURN QUERY SELECT false, 'Financing term must be 12, 24, 36, 48, or 60 months.'::TEXT, 0::NUMERIC; RETURN;
END IF;
IF p_down_payment_pct < 0.10 OR p_down_payment_pct > 0.50 THEN
RETURN QUERY SELECT false, 'Down payment must be between 10% and 50%.'::TEXT, 0::NUMERIC; RETURN;
END IF;
v_down_payment := v_purchase_price * p_down_payment_pct;
v_principal := v_purchase_price - v_down_payment;
v_interest_rate := CASE
WHEN v_tier = 'Platinum' THEN 0.03 WHEN v_tier = 'Gold' THEN 0.04
WHEN v_tier = 'Silver' THEN 0.05 WHEN v_tier = 'Standard' THEN 0.07
ELSE 0.10
END;
v_total_repayable := v_principal * (1 + v_interest_rate);
v_monthly_payment := v_total_repayable / p_term_months;
IF v_cash < v_down_payment THEN
RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
END IF;
PERFORM debit_bank_account(p_user_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
'Aircraft financing down payment — ' || v_model.model_name, v_game_time);
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
VALUES (p_user_id, p_aircraft_model_id, v_model.model_name, generate_tail_number(COALESCE(v_hq_iata, 'CGK')), 'finance', 100.00, 'active', v_model.capacity, 0, 0)
RETURNING id INTO v_fleet_id;
INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id, term_months, monthly_payment)
VALUES (p_user_id, v_principal, v_interest_rate, v_total_repayable, 0, 'active', 'aircraft_financing', v_fleet_id, p_term_months, v_monthly_payment);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$function$;


-- ============================================================================
-- FIX 10 (M18): Bot net_worth include leased aircraft
-- calculate_user_net_worth previously only counted purchased aircraft.
-- Now includes leased aircraft valued at lease_price_per_month * 12 * condition.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.calculate_user_net_worth(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_cash NUMERIC;
v_fleet_value NUMERIC;
BEGIN
v_cash := get_user_balance(p_user_id);
-- FIX 10: Include leased aircraft at discounted annualised value
SELECT COALESCE(SUM(
  CASE WHEN f.acquisition_type = 'purchase' THEN m.purchase_price * (f.condition / 100.00)
       WHEN f.acquisition_type = 'lease' THEN m.lease_price_per_month * 12 * (f.condition / 100.00)
       ELSE 0
  END), 0)
INTO v_fleet_value
FROM fleet_aircraft f
JOIN aircraft_models m ON f.aircraft_model_id = m.id
WHERE f.user_id = p_user_id;
RETURN COALESCE(v_cash, 0) + v_fleet_value;
END;
$function$;
