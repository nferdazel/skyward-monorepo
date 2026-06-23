-- ============================================================================
-- Migration 109: Fix 5 critical integration bugs
-- ============================================================================
-- Bug 1: process_player_simulation_to_time references old table names
-- Bug 2: take_loan variable scoping bug (v_user_id → p_user_id)
-- Bug 3: get_global_leaderboard ambiguous column reference
-- Bug 4: update_credit_score references dropped column
-- Bug 5: process_all_bots_simulation_to_time references non-existent column
-- ============================================================================

-- ============================================================================
-- Bug 5: Add missing crew_cost_per_hour column to global_game_settings
-- ============================================================================
-- This column is referenced by process_all_bots_simulation_to_time but was
-- never created. Default 350.0 is the standard crew cost per flight-hour.
ALTER TABLE global_game_settings
ADD COLUMN IF NOT EXISTS crew_cost_per_hour NUMERIC NOT NULL DEFAULT 350.0;


-- ============================================================================
-- Bug 1: process_player_simulation_to_time — fix old table/column references
-- ============================================================================
-- Tables were renamed in migration 100: user_routes → route_assignments,
-- user_fleet → fleet_aircraft. This function was rewritten in migration 108
-- but still uses the old names.
--
-- Additionally, v_aircraft.capacity and v_aircraft.lease_price_per_month are
-- referenced but these columns live on aircraft_models, not fleet_aircraft.
-- Since the route query already JOINs aircraft_models and selects these
-- columns, we switch to v_route.capacity and v_route.lease_price_per_month.
-- ============================================================================
CREATE OR REPLACE FUNCTION process_player_simulation_to_time(
    p_user_id UUID,
    p_target_game_time TIMESTAMPTZ
) RETURNS TABLE (
    game_time TIMESTAMPTZ,
    cash NUMERIC,
    flights_run INT,
    elapsed_days NUMERIC
) AS $$
DECLARE
    r_user RECORD;
    v_route RECORD;
    v_aircraft RECORD;
    v_flight_hours NUMERIC;
    v_revenue NUMERIC;
    v_ops_cost NUMERIC;
    v_lease_cost NUMERIC;
    v_net NUMERIC;
    v_flights_run INT := 0;
    v_cash_after NUMERIC;
    v_elapsed_days NUMERIC;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_buffered_rev_accum NUMERIC(20,2) := 0.00;
    v_buffered_ops_accum NUMERIC(20,2) := 0.00;
    v_buffered_lease_accum NUMERIC(20,2) := 0.00;
    v_buffered_cargo_accum NUMERIC(20,2) := 0.00;
    v_cargo_rev NUMERIC(20,2);
    v_turnaround_hours NUMERIC;
    v_last_flown TIMESTAMPTZ;
    v_can_fly BOOLEAN;
    v_weekly_hours NUMERIC;
    v_max_weekly_hours NUMERIC := 168.0;
    v_demand_multiplier NUMERIC;
    v_class_multiplier NUMERIC;
    v_crew_cost NUMERIC;
    v_fuel_price NUMERIC;
    v_subsidy NUMERIC;
    v_seasonal_factor NUMERIC;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    SELECT COALESCE(fuel_price_per_liter, 0.85) INTO v_fuel_price
    FROM global_game_settings LIMIT 1;

    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;

    FOR v_route IN
        SELECT ur.*,
               am.fuel_burn_per_km,
               am.speed_kmh,
               am.turnaround_hours,
               am.capacity,
               am.lease_price_per_month,
               a1.demand_index AS origin_demand,
               a2.demand_index AS dest_demand
        FROM route_assignments ur
        JOIN aircraft_models am ON am.id = (
            SELECT aircraft_model_id FROM fleet_aircraft WHERE id = ur.assigned_aircraft_id
        )
        JOIN airports a1 ON a1.iata = ur.origin_iata
        JOIN airports a2 ON a2.iata = ur.destination_iata
        WHERE ur.user_id = p_user_id
          AND ur.assigned_aircraft_id IS NOT NULL
          AND ur.status = 'active'
    LOOP
        SELECT * INTO v_aircraft FROM fleet_aircraft WHERE id = v_route.assigned_aircraft_id;
        IF NOT FOUND OR v_aircraft.status != 'active' THEN CONTINUE; END IF;

        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
        v_last_flown := v_aircraft.last_flown_at;
        v_can_fly := (v_last_flown IS NULL OR
                      p_target_game_time >= v_last_flown + (v_turnaround_hours || ' hours')::INTERVAL);
        IF NOT v_can_fly THEN CONTINUE; END IF;

        SELECT COALESCE(SUM(EXTRACT(EPOCH FROM (completed_at - departed_at)) / 3600.0), 0)
        INTO v_weekly_hours
        FROM flight_log
        WHERE aircraft_id = v_aircraft.id
          AND completed_at >= p_target_game_time - INTERVAL '7 days';

        IF v_weekly_hours >= v_max_weekly_hours THEN CONTINUE; END IF;

        v_demand_multiplier := (v_route.origin_demand + v_route.dest_demand) / 200.0;
        v_class_multiplier := 1.0;
        v_revenue := v_route.ticket_price * v_route.flights_per_week *
                     v_route.capacity * v_demand_multiplier * v_class_multiplier;

        v_fuel_price := COALESCE(v_fuel_price, 0.85);
        v_ops_cost := (v_route.distance_km * 2 * v_fuel_price * v_route.fuel_burn_per_km) +
                      (v_route.flights_per_week * 350.0);
        v_lease_cost := CASE WHEN v_aircraft.acquisition_type = 'lease'
                             THEN v_route.lease_price_per_month / 4.33 ELSE 0 END;
        v_cargo_rev := v_revenue * 0.10;

        v_net := v_revenue + v_cargo_rev - v_ops_cost - v_lease_cost;

        v_buffered_rev_accum := v_buffered_rev_accum + v_revenue;
        v_buffered_ops_accum := v_buffered_ops_accum + v_ops_cost;
        v_buffered_lease_accum := v_buffered_lease_accum + v_lease_cost;
        v_buffered_cargo_accum := v_buffered_cargo_accum + v_cargo_rev;

        v_wear_per_cycle := 0.02;
        v_gross_damage := v_route.flights_per_week * v_wear_per_cycle;
        v_self_healing_credit := 0.0;
        v_net_damage := GREATEST(0.00, v_gross_damage - v_self_healing_credit);

        UPDATE fleet_aircraft
        SET condition = GREATEST(0.00, condition - v_net_damage),
            last_flown_at = p_target_game_time,
            total_flights = total_flights + v_route.flights_per_week
        WHERE id = v_aircraft.id;

        v_flights_run := v_flights_run + v_route.flights_per_week;
    END LOOP;

    v_subsidy := 0.0;
    IF v_net < 0 THEN
        v_subsidy := LEAST(ABS(v_net) * 0.05, 50000.0);
    END IF;
    v_subsidy := GREATEST(0, LEAST(v_subsidy, v_buffered_rev_accum * 0.10));
    IF v_subsidy > 0 THEN
        INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
        VALUES (p_user_id, 'revenue', 'subsidy', v_subsidy, 'Government route subsidy', date_trunc('day', p_target_game_time));
        v_net := v_net + v_subsidy;
    END IF;

    IF date_trunc('day', p_target_game_time) > date_trunc('day', r_user.game_current_time) THEN
        IF v_buffered_rev_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active routes', date_trunc('day', p_target_game_time));
        END IF;
        IF v_buffered_cargo_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'revenue', 'cargo', v_buffered_cargo_accum, 'Cargo revenue — distance-scaled freight income', date_trunc('day', p_target_game_time));
        END IF;
        IF v_buffered_ops_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew maintenance, & landing fees', date_trunc('day', p_target_game_time));
        END IF;
        IF v_buffered_lease_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (p_user_id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active fleet', date_trunc('day', p_target_game_time));
        END IF;

        DELETE FROM financial_ledger
        WHERE user_id = p_user_id
          AND game_date < (p_target_game_time - INTERVAL '30 days');

        v_buffered_rev_accum := 0.00;
        v_buffered_ops_accum := 0.00;
        v_buffered_lease_accum := 0.00;
        v_buffered_cargo_accum := 0.00;

        PERFORM check_achievements(p_user_id, p_target_game_time);
        PERFORM process_loan_payments(p_user_id, p_target_game_time);
        PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time);
        PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time);
        PERFORM accrue_savings_interest(p_user_id, p_target_game_time);
    END IF;

    v_cash_after := r_user.cash + v_net;
    UPDATE users SET
        cash = v_cash_after,
        game_current_time = p_target_game_time,
        credit_score = COALESCE((SELECT score FROM credit_scores WHERE user_id = p_user_id), r_user.credit_score)
    WHERE id = p_user_id;

    game_time := p_target_game_time;
    cash := v_cash_after;
    flights_run := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION process_player_simulation_to_time(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION process_player_simulation_to_time(UUID, TIMESTAMPTZ) TO service_role, authenticated;


-- ============================================================================
-- Bug 2: take_loan — fix v_user_id → p_user_id variable scoping
-- ============================================================================
-- The bank_transactions INSERTs use v_user_id which is never declared.
-- The parameter is p_user_id. Also, the bot path INSERT referenced v_user_id
-- instead of p_user_id.
-- ============================================================================
CREATE OR REPLACE FUNCTION take_loan(
    p_user_id   UUID,
    p_principal NUMERIC,
    p_term_weeks INT DEFAULT 52,
    p_loan_type VARCHAR DEFAULT 'unsecured',
    p_collateral_aircraft_id UUID DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT, new_cash NUMERIC) AS $$
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
    v_rate_key TEXT;
    v_loan_id UUID;
BEGIN
    SELECT u.actor_type, u.credit_score, u.game_current_time
    INTO v_actor_type, v_credit_score, v_game_time
    FROM users u WHERE u.id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    IF v_actor_type = 'AI' THEN
        SELECT COUNT(*) INTO v_existing_loans
        FROM loans WHERE user_id = p_user_id AND status = 'active';
        IF v_existing_loans >= 3 THEN
            RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        IF p_principal < 100000 OR p_principal > 5000000 THEN
            RETURN QUERY SELECT false, 'Bot loan amount must be between $100K and $5M.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;

        v_interest_rate := 0.05;
        v_total_repayable := p_principal * (1 + v_interest_rate);
        v_weekly_payment := v_total_repayable / p_term_weeks;

        INSERT INTO loans (
            user_id, principal, interest_rate, remaining_balance,
            weekly_payment, game_date_taken, status
        ) VALUES (
            p_user_id, p_principal, v_interest_rate, v_total_repayable,
            v_weekly_payment, v_game_time, 'active'
        ) RETURNING id INTO v_loan_id;

        UPDATE users SET cash = cash + p_principal WHERE id = p_user_id;

        INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, reference_type, reference_id, game_date)
        SELECT ba.id, p_user_id, 'disbursement', p_principal, ba.balance,
            'Loan disbursement',
            'loan', v_loan_id, v_game_time
        FROM bank_accounts ba
        WHERE ba.user_id = p_user_id AND ba.account_type = 'checking'
        LIMIT 1;

        INSERT INTO financial_ledger (
            user_id, transaction_type, category, amount, description, game_date
        ) VALUES (
            p_user_id, 'revenue', 'loan', p_principal,
            'Bank loan taken — $' || p_principal::TEXT || ' at 5% APR',
            v_game_time
        );

        SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
        RETURN QUERY SELECT true,
            'Loan approved! $' || p_principal::TEXT || ' at 5% APR (bot).',
            v_cash;
        RETURN;
    END IF;

    SELECT credit_tier_config INTO v_config
    FROM global_game_settings WHERE id = 1;

    v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
    v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);

    SELECT COUNT(*) INTO v_existing_loans
    FROM loans WHERE user_id = p_user_id AND status = 'active';
    IF v_existing_loans >= v_max_loans THEN
        RETURN QUERY SELECT false,
            'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_credit_score := COALESCE(v_credit_score, 500);

    SELECT * INTO v_score_record
    FROM calculate_credit_score(p_user_id)
    LIMIT 1;

    IF FOUND THEN
        v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE
        v_tier := resolve_credit_tier(v_credit_score);
    END IF;

    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);

    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
        RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    IF p_loan_type = 'unsecured' THEN
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
        v_rate_key := 'rate_unsecured';
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE id = p_collateral_aircraft_id AND user_id = p_user_id) THEN
            RETURN QUERY SELECT false, 'You do not own that aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
        v_rate_key := 'rate_secured';
    ELSE
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_financing')::NUMERIC, 0.07);
        v_rate_key := 'rate_financing';
    END IF;

    IF p_principal < v_min_loan OR p_principal > v_max_principal THEN
        RETURN QUERY SELECT false,
            'Loan amount must be between $' ||
            (v_min_loan / 1000)::TEXT || 'K and $' ||
            CASE WHEN v_max_principal >= 1000000
                 THEN (v_max_principal / 1000000)::TEXT || 'M'
                 ELSE (v_max_principal / 1000)::TEXT || 'K'
            END ||
            ' for your ' || v_tier || ' credit tier.'::TEXT,
            0::NUMERIC;
        RETURN;
    END IF;

    v_total_repayable := p_principal * (1 + v_interest_rate * (p_term_weeks / 52.0));
    v_weekly_payment := v_total_repayable / p_term_weeks;

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id FOR UPDATE;
    IF v_cash < 0 THEN
        RETURN QUERY SELECT false, 'Cannot take loan with negative cash balance.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance,
        weekly_payment, status, game_date_taken,
        loan_type, collateral_aircraft_id, credit_score_at_origination
    ) VALUES (
        p_user_id, p_principal, v_interest_rate, v_total_repayable,
        v_weekly_payment, 'active', v_game_time,
        p_loan_type, p_collateral_aircraft_id, v_credit_score
    ) RETURNING id INTO v_loan_id;

    UPDATE users SET cash = cash + p_principal WHERE id = p_user_id;

    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, reference_type, reference_id, game_date)
    SELECT ba.id, p_user_id, 'disbursement', p_principal, ba.balance,
        'Loan disbursement (' || v_tier || ' tier)',
        'loan', v_loan_id, v_game_time
    FROM bank_accounts ba
    WHERE ba.user_id = p_user_id AND ba.account_type = 'checking'
    LIMIT 1;

    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;

    RETURN QUERY SELECT true,
        'Loan approved! $' || p_principal::TEXT || ' at ' ||
        (v_interest_rate * 100)::TEXT || '% APR (' || v_tier || ' tier).'::TEXT,
        v_cash;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION take_loan(UUID, NUMERIC, INT, VARCHAR, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION take_loan(UUID, NUMERIC, INT, VARCHAR, UUID) TO service_role;

COMMENT ON FUNCTION take_loan(UUID, NUMERIC, INT, VARCHAR, UUID) IS
    'Process a loan for a specific user. Bot (actor_type=AI) uses simplified 5% rate / $5M max. Player uses credit-tier logic. Writes to bank_transactions.';


-- ============================================================================
-- Bug 3: get_global_leaderboard — fix ambiguous column reference
-- ============================================================================
-- The RETURNS TABLE has a column named "status" which acts as an implicit
-- OUT variable in PL/pgSQL. The SELECT aliases COALESCE(u.operational_status,
-- ''Active'')::VARCHAR AS status, creating ambiguity. Fix: keep the returned
-- column name as "status" for API compatibility but remove the redundant
-- alias so PostgreSQL maps by position, not by name collision.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_global_leaderboard()
RETURNS TABLE (
    id UUID,
    company_name VARCHAR,
    ceo_name VARCHAR,
    is_bot BOOLEAN,
    archetype VARCHAR,
    cash NUMERIC,
    net_worth NUMERIC,
    fleet_size INT,
    monthly_revenue NUMERIC,
    status VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        u.id,
        u.company_name::VARCHAR,
        u.ceo_name::VARCHAR,
        (u.actor_type = 'AI')::BOOLEAN,
        COALESCE(u.archetype, 'Player')::VARCHAR,
        u.cash,
        u.net_worth,
        (SELECT COUNT(*)::INT FROM fleet_aircraft WHERE user_id = u.id AND status = 'active'),
        COALESCE((
            SELECT SUM(amount)
            FROM financial_ledger
            WHERE user_id = u.id
              AND transaction_type = 'revenue'
              AND game_date >= u.game_current_time - INTERVAL '30 days'
        ), 0.00)::NUMERIC,
        COALESCE(u.operational_status, 'Active')::VARCHAR
    FROM users u;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- Bug 4: update_credit_score — remove reference to dropped column
-- ============================================================================
-- credit_score_updated_at was dropped from users in migration 103.
-- The UPDATE SET clause must only touch credit_score and credit_tier.
-- ============================================================================
CREATE OR REPLACE FUNCTION update_credit_score(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
)
RETURNS VOID AS $$
DECLARE
    v_score RECORD;
    v_tier VARCHAR(10);
BEGIN
    SELECT * INTO v_score FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF NOT FOUND THEN RETURN; END IF;

    v_tier := CASE
        WHEN v_score.total_score >= 900 THEN 'Platinum'
        WHEN v_score.total_score >= 750 THEN 'Gold'
        WHEN v_score.total_score >= 600 THEN 'Silver'
        WHEN v_score.total_score >= 400 THEN 'Standard'
        ELSE 'Subprime'
    END;

    INSERT INTO credit_scores (
        user_id, score, tier,
        fleet_health_score, revenue_stability_score,
        debt_ratio_score, cash_reserves_score, profit_history_score,
        computed_at
    ) VALUES (
        p_user_id, v_score.total_score, v_tier,
        v_score.fleet_health, v_score.revenue_stability,
        v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history,
        NOW()
    )
    ON CONFLICT (user_id) DO UPDATE SET
        score = EXCLUDED.score,
        tier = EXCLUDED.tier,
        fleet_health_score = EXCLUDED.fleet_health_score,
        revenue_stability_score = EXCLUDED.revenue_stability_score,
        debt_ratio_score = EXCLUDED.debt_ratio_score,
        cash_reserves_score = EXCLUDED.cash_reserves_score,
        profit_history_score = EXCLUDED.profit_history_score,
        computed_at = EXCLUDED.computed_at;

    UPDATE users
    SET credit_score = v_score.total_score,
        credit_tier = v_tier
    WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION update_credit_score(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_credit_score(UUID, TIMESTAMPTZ) TO service_role;

COMMENT ON FUNCTION update_credit_score(UUID, TIMESTAMPTZ) IS
    'Recalculates and persists a player''s credit score at each game-day boundary.';


-- ============================================================================
-- Bug 5: process_all_bots_simulation_to_time — already fixed by ALTER TABLE
-- ============================================================================
-- The crew_cost_per_hour column was added to global_game_settings above.
-- The existing COALESCE(crew_cost_per_hour, 350.0) in the function will now
-- resolve correctly against the real column. No function rewrite needed.
-- ============================================================================


-- ============================================================================
-- Verification queries
-- ============================================================================
DO $$
DECLARE
    v_count INT;
BEGIN
    -- Bug 1: No user_routes references
    SELECT COUNT(*) INTO v_count
    FROM pg_proc
    WHERE proname = 'process_player_simulation_to_time'
      AND pg_get_functiondef(oid) LIKE '%user_routes%';
    IF v_count > 0 THEN
        RAISE WARNING 'Bug 1 NOT fixed: process_player_simulation_to_time still references user_routes';
    END IF;

    -- Bug 1: No user_fleet references
    SELECT COUNT(*) INTO v_count
    FROM pg_proc
    WHERE proname = 'process_player_simulation_to_time'
      AND pg_get_functiondef(oid) LIKE '%user_fleet%';
    IF v_count > 0 THEN
        RAISE WARNING 'Bug 1 NOT fixed: process_player_simulation_to_time still references user_fleet';
    END IF;

    -- Bug 2: No v_user_id references in take_loan
    SELECT COUNT(*) INTO v_count
    FROM pg_proc
    WHERE proname = 'take_loan'
      AND pg_get_functiondef(oid) LIKE '%v_user_id%';
    IF v_count > 0 THEN
        RAISE WARNING 'Bug 2 NOT fixed: take_loan still references v_user_id';
    END IF;

    -- Bug 4: No credit_score_updated_at references
    SELECT COUNT(*) INTO v_count
    FROM pg_proc
    WHERE proname = 'update_credit_score'
      AND pg_get_functiondef(oid) LIKE '%credit_score_updated_at%';
    IF v_count > 0 THEN
        RAISE WARNING 'Bug 4 NOT fixed: update_credit_score still references credit_score_updated_at';
    END IF;

    -- Bug 5: crew_cost_per_hour column exists
    SELECT COUNT(*) INTO v_count
    FROM information_schema.columns
    WHERE table_name = 'global_game_settings'
      AND column_name = 'crew_cost_per_hour';
    IF v_count = 0 THEN
        RAISE WARNING 'Bug 5 NOT fixed: crew_cost_per_hour column missing from global_game_settings';
    END IF;

    RAISE NOTICE 'Migration 109 verification complete.';
END $$;
