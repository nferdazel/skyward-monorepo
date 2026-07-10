-- ============================================================================
-- Migration 36: Bot Realism Pass
-- Goal:
--   Make bots feel less scripted and more operator-like without breaking
--   balance. All data surfaces are shared (parity principle).
--
-- Changes:
--   1. get_route_performance() shared function for route analytics
--   2. bot_profiles schema additions (6 new columns)
--   3. game_config entries (8 new)
--   4. execute_bot_decisions() full rewrite with 9 behavioral improvements
-- ============================================================================

BEGIN;

-- ============================================================================
-- PART 1: Shared route performance function
-- ============================================================================
-- This function computes per-route financial performance from existing data.
-- Both player dashboard and bot decisions can use it.
-- No new tables — uses existing route_assignments, fleet_aircraft, airports.

CREATE OR REPLACE FUNCTION public.get_route_performance(p_user_id uuid)
RETURNS TABLE(
    route_id            uuid,
    origin_iata         varchar,
    destination_iata    varchar,
    distance_km         double precision,
    ticket_price        numeric,
    flights_per_week    int,
    assigned_aircraft   varchar,
    effective_capacity  int,
    expected_passengers int,
    load_factor         numeric,
    revenue_per_flight  numeric,
    cost_per_flight     numeric,
    profit_per_flight   numeric,
    weekly_profit       numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
            -- Effective capacity
            GREATEST(0, COALESCE(
                NULLIF(COALESCE(rd.economy_seats, 0) + COALESCE(rd.business_seats, 0) + COALESCE(rd.first_class_seats, 0), 0),
                COALESCE(rd.model_capacity, 0)
            ))::INT AS eff_capacity,
            -- Expected passengers (8-param version)
            calculate_route_expected_passengers(
                GREATEST(0, COALESCE(
                    NULLIF(COALESCE(rd.economy_seats, 0) + COALESCE(rd.business_seats, 0) + COALESCE(rd.first_class_seats, 0), 0),
                    COALESCE(rd.model_capacity, 0)
                ))::INT,
                rd.r_distance,
                rd.r_price,
                rd.origin_demand,
                rd.dest_demand,
                rd.r_origin,
                rd.r_dest,
                p_user_id
            ) AS exp_passengers,
            -- Fuel cost per flight
            rd.r_distance * COALESCE(rd.fuel_burn_per_km, 0.03) * v_fuel_price_per_liter * v_fuel_price_multiplier AS fuel_cost,
            -- Crew cost per flight
            ((rd.r_distance / GREATEST(rd.speed_kmh, 1)) + COALESCE(rd.turnaround_hours, 1.0)) * v_crew_cost_per_hour AS crew_cost,
            -- Maintenance cost per flight
            (rd.r_distance / GREATEST(rd.speed_kmh, 1)) * COALESCE(rd.maintenance_cost_per_hour, 500.0) * v_maintenance_multiplier AS maint_cost
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
        c.exp_passengers,
        -- Load factor
        CASE WHEN c.eff_capacity > 0
            THEN ROUND(c.exp_passengers::numeric / c.eff_capacity, 2)
            ELSE 0
        END,
        -- Revenue per flight (ticket + cargo)
        ROUND(c.exp_passengers * c.r_price * (1 + v_cargo_revenue_pct), 2),
        -- Cost per flight (fuel + crew + maintenance)
        ROUND(c.fuel_cost + c.crew_cost + c.maint_cost, 2),
        -- Profit per flight
        ROUND((c.exp_passengers * c.r_price * (1 + v_cargo_revenue_pct)) - (c.fuel_cost + c.crew_cost + c.maint_cost), 2),
        -- Weekly profit
        ROUND(c.r_flights * ((c.exp_passengers * c.r_price * (1 + v_cargo_revenue_pct)) - (c.fuel_cost + c.crew_cost + c.maint_cost)), 2)
    FROM computed c;
END;
$function$;

-- ============================================================================
-- PART 2: bot_profiles schema additions
-- ============================================================================

ALTER TABLE public.bot_profiles
ADD COLUMN IF NOT EXISTS consecutive_loss_days int NOT NULL DEFAULT 0,
ADD COLUMN IF NOT EXISTS secondary_hub_iata varchar(3),
ADD COLUMN IF NOT EXISTS last_route_optimization_at timestamptz,
ADD COLUMN IF NOT EXISTS last_route_audit_at timestamptz,
ADD COLUMN IF NOT EXISTS last_financial_action_at timestamptz,
ADD COLUMN IF NOT EXISTS recovery_loan_taken boolean NOT NULL DEFAULT false;

-- ============================================================================
-- PART 3: game_config entries
-- ============================================================================

INSERT INTO game_config (key, value, category, unit, description) VALUES
  ('bot_consecutive_loss_days_threshold', '7'::jsonb, 'simulation', 'game_days',
   'Days of consecutive route loss before bot deletes the route'),
  ('bot_route_optimization_cooldown_hours', '24'::jsonb, 'simulation', 'hours',
   'Hours between bot route optimization attempts'),
  ('bot_secondary_hub_chance', '0.20'::jsonb, 'simulation', 'ratio',
   'Chance of bot using secondary hub for new route'),
  ('bot_fleet_diversity_chance', '0.30'::jsonb, 'simulation', 'ratio',
   'Chance of bot using alternative aircraft model'),
  ('bot_purchase_cash_multiplier', '1.5'::jsonb, 'simulation', 'multiplier',
   'Bot cash must be > starting_cash * this to purchase aircraft'),
  ('bot_competitive_price_threshold', '0.20'::jsonb, 'simulation', 'ratio',
   'Price deviation ratio before bot responds to competitor pricing'),
  ('bot_recovery_loan_amount', '2000000'::jsonb, 'simulation', 'currency',
   'Loan amount for desperate bot recovery'),
  ('bot_loan_repayment_ratio', '0.20'::jsonb, 'simulation', 'ratio',
   'Max ratio of loan balance to repay per action')
ON CONFLICT (key) DO NOTHING;

-- ============================================================================
-- PART 4: execute_bot_decisions() full rewrite
-- ============================================================================

CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    r_bot RECORD;
    r_route RECORD;
    v_archetype VARCHAR(30);
    v_bot_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_origin_iata VARCHAR(3);
    v_effective_threshold NUMERIC(5,2);
    v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00;
    v_cash_ratio NUMERIC;
    v_distress_stage VARCHAR(20);
    v_route_change_allowed BOOLEAN;
    v_growth_allowed BOOLEAN;
    v_pricing_allowed BOOLEAN;
    v_repair_allowed BOOLEAN;
    v_route_audit_allowed BOOLEAN;
    v_route_optimization_allowed BOOLEAN;
    v_financial_action_allowed BOOLEAN;

    -- Archetype params
    v_target_fleet_cap INT;
    v_min_cash_reserve NUMERIC;
    v_growth_chance NUMERIC;
    v_target_distance DOUBLE PRECISION;
    v_target_price_multiplier NUMERIC;
    v_target_schedule_ratio NUMERIC;

    -- Config values
    v_ticket_base_fare NUMERIC;
    v_ticket_per_km_rate NUMERIC;
    v_starting_cash NUMERIC;
    v_bankruptcy_threshold NUMERIC;
    v_bot_repair_cash_reserve NUMERIC;
    v_loss_days_threshold INT;
    v_purchase_cash_multiplier NUMERIC;
    v_competitive_price_threshold NUMERIC;
    v_recovery_loan_amount NUMERIC;
    v_loan_repayment_ratio NUMERIC;
    v_secondary_hub_chance NUMERIC;
    v_fleet_diversity_chance NUMERIC;

    -- Fleet/route counts
    v_fleet_count INT;
    v_route_count INT;
    v_idle_aircraft_count INT;
    v_owned_count INT;
    v_leased_count INT;

    -- Aircraft selection
    v_model_id UUID;
    v_model_name VARCHAR;
    v_lease_price NUMERIC;
    v_purchase_price NUMERIC;
    v_capacity INT;
    v_speed_kmh NUMERIC;
    v_range_km NUMERIC;
    v_deposit_amount NUMERIC;
    v_tail VARCHAR(20);

    -- Route selection
    v_dest_iata VARCHAR(3);
    v_distance DOUBLE PRECISION;
    v_selected_route_id UUID;
    v_selected_flights INT;
    v_selected_base_fare NUMERIC;
    v_max_weekly_flights INT;
    v_target_flights INT;
    v_target_price NUMERIC;

    -- Growth
    v_idle_aircraft_id UUID;
    v_idle_condition NUMERIC;
    v_idle_range NUMERIC;
    v_growth_roll NUMERIC;
    v_lease_growth_bias NUMERIC;
    v_purchase_growth_bias NUMERIC;
    v_route_creation_bias NUMERIC;
    v_loan_request_bias NUMERIC;

    -- Pricing
    v_base_fare NUMERIC;
    v_new_price NUMERIC;
    v_price_adjustment NUMERIC;
    v_avg_competitor_price NUMERIC;
    v_competitor_count INT;

    -- Route trim
    v_route_trim_threshold INT;
    v_route_floor INT;
    v_route_reduction INT;

    -- Financial
    v_active_loans INT;
    v_requested_loan NUMERIC;
    v_worst_route_id UUID;
    v_worst_route_profit NUMERIC;

    -- Action results
    v_action_success BOOLEAN;
    v_action_message VARCHAR;
    v_action_cash NUMERIC;
    v_created_route_id UUID;
    v_created_fleet_id UUID;
    v_spawned_id UUID;

    -- Route performance
    v_route_profit NUMERIC;
    v_all_routes_profitable BOOLEAN;
    v_any_route_profitable BOOLEAN;

    -- Misc
    v_attempts INT;
    v_inserted BOOLEAN;
    v_economy INT;
    v_business INT;
    v_first INT;
    v_error_msg TEXT;
    v_bot_season_id UUID;
    v_base_wear NUMERIC;
    v_route_perf RECORD;

    -- Purchase model tracking
    v_purchase_capacity INT;
    v_purchase_model_name VARCHAR;
BEGIN
    -- Load global config
    v_ticket_base_fare := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
    v_ticket_per_km_rate := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);
    v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
    v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);
    v_bot_repair_cash_reserve := COALESCE(get_config_numeric('bot_repair_cash_reserve'), 500000.00);
    v_loss_days_threshold := COALESCE(get_config_numeric('bot_consecutive_loss_days_threshold'), 7)::INT;
    v_purchase_cash_multiplier := COALESCE(get_config_numeric('bot_purchase_cash_multiplier'), 1.5);
    v_competitive_price_threshold := COALESCE(get_config_numeric('bot_competitive_price_threshold'), 0.20);
    v_recovery_loan_amount := COALESCE(get_config_numeric('bot_recovery_loan_amount'), 2000000.0);
    v_loan_repayment_ratio := COALESCE(get_config_numeric('bot_loan_repayment_ratio'), 0.20);
    v_secondary_hub_chance := COALESCE(get_config_numeric('bot_secondary_hub_chance'), 0.20);
    v_fleet_diversity_chance := COALESCE(get_config_numeric('bot_fleet_diversity_chance'), 0.30);

    -- Look up active season for error logging
    SELECT id INTO v_bot_season_id FROM season_clock WHERE status = 'active' LIMIT 1;

    FOR r_bot IN
        SELECT u.*, COALESCE(bp.archetype, 'Balanced') AS archetype,
               bp.last_growth_action_at,
               bp.last_route_change_at,
               bp.last_pricing_review_at,
               bp.last_repair_action_at,
               bp.last_route_optimization_at,
               bp.last_route_audit_at,
               bp.last_financial_action_at,
               bp.consecutive_loss_days,
               bp.secondary_hub_iata,
               bp.recovery_loan_taken,
               COALESCE(bp.distress_stage, 'stable') AS profile_distress_stage
        FROM users u
        LEFT JOIN bot_profiles bp ON bp.user_id = u.id
        WHERE u.actor_type = 'AI'
          AND u.operational_status != 'Bankrupt'
    LOOP
    BEGIN

        -- === PER-BOT INIT ===
        v_archetype := r_bot.archetype;
        v_bot_cash := get_user_balance(r_bot.id);
        v_game_time := r_bot.game_current_time;
        v_origin_iata := r_bot.hq_airport_iata;
        v_effective_threshold := GREATEST(v_absolute_minimum_safety_limit, COALESCE(r_bot.auto_grounding_threshold, 40.00));
        v_cash_ratio := CASE WHEN v_starting_cash > 0 THEN v_bot_cash / v_starting_cash ELSE 0 END;

        -- Cooldown checks
        v_route_change_allowed := r_bot.last_route_change_at IS NULL
            OR r_bot.last_route_change_at <= v_game_time - INTERVAL '8 hours';
        v_growth_allowed := r_bot.last_growth_action_at IS NULL
            OR r_bot.last_growth_action_at <= v_game_time - INTERVAL '18 hours';
        v_pricing_allowed := r_bot.last_pricing_review_at IS NULL
            OR r_bot.last_pricing_review_at <= v_game_time - INTERVAL '6 hours';
        v_repair_allowed := r_bot.last_repair_action_at IS NULL
            OR r_bot.last_repair_action_at <= v_game_time - INTERVAL '12 hours';
        v_route_audit_allowed := r_bot.last_route_audit_at IS NULL
            OR r_bot.last_route_audit_at <= v_game_time - INTERVAL '4 hours';
        v_route_optimization_allowed := r_bot.last_route_optimization_at IS NULL
            OR r_bot.last_route_optimization_at <= v_game_time - INTERVAL '24 hours';
        v_financial_action_allowed := r_bot.last_financial_action_at IS NULL
            OR r_bot.last_financial_action_at <= v_game_time - INTERVAL '12 hours';

        -- === PHASE 1: BANKRUPTCY CHECK ===
        IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < v_bankruptcy_threshold THEN
            PERFORM apply_actor_bankruptcy_state(r_bot.id);
            UPDATE bot_profiles SET distress_stage = 'desperate' WHERE user_id = r_bot.id;
            CONTINUE;
        END IF;

        -- === PHASE 2: DISTRESS CALCULATION ===
        v_distress_stage := CASE
            WHEN COALESCE(r_bot.consecutive_negative_days, 0) >= 5 OR v_cash_ratio < 0.18 THEN 'desperate'
            WHEN COALESCE(r_bot.consecutive_negative_days, 0) >= 3 OR v_cash_ratio < 0.30 THEN 'defensive'
            WHEN COALESCE(r_bot.consecutive_negative_days, 0) >= 1 OR v_cash_ratio < 0.50 THEN 'cautious'
            ELSE 'stable'
        END;

        UPDATE bot_profiles SET distress_stage = v_distress_stage WHERE user_id = r_bot.id;

        -- === PHASE 3: ARCHETYPE PARAMETERS ===
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

        -- Recovery streak bonus
        IF COALESCE(r_bot.recovery_streak_days, 0) >= 3 THEN
            v_growth_chance := LEAST(0.35, v_growth_chance + 0.04);
        END IF;

        -- Distress modifiers
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

        -- === PHASE 4: FLEET/ROUTE/IDLE COUNTS ===
        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id AND status = 'active';
        SELECT COUNT(*)::INT INTO v_owned_count FROM fleet_aircraft WHERE user_id = r_bot.id AND acquisition_type = 'purchase';
        SELECT COUNT(*)::INT INTO v_leased_count FROM fleet_aircraft WHERE user_id = r_bot.id AND acquisition_type = 'lease';

        SELECT COUNT(*)::INT INTO v_idle_aircraft_count
        FROM fleet_aircraft f
        WHERE f.user_id = r_bot.id
          AND f.status = 'active'
          AND f.condition >= v_effective_threshold
          AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);

        -- === PHASE 5: REPAIR (enhanced for desperate recovery) ===
        IF v_repair_allowed AND v_distress_stage <> 'desperate' THEN
            -- Normal repair for non-desperate bots
            SELECT f.id, f.condition INTO v_idle_aircraft_id, v_idle_condition
            FROM fleet_aircraft f
            WHERE f.user_id = r_bot.id
              AND (f.status = 'grounded' OR f.condition < v_effective_threshold)
            ORDER BY f.condition ASC
            LIMIT 1;

            IF v_idle_aircraft_id IS NOT NULL THEN
                PERFORM perform_actor_aircraft_repair(r_bot.id, v_idle_aircraft_id, v_bot_repair_cash_reserve, v_game_time, 'Bot maintenance repair');
                GET DIAGNOSTICS v_action_success = ROW_COUNT;
                IF v_action_success THEN
                    UPDATE bot_profiles SET last_repair_action_at = v_game_time WHERE user_id = r_bot.id;
                END IF;
            END IF;
        ELSIF v_repair_allowed AND v_distress_stage = 'desperate' THEN
            -- Desperate recovery: allow repair of grounded aircraft with condition >= 60
            SELECT f.id, f.condition INTO v_idle_aircraft_id, v_idle_condition
            FROM fleet_aircraft f
            WHERE f.user_id = r_bot.id
              AND f.status = 'grounded'
              AND f.condition >= 60
            ORDER BY f.condition DESC
            LIMIT 1;

            IF v_idle_aircraft_id IS NOT NULL THEN
                PERFORM perform_actor_aircraft_repair(r_bot.id, v_idle_aircraft_id, v_bot_repair_cash_reserve, v_game_time, 'Desperate recovery repair');
                GET DIAGNOSTICS v_action_success = ROW_COUNT;
                IF v_action_success THEN
                    UPDATE bot_profiles SET last_repair_action_at = v_game_time WHERE user_id = r_bot.id;
                END IF;
            END IF;
        END IF;

        -- === PHASE 6: ROUTE AUDIT (smart deletion based on performance) ===
        IF v_route_audit_allowed AND v_route_count > 0 THEN
            -- Check route performance using shared function
            v_all_routes_profitable := true;
            v_any_route_profitable := false;

            FOR v_route_perf IN
                SELECT route_id, weekly_profit FROM get_route_performance(r_bot.id)
            LOOP
                IF v_route_perf.weekly_profit < 0 THEN
                    v_all_routes_profitable := false;
                ELSE
                    v_any_route_profitable := true;
                END IF;
            END LOOP;

            -- Update consecutive loss days
            IF v_all_routes_profitable AND v_route_count > 0 THEN
                UPDATE bot_profiles SET consecutive_loss_days = 0 WHERE user_id = r_bot.id;
            ELSIF NOT v_any_route_profitable AND v_route_count > 0 THEN
                UPDATE bot_profiles SET consecutive_loss_days = consecutive_loss_days + 1 WHERE user_id = r_bot.id;
            END IF;

            -- Delete chronically unprofitable routes
            SELECT consecutive_loss_days INTO v_action_cash FROM bot_profiles WHERE user_id = r_bot.id;
            IF COALESCE(v_action_cash, 0) >= v_loss_days_threshold AND v_route_change_allowed THEN
                -- Find and delete the worst route
                SELECT route_id, weekly_profit INTO v_worst_route_id, v_worst_route_profit
                FROM get_route_performance(r_bot.id)
                ORDER BY weekly_profit ASC
                LIMIT 1;

                IF v_worst_route_id IS NOT NULL THEN
                    PERFORM delete_actor_route_assignment(r_bot.id, v_worst_route_id, false);
                    UPDATE bot_profiles
                    SET last_route_change_at = v_game_time,
                        consecutive_loss_days = 0
                    WHERE user_id = r_bot.id;
                END IF;
            END IF;

            UPDATE bot_profiles SET last_route_audit_at = v_game_time WHERE user_id = r_bot.id;
        END IF;

        -- === PHASE 7: ROUTE TRIM / DELETE (distress-driven) ===
        IF v_distress_stage IN ('cautious', 'defensive', 'desperate') AND v_route_change_allowed AND v_route_count > 0 THEN
            IF v_distress_stage = 'desperate' OR
               v_distress_stage = 'defensive' OR
               (v_distress_stage = 'cautious' AND random() < 0.45) THEN

                -- Find the most overpriced route
                SELECT r.id, r.flights_per_week,
                       COALESCE(calculate_route_base_fare(r.distance_km), v_ticket_base_fare + r.distance_km * v_ticket_per_km_rate)
                INTO v_selected_route_id, v_selected_flights, v_selected_base_fare
                FROM route_assignments r
                WHERE r.user_id = r_bot.id AND r.status = 'active'
                ORDER BY (r.ticket_price / GREATEST(COALESCE(calculate_route_base_fare(r.distance_km), 1), 1)) DESC,
                         r.flights_per_week DESC
                LIMIT 1;

                IF v_selected_route_id IS NOT NULL THEN
                    -- Set trim parameters based on distress
                    IF v_distress_stage = 'desperate' THEN
                        v_route_trim_threshold := 6; v_route_floor := 4; v_route_reduction := 6;
                        v_price_adjustment := 0.88;
                    ELSIF v_distress_stage = 'defensive' THEN
                        v_route_trim_threshold := 8; v_route_floor := 6; v_route_reduction := 4;
                        v_price_adjustment := 0.92;
                    ELSE
                        v_route_trim_threshold := 10; v_route_floor := 6; v_route_reduction := 2;
                        v_price_adjustment := 0.96;
                    END IF;

                    IF v_selected_flights > v_route_trim_threshold THEN
                        v_target_price := LEAST(
                            v_selected_base_fare * v_target_price_multiplier,
                            (SELECT ticket_price FROM route_assignments WHERE id = v_selected_route_id) * v_price_adjustment
                        );
                        v_target_flights := GREATEST(v_route_floor, v_selected_flights - v_route_reduction);

                        PERFORM update_actor_route_economics(r_bot.id, v_selected_route_id, v_target_price, v_target_flights);
                        UPDATE bot_profiles SET last_route_change_at = v_game_time WHERE user_id = r_bot.id;
                    ELSIF v_selected_flights <= v_route_trim_threshold AND v_distress_stage = 'desperate' THEN
                        PERFORM delete_actor_route_assignment(r_bot.id, v_selected_route_id, false);
                        UPDATE bot_profiles SET last_route_change_at = v_game_time WHERE user_id = r_bot.id;
                    END IF;
                END IF;
            END IF;
        END IF;

        -- Refresh counts after potential deletions
        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id AND status = 'active';
        SELECT COUNT(*)::INT INTO v_idle_aircraft_count
        FROM fleet_aircraft f
        WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold
          AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);

        -- === PHASE 8: ROUTE OPTIMIZATION (reassign underperforming aircraft) ===
        IF v_route_optimization_allowed AND v_idle_aircraft_count = 0 AND v_route_count >= 2 AND v_distress_stage NOT IN ('desperate') THEN
            -- Find worst performing route
            SELECT route_id, weekly_profit INTO v_worst_route_id, v_worst_route_profit
            FROM get_route_performance(r_bot.id)
            ORDER BY weekly_profit ASC
            LIMIT 1;

            -- If worst route is losing money, unassign its aircraft (make it idle)
            IF v_worst_route_id IS NOT NULL AND v_worst_route_profit < 0 THEN
                PERFORM delete_actor_route_assignment(r_bot.id, v_worst_route_id, false);
                UPDATE bot_profiles SET last_route_optimization_at = v_game_time WHERE user_id = r_bot.id;
            END IF;
        END IF;

        -- Refresh idle count after optimization
        SELECT COUNT(*)::INT INTO v_idle_aircraft_count
        FROM fleet_aircraft f
        WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold
          AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);

        -- === PHASE 9: FLEET GROWTH — LEASE ===
        IF v_growth_allowed AND v_fleet_count < v_target_fleet_cap AND v_bot_cash > v_min_cash_reserve
           AND COALESCE(r_bot.consecutive_negative_days, 0) = 0 AND v_idle_aircraft_count = 0
           AND v_route_count >= v_fleet_count AND random() < v_growth_chance THEN

            -- Model selection with fleet diversity (4.5)
            IF random() < v_fleet_diversity_chance THEN
                -- Alternative model: cheapest in range band
                SELECT m.id, m.model_name, m.lease_price_per_month, m.purchase_price, m.capacity, m.speed_kmh, m.range_km
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                FROM aircraft_models m
                WHERE m.range_km >= v_target_distance * 0.7 AND m.range_km <= v_target_distance * 1.5
                ORDER BY m.lease_price_per_month ASC
                LIMIT 1;
            ELSE
                -- Primary model per archetype
                CASE v_archetype
                    WHEN 'Regional' THEN
                        SELECT m.id, m.model_name, m.lease_price_per_month, m.purchase_price, m.capacity, m.speed_kmh, m.range_km
                        INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                        FROM aircraft_models m WHERE m.model_name ILIKE '%ATR%' OR m.model_name ILIKE '%72-600%'
                        ORDER BY m.lease_price_per_month ASC LIMIT 1;
                    WHEN 'Aggressive' THEN
                        SELECT m.id, m.model_name, m.lease_price_per_month, m.purchase_price, m.capacity, m.speed_kmh, v_range_km
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

            -- Fallback if primary model not found
            IF v_model_id IS NULL THEN
                SELECT m.id, m.model_name, m.lease_price_per_month, m.purchase_price, m.capacity, m.speed_kmh, m.range_km
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                FROM aircraft_models m
                WHERE m.range_km >= v_target_distance
                ORDER BY m.lease_price_per_month ASC
                LIMIT 1;
            END IF;

            IF v_model_id IS NOT NULL THEN
                -- Lease vs purchase decision
                v_lease_growth_bias := CASE WHEN v_archetype = 'Aggressive' THEN 0.70 ELSE 0.50 END;

                IF v_distress_stage IN ('stable', 'cautious') AND random() < v_lease_growth_bias THEN
                    v_deposit_amount := calculate_required_lease_deposit(v_purchase_price, v_lease_price);

                    SELECT m.economy_seats, m.business_seats, m.first_class_seats
                    INTO v_economy, v_business, v_first
                    FROM aircraft_models m WHERE m.id = v_model_id;

                    PERFORM create_actor_fleet_aircraft(
                        r_bot.id, v_model_id, NULL, 'lease',
                        COALESCE(v_economy, 0), COALESCE(v_business, 0), COALESCE(v_first, 0)
                    );

                    UPDATE bot_profiles SET last_growth_action_at = v_game_time WHERE user_id = r_bot.id;
                END IF;
            END IF;
        END IF;

        -- === PHASE 10: FLEET GROWTH — PURCHASE (lowered threshold 4.6) ===
        IF v_distress_stage = 'stable' AND v_growth_allowed
           AND v_bot_cash > (v_starting_cash * v_purchase_cash_multiplier)
           AND v_fleet_count < v_target_fleet_cap THEN

            v_purchase_growth_bias := CASE
                WHEN COALESCE(r_bot.recovery_streak_days, 0) >= 5 THEN 0.35
                WHEN v_owned_count = 0 THEN 0.28  -- encourage first purchase
                WHEN v_leased_count > v_owned_count THEN 0.23  -- encourage ownership
                ELSE 0.18
            END;

            IF random() < v_purchase_growth_bias THEN
                -- Use same model selection as lease (with diversity)
                IF v_model_id IS NULL THEN
                    SELECT m.id, m.model_name, m.purchase_price, m.capacity, m.speed_kmh, m.range_km
                    INTO v_model_id, v_model_name, v_purchase_price, v_capacity, v_speed_kmh, v_range_km
                    FROM aircraft_models m
                    WHERE m.range_km >= v_target_distance
                    ORDER BY m.purchase_price ASC
                    LIMIT 1;
                END IF;

                IF v_model_id IS NOT NULL AND v_bot_cash > v_purchase_price THEN
                    SELECT m.economy_seats, m.business_seats, m.first_class_seats
                    INTO v_economy, v_business, v_first
                    FROM aircraft_models m WHERE m.id = v_model_id;

                    PERFORM create_actor_fleet_aircraft(
                        r_bot.id, v_model_id, NULL, 'purchase',
                        COALESCE(v_economy, 0), COALESCE(v_business, 0), COALESCE(v_first, 0)
                    );

                    UPDATE bot_profiles SET last_growth_action_at = v_game_time WHERE user_id = r_bot.id;
                END IF;
            END IF;
        END IF;

        -- === PHASE 11: ROUTE CREATION (with secondary hub 4.4) ===
        -- Refresh idle count
        SELECT COUNT(*)::INT INTO v_idle_aircraft_count
        FROM fleet_aircraft f
        WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold
          AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);

        v_route_creation_bias := CASE WHEN v_distress_stage = 'cautious' THEN 0.45 ELSE 0.70 END;

        IF v_idle_aircraft_count > 0 AND v_route_count < v_target_fleet_cap
           AND v_route_change_allowed AND v_distress_stage <> 'desperate'
           AND random() < v_route_creation_bias THEN

            -- Select idle aircraft
            SELECT f.id, f.condition, m.range_km, m.speed_kmh, m.capacity,
                   m.economy_seats, m.business_seats, m.first_class_seats
            INTO v_idle_aircraft_id, v_idle_condition, v_idle_range, v_speed_kmh, v_capacity,
                 v_economy, v_business, v_first
            FROM fleet_aircraft f
            JOIN aircraft_models m ON m.id = f.aircraft_model_id
            WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold
              AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id)
            LIMIT 1;

            IF v_idle_aircraft_id IS NOT NULL THEN
                -- Secondary hub logic (4.4)
                IF v_route_count >= 3 AND random() < v_secondary_hub_chance THEN
                    -- Pick a destination from existing routes as new origin
                    SELECT r.destination_iata INTO v_origin_iata
                    FROM route_assignments r
                    WHERE r.user_id = r_bot.id AND r.status = 'active'
                    ORDER BY random()
                    LIMIT 1;
                ELSE
                    v_origin_iata := r_bot.hq_airport_iata;
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
                    ORDER BY a.demand_index DESC, random()
                    LIMIT 1;

                    IF v_dest_iata IS NOT NULL THEN
                        v_base_fare := v_ticket_base_fare + (v_distance * v_ticket_per_km_rate);
                        v_target_price := v_base_fare * v_target_price_multiplier;
                        v_max_weekly_flights := calculate_route_max_weekly_flights(v_distance, v_speed_kmh);
                        v_target_flights := GREATEST(1, FLOOR(v_max_weekly_flights * v_target_schedule_ratio));
                        IF v_distress_stage = 'cautious' THEN
                            v_target_flights := GREATEST(1, FLOOR(v_target_flights * 0.85));
                        END IF;

                        PERFORM create_actor_route_assignment(
                            r_bot.id, v_origin_iata, v_dest_iata, v_distance,
                            v_target_price, v_target_flights, v_idle_aircraft_id
                        );

                        -- Check if route was created
                        IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = r_bot.id AND origin_iata = v_origin_iata AND destination_iata = v_dest_iata AND status = 'active') THEN
                            v_inserted := true;
                            UPDATE bot_profiles SET last_route_change_at = v_game_time WHERE user_id = r_bot.id;
                        END IF;
                    END IF;
                END LOOP;
            END IF;
        END IF;

        -- === PHASE 12: PRICING REVIEW (with competitive response 4.7) ===
        IF v_pricing_allowed THEN
            FOR r_route IN
                SELECT r.id, r.ticket_price, r.flights_per_week, r.distance_km,
                       r.origin_iata, r.destination_iata
                FROM route_assignments r
                WHERE r.user_id = r_bot.id AND r.status = 'active'
            LOOP
                -- Count competitors and get average price
                SELECT COUNT(*), COALESCE(AVG(r2.ticket_price), 0)
                INTO v_competitor_count, v_avg_competitor_price
                FROM route_assignments r2
                WHERE r2.origin_iata = r_route.origin_iata
                  AND r2.destination_iata = r_route.destination_iata
                  AND r2.user_id <> r_bot.id
                  AND r2.status = 'active';

                IF v_competitor_count > 0 OR random() < 0.20 THEN
                    v_base_fare := v_ticket_base_fare + (r_route.distance_km * v_ticket_per_km_rate);

                    -- Base price adjustment from distress/archetype
                    v_price_adjustment := CASE
                        WHEN v_distress_stage = 'desperate' THEN 0.90
                        WHEN v_distress_stage = 'defensive' THEN 0.95
                        WHEN v_distress_stage = 'cautious' THEN 0.98
                        WHEN v_archetype = 'Aggressive' THEN 1.01
                        WHEN v_archetype = 'Balanced' THEN 1.03
                        ELSE 0.97
                    END;

                    -- Competitive response (4.7): adjust based on competitor pricing
                    IF v_competitor_count > 0 AND v_avg_competitor_price > 0
                       AND v_distress_stage IN ('stable', 'cautious') THEN
                        IF r_route.ticket_price > v_avg_competitor_price * (1 + v_competitive_price_threshold) THEN
                            -- Too expensive vs competitors
                            v_price_adjustment := v_price_adjustment * 0.95;
                        ELSIF r_route.ticket_price < v_avg_competitor_price * (1 - v_competitive_price_threshold) THEN
                            -- Too cheap vs competitors
                            v_price_adjustment := v_price_adjustment * 1.03;
                        END IF;
                    END IF;

                    v_target_price := v_base_fare * v_target_price_multiplier * v_price_adjustment;
                    v_new_price := (r_route.ticket_price * 0.55) + (v_target_price * 0.45);

                    -- Only update if change >= 3%
                    IF ABS(v_new_price - r_route.ticket_price) / GREATEST(r_route.ticket_price, 1) >= 0.03 THEN
                        PERFORM update_actor_route_economics(r_bot.id, r_route.id, v_new_price, r_route.flights_per_week);
                    END IF;
                END IF;
            END LOOP;

            UPDATE bot_profiles SET last_pricing_review_at = v_game_time WHERE user_id = r_bot.id;
        END IF;

        -- === PHASE 13: LOAN REPAYMENT (4.9) ===
        IF v_financial_action_allowed AND v_distress_stage NOT IN ('desperate') THEN
            SELECT COUNT(*)::INT INTO v_active_loans FROM loans WHERE user_id = r_bot.id AND status = 'active';

            IF v_active_loans > 0 AND v_bot_cash > (v_min_cash_reserve * 1.5) THEN
                -- Find highest interest rate loan
                SELECT id, remaining_balance INTO v_selected_route_id, v_selected_base_fare
                FROM loans
                WHERE user_id = r_bot.id AND status = 'active'
                ORDER BY interest_rate DESC
                LIMIT 1;

                IF v_selected_route_id IS NOT NULL AND v_selected_base_fare > 0 THEN
                    v_requested_loan := LEAST(
                        v_selected_base_fare * v_loan_repayment_ratio,
                        v_bot_cash - v_min_cash_reserve
                    );

                    IF v_requested_loan > 0 THEN
                        PERFORM repay_loan(v_selected_route_id, v_requested_loan);
                        UPDATE bot_profiles SET last_financial_action_at = v_game_time WHERE user_id = r_bot.id;
                    END IF;
                END IF;
            END IF;
        END IF;

        -- === PHASE 14: LOAN REQUEST (enhanced with recovery loan 4.8) ===
        SELECT COUNT(*)::INT INTO v_active_loans FROM loans WHERE user_id = r_bot.id AND status = 'active';

        IF v_active_loans = 0 THEN
            -- Normal loan request
            IF v_bot_cash < v_starting_cash * 0.5 AND v_bot_cash > 1000000
               AND v_distress_stage IN ('cautious', 'defensive') THEN

                v_loan_request_bias := CASE WHEN v_distress_stage = 'defensive' THEN 0.65 ELSE 0.35 END;

                IF random() < v_loan_request_bias THEN
                    v_requested_loan := LEAST(5000000, v_starting_cash - v_bot_cash);
                    PERFORM take_loan(r_bot.id, v_requested_loan, 52, 'unsecured', NULL);
                END IF;
            END IF;

            -- Desperate recovery loan (4.8)
            IF v_distress_stage = 'desperate' AND NOT COALESCE(r_bot.recovery_loan_taken, false)
               AND v_bot_cash > 500000 AND v_bot_cash < v_starting_cash * 0.3 THEN
                PERFORM take_loan(r_bot.id, v_recovery_loan_amount, 26, 'unsecured', NULL);
                UPDATE bot_profiles SET recovery_loan_taken = true WHERE user_id = r_bot.id;
            END IF;
        END IF;

        -- Reset recovery_loan_taken if bot recovers
        IF v_distress_stage = 'stable' AND COALESCE(r_bot.recovery_loan_taken, false) THEN
            UPDATE bot_profiles SET recovery_loan_taken = false WHERE user_id = r_bot.id;
        END IF;

        -- === PHASE 15: LAST ACTIVE TIMESTAMP ===
        UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;

    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_error_msg = MESSAGE_TEXT;
        INSERT INTO world_tick_log (season_id, status, message, started_at, finished_at)
        VALUES (v_bot_season_id, 'bot_error',
                'Bot ' || r_bot.id || ' error: ' || v_error_msg,
                now(), now());
    END;
    END LOOP;

    -- Post-loop: spawn replacement if needed
    IF (SELECT COUNT(*) FROM users WHERE actor_type = 'AI'
        AND COALESCE(operational_status, 'Active') != 'Bankrupt') <
       COALESCE(get_config_int('max_bot_count'), 5)
    THEN
        v_spawned_id := spawn_bot();
    END IF;
END;
$function$;

COMMIT;
