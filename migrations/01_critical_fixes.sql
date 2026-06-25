-- ============================================================================
-- Migration 01: Critical Bug Fixes
-- ============================================================================
-- This migration fixes 10 confirmed critical bugs in the baseline schema.
-- Each fix is self-contained and commented.
-- ============================================================================

-- FIX 1: fleet_reconcile_net_worth trigger — FOR EACH STATEMENT → FOR EACH ROW
-- BUG: The trigger was FOR EACH STATEMENT but uses NEW/OLD (always NULL in
--      statement-level triggers), causing net_worth to never reconcile.
-- FIX: Drop and recreate as FOR EACH ROW.
-- ============================================================================
DROP TRIGGER IF EXISTS fleet_reconcile_net_worth ON public.fleet_aircraft;
CREATE TRIGGER fleet_reconcile_net_worth
    AFTER INSERT OR DELETE OR UPDATE ON public.fleet_aircraft
    FOR EACH ROW
    EXECUTE FUNCTION trg_fleet_reconcile_net_worth();

-- FIX 2: bank_transactions CHECK constraint — add 'late_fee'
-- BUG: The CHECK constraint on transaction_type excludes 'late_fee', but
--      process_loan_payments and process_aircraft_financing_payments both
--      INSERT rows with transaction_type = 'late_fee', causing constraint
--      violations at runtime.
-- FIX: Add 'late_fee' to the allowed values.
-- ============================================================================
ALTER TABLE public.bank_transactions
    DROP CONSTRAINT IF EXISTS bank_transactions_transaction_type_check;
ALTER TABLE public.bank_transactions
    ADD CONSTRAINT bank_transactions_transaction_type_check
    CHECK (transaction_type IN ('debit','credit','payment','deposit','disbursement','refinance','late_fee'));

-- FIX 3: resolve_credit_tier — fix config path mismatch
-- BUG: The function reads v_config->'tiers' but seed data stores tiers at
--      the root level of the JSONB (e.g. {"Platinum":{"min":800,...}, ...}).
--      It also looks for 'min_score' key but seed data uses 'min'.
-- FIX: Iterate tiers from v_config directly, use 'min' key, and fall back
--      to hardcoded defaults when config is missing.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.resolve_credit_tier(p_score integer)
RETURNS character varying
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
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
$function$;

-- FIX 4: get_credit_report — don't overwrite correct tier
-- BUG: get_credit_report calls resolve_credit_tier (was broken, now fixed)
--      and always upserts the result into credit_scores, potentially
--      overwriting the correct tier set by update_credit_score (which uses
--      hardcoded thresholds). It also reads tier config via v_config->'tiers'
--      which doesn't exist in the seed data.
-- FIX: Read existing tier from credit_scores (set by update_credit_score
--      via process_credit_at_day_boundary). Only calculate fresh if no
--      credit_scores entry exists. Fix tier config lookup path.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_credit_report()
RETURNS TABLE(
    current_score        integer,
    fleet_health         integer,
    revenue_stability    integer,
    debt_ratio           integer,
    cash_reserve         integer,
    profit_history       integer,
    credit_tier          character varying,
    max_unsecured_loan   numeric,
    max_secured_loan     numeric,
    max_financing_amount numeric,
    base_interest_rate   numeric,
    suggestions          text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id  UUID;
    v_score    RECORD;
    v_tier     VARCHAR(20);
    v_config   JSONB;
    v_tier_cfg JSONB;
    v_sugg     TEXT[] := '{}';
    v_existing RECORD;
BEGIN
    v_user_id := require_current_user_id();
    SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';

    -- Check for existing credit_scores entry (written by update_credit_score)
    SELECT cs.tier INTO v_existing
    FROM credit_scores cs
    WHERE cs.user_id = v_user_id;

    -- Always compute fresh component scores
    SELECT * INTO v_score FROM calculate_credit_score(v_user_id) LIMIT 1;
    IF NOT FOUND THEN
        current_score := 500; fleet_health := 100; revenue_stability := 100;
        debt_ratio := 100; cash_reserve := 100; profit_history := 100;
        credit_tier := 'Standard'; max_unsecured_loan := 5000000;
        max_secured_loan := 25000000; max_financing_amount := 20000000;
        base_interest_rate := 0.07;
        suggestions := ARRAY['Build your fleet and routes to establish credit history.'];
        RETURN NEXT; RETURN;
    END IF;

    -- Use existing tier from credit_scores if available (set correctly by
    -- update_credit_score). Only fall back to resolve_credit_tier when no
    -- credit_scores entry exists yet.
    IF v_existing IS NOT NULL THEN
        v_tier := v_existing.tier;
    ELSE
        v_tier := resolve_credit_tier(v_score.total_score);
    END IF;

    -- Upsert the computed scores (preserving the authoritative tier)
    INSERT INTO credit_scores (
        user_id, score, tier, fleet_health_score, revenue_stability_score,
        debt_ratio_score, cash_reserves_score, profit_history_score, computed_at
    ) VALUES (
        v_user_id, v_score.total_score, v_tier,
        v_score.fleet_health, v_score.revenue_stability, v_score.debt_ratio,
        v_score.cash_reserve, v_score.profit_history, NOW()
    )
    ON CONFLICT (user_id) DO UPDATE SET
        score                = EXCLUDED.score,
        -- Only update tier if we are NOT preserving an existing one
        tier                 = CASE
                                 WHEN credit_scores.tier IS NOT NULL THEN credit_scores.tier
                                 ELSE EXCLUDED.tier
                               END,
        fleet_health_score   = EXCLUDED.fleet_health_score,
        revenue_stability_score = EXCLUDED.revenue_stability_score,
        debt_ratio_score     = EXCLUDED.debt_ratio_score,
        cash_reserves_score  = EXCLUDED.cash_reserves_score,
        profit_history_score = EXCLUDED.profit_history_score,
        computed_at          = EXCLUDED.computed_at;

    -- Read back the (possibly preserved) tier
    SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = v_user_id;

    -- Lookup tier config: tiers are at root level in seed data
    v_tier_cfg := COALESCE(v_config->v_tier, '{}'::JSONB);

    current_score        := v_score.total_score;
    fleet_health         := v_score.fleet_health;
    revenue_stability    := v_score.revenue_stability;
    debt_ratio           := v_score.debt_ratio;
    cash_reserve         := v_score.cash_reserve;
    profit_history       := v_score.profit_history;
    credit_tier          := v_tier;
    max_unsecured_loan   := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
    max_secured_loan     := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
    max_financing_amount := COALESCE((v_tier_cfg->>'max_financing')::NUMERIC, 20000000);
    base_interest_rate   := COALESCE((v_tier_cfg->>'rate')::NUMERIC,
                            COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07));

    v_sugg := '{}';
    IF v_score.fleet_health < 100 THEN
        v_sugg := array_append(v_sugg, 'Repair grounded aircraft to improve fleet health.');
    END IF;
    IF v_score.debt_ratio < 100 THEN
        v_sugg := array_append(v_sugg, 'Reduce outstanding debt to improve your debt ratio.');
    END IF;
    IF v_score.cash_reserve < 100 THEN
        v_sugg := array_append(v_sugg, 'Build cash reserves for financial stability.');
    END IF;
    IF v_score.revenue_stability < 100 THEN
        v_sugg := array_append(v_sugg, 'Establish consistent revenue from routes.');
    END IF;
    IF array_length(v_sugg, 1) IS NULL THEN
        v_sugg := ARRAY['Your credit profile is healthy. Keep it up!'];
    END IF;
    suggestions := v_sugg;
    RETURN NEXT;
END;
$function$;

-- FIX 5: calculate_credit_score — filter profit by IFRS category
-- BUG: The profit calculation sums ALL 'credit' and 'debit' transactions,
--      including financing activities (loans, disbursements, late fees).
--      A $10M loan disbursement inflates revenue and hides operating losses.
-- FIX: Filter transactions to only ifrs_category IN ('revenue','cogs','opex')
--      so that profit reflects actual operating performance.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.calculate_credit_score(p_user_id uuid)
RETURNS TABLE(
    total_score       integer,
    tier              character varying,
    fleet_health      integer,
    revenue_stability integer,
    debt_ratio        integer,
    cash_reserve      integer,
    profit_history    integer
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user              RECORD;
    v_actor_type        VARCHAR(10);
    v_fleet_count       INT     := 0;
    v_avg_condition     NUMERIC := 100.0;
    v_grounded_ratio    NUMERIC := 0.0;
    v_fleet_health      NUMERIC := 200.0;
    v_revenue_days      INT     := 0;
    v_positive_days     INT     := 0;
    v_revenue_stability NUMERIC := 200.0;
    v_total_debt        NUMERIC := 0.0;
    v_net_worth         NUMERIC := 0.0;
    v_debt_ratio        NUMERIC := 200.0;
    v_cash              NUMERIC := 0.0;
    v_starting_cash     NUMERIC := 15000000.0;
    v_cash_reserve      NUMERIC := 200.0;
    v_total_revenue_30d NUMERIC := 0.0;
    v_total_expense_30d NUMERIC := 0.0;
    v_profit_margin     NUMERIC := 0.0;
    v_profit_history    NUMERIC := 200.0;
    v_total_score       INT;
BEGIN
    SELECT u.net_worth, u.game_current_time, u.actor_type
      INTO v_user FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        total_score := 500; tier := 'Standard';
        fleet_health := 100; revenue_stability := 100;
        debt_ratio := 100; cash_reserve := 100;
        profit_history := 100;
        RETURN NEXT; RETURN;
    END IF;

    v_actor_type := COALESCE(v_user.actor_type, 'REAL');
    v_cash       := get_user_balance(p_user_id);
    v_net_worth  := COALESCE(v_user.net_worth, 0.0);
    v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.0);

    -- Fleet health
    SELECT COUNT(*)::INT, COALESCE(AVG(condition), 100.0),
           COALESCE(COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC
                    / NULLIF(COUNT(*), 0), 0.0)
      INTO v_fleet_count, v_avg_condition, v_grounded_ratio
      FROM fleet_aircraft WHERE user_id = p_user_id;

    IF v_fleet_count > 0 THEN
        v_fleet_health := (v_avg_condition / 100.0) * 150.0
                        + 50.0 * (1.0 - v_grounded_ratio);
    ELSE
        v_fleet_health := 100.0;
    END IF;

    -- Revenue stability (counts days with revenue-category credits)
    SELECT COUNT(*)::INT, COUNT(*) FILTER (WHERE amount > 0)::INT
      INTO v_revenue_days, v_positive_days
      FROM bank_transactions
     WHERE user_id = p_user_id
       AND ifrs_category = 'revenue'
       AND game_date >= v_user.game_current_time - INTERVAL '30 days';

    IF v_revenue_days > 0 THEN
        v_revenue_stability := (v_positive_days::NUMERIC / v_revenue_days::NUMERIC) * 200.0;
    ELSE
        v_revenue_stability := 100.0;
    END IF;

    -- Debt ratio
    SELECT COALESCE(SUM(remaining_balance), 0)
      INTO v_total_debt FROM loans
     WHERE user_id = p_user_id AND status = 'active';

    IF v_net_worth > 0 THEN
        v_debt_ratio := GREATEST(0, 200.0 - ((v_total_debt / v_net_worth) * 200.0));
    ELSE
        v_debt_ratio := 0.0;
    END IF;

    -- Cash reserve
    IF v_starting_cash > 0 THEN
        v_cash_reserve := LEAST(200.0, (v_cash / v_starting_cash) * 200.0);
    ELSE
        v_cash_reserve := 100.0;
    END IF;

    -- FIX 5: Filter profit calculation to operating categories only.
    -- Excludes financing (loans, disbursements, late fees) and investing
    -- (aircraft purchases/sales) from revenue and expense totals.
    SELECT COALESCE(SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN transaction_type = 'debit'  THEN amount ELSE 0 END), 0)
      INTO v_total_revenue_30d, v_total_expense_30d
      FROM bank_transactions
     WHERE user_id = p_user_id
       AND game_date >= v_user.game_current_time - INTERVAL '30 days'
       AND ifrs_category IN ('revenue', 'cogs', 'opex');

    IF v_total_revenue_30d > 0 THEN
        v_profit_margin  := (v_total_revenue_30d - v_total_expense_30d)
                          / v_total_revenue_30d;
        v_profit_history := LEAST(200.0, 100.0 + (v_profit_margin * 100.0));
    ELSE
        v_profit_history := 100.0;
    END IF;

    v_total_score := GREATEST(0, LEAST(1000,
        ROUND(v_fleet_health) + ROUND(v_revenue_stability)
      + ROUND(v_debt_ratio) + ROUND(v_cash_reserve)
      + ROUND(v_profit_history)));

    total_score       := v_total_score;
    tier              := resolve_credit_tier(v_total_score);
    fleet_health      := ROUND(v_fleet_health)::INT;
    revenue_stability := ROUND(v_revenue_stability)::INT;
    debt_ratio        := ROUND(v_debt_ratio)::INT;
    cash_reserve      := ROUND(v_cash_reserve)::INT;
    profit_history    := ROUND(v_profit_history)::INT;
    RETURN NEXT;
END;
$function$;

-- FIX 6a: Auto-repair rate formula — process_player_simulation_to_time
-- BUG: The formula `v_gross_damage * (1.0 - v_auto_repair_rate)` computes
--      the DAMAGE portion, not the RECOVERY portion. With auto_repair_rate
--      = 0.85 (85% recovery), the formula only recovers 15% of gross damage.
-- FIX: Change to `v_gross_damage * v_auto_repair_rate` so that 85% of
--      damage is self-healed (the intended behavior per config semantics).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_player_simulation_to_time(
    p_user_id        uuid,
    p_target_game_time timestamp with time zone
)
RETURNS TABLE(
    game_time    timestamp with time zone,
    cash         numeric,
    flights_run  integer,
    elapsed_days numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    r_user                RECORD;
    v_route               RECORD;
    v_flight_hours        NUMERIC;
    v_revenue             NUMERIC;
    v_ops_cost            NUMERIC;
    v_lease_cost          NUMERIC;
    v_net                 NUMERIC := 0;
    v_flights_run         INT := 0;
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
    v_payment_periods         INT;
    v_i                       INT;
    v_fuel_cost               NUMERIC;
    v_crew_cost_total         NUMERIC;
    v_maint_cost              NUMERIC;
    v_owned_wear              NUMERIC;
    v_leased_wear             NUMERIC;
    v_auto_repair_rate        NUMERIC;
    v_bankruptcy_threshold    NUMERIC;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    v_fuel_price        := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_crew_cost         := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear        := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear       := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate  := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
    v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);

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

    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;
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
         WHERE ur.user_id = p_user_id AND ur.status = 'active'
           AND fa.status = 'active'
           AND fa.condition >= COALESCE(r_user.auto_grounding_threshold, 40.00)
    LOOP
        v_route_demand_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_demand_event
          FROM game_events
         WHERE event_type = 'demand_surge' AND is_active = true
           AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
           AND start_game_time <= p_target_game_time
           AND end_game_time > p_target_game_time
         ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_demand_event := 1.0; END IF;

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
        v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
        IF v_flight_hours <= 0 THEN CONTINUE; END IF;

        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price)
                             * v_route_demand_event;
        v_seasonal_factor := 1.0;
        v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);
        v_revenue := v_route.flights_per_week * v_route.ticket_price
                   * LEAST(v_effective_capacity,
                           FLOOR(v_effective_capacity * 0.95 * v_demand_multiplier * v_seasonal_factor));
        v_fuel_cost := v_route.flights_per_week * v_route.distance_km
                     * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
        v_crew_cost_total := v_route.flights_per_week * v_flight_hours * v_crew_cost;
        v_maint_cost := v_route.flights_per_week * v_route.distance_km
                      * COALESCE(v_route.maintenance_cost_per_hour, 0)
                      * COALESCE(v_maintenance_multiplier, 1.0)
                      / NULLIF(v_route.speed_kmh, 0);
        v_ops_cost := v_fuel_cost + v_crew_cost_total + v_maint_cost;
        v_lease_cost := CASE
            WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                          WHERE fa2.id = v_route.assigned_aircraft_id
                            AND fa2.acquisition_type = 'lease')
            THEN COALESCE(v_route.lease_price_per_month, 0) * (v_elapsed_days / 30.0)
            ELSE 0
        END;

        v_revenue  := v_revenue * v_time_fraction;
        v_ops_cost := v_ops_cost * v_time_fraction;
        v_cargo_rev := v_revenue * 0.05;

        PERFORM credit_bank_account(p_user_id, v_revenue + v_cargo_rev,
            'revenue', 'ticket_revenue',
            'Route ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        PERFORM debit_bank_account(p_user_id, v_fuel_cost * v_time_fraction,
            'cogs', 'fuel',
            'Fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        PERFORM debit_bank_account(p_user_id, v_crew_cost_total * v_time_fraction,
            'cogs', 'crew',
            'Crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        PERFORM debit_bank_account(p_user_id, v_maint_cost * v_time_fraction,
            'cogs', 'maintenance',
            'Maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        IF v_lease_cost > 0 THEN
            PERFORM debit_bank_account(p_user_id, v_lease_cost,
                'opex', 'aircraft_lease',
                'Lease: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
        END IF;

        -- Wear formula
        v_wear_per_cycle := CASE
            WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
            ELSE v_owned_wear
        END + (v_route.distance_km * 0.0001);
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week
                        * v_elapsed_days / 7.0;

        -- FIX 6a: Use auto_repair_rate directly as the recovery fraction.
        -- v_auto_repair_rate = 0.85 means 85% of gross damage is self-healed.
        v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
        v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

        UPDATE fleet_aircraft
           SET condition = GREATEST(0, condition - v_net_damage)
         WHERE id = v_route.assigned_aircraft_id;

        v_flights_run := v_flights_run
                       + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
    END LOOP;

    v_cash_after := get_user_balance(p_user_id);

    UPDATE users u
       SET game_current_time = p_target_game_time,
           last_active_at = NOW()
     WHERE u.id = p_user_id;

    -- Bankruptcy check
    IF v_cash_after < v_bankruptcy_threshold THEN
        UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
        UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
    END IF;

    IF v_elapsed_days >= 1.0 THEN
        v_payment_periods := GREATEST(1, FLOOR(v_elapsed_days / 7.0)::INT);
        FOR v_i IN 1..v_payment_periods LOOP
            PERFORM process_loan_payments(p_user_id, p_target_game_time);
            PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time);
        END LOOP;
        PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time);
        PERFORM check_achievements(p_user_id, p_target_game_time);

        v_cash_after := get_user_balance(p_user_id);
        IF v_cash_after < 0 THEN
            UPDATE users
               SET consecutive_negative_days = consecutive_negative_days + 1
             WHERE id = p_user_id;
            IF (SELECT consecutive_negative_days FROM users WHERE id = p_user_id) >= 30 THEN
                UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
                UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
            END IF;
        ELSE
            UPDATE users
               SET consecutive_negative_days = 0,
                   recovery_streak_days = recovery_streak_days + 1
             WHERE id = p_user_id;
        END IF;
    END IF;

    v_cash_after := get_user_balance(p_user_id);
    game_time    := p_target_game_time;
    cash         := v_cash_after;
    flights_run  := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$function$;

-- FIX 6b: Auto-repair rate formula — process_all_bots_simulation_to_time
-- BUG: Same inverted formula as FIX 6a but in the bot simulation path.
-- FIX: Change `v_gross_damage * (1.0 - v_auto_repair_rate)` to
--      `v_gross_damage * v_auto_repair_rate`.
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
BEGIN
    v_fuel_price       := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_absolute_minimum_safety_limit := COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00);
    v_crew_cost_per_hour := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear       := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear      := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
    v_fuel_price_multiplier := 1.0;
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
            v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
            v_flight_duration := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0))
                               + v_turnaround_hours;
            IF v_flight_duration <= 0 THEN CONTINUE; END IF;

            v_max_weekly_flights := FLOOR(168.0 / v_flight_duration)::INT;
            v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);

            v_demand_multiplier := calculate_route_demand_multiplier(
                v_route.distance_km, v_route.ticket_price);
            v_passengers := LEAST(v_route.capacity,
                FLOOR(v_route.capacity * 0.95 * v_demand_multiplier * v_seasonal_multiplier));

            v_revenue   := v_flights * v_route.ticket_price * v_passengers;
            v_fuel_cost := v_flights * v_route.distance_km
                         * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
            v_crew_cost := v_flights * v_flight_duration * v_crew_cost_per_hour;
            v_maint_cost := v_flights * v_route.distance_km
                          * v_route.maintenance_cost_per_hour
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

            -- FIX 6b: Use auto_repair_rate directly as the recovery fraction.
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

-- FIX 7: process_loan_payments — align bot late-fee penalty to human formula
-- BUG: Bot (AI) path applies `remaining_balance * 1.10` on missed payment,
--      which inflates a $1M balance by $100K per missed week. The human path
--      correctly applies `payment * 0.10` (~$2K per missed week).
-- FIX: Change bot path to match: add `v_effective_weekly * 0.10` as late fee
--      instead of multiplying entire balance by 1.10. Also record the
--      late_fee transaction for bots so it shows in the ledger.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.process_loan_payments(
    p_user_id  uuid,
    p_game_date timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
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
        SELECT * FROM loans
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
                PERFORM debit_bank_account(p_user_id, v_effective_weekly,
                    'financing', 'loan_payment',
                    'Weekly loan payment', p_game_date);
                v_cash := v_cash - v_effective_weekly;
                UPDATE loans
                   SET remaining_balance = remaining_balance - v_effective_weekly
                 WHERE id = r_loan.id;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', remaining_balance = 0
                     WHERE id = r_loan.id;
                END IF;
            ELSE
                -- FIX 7: Align bot late fee to human formula.
                -- Late fee = 10% of the weekly payment (not 10% of total balance).
                v_late_fee := v_effective_weekly * 0.10;
                UPDATE loans
                   SET remaining_balance = remaining_balance + v_late_fee,
                       missed_payments = missed_payments + 1
                 WHERE id = r_loan.id;
                -- Record the late fee in the ledger for transparency
                INSERT INTO bank_transactions (
                    account_id, user_id, transaction_type, amount, balance_after,
                    description, game_date, ifrs_category, ifrs_subcategory
                )
                SELECT ba.id, p_user_id, 'late_fee', v_late_fee, ba.balance,
                       'Loan payment late fee', p_game_date, 'financing', 'loan_late_fee'
                  FROM bank_accounts ba
                 WHERE ba.user_id = p_user_id AND ba.account_type = 'operating'
                 LIMIT 1;
                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
                END IF;
            END IF;
        ELSE
            v_payment := v_effective_weekly;
            IF v_cash >= v_payment THEN
                PERFORM debit_bank_account(p_user_id, v_payment,
                    'financing', 'loan_payment',
                    'Weekly loan payment', p_game_date);
                v_cash := v_cash - v_payment;
                UPDATE loans
                   SET remaining_balance = remaining_balance - v_payment
                 WHERE id = r_loan.id;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', remaining_balance = 0
                     WHERE id = r_loan.id;
                END IF;
            ELSE
                v_late_fee := v_payment * 0.10;
                UPDATE loans
                   SET remaining_balance = remaining_balance + v_late_fee,
                       missed_payments = missed_payments + 1
                 WHERE id = r_loan.id;
                INSERT INTO bank_transactions (
                    account_id, user_id, transaction_type, amount, balance_after,
                    description, game_date, ifrs_category, ifrs_subcategory
                )
                SELECT ba.id, p_user_id, 'late_fee', v_late_fee, ba.balance,
                       'Loan payment late fee', p_game_date, 'financing', 'loan_late_fee'
                  FROM bank_accounts ba
                 WHERE ba.user_id = p_user_id AND ba.account_type = 'operating'
                 LIMIT 1;
                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
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
$function$;

-- FIX 8: fleet_aircraft.tail_number UNIQUE constraint
-- BUG: No UNIQUE constraint exists on tail_number, allowing duplicate tail
--      numbers to be inserted (the bot code already retries on unique_violation
--      but there's no constraint to trigger it for all paths).
-- FIX: Create a UNIQUE index on tail_number.
-- ============================================================================
CREATE UNIQUE INDEX IF NOT EXISTS fleet_aircraft_tail_number_key
    ON public.fleet_aircraft (tail_number);

-- FIX 9: spawn_bot company name collision handler
-- BUG: spawn_bot generates a random company_name and INSERTs it, but
--      company_name has a UNIQUE constraint. If the name collides, the
--      entire function throws an exception instead of retrying.
-- FIX: Add a retry loop (up to 10 attempts) around the INSERT, generating
--      a new company_name each iteration, similar to the tail_number pattern.
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
$function$;

-- FIX 10: Bankrupt bot route cleanup in execute_bot_decisions
-- BUG: When a bot goes bankrupt in execute_bot_decisions, fleet_aircraft
--      are grounded and loans are defaulted, but route_assignments are NOT
--      cleaned up. Orphaned routes persist, potentially showing stale data
--      in the route network and consuming resources in future simulation
--      queries.
-- FIX: Add DELETE FROM route_assignments to the bankruptcy block, right
--      before the CONTINUE statement.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    r_bot RECORD;
    v_model_id UUID;
    v_model_name VARCHAR;
    v_lease_price NUMERIC;
    v_purchase_price NUMERIC;
    v_capacity INT;
    v_speed_kmh NUMERIC;
    v_range_km NUMERIC;
    v_deposit_pct NUMERIC;
    v_deposit_amount NUMERIC;
    v_tail VARCHAR(20);
    v_origin_iata VARCHAR(3);
    v_dest_iata VARCHAR(3);
    v_distance DOUBLE PRECISION;
    v_fleet_count INT;
    v_route_count INT;
    v_idle_aircraft_count INT;
    v_idle_aircraft_id UUID;
    v_idle_tail VARCHAR(20);
    v_idle_condition NUMERIC;
    v_idle_model_name VARCHAR;
    v_idle_capacity INT;
    v_idle_speed NUMERIC;
    v_idle_range NUMERIC;
    v_grounded_aircraft_id UUID;
    v_grounded_condition NUMERIC;
    v_grounded_acquisition_type VARCHAR;
    v_grounded_model_name VARCHAR;
    v_grounded_lease_price NUMERIC;
    v_grounded_purchase_price NUMERIC;
    v_repair_cost NUMERIC;
    v_target_fleet_cap INT;
    v_min_cash_reserve NUMERIC;
    v_growth_chance NUMERIC;
    v_target_distance DOUBLE PRECISION;
    v_target_price_multiplier NUMERIC;
    v_target_schedule_ratio NUMERIC;
    v_effective_threshold NUMERIC(5,2);
    v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00;
    v_selected_route_id UUID;
    v_selected_flights INT;
    v_selected_base_fare NUMERIC;
    v_max_weekly_flights INT;
    v_target_flights INT;
    v_target_price NUMERIC;
    v_bot_cash NUMERIC;
    v_starting_cash NUMERIC;
    v_attempts INT;
    v_inserted BOOLEAN;
    v_economy INT;
    v_business INT;
    v_first INT;
    r_route RECORD;
    v_human_competitors INT;
    v_new_price NUMERIC;
    v_base_fare NUMERIC;
    v_purchase_capacity INT;
    v_purchase_model_name VARCHAR;
    v_active_loans INT;
    v_game_time TIMESTAMPTZ;
    v_archetype VARCHAR(30);
    v_ticket_base_fare NUMERIC;
    v_ticket_per_km_rate NUMERIC;
    v_bankruptcy_threshold NUMERIC;
    v_spawned_id UUID;
BEGIN
    -- Read constants from game_config
    v_ticket_base_fare    := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
    v_ticket_per_km_rate  := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);
    v_starting_cash       := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
    v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);
    SELECT value::numeric INTO v_deposit_pct
      FROM game_config WHERE key = 'base_lease_deposit_percentage';
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);

    FOR r_bot IN
        SELECT u.*, COALESCE(bp.archetype, 'Balanced') as archetype
          FROM users u
          LEFT JOIN bot_profiles bp ON bp.user_id = u.id
         WHERE u.actor_type = 'AI' AND u.operational_status != 'Bankrupt'
    LOOP
        v_archetype := r_bot.archetype;
        v_bot_cash  := get_user_balance(r_bot.id);
        v_game_time := r_bot.game_current_time;
        v_origin_iata := r_bot.hq_airport_iata;
        v_effective_threshold := GREATEST(
            v_absolute_minimum_safety_limit,
            COALESCE(r_bot.auto_grounding_threshold, 40.00)
        );

        -- Bankruptcy detection + cleanup
        IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt'
           OR v_bot_cash < v_bankruptcy_threshold
        THEN
            UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
            UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id;
            UPDATE loans SET status = 'defaulted', remaining_balance = 0
             WHERE user_id = r_bot.id AND status = 'active';
            -- FIX 10: Clean up route assignments for bankrupt bots
            DELETE FROM route_assignments WHERE user_id = r_bot.id;
            CONTINUE;
        END IF;

        -- Archetype parameters
        CASE v_archetype
            WHEN 'Regional' THEN
                v_target_fleet_cap := 8;
                v_min_cash_reserve := 3500000.00;
                v_growth_chance    := 0.20;
                v_target_distance  := 900.0;
                v_target_price_multiplier := 0.95;
                v_target_schedule_ratio   := 0.72;
            WHEN 'Aggressive' THEN
                v_target_fleet_cap := 14;
                v_min_cash_reserve := 4500000.00;
                v_growth_chance    := 0.26;
                v_target_distance  := 1800.0;
                v_target_price_multiplier := 1.02;
                v_target_schedule_ratio   := 0.82;
            ELSE
                v_target_fleet_cap := 10;
                v_min_cash_reserve := 7000000.00;
                v_growth_chance    := 0.16;
                v_target_distance  := 4200.0;
                v_target_price_multiplier := 1.18;
                v_target_schedule_ratio   := 0.58;
        END CASE;

        SELECT COUNT(*)::INT INTO v_fleet_count
          FROM fleet_aircraft WHERE user_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_route_count
          FROM route_assignments WHERE user_id = r_bot.id;

        -- Count idle aircraft (active + above threshold + no route)
        SELECT COUNT(*)::INT INTO v_idle_aircraft_count
          FROM fleet_aircraft f
         WHERE f.user_id = r_bot.id
           AND f.status = 'active'
           AND f.condition >= v_effective_threshold
           AND NOT EXISTS (SELECT 1 FROM route_assignments r
                            WHERE r.assigned_aircraft_id = f.id);

        -- Find grounded aircraft for repair
        SELECT f.id, f.condition, f.acquisition_type, m.model_name,
               m.lease_price_per_month, m.purchase_price
          INTO v_grounded_aircraft_id, v_grounded_condition,
               v_grounded_acquisition_type, v_grounded_model_name,
               v_grounded_lease_price, v_grounded_purchase_price
          FROM fleet_aircraft f
          JOIN aircraft_models m ON f.aircraft_model_id = m.id
         WHERE f.user_id = r_bot.id
           AND (f.status = 'grounded' OR f.condition < v_effective_threshold)
         ORDER BY f.condition DESC
         LIMIT 1;

        -- Attempt repair
        IF v_grounded_aircraft_id IS NOT NULL THEN
            v_repair_cost := CASE
                WHEN v_grounded_acquisition_type = 'lease' THEN
                    (100.00 - v_grounded_condition)
                    * (COALESCE(v_grounded_lease_price, 0.00) * 0.50)
                ELSE
                    (100.00 - v_grounded_condition)
                    * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005)
            END;
            IF v_repair_cost > 0 AND v_bot_cash >= (v_repair_cost + 500000.00) THEN
                PERFORM debit_bank_account(r_bot.id, v_repair_cost,
                    'cogs', 'maintenance',
                    'Bot maintenance recovery: ' || v_grounded_model_name, v_game_time);
                UPDATE fleet_aircraft
                   SET condition = 100.00, status = 'active'
                 WHERE id = v_grounded_aircraft_id;
                v_bot_cash := v_bot_cash - v_repair_cost;
            END IF;
        END IF;

        -- Cost-cutting: reduce or remove worst route if cash is low
        IF v_bot_cash < 3000000.00
           OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2
        THEN
            SELECT r.id, r.flights_per_week,
                   (v_ticket_base_fare + (r.distance_km * v_ticket_per_km_rate))::NUMERIC
              INTO v_selected_route_id, v_selected_flights, v_selected_base_fare
              FROM route_assignments r
             WHERE r.user_id = r_bot.id
             ORDER BY (r.ticket_price
                       / NULLIF((v_ticket_base_fare
                                + (r.distance_km * v_ticket_per_km_rate)), 0)) DESC,
                      r.flights_per_week DESC
             LIMIT 1;
            IF v_selected_route_id IS NOT NULL THEN
                IF v_selected_flights > 8 THEN
                    UPDATE route_assignments
                       SET flights_per_week = GREATEST(6, flights_per_week
                           - CASE v_archetype
                                 WHEN 'Regional' THEN 6
                                 WHEN 'Aggressive' THEN 4
                                 ELSE 2
                             END),
                           ticket_price = GREATEST(
                               ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2),
                               ROUND((ticket_price * 0.90)::numeric, 2))
                     WHERE id = v_selected_route_id;
                ELSE
                    DELETE FROM route_assignments WHERE id = v_selected_route_id;
                END IF;
            END IF;
        END IF;

        -- Growth: lease new aircraft
        IF v_fleet_count < v_target_fleet_cap
           AND v_bot_cash > v_min_cash_reserve
           AND COALESCE(r_bot.consecutive_negative_days, 0) = 0
           AND v_idle_aircraft_count = 0
           AND v_route_count >= v_fleet_count
           AND random() < v_growth_chance
        THEN
            v_model_id := NULL; v_model_name := NULL;
            v_lease_price := NULL; v_purchase_price := NULL; v_capacity := NULL;

            IF v_archetype = 'Regional' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price,
                       capacity, speed_kmh, range_km
                  INTO v_model_id, v_model_name, v_lease_price, v_purchase_price,
                       v_capacity, v_speed_kmh, v_range_km
                  FROM aircraft_models
                 WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600' LIMIT 1;
            ELSIF v_archetype = 'Aggressive' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price,
                       capacity, speed_kmh, range_km
                  INTO v_model_id, v_model_name, v_lease_price, v_purchase_price,
                       v_capacity, v_speed_kmh, v_range_km
                  FROM aircraft_models
                 WHERE manufacturer = 'Airbus' AND model_name = 'A320neo' LIMIT 1;
            ELSE
                SELECT id, model_name, lease_price_per_month, purchase_price,
                       capacity, speed_kmh, range_km
                  INTO v_model_id, v_model_name, v_lease_price, v_purchase_price,
                       v_capacity, v_speed_kmh, v_range_km
                  FROM aircraft_models
                 WHERE manufacturer = 'Boeing' AND model_name = '787-9' LIMIT 1;
            END IF;

            -- Fallback if preferred model not found
            IF v_model_id IS NULL THEN
                IF v_archetype = 'Regional' THEN
                    SELECT id, model_name, lease_price_per_month, purchase_price,
                           capacity, speed_kmh, range_km
                      INTO v_model_id, v_model_name, v_lease_price, v_purchase_price,
                           v_capacity, v_speed_kmh, v_range_km
                      FROM aircraft_models
                     WHERE manufacturer = 'ATR'
                     ORDER BY capacity DESC LIMIT 1;
                ELSIF v_archetype = 'Aggressive' THEN
                    SELECT id, model_name, lease_price_per_month, purchase_price,
                           capacity, speed_kmh, range_km
                      INTO v_model_id, v_model_name, v_lease_price, v_purchase_price,
                           v_capacity, v_speed_kmh, v_range_km
                      FROM aircraft_models
                     WHERE manufacturer = 'Airbus'
                     ORDER BY capacity DESC LIMIT 1;
                ELSE
                    SELECT id, model_name, lease_price_per_month, purchase_price,
                           capacity, speed_kmh, range_km
                      INTO v_model_id, v_model_name, v_lease_price, v_purchase_price,
                           v_capacity, v_speed_kmh, v_range_km
                      FROM aircraft_models
                     WHERE manufacturer = 'Boeing'
                     ORDER BY capacity DESC LIMIT 1;
                END IF;
            END IF;

            v_deposit_amount := COALESCE(v_lease_price, 0.00) * v_deposit_pct;

            IF v_model_id IS NOT NULL AND v_bot_cash >= v_deposit_amount THEN
                IF v_archetype = 'Regional' THEN
                    v_economy := FLOOR(v_capacity * 0.80);
                    v_business := FLOOR(v_capacity * 0.15);
                    v_first := v_capacity - v_economy - v_business;
                ELSIF v_archetype = 'Aggressive' THEN
                    v_economy := FLOOR(v_capacity * 0.70);
                    v_business := FLOOR(v_capacity * 0.20);
                    v_first := v_capacity - v_economy - v_business;
                ELSE
                    v_economy := FLOOR(v_capacity * 0.50);
                    v_business := FLOOR(v_capacity * 0.30);
                    v_first := v_capacity - v_economy - v_business;
                END IF;

                v_attempts := 0;
                v_inserted := false;
                WHILE v_attempts < 10 AND NOT v_inserted LOOP
                    v_tail := generate_tail_number(r_bot.hq_airport_iata);
                    BEGIN
                        INSERT INTO fleet_aircraft (
                            id, user_id, aircraft_model_id, nickname,
                            acquisition_type, condition, status, tail_number,
                            economy_seats, business_seats, first_class_seats
                        ) VALUES (
                            gen_random_uuid(), r_bot.id, v_model_id, v_model_name,
                            'lease', 100.00, 'active', v_tail,
                            v_economy, v_business, v_first
                        );
                        v_inserted := true;
                    EXCEPTION
                        WHEN unique_violation THEN v_attempts := v_attempts + 1;
                    END;
                END LOOP;

                IF v_inserted THEN
                    PERFORM debit_bank_account(r_bot.id, v_deposit_amount,
                        'investing', 'aircraft_lease_deposit',
                        'Leased aircraft ' || v_model_name || ' [' || v_tail || '] - deposit',
                        v_game_time);
                    v_bot_cash := v_bot_cash - v_deposit_amount;
                END IF;
            END IF;
        END IF;

        -- Growth: purchase aircraft outright if very cash-rich
        IF v_bot_cash > (v_starting_cash * 3)
           AND v_fleet_count < v_target_fleet_cap
        THEN
            SELECT id, purchase_price, capacity, model_name
              INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name
              FROM aircraft_models
             WHERE range_km >= v_target_distance
             ORDER BY purchase_price ASC LIMIT 1;

            IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN
                IF v_archetype = 'Regional' THEN
                    v_economy := FLOOR(v_purchase_capacity * 0.80);
                    v_business := FLOOR(v_purchase_capacity * 0.15);
                    v_first := v_purchase_capacity - v_economy - v_business;
                ELSIF v_archetype = 'Aggressive' THEN
                    v_economy := FLOOR(v_purchase_capacity * 0.70);
                    v_business := FLOOR(v_purchase_capacity * 0.20);
                    v_first := v_purchase_capacity - v_economy - v_business;
                ELSE
                    v_economy := FLOOR(v_purchase_capacity * 0.50);
                    v_business := FLOOR(v_purchase_capacity * 0.30);
                    v_first := v_purchase_capacity - v_economy - v_business;
                END IF;

                v_attempts := 0;
                v_inserted := false;
                WHILE v_attempts < 10 AND NOT v_inserted LOOP
                    v_tail := generate_tail_number(r_bot.hq_airport_iata);
                    BEGIN
                        INSERT INTO fleet_aircraft (
                            user_id, aircraft_model_id, nickname, tail_number,
                            acquisition_type, condition, status,
                            economy_seats, business_seats, first_class_seats
                        ) VALUES (
                            r_bot.id, v_model_id, v_purchase_model_name, v_tail,
                            'purchase', 100.00, 'active',
                            v_economy, v_business, v_first
                        );
                        v_inserted := true;
                    EXCEPTION
                        WHEN unique_violation THEN v_attempts := v_attempts + 1;
                    END;
                END LOOP;

                IF v_inserted THEN
                    PERFORM debit_bank_account(r_bot.id, v_purchase_price,
                        'investing', 'aircraft_purchase',
                        'Aircraft purchase: ' || v_tail, v_game_time);
                    v_bot_cash := v_bot_cash - v_purchase_price;
                END IF;
            END IF;
        END IF;

        -- Recount after potential purchases
        SELECT COUNT(*)::INT INTO v_fleet_count
          FROM fleet_aircraft WHERE user_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_route_count
          FROM route_assignments WHERE user_id = r_bot.id;

        -- Find idle aircraft for new route assignment
        SELECT f.id, f.tail_number, f.condition, m.model_name,
               m.capacity, m.speed_kmh, m.range_km
          INTO v_idle_aircraft_id, v_idle_tail, v_idle_condition,
               v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range
          FROM fleet_aircraft f
          JOIN aircraft_models m ON f.aircraft_model_id = m.id
         WHERE f.user_id = r_bot.id
           AND f.status = 'active'
           AND f.condition >= v_effective_threshold
           AND NOT EXISTS (SELECT 1 FROM route_assignments r
                            WHERE r.assigned_aircraft_id = f.id)
         ORDER BY f.condition DESC LIMIT 1;

        -- Assign idle aircraft to a new route
        IF v_idle_aircraft_id IS NOT NULL
           AND v_route_count < v_target_fleet_cap
        THEN
            v_attempts := 0;
            v_inserted := false;
            WHILE v_attempts < 20 AND NOT v_inserted LOOP
                SELECT iata INTO v_dest_iata
                  FROM airports
                 WHERE iata != v_origin_iata
                 ORDER BY demand_index DESC, random()
                 LIMIT 1;
                IF v_dest_iata IS NULL THEN EXIT; END IF;

                SELECT haversine_distance(o.latitude, o.longitude,
                                          d.latitude, d.longitude)
                  INTO v_distance
                  FROM airports o, airports d
                 WHERE o.iata = v_origin_iata AND d.iata = v_dest_iata;

                IF v_distance > 0 AND v_distance <= v_idle_range THEN
                    v_base_fare   := v_ticket_base_fare
                                   + (v_distance * v_ticket_per_km_rate);
                    v_target_price := ROUND(v_base_fare * v_target_price_multiplier, 2);
                    v_max_weekly_flights := calculate_route_max_weekly_flights(
                        v_distance, v_idle_speed::INT);
                    v_target_flights := GREATEST(1,
                        FLOOR(v_max_weekly_flights * v_target_schedule_ratio));
                    BEGIN
                        INSERT INTO route_assignments (
                            user_id, origin_iata, destination_iata,
                            distance_km, ticket_price, assigned_aircraft_id,
                            flights_per_week
                        ) VALUES (
                            r_bot.id, v_origin_iata, v_dest_iata,
                            v_distance, v_target_price, v_idle_aircraft_id,
                            v_target_flights
                        );
                        v_inserted := true;
                    EXCEPTION
                        WHEN unique_violation THEN v_attempts := v_attempts + 1;
                    END;
                ELSE
                    v_attempts := v_attempts + 1;
                END IF;
            END LOOP;
        END IF;

        -- Price competition against human players
        FOR r_route IN
            SELECT ra.*, m.speed_kmh, m.range_km, m.turnaround_hours
              FROM route_assignments ra
              JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id
              JOIN aircraft_models m ON m.id = fa.aircraft_model_id
             WHERE ra.user_id = r_bot.id AND ra.status = 'active'
        LOOP
            SELECT COUNT(*) INTO v_human_competitors
              FROM route_assignments
             WHERE origin_iata = r_route.origin_iata
               AND destination_iata = r_route.destination_iata
               AND status = 'active'
               AND user_id != r_bot.id
               AND user_id IN (SELECT id FROM users WHERE actor_type = 'REAL');

            IF v_human_competitors > 0 THEN
                v_base_fare := v_ticket_base_fare
                             + (r_route.distance_km * v_ticket_per_km_rate);
                v_new_price := ROUND(
                    v_base_fare * v_target_price_multiplier
                    * CASE WHEN r_route.ticket_price > v_base_fare * 1.3
                           THEN 0.95 ELSE 1.0 END, 2);
                IF v_new_price != r_route.ticket_price THEN
                    UPDATE route_assignments
                       SET ticket_price = v_new_price
                     WHERE id = r_route.id;
                END IF;
            END IF;
        END LOOP;

        -- Take a loan if cash is low but not critical
        SELECT COUNT(*) INTO v_active_loans
          FROM loans WHERE user_id = r_bot.id AND status = 'active';
        IF v_active_loans = 0
           AND v_bot_cash < v_starting_cash * 0.5
           AND v_bot_cash > 1000000
        THEN
            PERFORM bot_take_loan(r_bot.id, LEAST(5000000, v_starting_cash - v_bot_cash));
        END IF;

        UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;
    END LOOP;

    -- Spawn replacement bot if below max
    IF (SELECT COUNT(*) FROM users
         WHERE actor_type = 'AI'
           AND COALESCE(operational_status, 'Active') != 'Bankrupt')
       < COALESCE(get_config_int('max_bot_count'), 5)
    THEN
        v_spawned_id := spawn_bot();
    END IF;
END;
$function$;

-- ============================================================================
-- End of migration 01: Critical Bug Fixes
-- ============================================================================
