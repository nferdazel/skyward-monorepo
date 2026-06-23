-- ============================================================================
-- Migration 102: Clean up remaining ai_competitors references
-- ============================================================================
-- Fixes the 9 functions that still reference the now-dropped ai_competitors table.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. get_world_tick_guardrail_report — uses ai_competitors for lag/ahead counts
-- ============================================================================
CREATE OR REPLACE FUNCTION get_world_tick_guardrail_report()
RETURNS TABLE (
    check_name TEXT,
    check_status TEXT,
    details TEXT
) AS $$
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
$$ LANGUAGE plpgsql STABLE;


-- ============================================================================
-- 2. get_financial_ledger_compaction_report — CTE uses ai_competitors
-- ============================================================================
CREATE OR REPLACE FUNCTION get_financial_ledger_compaction_report()
RETURNS TABLE (
    actor_id UUID,
    is_bot BOOLEAN,
    company_name VARCHAR,
    summary_game_date DATE,
    summary_month DATE,
    transaction_type VARCHAR,
    category VARCHAR,
    source_row_count BIGINT,
    total_amount NUMERIC,
    first_game_date TIMESTAMP WITH TIME ZONE,
    last_game_date TIMESTAMP WITH TIME ZONE,
    first_created_at TIMESTAMP WITH TIME ZONE,
    last_created_at TIMESTAMP WITH TIME ZONE,
    retention_game_days INT,
    actor_game_current_time TIMESTAMP WITH TIME ZONE,
    cutoff_game_time TIMESTAMP WITH TIME ZONE
) AS $$
BEGIN
    RETURN QUERY
    WITH actor_cutoffs AS (
        SELECT
            u.id AS actor_id,
            (u.actor_type = 'AI') AS is_bot,
            u.company_name,
            u.game_current_time AS actor_game_current_time,
            COALESCE(policy.value_int, CASE WHEN u.actor_type = 'AI' THEN 30 ELSE 90 END) AS retention_game_days,
            u.game_current_time - make_interval(days => COALESCE(policy.value_int, CASE WHEN u.actor_type = 'AI' THEN 30 ELSE 90 END)) AS cutoff_game_time
        FROM users u
        LEFT JOIN data_retention_policy policy
            ON policy.key = CASE WHEN u.actor_type = 'AI' THEN 'bot_ledger_raw_game_days' ELSE 'player_ledger_raw_game_days' END
    ),
    eligible AS (
        SELECT
            ac.actor_id,
            ac.is_bot,
            ac.company_name,
            ac.retention_game_days,
            ac.actor_game_current_time,
            ac.cutoff_game_time,
            fl.transaction_type,
            fl.category,
            fl.amount,
            fl.game_date,
            fl.created_at
        FROM financial_ledger fl
        JOIN actor_cutoffs ac ON fl.user_id = ac.actor_id
        WHERE fl.game_date < ac.cutoff_game_time
    )
    SELECT
        eligible.actor_id,
        eligible.is_bot,
        eligible.company_name,
        (eligible.game_date AT TIME ZONE 'UTC')::DATE AS summary_game_date,
        date_trunc('month', eligible.game_date AT TIME ZONE 'UTC')::DATE AS summary_month,
        eligible.transaction_type,
        eligible.category,
        COUNT(*)::BIGINT AS source_row_count,
        COALESCE(SUM(eligible.amount), 0.00)::NUMERIC AS total_amount,
        MIN(eligible.game_date) AS first_game_date,
        MAX(eligible.game_date) AS last_game_date,
        MIN(eligible.created_at) AS first_created_at,
        MAX(eligible.created_at) AS last_created_at,
        eligible.retention_game_days,
        eligible.actor_game_current_time,
        eligible.cutoff_game_time
    FROM eligible
    GROUP BY
        eligible.actor_id, eligible.is_bot, eligible.company_name,
        (eligible.game_date AT TIME ZONE 'UTC')::DATE,
        date_trunc('month', eligible.game_date AT TIME ZONE 'UTC')::DATE,
        eligible.transaction_type, eligible.category,
        eligible.retention_game_days, eligible.actor_game_current_time, eligible.cutoff_game_time
    ORDER BY
        summary_game_date ASC, eligible.is_bot ASC, eligible.actor_id ASC,
        eligible.transaction_type ASC, eligible.category ASC;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;


-- ============================================================================
-- 3. set_acquired_game_date — trigger uses ai_competitor_id (column dropped)
-- ============================================================================
CREATE OR REPLACE FUNCTION set_acquired_game_date()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.acquired_game_date IS NULL THEN
        IF NEW.user_id IS NOT NULL THEN
            SELECT game_current_time INTO NEW.acquired_game_date
            FROM users WHERE id = NEW.user_id;
        END IF;
        NEW.acquired_game_date := COALESCE(NEW.acquired_game_date, NOW());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 4. process_bot_loan_payments — reads ai_competitors + loans.ai_competitor_id
-- ============================================================================
CREATE OR REPLACE FUNCTION process_bot_loan_payments(
    p_bot_id UUID,
    p_game_date TIMESTAMPTZ
) RETURNS VOID AS $$
DECLARE
    v_loan RECORD;
    v_cash NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_bot_id AND actor_type = 'AI';

    FOR v_loan IN
        SELECT * FROM loans
        WHERE user_id = p_bot_id AND status = 'active'
    LOOP
        IF v_cash >= v_loan.weekly_payment THEN
            UPDATE users SET cash = cash - v_loan.weekly_payment WHERE id = p_bot_id;
            v_cash := v_cash - v_loan.weekly_payment;

            UPDATE loans SET remaining_balance = remaining_balance - v_loan.weekly_payment
            WHERE id = v_loan.id;

            IF (SELECT remaining_balance FROM loans WHERE id = v_loan.id) <= 0 THEN
                UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0
                WHERE id = v_loan.id;
            END IF;
        ELSE
            UPDATE loans SET
                remaining_balance = remaining_balance * 1.10,
                missed_payments = missed_payments + 1
            WHERE id = v_loan.id;

            IF (SELECT missed_payments FROM loans WHERE id = v_loan.id) >= 4 THEN
                UPDATE loans SET status = 'defaulted' WHERE id = v_loan.id;
            END IF;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;


-- ============================================================================
-- 5. trg_ai_competitor_bankruptcy — orphaned (trigger dropped in m81), replace
-- ============================================================================
CREATE OR REPLACE FUNCTION trg_ai_competitor_bankruptcy()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.operational_status = 'Bankrupt' AND NEW.actor_type = 'AI' THEN
        UPDATE user_fleet SET status = 'grounded' WHERE user_id = NEW.id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 6. trg_ai_competitor_respawn — orphaned (trigger dropped in m81), replace
-- ============================================================================
CREATE OR REPLACE FUNCTION trg_ai_competitor_respawn()
RETURNS TRIGGER AS $$
DECLARE
    v_max_bots INT;
    v_current_bots INT;
    v_missing INT;
    v_names VARCHAR[] := ARRAY['Apex Aero', 'Vanguard Premium', 'Nusantara Link', 'Red Star Wings', 'Mekong Express', 'Zephyr Airways', 'Aurora Horizon', 'Pacific Wings', 'Equator Sky', 'Atlas Airway'];
    v_ceos VARCHAR[] := ARRAY['Edward Falcon', 'Sophia Rothschild', 'Ahmad Hidayat', 'Viktor Reznov', 'Linh Nguyen', 'James Sterling', 'Elena Rostova', 'Kenji Sato', 'Hans Muller', 'Chloe Dupont'];
    v_archetypes VARCHAR[] := ARRAY['Regional', 'Aggressive', 'Premium'];
    v_airports VARCHAR[] := ARRAY['CGK', 'SIN', 'LHR', 'KUL', 'BKK'];
    v_random_name VARCHAR;
    v_random_ceo VARCHAR;
    v_random_arch VARCHAR;
    v_random_hq VARCHAR;
    v_starting_cash NUMERIC;
    r_season RECORD;
BEGIN
    SELECT max_bot_count, starting_cash INTO v_max_bots, v_starting_cash FROM global_game_settings LIMIT 1;
    v_max_bots := COALESCE(v_max_bots, 5);
    v_starting_cash := COALESCE(v_starting_cash, 15000000.00);

    SELECT COUNT(*)::INT INTO v_current_bots FROM users WHERE actor_type = 'AI';
    v_missing := v_max_bots - v_current_bots;

    SELECT id, current_game_time INTO r_season
    FROM season_clock WHERE status = 'active' ORDER BY created_at ASC LIMIT 1;

    WHILE v_missing > 0 LOOP
        v_random_name := v_names[floor(random() * array_length(v_names, 1) + 1)::int] || ' ' || floor(random() * 900 + 100)::text;
        v_random_ceo := v_ceos[floor(random() * array_length(v_ceos, 1) + 1)::int];
        v_random_arch := v_archetypes[floor(random() * array_length(v_archetypes, 1) + 1)::int];
        v_random_hq := v_airports[floor(random() * array_length(v_airports, 1) + 1)::int];

        IF NOT EXISTS (SELECT 1 FROM users WHERE company_name = v_random_name) THEN
            INSERT INTO users (
                company_name, ceo_name, archetype, hq_airport_iata,
                cash, net_worth, actor_type, season_id, game_current_time
            ) VALUES (
                v_random_name, v_random_ceo, v_random_arch, v_random_hq,
                v_starting_cash, v_starting_cash, 'AI',
                r_season.id, r_season.current_game_time
            );
            v_missing := v_missing - 1;
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 7. process_all_bots_simulation — old tick function, superseded
-- ============================================================================
-- This legacy function is no longer called (process_world_tick uses
-- process_all_bots_simulation_to_time). Rewrite to delegate.
CREATE OR REPLACE FUNCTION process_all_bots_simulation()
RETURNS VOID AS $$
BEGIN
    PERFORM process_all_bots_simulation_to_time(NOW());
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 8. process_bot_simulation — very old single-bot function
-- ============================================================================
CREATE OR REPLACE FUNCTION process_bot_simulation(p_bot_id UUID DEFAULT NULL)
RETURNS void AS $$
DECLARE
    r_bot RECORD;
    r_route RECORD;
    v_model_id UUID;
    v_model_name VARCHAR;
    v_lease_price NUMERIC;
    v_purchase_price NUMERIC;
    v_capacity INT;
    v_deposit_pct NUMERIC := 0.10;
    v_deposit_amount NUMERIC;
    v_tail VARCHAR;
    v_new_aircraft_id UUID;
    v_origin_iata VARCHAR;
    v_dest_iata VARCHAR;
    v_distance NUMERIC;
    v_origin_lat NUMERIC;
    v_origin_lon NUMERIC;
    v_dest_lat NUMERIC;
    v_dest_lon NUMERIC;
    v_flights INT;
    v_flight_duration NUMERIC;
    v_fuel_price NUMERIC;
    v_fuel_cost NUMERIC;
    v_ticket_revenue NUMERIC;
    v_demand_multiplier NUMERIC;
    v_wear_per_flight NUMERIC;
    v_daily_revenue NUMERIC;
    v_daily_expense NUMERIC;
    v_daily_profit NUMERIC;
    v_game_current_time_new TIMESTAMP WITH TIME ZONE;
    v_elapsed_days NUMERIC;
    v_buffered_rev_accum NUMERIC := 0.0;
BEGIN
    SELECT fuel_price_per_liter INTO v_fuel_price FROM global_game_settings LIMIT 1;
    v_fuel_price := COALESCE(v_fuel_price, 0.85);

    FOR r_bot IN
        SELECT * FROM users
        WHERE actor_type = 'AI'
          AND (p_bot_id IS NULL OR id = p_bot_id)
          AND COALESCE(operational_status, 'Active') != 'Bankrupt'
    LOOP
        v_elapsed_days := EXTRACT(EPOCH FROM (NOW() - r_bot.last_active_at)) / 86400.0 * 30.0;
        v_game_current_time_new := r_bot.game_current_time + (v_elapsed_days || ' days')::INTERVAL;

        IF NOT EXISTS (SELECT 1 FROM user_fleet WHERE user_id = r_bot.id) THEN
            IF r_bot.archetype = 'Regional' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity
                FROM aircraft_models WHERE model_name = 'ATR 72-600' LIMIT 1;
            ELSIF r_bot.archetype = 'Aggressive' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity
                FROM aircraft_models WHERE model_name = 'A320neo' LIMIT 1;
            ELSE
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity
                FROM aircraft_models WHERE model_name = '787-9 Dreamliner' LIMIT 1;
            END IF;

            v_deposit_amount := v_lease_price * (v_deposit_pct * 10.0);

            IF v_model_id IS NOT NULL AND r_bot.cash >= v_deposit_amount THEN
                v_tail := generate_tail_number(r_bot.hq_airport_iata);
                v_new_aircraft_id := gen_random_uuid();

                INSERT INTO user_fleet (id, user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
                VALUES (v_new_aircraft_id, r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_capacity, 0, 0);

                UPDATE users SET cash = cash - v_deposit_amount WHERE id = r_bot.id;

                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (r_bot.id, 'expense', 'aircraft_lease', v_deposit_amount,
                    'Leased aircraft ' || v_model_name || ' with Call Sign: ' || v_tail || ' - Downpayment deposit',
                    r_bot.game_current_time);

                v_origin_iata := r_bot.hq_airport_iata;
                SELECT latitude, longitude INTO v_origin_lat, v_origin_lon FROM airports WHERE iata = v_origin_iata;
                SELECT iata INTO v_dest_iata FROM airports WHERE iata != v_origin_iata ORDER BY demand_index DESC, random() LIMIT 1;

                IF v_dest_iata IS NOT NULL THEN
                    SELECT latitude, longitude INTO v_dest_lat, v_dest_lon FROM airports WHERE iata = v_dest_iata;
                    v_distance := haversine_distance(v_origin_lat, v_origin_lon, v_dest_lat, v_dest_lon);

                    INSERT INTO user_routes (user_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week)
                    VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, 150.00, v_new_aircraft_id, 14)
                    ON CONFLICT DO NOTHING;
                END IF;
            END IF;
        END IF;

        v_buffered_rev_accum := 0.0;

        FOR r_route IN
            SELECT r.*, m.fuel_burn_per_km, m.speed_kmh, m.capacity, f.id AS fleet_aircraft_id, f.condition, f.status AS fleet_status
            FROM user_routes r
            JOIN user_fleet f ON r.assigned_aircraft_id = f.id
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            WHERE r.user_id = r_bot.id
        LOOP
            IF COALESCE(r_route.condition, 0.00) < COALESCE(r_bot.auto_grounding_threshold, 40.00) OR COALESCE(r_route.fleet_status, 'grounded') != 'active' THEN
                UPDATE user_fleet SET status = 'grounded' WHERE id = r_route.fleet_aircraft_id;
                CONTINUE;
            END IF;

            v_flights := LEAST(r_route.flights_per_week, 168);
            v_flight_duration := COALESCE((r_route.distance_km / NULLIF(r_route.speed_kmh, 0)), 0.0) + 1.0;

            IF (v_flights * v_flight_duration) > 168.0 THEN
                v_flights := FLOOR(168.0 / v_flight_duration);
            END IF;

            v_demand_multiplier := 1.5 - 0.8 * POWER((COALESCE(r_route.ticket_price, 0.00) / NULLIF((50.0 + (COALESCE(r_route.distance_km, 0.0) * 0.12)), 0)), 2);
            v_demand_multiplier := GREATEST(0.0, LEAST(1.5, v_demand_multiplier));

            v_ticket_revenue := v_flights * r_route.ticket_price * LEAST(r_route.capacity, FLOOR((50 + 50) * v_demand_multiplier * 10));
            v_fuel_cost := COALESCE(v_flights * r_route.distance_km * r_route.fuel_burn_per_km * v_fuel_price, 0.00);
            v_wear_per_flight := 0.50 + (COALESCE(r_route.distance_km, 0.0) * 0.0001);

            v_daily_revenue := v_ticket_revenue;
            v_daily_expense := v_fuel_cost;
            v_daily_profit := v_daily_revenue - v_daily_expense;

            v_buffered_rev_accum := v_buffered_rev_accum + v_daily_revenue;

            UPDATE user_routes SET
                load_factor = LEAST(100.0, GREATEST(0.0, v_demand_multiplier * 66.67)),
                expected_passengers = FLOOR(LEAST(r_route.capacity, FLOOR((100) * v_demand_multiplier * 10))),
                demand_multiplier = v_demand_multiplier,
                weekly_ask = v_flights * r_route.capacity * r_route.distance_km,
                weekly_rpk = v_flights * FLOOR(LEAST(r_route.capacity, FLOOR((100) * v_demand_multiplier * 10))) * r_route.distance_km
            WHERE id = r_route.id;

            UPDATE user_fleet SET condition = GREATEST(0.0, condition - (v_wear_per_flight * v_flights))
            WHERE id = r_route.fleet_aircraft_id;

            IF r_route.condition < r_bot.auto_grounding_threshold THEN
                UPDATE user_fleet SET status = 'grounded' WHERE id = r_route.fleet_aircraft_id;
            END IF;
        END LOOP;

        IF v_buffered_rev_accum > 0 THEN
            INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
            VALUES (r_bot.id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active bot routes', date_trunc('day', v_game_current_time_new));
        END IF;

        UPDATE users SET
            cash = cash + v_daily_profit,
            net_worth = cash + (SELECT COALESCE(SUM(purchase_price), 0) FROM user_fleet WHERE user_id = r_bot.id),
            game_current_time = v_game_current_time_new,
            last_active_at = NOW()
        WHERE id = r_bot.id;

        IF r_bot.cash < 0.00 THEN
            UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1, operational_status = 'Distress' WHERE id = r_bot.id;
        ELSE
            UPDATE users SET consecutive_negative_days = 0, operational_status = 'Active' WHERE id = r_bot.id;
        END IF;

        IF r_bot.consecutive_negative_days >= 30 THEN
            UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 9. process_all_bots_simulation_segment — renamed from process_all_bots_simulation_to_time
-- ============================================================================
-- This was the original name in migration 42, renamed in migration 45.
-- process_world_tick now calls process_all_bots_simulation_to_time (which
-- migration 101 already rewrote). This segment function is unused but we
-- rewrite it to delegate for safety.
CREATE OR REPLACE FUNCTION process_all_bots_simulation_segment(
    p_target_game_time TIMESTAMP WITH TIME ZONE,
    p_season_id UUID DEFAULT NULL
)
RETURNS INT AS $$
BEGIN
    RETURN process_all_bots_simulation_to_time(p_target_game_time, p_season_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;


COMMIT;
