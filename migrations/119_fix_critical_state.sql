-- Migration 119: Fix critical state issues found in audit
-- ==========================================================

-- Fix 1: process_world_tick is already SECURITY DEFINER (verified).
-- No change needed.

-- Fix 2: credit_score_history sub-scores always 0
-- process_credit_at_day_boundary INSERT was missing sub-score columns
CREATE OR REPLACE FUNCTION public.process_credit_at_day_boundary(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
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
$function$;

-- Fix 3: world_tick_log dead columns (real_seconds_processed, game_seconds_processed, message)
CREATE OR REPLACE FUNCTION public.process_world_tick(
    p_season_id UUID DEFAULT NULL,
    p_max_ticks INT DEFAULT 10
) RETURNS TABLE (
    season_id UUID,
    ticks_processed INT,
    game_time_after TIMESTAMPTZ,
    players_processed INT,
    bots_processed INT
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
DECLARE
    r_season RECORD;
    v_game_time_after TIMESTAMPTZ;
    v_ticks_processed INT := 0;
    v_players_processed INT := 0;
    v_bots_processed INT := 0;
    r_user RECORD;
    r_player_result RECORD;
    v_lock_key BIGINT;
    v_start_time TIMESTAMPTZ;
BEGIN
    IF p_season_id IS NOT NULL THEN
        SELECT * INTO r_season FROM season_clock WHERE id = p_season_id;
    ELSE
        SELECT * INTO r_season FROM season_clock WHERE status = 'active' LIMIT 1;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active season found';
    END IF;

    v_lock_key := hashtext(r_season.id::text);
    IF NOT pg_try_advisory_lock(v_lock_key) THEN
        RAISE EXCEPTION 'World tick already in progress for season %', r_season.id;
    END IF;

    v_start_time := NOW();

    v_game_time_after := r_season.current_game_time +
        (r_season.tick_interval_seconds * r_season.time_scale_multiplier * INTERVAL '1 second');

    PERFORM generate_game_events(v_game_time_after);
    PERFORM deactivate_expired_events(v_game_time_after);

    FOR r_user IN
        SELECT u.id, u.game_current_time
        FROM users u
        WHERE u.season_id = r_season.id
          AND u.actor_type = 'REAL'
          AND u.operational_status != 'Bankrupt'
    LOOP
        SELECT *
        INTO r_player_result
        FROM process_player_simulation_to_time(r_user.id, v_game_time_after)
        LIMIT 1;
        IF COALESCE(r_player_result.elapsed_days, 0.0) > 0.0 THEN
            v_players_processed := v_players_processed + 1;
        END IF;
    END LOOP;

    v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);

    IF date_trunc('day', r_season.current_game_time)::DATE <>
       date_trunc('day', v_game_time_after)::DATE THEN
        PERFORM record_rank_snapshot(date_trunc('day', v_game_time_after)::DATE);
    END IF;

    UPDATE season_clock SET
        current_game_time = v_game_time_after,
        last_tick_at = NOW(),
        updated_at = NOW()
    WHERE id = r_season.id;

    INSERT INTO world_tick_log (
        season_id, started_at, finished_at,
        game_time_before, game_time_after,
        ticks_processed, players_processed, bots_processed,
        status,
        real_seconds_processed, game_seconds_processed, message
    ) VALUES (
        r_season.id, v_start_time, NOW(),
        r_season.current_game_time, v_game_time_after,
        1, v_players_processed, v_bots_processed,
        'success',
        EXTRACT(EPOCH FROM (NOW() - v_start_time)),
        EXTRACT(EPOCH FROM (v_game_time_after - r_season.current_game_time)),
        'Tick completed successfully'
    );

    PERFORM pg_advisory_unlock(v_lock_key);

    season_id := r_season.id;
    ticks_processed := 1;
    game_time_after := v_game_time_after;
    players_processed := v_players_processed;
    bots_processed := v_bots_processed;
    RETURN NEXT;
END;
$function$;

-- Fix 4: Drop orphaned scheduler_config table
DROP TABLE IF EXISTS scheduler_config CASCADE;

-- Fix 5: Drop _desc columns from global_game_settings
ALTER TABLE global_game_settings DROP COLUMN IF EXISTS starting_cash_desc;
ALTER TABLE global_game_settings DROP COLUMN IF EXISTS fuel_price_per_liter_desc;
ALTER TABLE global_game_settings DROP COLUMN IF EXISTS absolute_minimum_safety_limit_desc;
ALTER TABLE global_game_settings DROP COLUMN IF EXISTS max_bot_count_desc;
ALTER TABLE global_game_settings DROP COLUMN IF EXISTS base_lease_deposit_percentage_desc;

-- Fix 6: Grant SELECT on world_tick_log to authenticated
GRANT SELECT ON world_tick_log TO authenticated;

-- Fix 7: Fix loan payment processing
-- Aircraft financing loans have weekly_payment=0 but monthly_payment>0.
-- The old function would "pay" 0 every tick, never reducing the balance.
-- Fix: derive effective weekly payment from monthly_payment when weekly_payment is 0 or NULL.
CREATE OR REPLACE FUNCTION public.process_loan_payments(
    p_user_id UUID,
    p_game_date TIMESTAMPTZ
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog
AS $function$
DECLARE
    v_actor_type VARCHAR(10);
    r_loan RECORD;
    v_cash NUMERIC;
    v_payment NUMERIC;
    v_late_fee NUMERIC;
    v_effective_weekly NUMERIC;
BEGIN
    SELECT actor_type, cash INTO v_actor_type, v_cash FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN; END IF;

    FOR r_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id AND status = 'active'
        ORDER BY taken_at ASC
    LOOP
        -- Derive effective weekly payment:
        -- Use weekly_payment if > 0, otherwise approximate from monthly_payment
        IF COALESCE(r_loan.weekly_payment, 0) > 0 THEN
            v_effective_weekly := r_loan.weekly_payment;
        ELSIF COALESCE(r_loan.monthly_payment, 0) > 0 THEN
            v_effective_weekly := r_loan.monthly_payment / 4.33;
        ELSE
            -- No payment amount defined; skip this loan
            CONTINUE;
        END IF;

        IF v_actor_type = 'AI' THEN
            IF v_cash >= v_effective_weekly THEN
                UPDATE users SET cash = cash - v_effective_weekly WHERE id = p_user_id;
                v_cash := v_cash - v_effective_weekly;
                UPDATE loans SET remaining_balance = remaining_balance - v_effective_weekly WHERE id = r_loan.id;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0 WHERE id = r_loan.id;
                END IF;
            ELSE
                UPDATE loans SET remaining_balance = remaining_balance * 1.10,
                                 missed_payments = missed_payments + 1 WHERE id = r_loan.id;
                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
                END IF;
            END IF;
        ELSE
            v_payment := v_effective_weekly;
            IF v_cash >= v_payment THEN
                v_cash := v_cash - v_payment;
                UPDATE users SET cash = v_cash WHERE id = p_user_id;
                UPDATE loans SET remaining_balance = remaining_balance - v_payment WHERE id = r_loan.id;
                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (p_user_id, 'expense', 'loan_payment', v_payment, 'Weekly loan payment', p_game_date);
                PERFORM ensure_checking_account(p_user_id);
                INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date)
                SELECT ba.id, p_user_id, 'payment', v_payment,
                       (SELECT u.cash FROM users u WHERE u.id = p_user_id),
                       'Weekly loan payment',
                       p_game_date
                FROM bank_accounts ba
                WHERE ba.user_id = p_user_id AND ba.account_type = 'checking'
                LIMIT 1;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0 WHERE id = r_loan.id;
                END IF;
            ELSE
                v_late_fee := v_payment * 0.10;
                UPDATE loans SET remaining_balance = remaining_balance + v_late_fee,
                                 missed_payments = missed_payments + 1 WHERE id = r_loan.id;
                INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date)
                VALUES (p_user_id, 'expense', 'loan_late_fee', v_late_fee, 'Loan payment late fee', p_game_date);
                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
                    IF r_loan.collateral_aircraft_id IS NOT NULL THEN
                        UPDATE fleet_aircraft SET status = 'grounded' WHERE id = r_loan.collateral_aircraft_id;
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$function$;
