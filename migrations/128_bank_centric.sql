-- Migration 128: Bank-centric financial architecture — clean break
-- ============================================================================
-- Target:
--   bank_accounts.account_type = 'operating' (ONE per user) = canonical balance
--   bank_transactions = single source of truth + IFRS categories
--   users.cash = DROPPED
--   users.net_worth = KEPT (derived, updated by trigger)
--   financial_ledger = DROPPED
--   financial_ledger_summary = DROPPED
-- ============================================================================

BEGIN;

-- ============================================================================
-- Part 1: Schema Changes
-- ============================================================================

-- 1a. Add IFRS columns to bank_transactions
ALTER TABLE bank_transactions ADD COLUMN IF NOT EXISTS ifrs_category VARCHAR(30);
ALTER TABLE bank_transactions ADD COLUMN IF NOT EXISTS ifrs_subcategory VARCHAR(50);
ALTER TABLE bank_transactions ADD COLUMN IF NOT EXISTS cost_center_type VARCHAR(20);
ALTER TABLE bank_transactions ADD COLUMN IF NOT EXISTS cost_center_id UUID;

-- 1b. Expand account_type check constraint, then rename all to 'operating'
-- First, delete orphaned 'checking' accounts if user also has 'savings'
DELETE FROM bank_transactions WHERE account_id IN (
    SELECT ba2.id FROM bank_accounts ba2
    WHERE ba2.account_type = 'checking'
    AND EXISTS (
        SELECT 1 FROM bank_accounts ba1
        WHERE ba1.user_id = ba2.user_id AND ba1.account_type = 'savings'
    )
);
DELETE FROM bank_accounts ba2
WHERE ba2.account_type = 'checking'
AND EXISTS (
    SELECT 1 FROM bank_accounts ba1
    WHERE ba1.user_id = ba2.user_id AND ba1.account_type = 'savings'
);
-- Rename any remaining 'checking' to 'savings' first (merge)
UPDATE bank_accounts SET account_type = 'savings' WHERE account_type = 'checking';
-- Now expand constraint and rename to 'operating'
ALTER TABLE bank_accounts DROP CONSTRAINT IF EXISTS bank_accounts_account_type_check;
ALTER TABLE bank_accounts ADD CONSTRAINT bank_accounts_account_type_check
    CHECK (account_type IN ('checking', 'savings', 'operating'));
UPDATE bank_accounts SET account_type = 'operating' WHERE account_type = 'savings';
-- Tighten constraint to only allow 'operating'
ALTER TABLE bank_accounts DROP CONSTRAINT IF EXISTS bank_accounts_account_type_check;
ALTER TABLE bank_accounts ADD CONSTRAINT bank_accounts_account_type_check
    CHECK (account_type = 'operating');

-- 1c. Drop interest_rate from bank_accounts
ALTER TABLE bank_accounts DROP COLUMN IF EXISTS interest_rate;

-- 1d. Fix check constraints that reference old values
ALTER TABLE bank_transactions DROP CONSTRAINT IF EXISTS bank_transactions_transaction_type_check;
ALTER TABLE bank_transactions ADD CONSTRAINT bank_transactions_transaction_type_check
    CHECK (transaction_type IN ('deposit', 'withdrawal', 'transfer', 'interest', 'fee',
                                'disbursement', 'payment', 'debit', 'credit', 'refinance'));

ALTER TABLE world_tick_log DROP CONSTRAINT IF EXISTS world_tick_log_status_check;
ALTER TABLE world_tick_log ADD CONSTRAINT world_tick_log_status_check
    CHECK (status IN ('started', 'skipped', 'success', 'error', 'player_error'));

-- 1e. Add indexes
CREATE INDEX IF NOT EXISTS idx_bank_txn_ifrs ON bank_transactions(user_id, ifrs_category, game_date);
CREATE INDEX IF NOT EXISTS idx_bank_txn_cost_center ON bank_transactions(cost_center_type, cost_center_id);


-- ============================================================================
-- Part 2: Drop Old Tables and Columns
-- ============================================================================

DROP TABLE IF EXISTS financial_ledger_summary CASCADE;
DROP TABLE IF EXISTS financial_ledger CASCADE;
-- Drop triggers that depend on users.cash before dropping the column
DROP TRIGGER IF EXISTS trg_user_cash_change ON users;
DROP TRIGGER IF EXISTS trg_sync_cash_to_bank ON users;
DROP TRIGGER IF EXISTS sync_checking_balance ON users;
ALTER TABLE users DROP COLUMN IF EXISTS cash CASCADE;

-- Unschedule cron job that references financial_ledger compaction
DO $$ BEGIN PERFORM cron.unschedule('skyward_compact_financial_ledger'); EXCEPTION WHEN OTHERS THEN NULL; END $$;

DROP FUNCTION IF EXISTS deposit_to_savings(NUMERIC) CASCADE;
DROP FUNCTION IF EXISTS withdraw_from_savings(NUMERIC) CASCADE;
DROP FUNCTION IF EXISTS create_savings_account() CASCADE;
DROP FUNCTION IF EXISTS ensure_checking_account(UUID) CASCADE;
DROP FUNCTION IF EXISTS ensure_savings_account(UUID) CASCADE;
DROP FUNCTION IF EXISTS compact_financial_ledger(BOOLEAN) CASCADE;
DROP FUNCTION IF EXISTS get_financial_ledger_compaction_report() CASCADE;
DROP FUNCTION IF EXISTS trg_sync_checking_balance() CASCADE;
DROP FUNCTION IF EXISTS reconcile_all_net_worths() CASCADE;


-- ============================================================================
-- Part 3: Create Helper Functions
-- ============================================================================

CREATE OR REPLACE FUNCTION public.debit_bank_account(
    p_user_id UUID,
    p_amount NUMERIC,
    p_ifrs_category VARCHAR(30),
    p_ifrs_subcategory VARCHAR(50),
    p_description TEXT,
    p_game_date TIMESTAMPTZ,
    p_cost_center_type VARCHAR(20) DEFAULT NULL,
    p_cost_center_id UUID DEFAULT NULL
) RETURNS NUMERIC
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    v_account_id UUID;
    v_new_balance NUMERIC;
BEGIN
    SELECT id INTO v_account_id
    FROM bank_accounts
    WHERE user_id = p_user_id AND account_type = 'operating'
    LIMIT 1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'No operating bank account for user %', p_user_id;
    END IF;

    UPDATE bank_accounts
    SET balance = balance - p_amount
    WHERE id = v_account_id
    RETURNING balance INTO v_new_balance;

    INSERT INTO bank_transactions (
        account_id, user_id, transaction_type, amount, balance_after,
        description, game_date, ifrs_category, ifrs_subcategory,
        cost_center_type, cost_center_id
    ) VALUES (
        v_account_id, p_user_id, 'debit', -p_amount, v_new_balance,
        p_description, p_game_date, p_ifrs_category, p_ifrs_subcategory,
        p_cost_center_type, p_cost_center_id
    );

    RETURN v_new_balance;
END;
$$;


CREATE OR REPLACE FUNCTION public.credit_bank_account(
    p_user_id UUID,
    p_amount NUMERIC,
    p_ifrs_category VARCHAR(30),
    p_ifrs_subcategory VARCHAR(50),
    p_description TEXT,
    p_game_date TIMESTAMPTZ,
    p_cost_center_type VARCHAR(20) DEFAULT NULL,
    p_cost_center_id UUID DEFAULT NULL
) RETURNS NUMERIC
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
    v_account_id UUID;
    v_new_balance NUMERIC;
BEGIN
    SELECT id INTO v_account_id
    FROM bank_accounts
    WHERE user_id = p_user_id AND account_type = 'operating'
    LIMIT 1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'No operating bank account for user %', p_user_id;
    END IF;

    UPDATE bank_accounts
    SET balance = balance + p_amount
    WHERE id = v_account_id
    RETURNING balance INTO v_new_balance;

    INSERT INTO bank_transactions (
        account_id, user_id, transaction_type, amount, balance_after,
        description, game_date, ifrs_category, ifrs_subcategory,
        cost_center_type, cost_center_id
    ) VALUES (
        v_account_id, p_user_id, 'credit', p_amount, v_new_balance,
        p_description, p_game_date, p_ifrs_category, p_ifrs_subcategory,
        p_cost_center_type, p_cost_center_id
    );

    RETURN v_new_balance;
END;
$$;


CREATE OR REPLACE FUNCTION public.get_user_balance(p_user_id UUID)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(balance, 0)
    FROM bank_accounts
    WHERE user_id = p_user_id AND account_type = 'operating'
    LIMIT 1;
$$;


-- ============================================================================
-- Part 4: New Triggers
-- ============================================================================

CREATE OR REPLACE FUNCTION public.trg_create_default_bank_account()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO bank_accounts (user_id, account_type, balance)
    VALUES (NEW.id, 'operating', 15000000.00)
    ON CONFLICT (user_id, account_type) DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE TRIGGER create_default_bank_account
    AFTER INSERT ON users
    FOR EACH ROW EXECUTE FUNCTION trg_create_default_bank_account();


CREATE OR REPLACE FUNCTION public.trg_fleet_reconcile_net_worth()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_user_id UUID;
    v_fleet_value NUMERIC;
    v_cash NUMERIC;
BEGIN
    v_user_id := COALESCE(NEW.user_id, OLD.user_id);

    SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
    INTO v_fleet_value
    FROM fleet_aircraft f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.user_id = v_user_id AND f.acquisition_type = 'purchase';

    SELECT COALESCE(balance, 0) INTO v_cash
    FROM bank_accounts
    WHERE user_id = v_user_id AND account_type = 'operating'
    LIMIT 1;

    UPDATE users SET net_worth = v_cash + v_fleet_value WHERE id = v_user_id;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER fleet_reconcile_net_worth
    AFTER INSERT OR UPDATE OR DELETE ON fleet_aircraft
    FOR EACH ROW EXECUTE FUNCTION trg_fleet_reconcile_net_worth();


CREATE OR REPLACE FUNCTION public.trg_update_user_net_worth()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_fleet_value NUMERIC;
BEGIN
    SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
    INTO v_fleet_value
    FROM fleet_aircraft f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.user_id = NEW.id AND f.acquisition_type = 'purchase';

    NEW.net_worth := get_user_balance(NEW.id) + v_fleet_value;
    RETURN NEW;
END;
$$;


-- ============================================================================
-- Part 5: Drop old triggers
-- ============================================================================

DROP TRIGGER IF EXISTS sync_checking_balance ON users;


-- ============================================================================
-- Part 6: Rewrite ALL Mutation RPCs
-- ============================================================================


-- ── 6.01 purchase_aircraft (6-param internal) ──

CREATE OR REPLACE FUNCTION public.purchase_aircraft(
    p_user_id uuid, p_model_id uuid, p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
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
    RETURN QUERY SELECT TRUE, 'Successfully purchased ' || v_model_name || ' [' || v_tail || ']'::VARCHAR, v_cash;
END;
$function$;


-- ── 6.02 purchase_aircraft (5-param frontend overload) ──

CREATE OR REPLACE FUNCTION public.purchase_aircraft(
    p_model_id uuid, p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM purchase_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;


-- ── 6.03 lease_aircraft (6-param internal) ──

CREATE OR REPLACE FUNCTION public.lease_aircraft(
    p_user_id uuid, p_model_id uuid, p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
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

    SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1;
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
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


-- ── 6.04 lease_aircraft (5-param frontend overload) ──

CREATE OR REPLACE FUNCTION public.lease_aircraft(
    p_model_id uuid, p_nickname character varying,
    p_economy_seats integer DEFAULT NULL::integer,
    p_business_seats integer DEFAULT 0,
    p_first_class_seats integer DEFAULT 0
)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM lease_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;


-- ── 6.05 sell_aircraft (2-param internal) ──

CREATE OR REPLACE FUNCTION public.sell_aircraft(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_user RECORD; v_fleet RECORD;
    v_base_value NUMERIC(20,2); v_age_years NUMERIC; v_depreciation_factor NUMERIC;
    v_sale_value NUMERIC(20,2);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;

    SELECT f.*, m.model_name, m.purchase_price
    INTO v_fleet FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;

    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'purchase' THEN
        RETURN QUERY SELECT FALSE, 'Only owned aircraft can be sold.'::VARCHAR, NULL::NUMERIC; RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC; RETURN;
    END IF;

    v_base_value := v_fleet.purchase_price * (v_fleet.condition / 100.00);
    IF v_fleet.acquired_game_date IS NOT NULL AND v_user.game_current_time IS NOT NULL THEN
        v_age_years := EXTRACT(EPOCH FROM (v_user.game_current_time - v_fleet.acquired_game_date)) / (365.25 * 86400.0);
        v_depreciation_factor := GREATEST(0.10, 1.0 - (0.05 * COALESCE(v_age_years, 0)));
        v_sale_value := ROUND(v_base_value * v_depreciation_factor, 2);
    ELSE
        v_sale_value := v_base_value;
    END IF;

    PERFORM credit_bank_account(p_user_id, v_sale_value, 'investing', 'aircraft_sale',
        'Sold aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
        v_user.game_current_time);

    DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;

    new_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT TRUE, 'Aircraft sold for $' || ROUND(v_sale_value, 2)::TEXT || '.'::VARCHAR, new_cash;
END;
$function$;


-- ── 6.06 sell_aircraft (1-param frontend overload) ──

CREATE OR REPLACE FUNCTION public.sell_aircraft(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM sell_aircraft(v_user_id, p_fleet_id);
END;
$function$;


-- ── 6.07 repair_aircraft (2-param internal) ──

CREATE OR REPLACE FUNCTION public.repair_aircraft(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_cash NUMERIC; v_condition NUMERIC; v_purchase_price NUMERIC; v_lease_price NUMERIC;
    v_model_name VARCHAR; v_repair_cost NUMERIC; v_acquisition_type VARCHAR; v_game_time TIMESTAMPTZ;
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT f.condition, f.acquisition_type, m.purchase_price, m.lease_price_per_month, m.model_name
    INTO v_condition, v_acquisition_type, v_purchase_price, v_lease_price, v_model_name
    FROM fleet_aircraft f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id;

    v_cash := get_user_balance(p_user_id);
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_user_id FOR UPDATE;

    IF v_model_name IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, v_cash; RETURN;
    END IF;
    IF v_condition >= 100.00 THEN
        RETURN QUERY SELECT FALSE, ('Aircraft ' || v_model_name || ' is already in pristine condition.')::VARCHAR, v_cash; RETURN;
    END IF;

    v_repair_cost := CASE
        WHEN v_acquisition_type = 'lease' THEN (100.00 - v_condition) * (COALESCE(v_lease_price, 0.00) * 0.50)
        ELSE (100.00 - v_condition) * (COALESCE(v_purchase_price, 0.00) * 0.0005)
    END;

    IF v_cash < v_repair_cost THEN
        RETURN QUERY SELECT FALSE, ('Insufficient funds for repair. Required: $' || ROUND(v_repair_cost, 2))::VARCHAR, v_cash; RETURN;
    END IF;

    PERFORM debit_bank_account(p_user_id, v_repair_cost, 'cogs', 'maintenance',
        'Maintenance completed for ' || v_model_name || ' - restored from ' || ROUND(v_condition::numeric, 2) || '% to 100%',
        v_game_time);

    UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = p_fleet_id;

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT TRUE, 'Aircraft maintenance complete. Health restored to 100%!'::VARCHAR, v_cash;
END;
$function$;


-- ── 6.08 repair_aircraft (1-param frontend overload) ──

CREATE OR REPLACE FUNCTION public.repair_aircraft(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM repair_aircraft(v_user_id, p_fleet_id);
END;
$function$;


-- ── 6.09 terminate_aircraft_lease (2-param internal) ──

CREATE OR REPLACE FUNCTION public.terminate_aircraft_lease(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_user RECORD; v_fleet RECORD; v_exit_fee NUMERIC(20,2);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);
    SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;

    SELECT f.*, m.model_name, m.lease_price_per_month
    INTO v_fleet FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.id = p_fleet_id AND f.user_id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;

    IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'lease' THEN
        RETURN QUERY SELECT FALSE, 'Only leased aircraft can be terminated through this action.'::VARCHAR, NULL::NUMERIC; RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
        RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC; RETURN;
    END IF;

    v_exit_fee := calculate_lease_termination_fee(v_fleet.lease_price_per_month);

    IF v_exit_fee > 0 THEN
        PERFORM debit_bank_account(p_user_id, v_exit_fee, 'opex', 'lease_termination',
            'Terminated leased aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
            date_trunc('day', v_user.game_current_time));
    END IF;

    DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;

    new_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT TRUE, 'Lease terminated successfully!'::VARCHAR, new_cash;
END;
$function$;


-- ── 6.10 terminate_aircraft_lease (1-param frontend overload) ──

CREATE OR REPLACE FUNCTION public.terminate_aircraft_lease(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM terminate_aircraft_lease(v_user_id, p_fleet_id);
END;
$function$;


-- ── 6.11 take_loan (5-param internal) ──

CREATE OR REPLACE FUNCTION public.take_loan(
    p_user_id uuid, p_principal numeric,
    p_term_weeks integer DEFAULT 52,
    p_loan_type character varying DEFAULT 'unsecured',
    p_collateral_aircraft_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_actor_type VARCHAR(10); v_existing_loans INT; v_credit_score INT;
    v_score_record RECORD; v_tier VARCHAR(10); v_config JSONB; v_tier_cfg JSONB;
    v_min_loan NUMERIC; v_max_loans INT; v_interest_rate NUMERIC;
    v_weekly_payment NUMERIC; v_total_repayable NUMERIC; v_cash NUMERIC;
    v_game_time TIMESTAMPTZ; v_max_principal NUMERIC; v_rate_key TEXT; v_loan_id UUID;
BEGIN
    SELECT u.actor_type, u.credit_score, u.game_current_time
    INTO v_actor_type, v_credit_score, v_game_time
    FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;

    IF v_actor_type = 'AI' THEN
        SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active';
        IF v_existing_loans >= 3 THEN RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC; RETURN; END IF;
        IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN QUERY SELECT false, 'Bot loan amount must be between $100K and $5M.'::TEXT, 0::NUMERIC; RETURN; END IF;
        v_interest_rate := 0.05;
        v_total_repayable := p_principal * (1 + v_interest_rate);
        v_weekly_payment := v_total_repayable / p_term_weeks;
        INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, game_date_taken, status, loan_type, credit_score_at_origination)
        VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, v_game_time, 'active', 'unsecured', v_credit_score)
        RETURNING id INTO v_loan_id;
        PERFORM credit_bank_account(p_user_id, p_principal, 'financing', 'loan_disbursement',
            'Loan disbursement', v_game_time);
        v_cash := get_user_balance(p_user_id);
        RETURN QUERY SELECT true, 'Loan disbursed.'::TEXT, v_cash;
        RETURN;
    END IF;

    SELECT credit_tier_config INTO v_config FROM global_game_settings WHERE id = 1;
    v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
    v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);

    SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active';
    IF v_existing_loans >= v_max_loans THEN
        RETURN QUERY SELECT false, 'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    v_credit_score := COALESCE(v_credit_score, 500);

    SELECT * INTO v_score_record FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF FOUND THEN v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE v_tier := resolve_credit_tier(v_credit_score); END IF;

    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);

    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
        RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    IF p_loan_type = 'unsecured' THEN
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC; RETURN;
        END IF;
        v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
    ELSE
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000) * 0.5;
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07) + 0.02;
    END IF;

    IF p_principal < v_min_loan THEN
        RETURN QUERY SELECT false, 'Minimum loan amount is $' || v_min_loan::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;
    IF p_principal > v_max_principal THEN
        RETURN QUERY SELECT false, 'Maximum for ' || v_tier || ' tier ' || p_loan_type || ' loan is $' || v_max_principal::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
    END IF;

    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, game_date_taken, status, loan_type, collateral_aircraft_id, credit_score_at_origination)
    VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, v_game_time, 'active', p_loan_type, p_collateral_aircraft_id, v_credit_score)
    RETURNING id INTO v_loan_id;

    PERFORM credit_bank_account(p_user_id, p_principal, 'financing', 'loan_disbursement',
        'Loan disbursement', v_game_time);

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Loan disbursed at ' || ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT, v_cash;
END;
$function$;


-- ── 6.12 take_loan (4-param frontend overload) ──

CREATE OR REPLACE FUNCTION public.take_loan(
    p_principal numeric, p_term_weeks integer DEFAULT 52,
    p_loan_type character varying DEFAULT 'unsecured',
    p_collateral_aircraft_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := require_current_user_id();
    RETURN QUERY SELECT * FROM take_loan(v_user_id, p_principal, p_term_weeks, p_loan_type, p_collateral_aircraft_id);
END;
$function$;


-- ── 6.13 finance_aircraft (4-param internal) ──

CREATE OR REPLACE FUNCTION public.finance_aircraft(
    p_user_id uuid, p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20,
    p_term_months integer DEFAULT 36
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
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

    SELECT u.actor_type, u.credit_score, u.game_current_time, u.hq_airport_iata, u.archetype
    INTO v_actor_type, v_credit_score, v_game_time, v_hq_iata, v_archetype
    FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;

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

        INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
        VALUES (p_user_id, p_aircraft_model_id, v_model.model_name, 'BOT-' || left(p_user_id::text, 4), 'finance', 100.00, 'active', v_economy_seats, v_business_seats, v_first_seats)
        RETURNING id INTO v_fleet_id;

        INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made)
        VALUES (p_user_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0);

        v_cash := get_user_balance(p_user_id);
        RETURN QUERY SELECT true, 'Aircraft financed (bot).'::TEXT, v_cash;
        RETURN;
    END IF;

    v_cash := get_user_balance(p_user_id);
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

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made)
    VALUES (p_user_id, v_principal, v_interest_rate, v_total_repayable, 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0);

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$function$;


-- ── 6.14 finance_aircraft (3-param frontend overload) ──

CREATE OR REPLACE FUNCTION public.finance_aircraft(
    p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20,
    p_term_months integer DEFAULT 36
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := require_current_user_id();
    RETURN QUERY SELECT * FROM finance_aircraft(v_user_id, p_aircraft_model_id, p_down_payment_pct, p_term_months);
END;
$function$;


-- ── 6.15 repay_loan ──

CREATE OR REPLACE FUNCTION public.repay_loan(p_loan_id uuid, p_amount numeric DEFAULT NULL::numeric)
RETURNS TABLE(success boolean, message text, new_cash numeric, paid_off boolean)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog AS $function$
DECLARE
    v_user_id UUID; v_loan RECORD; v_payment NUMERIC; v_cash NUMERIC;
    v_is_paid_off BOOLEAN := false;
BEGIN
    v_user_id := require_current_user_id();
    SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'Loan not found or already paid off.'::TEXT, 0::NUMERIC, false; RETURN; END IF;

    IF p_amount IS NULL THEN v_payment := v_loan.remaining_balance;
    ELSE v_payment := LEAST(p_amount, v_loan.remaining_balance); END IF;

    IF v_payment <= 0 THEN RETURN QUERY SELECT false, 'Payment amount must be positive.'::TEXT, 0::NUMERIC, false; RETURN; END IF;

    v_cash := get_user_balance(v_user_id);
    IF v_cash < v_payment THEN
        RETURN QUERY SELECT false, 'Insufficient cash. Need $' || v_payment::TEXT || ', have $' || v_cash::TEXT || '.'::TEXT, v_cash, false; RETURN;
    END IF;

    PERFORM debit_bank_account(v_user_id, v_payment, 'financing', 'loan_repayment',
        CASE WHEN v_loan.remaining_balance - v_payment <= 0 THEN 'Loan fully repaid' ELSE 'Loan partial repayment' END,
        NOW());

    UPDATE loans
    SET remaining_balance = remaining_balance - v_payment,
        status = CASE WHEN remaining_balance - v_payment <= 0 THEN 'paid_off'::VARCHAR ELSE status END,
        paid_off_at = CASE WHEN remaining_balance - v_payment <= 0 THEN NOW() ELSE paid_off_at END
    WHERE id = p_loan_id;

    v_is_paid_off := (SELECT remaining_balance <= 0 FROM loans WHERE id = p_loan_id);

    v_cash := get_user_balance(v_user_id);
    RETURN QUERY SELECT true,
        CASE WHEN v_is_paid_off THEN 'Loan fully repaid!'
             ELSE 'Payment of $' || v_payment::TEXT || ' applied.' END::TEXT,
        v_cash, v_is_paid_off;
END;
$function$;

REVOKE ALL ON FUNCTION repay_loan(UUID, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION repay_loan(UUID, NUMERIC) TO authenticated;


-- ── 6.16 refinance_loan ──

CREATE OR REPLACE FUNCTION public.refinance_loan(p_loan_id uuid)
RETURNS TABLE(success boolean, message text, new_rate numeric, savings numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_user_id UUID; v_loan RECORD; v_new_rate NUMERIC; v_old_total NUMERIC; v_new_total NUMERIC;
    v_savings NUMERIC; v_tier VARCHAR; v_weekly_payment NUMERIC; v_monthly_payment NUMERIC;
    v_cash NUMERIC;
BEGIN
    v_user_id := require_current_user_id();
    SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';
    IF NOT FOUND THEN RETURN QUERY SELECT false, 'Loan not found or not active.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF;
    SELECT tier INTO v_tier FROM credit_scores WHERE user_id = v_user_id;
    v_new_rate := CASE COALESCE(v_tier, 'Standard')
        WHEN 'Platinum' THEN 0.03 WHEN 'Gold' THEN 0.04
        WHEN 'Silver' THEN 0.05 WHEN 'Standard' THEN 0.07
        ELSE 0.10
    END;
    IF v_new_rate >= v_loan.interest_rate THEN
        RETURN QUERY SELECT false, 'Current rate is not better than existing rate.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN;
    END IF;
    v_old_total := v_loan.remaining_balance;
    v_new_total := v_loan.principal * (1 + v_new_rate);
    v_savings := GREATEST(0, v_old_total - v_new_total);
    IF v_loan.term_months IS NOT NULL AND v_loan.term_months > 0 THEN
        v_monthly_payment := v_new_total / v_loan.term_months;
        v_weekly_payment := v_monthly_payment / 4.33;
    ELSE
        v_weekly_payment := v_new_total / 52;
        v_monthly_payment := v_weekly_payment * 4.33;
    END IF;
    UPDATE loans SET interest_rate = v_new_rate, remaining_balance = v_new_total,
        weekly_payment = v_weekly_payment, monthly_payment = v_monthly_payment
    WHERE id = p_loan_id;

    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after,
        description, game_date, ifrs_category, ifrs_subcategory)
    SELECT ba.id, v_user_id, 'refinance', 0, ba.balance,
        'Loan refinanced — new rate ' || ROUND(v_new_rate * 100, 1)::TEXT || '%',
        NOW(), 'financing', 'loan_refinance'
    FROM bank_accounts ba WHERE ba.user_id = v_user_id AND ba.account_type = 'operating' LIMIT 1;

    RETURN QUERY SELECT true, 'Loan refinanced successfully.'::TEXT, v_new_rate, v_savings;
END;
$function$;


-- ── 6.17 process_loan_payments ──

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
    SELECT actor_type INTO v_actor_type FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN; END IF;
    v_cash := get_user_balance(p_user_id);

    FOR r_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id AND status = 'active' AND loan_type != 'aircraft_financing'
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
                PERFORM debit_bank_account(p_user_id, v_effective_weekly, 'financing', 'loan_payment',
                    'Weekly loan payment', p_game_date);
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
                PERFORM debit_bank_account(p_user_id, v_payment, 'financing', 'loan_payment',
                    'Weekly loan payment', p_game_date);
                v_cash := v_cash - v_payment;
                UPDATE loans SET remaining_balance = remaining_balance - v_payment WHERE id = r_loan.id;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0 WHERE id = r_loan.id;
                END IF;
            ELSE
                v_late_fee := v_payment * 0.10;
                UPDATE loans SET remaining_balance = remaining_balance + v_late_fee,
                                 missed_payments = missed_payments + 1 WHERE id = r_loan.id;
                INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after,
                    description, game_date, ifrs_category, ifrs_subcategory)
                SELECT ba.id, p_user_id, 'late_fee', v_late_fee, ba.balance,
                    'Loan payment late fee', p_game_date, 'financing', 'loan_late_fee'
                FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'operating' LIMIT 1;
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


-- ── 6.18 process_aircraft_financing_payments ──

CREATE OR REPLACE FUNCTION public.process_aircraft_financing_payments(
    p_user_id uuid,
    p_game_date timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_loan RECORD;
    v_cash NUMERIC;
    v_payment NUMERIC;
    v_late_fee NUMERIC;
BEGIN
    v_cash := get_user_balance(p_user_id);

    FOR v_loan IN
        SELECT * FROM loans
        WHERE user_id = p_user_id AND loan_type = 'aircraft_financing' AND status = 'active'
    LOOP
        v_payment := v_loan.monthly_payment;

        IF v_cash >= v_payment THEN
            PERFORM debit_bank_account(p_user_id, v_payment, 'financing', 'financing_payment',
                'Aircraft financing payment', p_game_date);
            v_cash := v_cash - v_payment;
            UPDATE loans SET remaining_balance = remaining_balance - v_payment,
                             payments_made = payments_made + 1 WHERE id = v_loan.id;

            IF (SELECT remaining_balance FROM loans WHERE id = v_loan.id) <= 0 THEN
                UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0 WHERE id = v_loan.id;
            END IF;
        ELSE
            v_late_fee := v_payment * 0.05;
            UPDATE loans SET remaining_balance = remaining_balance + v_late_fee,
                             missed_payments = missed_payments + 1 WHERE id = v_loan.id;

            INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after,
                description, game_date, ifrs_category, ifrs_subcategory)
            SELECT ba.id, p_user_id, 'late_fee', v_late_fee, ba.balance,
                'Aircraft financing late fee', p_game_date, 'financing', 'financing_late_fee'
            FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'operating' LIMIT 1;

            IF (SELECT missed_payments FROM loans WHERE id = v_loan.id) >= 3 THEN
                UPDATE loans SET status = 'repossessed' WHERE id = v_loan.id;
                IF v_loan.fleet_aircraft_id IS NOT NULL THEN
                    UPDATE fleet_aircraft SET status = 'grounded' WHERE id = v_loan.fleet_aircraft_id;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$function$;


-- ── 6.19 accrue_savings_interest (no-op — operating accounts don't earn interest) ──

CREATE OR REPLACE FUNCTION public.accrue_savings_interest(
    p_user_id uuid,
    p_game_date timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql VOLATILE AS $function$
BEGIN
    -- No-op: operating accounts do not accrue interest
    RETURN;
END;
$function$;


-- ── 6.20 process_player_simulation_to_time ──

CREATE OR REPLACE FUNCTION public.process_player_simulation_to_time(
    p_user_id uuid,
    p_target_game_time timestamp with time zone
)
RETURNS TABLE(
    game_time timestamp with time zone,
    cash numeric,
    flights_run integer,
    elapsed_days numeric
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    r_user RECORD;
    v_route RECORD;
    v_flight_hours NUMERIC;
    v_revenue NUMERIC;
    v_ops_cost NUMERIC;
    v_lease_cost NUMERIC;
    v_net NUMERIC := 0;
    v_flights_run INT := 0;
    v_cash_after NUMERIC;
    v_elapsed_days NUMERIC;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_cargo_rev NUMERIC(20,2);
    v_turnaround_hours NUMERIC;
    v_demand_multiplier NUMERIC;
    v_crew_cost NUMERIC;
    v_fuel_price NUMERIC;
    v_seasonal_factor NUMERIC;
    v_fuel_price_multiplier NUMERIC := 1.0;
    v_maintenance_multiplier NUMERIC := 1.0;
    v_route_demand_event NUMERIC;
    v_route_capacity_event NUMERIC;
    v_effective_capacity NUMERIC;
    v_time_fraction NUMERIC;
    v_payment_periods INT;
    v_i INT;
    v_fuel_cost NUMERIC;
    v_crew_cost_total NUMERIC;
    v_maint_cost NUMERIC;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found: %', p_user_id; END IF;

    SELECT COALESCE(fuel_price_per_liter, 0.85), COALESCE(crew_cost_per_hour, 350.0)
    INTO v_fuel_price, v_crew_cost FROM global_game_settings LIMIT 1;

    SELECT COALESCE(effect_value, 1.0) INTO v_fuel_price_multiplier
    FROM game_events
    WHERE event_type = 'fuel_shock' AND is_active = true
      AND effect_type = 'fuel_price'
      AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_fuel_price_multiplier := 1.0; END IF;

    SELECT COALESCE(effect_value, 1.0) INTO v_maintenance_multiplier
    FROM game_events
    WHERE event_type = 'maintenance_shock' AND is_active = true
      AND effect_type = 'maintenance_cost'
      AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
    ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_maintenance_multiplier := 1.0; END IF;

    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;
    v_time_fraction := LEAST(v_elapsed_days / 7.0, 1.0);

    FOR v_route IN
        SELECT ur.*, am.fuel_burn_per_km, am.speed_kmh, am.turnaround_hours,
               am.capacity, am.lease_price_per_month, am.maintenance_cost_per_hour,
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
          AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
        ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_demand_event := 1.0; END IF;

        v_route_capacity_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_capacity_event
        FROM game_events
        WHERE event_type = 'weather_disruption' AND is_active = true
          AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
          AND start_game_time <= p_target_game_time AND end_game_time > p_target_game_time
        ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_capacity_event := 1.0; END IF;

        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
        v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
        IF v_flight_hours <= 0 THEN CONTINUE; END IF;

        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price) * v_route_demand_event;
        v_seasonal_factor := 1.0;
        v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);

        v_revenue := v_route.flights_per_week * v_route.ticket_price *
                     LEAST(v_effective_capacity,
                           FLOOR(v_effective_capacity * 0.95 * v_demand_multiplier * v_seasonal_factor));

        v_fuel_cost := v_route.flights_per_week * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
        v_crew_cost_total := v_route.flights_per_week * v_flight_hours * v_crew_cost;
        v_maint_cost := v_route.flights_per_week * v_route.distance_km * COALESCE(v_route.maintenance_cost_per_hour, 0) * COALESCE(v_maintenance_multiplier, 1.0) / NULLIF(v_route.speed_kmh, 0);

        v_ops_cost := v_fuel_cost + v_crew_cost_total + v_maint_cost;

        v_lease_cost := CASE
            WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                         WHERE fa2.id = v_route.assigned_aircraft_id
                           AND fa2.acquisition_type = 'lease')
            THEN COALESCE(v_route.lease_price_per_month, 0) * (v_elapsed_days / 30.0)
            ELSE 0
        END;

        v_revenue := v_revenue * v_time_fraction;
        v_ops_cost := v_ops_cost * v_time_fraction;

        v_cargo_rev := v_revenue * 0.05;

        PERFORM credit_bank_account(p_user_id, v_revenue + v_cargo_rev, 'revenue', 'ticket_revenue',
            'Route ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        PERFORM debit_bank_account(p_user_id, v_fuel_cost * v_time_fraction, 'cogs', 'fuel',
            'Fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        PERFORM debit_bank_account(p_user_id, v_crew_cost_total * v_time_fraction, 'cogs', 'crew',
            'Crew: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        PERFORM debit_bank_account(p_user_id, v_maint_cost * v_time_fraction, 'cogs', 'maintenance',
            'Maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

        IF v_lease_cost > 0 THEN
            PERFORM debit_bank_account(p_user_id, v_lease_cost, 'opex', 'aircraft_lease',
                'Lease: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
        END IF;

        v_wear_per_cycle := 0.50 + (v_route.distance_km * 0.0001);
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week * v_elapsed_days / 7.0;
        v_self_healing_credit := v_gross_damage * 0.10;
        v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

        UPDATE fleet_aircraft
        SET condition = GREATEST(0, condition - v_net_damage),
            total_flights = total_flights + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT
        WHERE id = v_route.assigned_aircraft_id;

        v_flights_run := v_flights_run + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
    END LOOP;

    v_net := get_user_balance(p_user_id) - COALESCE(r_user.net_worth, 0) + COALESCE(r_user.net_worth, 0);
    v_cash_after := get_user_balance(p_user_id);

    UPDATE users u
    SET game_current_time = p_target_game_time,
        last_active_at = NOW()
    WHERE u.id = p_user_id;

    -- Bankruptcy check for humans
    IF v_cash_after < -5000000.0 THEN
        UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
        UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
    END IF;

    IF v_elapsed_days >= 1.0 THEN
        v_payment_periods := GREATEST(1, FLOOR(v_elapsed_days / 7.0)::INT);
        FOR v_i IN 1..v_payment_periods LOOP
            PERFORM process_loan_payments(p_user_id, p_target_game_time);
            PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time);
        END LOOP;

        PERFORM accrue_savings_interest(p_user_id, p_target_game_time);
        PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time);
        PERFORM check_achievements(p_user_id, p_target_game_time);

        v_cash_after := get_user_balance(p_user_id);
        IF v_cash_after < 0 THEN
            UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1
            WHERE id = p_user_id;
            IF (SELECT consecutive_negative_days FROM users WHERE id = p_user_id) >= 30 THEN
                UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
                UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
            END IF;
        ELSE
            UPDATE users SET consecutive_negative_days = 0,
                             recovery_streak_days = recovery_streak_days + 1
            WHERE id = p_user_id;
        END IF;
    END IF;

    v_cash_after := get_user_balance(p_user_id);
    game_time := p_target_game_time;
    cash := v_cash_after;
    flights_run := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$function$;


-- ── 6.21 process_all_bots_simulation_to_time ──

CREATE OR REPLACE FUNCTION public.process_all_bots_simulation_to_time(
    p_target_game_time timestamp with time zone,
    p_season_id uuid DEFAULT NULL::uuid
)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    r_bot RECORD;
    v_game_sec DOUBLE PRECISION;
    v_game_days DOUBLE PRECISION;
    v_route RECORD;
    v_flights DOUBLE PRECISION;
    v_revenue NUMERIC(20,2) := 0;
    v_fuel_cost NUMERIC(20,2) := 0;
    v_maint_cost NUMERIC(20,2) := 0;
    v_crew_cost NUMERIC(20,2) := 0;
    v_total_cost NUMERIC(20,2) := 0;
    v_net NUMERIC(20,2) := 0;
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_turnaround_hours NUMERIC;
    v_lease_cost NUMERIC(20,2) := 0;
    v_fuel_price NUMERIC;
    v_fuel_price_multiplier NUMERIC;
    v_crew_cost_per_hour NUMERIC;
    v_absolute_minimum_safety_limit NUMERIC(5,2);
    v_effective_grounding_threshold NUMERIC(5,2);
    v_max_weekly_flights INT;
    v_wear_per_cycle NUMERIC(8,4);
    v_gross_damage NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage NUMERIC(20,4);
    v_cargo_rev NUMERIC(20,2);
    v_processed INT := 0;
    v_demand_multiplier NUMERIC;
    v_seasonal_multiplier NUMERIC;
BEGIN
    SELECT fuel_price_per_liter, absolute_minimum_safety_limit, COALESCE(crew_cost_per_hour, 350.0)
    INTO v_fuel_price, v_absolute_minimum_safety_limit, v_crew_cost_per_hour
    FROM global_game_settings LIMIT 1;

    v_fuel_price := COALESCE(v_fuel_price, 0.85);
    v_fuel_price_multiplier := 1.0;
    v_seasonal_multiplier := 1.0;

    FOR r_bot IN
        SELECT * FROM users
        WHERE actor_type = 'AI' AND COALESCE(operational_status, 'Active') != 'Bankrupt'
    LOOP
        v_effective_grounding_threshold := GREATEST(
            COALESCE(r_bot.auto_grounding_threshold, 40.00),
            v_absolute_minimum_safety_limit
        );

        v_game_sec := EXTRACT(EPOCH FROM (p_target_game_time - r_bot.game_current_time));
        v_game_days := v_game_sec / 86400.0;
        IF v_game_days <= 0 THEN CONTINUE; END IF;

        FOR v_route IN
            SELECT ra.*, am.fuel_burn_per_km, am.speed_kmh, am.capacity,
                   am.turnaround_hours, am.maintenance_cost_per_hour,
                   am.lease_price_per_month,
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
            v_flight_duration := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
            IF v_flight_duration <= 0 THEN CONTINUE; END IF;

            v_max_weekly_flights := FLOOR(168.0 / v_flight_duration)::INT;
            v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);

            v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price);
            v_passengers := LEAST(v_route.capacity,
                                  FLOOR(v_route.capacity * 0.95 * v_demand_multiplier * v_seasonal_multiplier));

            v_revenue := v_flights * v_route.ticket_price * v_passengers;
            v_fuel_cost := v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
            v_crew_cost := v_flights * v_flight_duration * v_crew_cost_per_hour;
            v_maint_cost := v_flights * v_route.distance_km * v_route.maintenance_cost_per_hour / NULLIF(v_route.speed_kmh, 0);
            v_cargo_rev := v_revenue * 0.05;
            v_lease_cost := CASE
                WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                             WHERE fa2.id = v_route.assigned_aircraft_id
                               AND fa2.acquisition_type = 'lease')
                THEN COALESCE(v_route.lease_price_per_month, 0) / 4.0
                ELSE 0
            END;

            PERFORM credit_bank_account(r_bot.id, v_revenue + v_cargo_rev, 'revenue', 'ticket_revenue',
                'Bot route ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            PERFORM debit_bank_account(r_bot.id, v_fuel_cost, 'cogs', 'fuel',
                'Bot fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            PERFORM debit_bank_account(r_bot.id, v_crew_cost, 'cogs', 'crew',
                'Bot crew: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            PERFORM debit_bank_account(r_bot.id, v_maint_cost, 'cogs', 'maintenance',
                'Bot maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);

            IF v_lease_cost > 0 THEN
                PERFORM debit_bank_account(r_bot.id, v_lease_cost, 'opex', 'aircraft_lease',
                    'Bot lease: ' || v_route.origin_iata || '-' || v_route.destination_iata, p_target_game_time);
            END IF;

            v_wear_per_cycle := 0.50 + (v_route.distance_km * 0.0001);
            v_gross_damage := v_wear_per_cycle * v_flights * v_game_days / 7.0;
            v_self_healing_credit := v_gross_damage * 0.10;
            v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

            UPDATE fleet_aircraft
            SET condition = GREATEST(0, condition - v_net_damage),
                total_flights = total_flights + (v_flights * v_game_days / 7.0)::INT
            WHERE id = v_route.assigned_aircraft_id;
        END LOOP;

        UPDATE users
        SET game_current_time = p_target_game_time,
            last_active_at = NOW()
        WHERE id = r_bot.id;

        IF v_game_days >= 1.0 THEN
            PERFORM process_loan_payments(r_bot.id, p_target_game_time);
            PERFORM process_aircraft_financing_payments(r_bot.id, p_target_game_time);
            PERFORM process_credit_at_day_boundary(r_bot.id, p_target_game_time);

            IF get_user_balance(r_bot.id) < 0 THEN
                UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1
                WHERE id = r_bot.id;
            ELSE
                UPDATE users SET consecutive_negative_days = 0
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


-- ── 6.22 execute_bot_decisions ──

CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    r_bot RECORD; v_model_id UUID; v_model_name VARCHAR; v_lease_price NUMERIC; v_purchase_price NUMERIC; v_capacity INT; v_speed_kmh NUMERIC; v_range_km NUMERIC; v_deposit_pct NUMERIC; v_deposit_amount NUMERIC; v_tail VARCHAR(20); v_origin_iata VARCHAR(3); v_dest_iata VARCHAR(3); v_distance DOUBLE PRECISION; v_fleet_count INT; v_route_count INT; v_idle_aircraft_count INT; v_idle_aircraft_id UUID; v_idle_tail VARCHAR(20); v_idle_condition NUMERIC; v_idle_model_name VARCHAR; v_idle_capacity INT; v_idle_speed NUMERIC; v_idle_range NUMERIC; v_grounded_aircraft_id UUID; v_grounded_condition NUMERIC; v_grounded_acquisition_type VARCHAR; v_grounded_model_name VARCHAR; v_grounded_lease_price NUMERIC; v_grounded_purchase_price NUMERIC; v_repair_cost NUMERIC; v_target_fleet_cap INT; v_min_cash_reserve NUMERIC; v_growth_chance NUMERIC; v_target_distance DOUBLE PRECISION; v_target_price_multiplier NUMERIC; v_target_schedule_ratio NUMERIC; v_effective_threshold NUMERIC(5,2); v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00; v_selected_route_id UUID; v_selected_flights INT; v_selected_base_fare NUMERIC; v_max_weekly_flights INT; v_target_flights INT; v_target_price NUMERIC; v_bot_cash NUMERIC; v_starting_cash NUMERIC := 15000000.00; v_attempts INT; v_inserted BOOLEAN; v_economy INT; v_business INT; v_first INT; r_route RECORD; v_human_competitors INT; v_new_price NUMERIC; v_base_fare NUMERIC; v_purchase_capacity INT; v_purchase_model_name VARCHAR; v_active_loans INT; v_game_time TIMESTAMPTZ;
BEGIN
    SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1; v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
    FOR r_bot IN SELECT * FROM users WHERE actor_type = 'AI' LOOP
        v_bot_cash := get_user_balance(r_bot.id);
        v_game_time := r_bot.game_current_time;
        v_origin_iata := r_bot.hq_airport_iata;
        v_effective_threshold := GREATEST(v_absolute_minimum_safety_limit, COALESCE(r_bot.auto_grounding_threshold, 40.00));
        IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < -5000000.00 THEN UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id; UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id; UPDATE loans SET status = 'defaulted', remaining_balance = 0 WHERE user_id = r_bot.id AND status = 'active'; CONTINUE; END IF;
        CASE r_bot.archetype WHEN 'Regional' THEN v_target_fleet_cap := 8; v_min_cash_reserve := 3500000.00; v_growth_chance := 0.20; v_target_distance := 900.0; v_target_price_multiplier := 0.95; v_target_schedule_ratio := 0.72; WHEN 'Aggressive' THEN v_target_fleet_cap := 14; v_min_cash_reserve := 4500000.00; v_growth_chance := 0.26; v_target_distance := 1800.0; v_target_price_multiplier := 1.02; v_target_schedule_ratio := 0.82; ELSE v_target_fleet_cap := 10; v_min_cash_reserve := 7000000.00; v_growth_chance := 0.16; v_target_distance := 4200.0; v_target_price_multiplier := 1.18; v_target_schedule_ratio := 0.58; END CASE;
        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_idle_aircraft_count FROM fleet_aircraft f WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);
        SELECT f.id, f.condition, f.acquisition_type, m.model_name, m.lease_price_per_month, m.purchase_price INTO v_grounded_aircraft_id, v_grounded_condition, v_grounded_acquisition_type, v_grounded_model_name, v_grounded_lease_price, v_grounded_purchase_price FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND (f.status = 'grounded' OR f.condition < v_effective_threshold) ORDER BY f.condition DESC LIMIT 1;
        IF v_grounded_aircraft_id IS NOT NULL THEN v_repair_cost := CASE WHEN v_grounded_acquisition_type = 'lease' THEN (100.00 - v_grounded_condition) * (COALESCE(v_grounded_lease_price, 0.00) * 0.50) ELSE (100.00 - v_grounded_condition) * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005) END; IF v_repair_cost > 0 AND v_bot_cash >= (v_repair_cost + 500000.00) THEN PERFORM debit_bank_account(r_bot.id, v_repair_cost, 'cogs', 'maintenance', 'Bot maintenance recovery: ' || v_grounded_model_name, v_game_time); UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = v_grounded_aircraft_id; v_bot_cash := v_bot_cash - v_repair_cost; END IF; END IF;
        IF v_bot_cash < 3000000.00 OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN SELECT r.id, r.flights_per_week, (50.00 + (r.distance_km * 0.12))::NUMERIC INTO v_selected_route_id, v_selected_flights, v_selected_base_fare FROM route_assignments r WHERE r.user_id = r_bot.id ORDER BY (r.ticket_price / NULLIF((50.00 + (r.distance_km * 0.12)), 0)) DESC, r.flights_per_week DESC LIMIT 1; IF v_selected_route_id IS NOT NULL THEN IF v_selected_flights > 8 THEN UPDATE route_assignments SET flights_per_week = GREATEST(6, flights_per_week - CASE r_bot.archetype WHEN 'Regional' THEN 6 WHEN 'Aggressive' THEN 4 ELSE 2 END), ticket_price = GREATEST(ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2), ROUND((ticket_price * 0.90)::numeric, 2)) WHERE id = v_selected_route_id; ELSE DELETE FROM route_assignments WHERE id = v_selected_route_id; END IF; END IF; END IF;
        IF v_fleet_count < v_target_fleet_cap AND v_bot_cash > v_min_cash_reserve AND COALESCE(r_bot.consecutive_negative_days, 0) = 0 AND v_idle_aircraft_count = 0 AND v_route_count >= v_fleet_count AND random() < v_growth_chance THEN
            v_model_id := NULL; v_model_name := NULL; v_lease_price := NULL; v_purchase_price := NULL; v_capacity := NULL;
            IF r_bot.archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600' LIMIT 1; ELSIF r_bot.archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' AND model_name = 'A320neo' LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' AND model_name = '787-9' LIMIT 1; END IF;
            IF v_model_id IS NULL THEN IF r_bot.archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' ORDER BY capacity DESC LIMIT 1; ELSIF r_bot.archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' ORDER BY capacity DESC LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' ORDER BY capacity DESC LIMIT 1; END IF; END IF;
            v_deposit_amount := COALESCE(v_lease_price, 0.00) * v_deposit_pct;
            IF v_model_id IS NOT NULL AND v_bot_cash >= v_deposit_amount THEN IF r_bot.archetype = 'Regional' THEN v_economy := FLOOR(v_capacity * 0.80); v_business := FLOOR(v_capacity * 0.15); v_first := v_capacity - v_economy - v_business; ELSIF r_bot.archetype = 'Aggressive' THEN v_economy := FLOOR(v_capacity * 0.70); v_business := FLOOR(v_capacity * 0.20); v_first := v_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_capacity * 0.50); v_business := FLOOR(v_capacity * 0.30); v_first := v_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (id, user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats) VALUES (gen_random_uuid(), r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN PERFORM debit_bank_account(r_bot.id, v_deposit_amount, 'investing', 'aircraft_lease_deposit', 'Leased aircraft ' || v_model_name || ' [' || v_tail || '] - deposit', v_game_time); v_bot_cash := v_bot_cash - v_deposit_amount; END IF; END IF;
        END IF;
        IF v_bot_cash > (v_starting_cash * 3) AND v_fleet_count < v_target_fleet_cap THEN SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name FROM aircraft_models WHERE range_km >= v_target_distance ORDER BY purchase_price ASC LIMIT 1; IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN IF r_bot.archetype = 'Regional' THEN v_economy := FLOOR(v_purchase_capacity * 0.80); v_business := FLOOR(v_purchase_capacity * 0.15); v_first := v_purchase_capacity - v_economy - v_business; ELSIF r_bot.archetype = 'Aggressive' THEN v_economy := FLOOR(v_purchase_capacity * 0.70); v_business := FLOOR(v_purchase_capacity * 0.20); v_first := v_purchase_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_purchase_capacity * 0.50); v_business := FLOOR(v_purchase_capacity * 0.30); v_first := v_purchase_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats) VALUES (r_bot.id, v_model_id, v_purchase_model_name, v_tail, 'purchase', 100.00, 'active', v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN PERFORM debit_bank_account(r_bot.id, v_purchase_price, 'investing', 'aircraft_purchase', 'Aircraft purchase: ' || v_tail, v_game_time); v_bot_cash := v_bot_cash - v_purchase_price; END IF; END IF; END IF;
        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
        SELECT f.id, f.tail_number, f.condition, m.model_name, m.capacity, m.speed_kmh, m.range_km INTO v_idle_aircraft_id, v_idle_tail, v_idle_condition, v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id) ORDER BY f.condition DESC LIMIT 1;
        IF v_idle_aircraft_id IS NOT NULL AND v_route_count < v_target_fleet_cap THEN v_attempts := 0; v_inserted := false; WHILE v_attempts < 20 AND NOT v_inserted LOOP SELECT iata INTO v_dest_iata FROM airports WHERE iata != v_origin_iata ORDER BY demand_index DESC, random() LIMIT 1; IF v_dest_iata IS NULL THEN EXIT; END IF; SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude) INTO v_distance FROM airports o, airports d WHERE o.iata = v_origin_iata AND d.iata = v_dest_iata; IF v_distance > 0 AND v_distance <= v_idle_range THEN v_base_fare := 50.00 + (v_distance * 0.12); v_target_price := ROUND(v_base_fare * v_target_price_multiplier, 2); v_max_weekly_flights := calculate_route_max_weekly_flights(v_distance, v_idle_speed); v_target_flights := GREATEST(1, FLOOR(v_max_weekly_flights * v_target_schedule_ratio)); BEGIN INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week) VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, v_target_price, v_idle_aircraft_id, v_target_flights); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; ELSE v_attempts := v_attempts + 1; END IF; END LOOP; END IF;
        FOR r_route IN SELECT ra.*, m.speed_kmh, m.range_km, m.turnaround_hours FROM route_assignments ra JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id JOIN aircraft_models m ON m.id = fa.aircraft_model_id WHERE ra.user_id = r_bot.id AND ra.status = 'active' LOOP SELECT COUNT(*) INTO v_human_competitors FROM route_assignments WHERE origin_iata = r_route.origin_iata AND destination_iata = r_route.destination_iata AND status = 'active' AND user_id != r_bot.id AND user_id IN (SELECT id FROM users WHERE actor_type = 'REAL'); IF v_human_competitors > 0 THEN v_base_fare := 50.00 + (r_route.distance_km * 0.12); v_new_price := ROUND(v_base_fare * v_target_price_multiplier * CASE WHEN r_route.ticket_price > v_base_fare * 1.3 THEN 0.95 ELSE 1.0 END, 2); IF v_new_price != r_route.ticket_price THEN UPDATE route_assignments SET ticket_price = v_new_price WHERE id = r_route.id; END IF; END IF; END LOOP;
        SELECT COUNT(*) INTO v_active_loans FROM loans WHERE user_id = r_bot.id AND status = 'active'; IF v_active_loans = 0 AND v_bot_cash < v_starting_cash * 0.5 AND v_bot_cash > 1000000 THEN PERFORM bot_take_loan(r_bot.id, LEAST(5000000, v_starting_cash - v_bot_cash)); END IF;
        UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;
    END LOOP;
END;
$function$;


-- ── 6.23 bot_take_loan ──

CREATE OR REPLACE FUNCTION public.bot_take_loan(
    p_bot_id uuid, p_principal numeric, p_term_weeks integer DEFAULT 52
)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_existing_loans INT;
    v_interest_rate NUMERIC := 0.05;
    v_total_repayable NUMERIC;
    v_weekly_payment NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_credit_score INT;
BEGIN
    SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_bot_id AND status = 'active';
    IF v_existing_loans >= 3 THEN RETURN false; END IF;
    IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN false; END IF;
    SELECT game_current_time, credit_score INTO v_game_time, v_credit_score FROM users WHERE id = p_bot_id;
    v_credit_score := COALESCE(v_credit_score, 500);
    v_total_repayable := p_principal * (1 + v_interest_rate);
    v_weekly_payment := v_total_repayable / p_term_weeks;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, credit_score_at_origination)
    VALUES (p_bot_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', v_game_time, 'unsecured', v_credit_score);

    PERFORM credit_bank_account(p_bot_id, p_principal, 'financing', 'loan_disbursement',
        'Bot loan disbursement', v_game_time);

    RETURN true;
END;
$function$;


-- ── 6.24 bot_finance_aircraft ──

CREATE OR REPLACE FUNCTION public.bot_finance_aircraft(
    p_bot_id uuid, p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 60
)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
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
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN RETURN false; END IF;
    v_purchase_price := v_model.purchase_price;
    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_monthly_payment := (v_principal * (1 + v_interest_rate)) / p_term_months;
    v_cash := get_user_balance(p_bot_id);
    SELECT game_current_time INTO v_game_time FROM users WHERE id = p_bot_id;
    IF v_cash < v_down_payment THEN RETURN false; END IF;

    PERFORM debit_bank_account(p_bot_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
        'Aircraft financing down payment — ' || v_model.model_name, v_game_time);

    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
    VALUES (p_bot_id, p_aircraft_model_id, v_model.model_name, 'finance', 100.00, 'active', 'BOT-' || left(p_bot_id::text, 4), FLOOR(v_model.capacity * 0.70)::INT, FLOOR(v_model.capacity * 0.20)::INT, FLOOR(v_model.capacity * 0.10)::INT)
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made)
    VALUES (p_bot_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0);

    RETURN true;
END;
$function$;


-- ── 6.25 reset_user_airline (1-param internal) ──

CREATE OR REPLACE FUNCTION public.reset_user_airline(p_user_id uuid)
RETURNS TABLE(success boolean, message text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
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
        onboarding_completed = false,
        credit_score = 500,
        credit_tier = 'Standard'
    WHERE id = p_user_id;

    INSERT INTO bank_accounts (user_id, account_type, balance)
    VALUES (p_user_id, 'operating', 15000000.00);

    RETURN QUERY SELECT TRUE, 'Airline reset successfully';
END;
$function$;


-- ── 6.26 reset_user_airline (0-param frontend overload) ──

CREATE OR REPLACE FUNCTION public.reset_user_airline()
RETURNS TABLE(success boolean, message text)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM reset_user_airline(v_user_id);
END;
$function$;


-- ── 6.27 handle_new_auth_user ──

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
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

    SELECT COALESCE((SELECT g.starting_cash::NUMERIC FROM public.global_game_settings g LIMIT 1), 15000000.00)
    INTO v_starting_cash;

    INSERT INTO public.users (
        auth_user_id, username, company_name, ceo_name, net_worth,
        game_current_time, last_active_at, operational_status,
        consecutive_negative_days, recovery_streak_days, auto_grounding_threshold,
        credit_score, credit_tier, actor_type, hq_airport_iata
    ) VALUES (
        NEW.id, v_username, v_company_name, v_ceo_name, v_starting_cash,
        '2020-01-01 00:00:00+00', NOW(), 'Active',
        0, 0, 40.00,
        500, 'Standard', 'REAL', 'CGK'
    );
    -- trg_create_default_bank_account trigger handles creating the operating account

    RETURN NEW;
END;
$function$;


-- ── 6.28 calculate_user_net_worth ──

CREATE OR REPLACE FUNCTION public.calculate_user_net_worth(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_cash NUMERIC;
    v_fleet_value NUMERIC;
BEGIN
    v_cash := get_user_balance(p_user_id);
    SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
    INTO v_fleet_value
    FROM fleet_aircraft f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.user_id = p_user_id AND f.acquisition_type = 'purchase';
    RETURN COALESCE(v_cash, 0) + v_fleet_value;
END;
$function$;


-- ── 6.29 calculate_credit_score ──

CREATE OR REPLACE FUNCTION public.calculate_credit_score(p_user_id uuid)
RETURNS TABLE(total_score integer, tier character varying, fleet_health integer, revenue_stability integer, debt_ratio integer, cash_reserve integer, profit_history integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $function$
DECLARE
    v_user RECORD; v_actor_type VARCHAR(10); v_fleet_count INT := 0; v_avg_condition NUMERIC := 100.0; v_grounded_ratio NUMERIC := 0.0; v_fleet_health NUMERIC := 200.0;
    v_revenue_days INT := 0; v_positive_days INT := 0; v_revenue_stability NUMERIC := 200.0;
    v_total_debt NUMERIC := 0.0; v_net_worth NUMERIC := 0.0; v_debt_ratio NUMERIC := 200.0;
    v_cash NUMERIC := 0.0; v_starting_cash NUMERIC := 15000000.0; v_cash_reserve NUMERIC := 200.0;
    v_total_revenue_30d NUMERIC := 0.0; v_total_expense_30d NUMERIC := 0.0; v_profit_margin NUMERIC := 0.0; v_profit_history NUMERIC := 200.0;
    v_total_score INT;
BEGIN
    SELECT u.net_worth, u.game_current_time, u.actor_type INTO v_user FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN total_score := 500; tier := 'Standard'; fleet_health := 100; revenue_stability := 100; debt_ratio := 100; cash_reserve := 100; profit_history := 100; RETURN NEXT; RETURN; END IF;
    v_actor_type := COALESCE(v_user.actor_type, 'REAL');
    v_cash := get_user_balance(p_user_id);
    v_net_worth := COALESCE(v_user.net_worth, 0.0);

    SELECT starting_cash INTO v_starting_cash FROM global_game_settings LIMIT 1;
    v_starting_cash := COALESCE(v_starting_cash, 15000000.0);

    SELECT COUNT(*)::INT, COALESCE(AVG(condition), 100.0), COALESCE(COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC / NULLIF(COUNT(*), 0), 0.0)
    INTO v_fleet_count, v_avg_condition, v_grounded_ratio FROM fleet_aircraft WHERE user_id = p_user_id;

    IF v_fleet_count > 0 THEN v_fleet_health := (v_avg_condition / 100.0) * 150.0 + 50.0 * (1.0 - v_grounded_ratio); ELSE v_fleet_health := 100.0; END IF;

    SELECT COUNT(*)::INT, COUNT(*) FILTER (WHERE amount > 0)::INT INTO v_revenue_days, v_positive_days
    FROM bank_transactions
    WHERE user_id = p_user_id AND ifrs_category = 'revenue'
      AND game_date >= v_user.game_current_time - INTERVAL '30 days';

    IF v_revenue_days > 0 THEN v_revenue_stability := (v_positive_days::NUMERIC / v_revenue_days::NUMERIC) * 200.0; ELSE v_revenue_stability := 100.0; END IF;

    SELECT COALESCE(SUM(remaining_balance), 0) INTO v_total_debt FROM loans WHERE user_id = p_user_id AND status = 'active';
    IF v_net_worth > 0 THEN v_debt_ratio := GREATEST(0, 200.0 - ((v_total_debt / v_net_worth) * 200.0)); ELSE v_debt_ratio := 0.0; END IF;

    IF v_starting_cash > 0 THEN v_cash_reserve := LEAST(200.0, (v_cash / v_starting_cash) * 200.0); ELSE v_cash_reserve := 100.0; END IF;

    SELECT COALESCE(SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN transaction_type = 'debit' THEN amount ELSE 0 END), 0)
    INTO v_total_revenue_30d, v_total_expense_30d
    FROM bank_transactions
    WHERE user_id = p_user_id AND game_date >= v_user.game_current_time - INTERVAL '30 days';

    IF v_total_revenue_30d > 0 THEN v_profit_margin := (v_total_revenue_30d - v_total_expense_30d) / v_total_revenue_30d; v_profit_history := LEAST(200.0, 100.0 + (v_profit_margin * 100.0)); ELSE v_profit_history := 100.0; END IF;

    v_total_score := GREATEST(0, LEAST(1000, ROUND(v_fleet_health) + ROUND(v_revenue_stability) + ROUND(v_debt_ratio) + ROUND(v_cash_reserve) + ROUND(v_profit_history)));
    total_score := v_total_score; tier := resolve_credit_tier(v_total_score); fleet_health := ROUND(v_fleet_health)::INT; revenue_stability := ROUND(v_revenue_stability)::INT; debt_ratio := ROUND(v_debt_ratio)::INT; cash_reserve := ROUND(v_cash_reserve)::INT; profit_history := ROUND(v_profit_history)::INT; RETURN NEXT;
END;
$function$;


-- ── 6.30 check_achievements ──

CREATE OR REPLACE FUNCTION public.check_achievements(p_user_id uuid, p_game_time timestamp with time zone)
RETURNS TABLE(achievement_name character varying, achievement_type character varying)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_cash NUMERIC; v_net_worth NUMERIC; v_fleet_count INT; v_route_count INT;
    v_hub_routes INT; v_has_first_class BOOLEAN; v_distress_recovered BOOLEAN;
    v_achievement_count_before INT; v_achievement_count_after INT;
BEGIN
    SELECT COUNT(*) INTO v_achievement_count_before FROM achievements WHERE user_id = p_user_id;
    v_cash := get_user_balance(p_user_id);
    SELECT COUNT(*) INTO v_fleet_count FROM fleet_aircraft WHERE user_id = p_user_id AND status = 'active';
    SELECT COUNT(*) INTO v_route_count FROM route_assignments WHERE user_id = p_user_id AND status = 'active';
    SELECT v_cash + COALESCE(SUM(am.purchase_price * 0.7), 0) INTO v_net_worth FROM fleet_aircraft uf JOIN aircraft_models am ON uf.aircraft_model_id = am.id WHERE uf.user_id = p_user_id AND uf.status = 'active';
    SELECT MAX(cnt) INTO v_hub_routes FROM (SELECT origin_iata, COUNT(*) AS cnt FROM route_assignments WHERE user_id = p_user_id AND status = 'active' GROUP BY origin_iata) sub;
    SELECT EXISTS(SELECT 1 FROM fleet_aircraft WHERE user_id = p_user_id AND first_class_seats > 0) INTO v_has_first_class;
    SELECT COALESCE(recovery_streak_days, 0) >= 3 AND COALESCE(operational_status, 'Active') = 'Active' INTO v_distress_recovered FROM users WHERE id = p_user_id;
    IF v_route_count >= 1 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'first_flight', 'First Flight', 'Established your first route', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_fleet_count >= 10 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'fleet_10', 'Fleet Commander', 'Operate 10 aircraft', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_fleet_count >= 50 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'fleet_50', 'Air Fleet Admiral', 'Operate 50 aircraft', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_net_worth >= 1000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'millionaire', 'Millionaire', 'Net worth exceeds $1M', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_net_worth >= 10000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'multi_millionaire', 'Multi-Millionaire', 'Net worth exceeds $10M', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_net_worth >= 100000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'hundred_million', 'Aviation Mogul', 'Net worth exceeds $100M', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_net_worth >= 1000000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'billionaire', 'Aviation Billionaire', 'Net worth exceeds $1B', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_route_count >= 25 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'route_master', 'Route Master', '25 active routes', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF COALESCE(v_hub_routes, 0) >= 10 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'hub_builder', 'Hub Builder', '10+ routes from a single airport', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_has_first_class THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'first_class', 'First Class', 'Configured first-class cabin', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_distress_recovered THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'survivor', 'Survivor', 'Recovered from distress status', p_game_time) ON CONFLICT DO NOTHING; END IF;
    SELECT COUNT(*) INTO v_achievement_count_after FROM achievements WHERE user_id = p_user_id;
    IF v_achievement_count_after > v_achievement_count_before THEN RETURN QUERY SELECT a.achievement_name, a.achievement_type FROM achievements a WHERE a.user_id = p_user_id AND a.id NOT IN (SELECT a2.id FROM achievements a2 WHERE a2.user_id = p_user_id ORDER BY a2.unlocked_at ASC LIMIT v_achievement_count_before); END IF;
END;
$function$;


-- ── 6.31 get_finance_snapshot (2-param internal) ──

CREATE OR REPLACE FUNCTION public.get_finance_snapshot(p_id uuid, p_is_bot boolean DEFAULT false)
RETURNS TABLE(actor_id uuid, is_bot boolean, company_name character varying, cash numeric, net_worth numeric, owned_aircraft_asset_value numeric, leased_aircraft_monthly_exposure numeric, fleet_count integer, owned_fleet_count integer, leased_fleet_count integer, active_route_count integer, rolling_revenue_30d numeric, rolling_expense_30d numeric, rolling_net_30d numeric, ledger_window_days integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $function$
DECLARE
    v_company_name VARCHAR; v_cash NUMERIC := 0.00; v_net_worth NUMERIC := 0.00;
    v_owned_asset_value NUMERIC := 0.00; v_leased_monthly_exposure NUMERIC := 0.00;
    v_fleet_count INT := 0; v_owned_fleet_count INT := 0; v_leased_fleet_count INT := 0;
    v_active_route_count INT := 0; v_revenue_30d NUMERIC := 0.00; v_expense_30d NUMERIC := 0.00;
    v_ledger_window_days INT := 30; v_game_current_time TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT u.company_name, u.net_worth, u.game_current_time
    INTO v_company_name, v_net_worth, v_game_current_time
    FROM users u WHERE u.id = p_id;
    IF NOT FOUND THEN RETURN; END IF;

    v_cash := get_user_balance(p_id);

    SELECT COUNT(*)::INT, COUNT(*) FILTER (WHERE f.acquisition_type = 'purchase')::INT,
           COUNT(*) FILTER (WHERE f.acquisition_type = 'lease')::INT,
           COALESCE(SUM(CASE WHEN f.acquisition_type = 'purchase' THEN m.purchase_price ELSE 0 END), 0.00),
           COALESCE(SUM(CASE WHEN f.acquisition_type = 'lease' THEN m.lease_price_per_month ELSE 0 END), 0.00)
    INTO v_fleet_count, v_owned_fleet_count, v_leased_fleet_count, v_owned_asset_value, v_leased_monthly_exposure
    FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.user_id = p_id;

    SELECT COUNT(*)::INT INTO v_active_route_count FROM route_assignments r WHERE r.user_id = p_id;

    SELECT COALESCE(SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END), 0.00),
           COALESCE(SUM(CASE WHEN transaction_type = 'debit' THEN amount ELSE 0 END), 0.00)
    INTO v_revenue_30d, v_expense_30d
    FROM bank_transactions
    WHERE user_id = p_id AND game_date >= v_game_current_time - INTERVAL '30 days';

    RETURN QUERY SELECT p_id, p_is_bot, v_company_name::VARCHAR, v_cash, v_net_worth,
        v_owned_asset_value, v_leased_monthly_exposure, v_fleet_count, v_owned_fleet_count,
        v_leased_fleet_count, v_active_route_count, v_revenue_30d, v_expense_30d,
        v_revenue_30d - v_expense_30d, v_ledger_window_days;
END;
$function$;


-- ── 6.32 get_finance_snapshot (0-param frontend overload) ──

CREATE OR REPLACE FUNCTION public.get_finance_snapshot()
RETURNS TABLE(actor_id uuid, is_bot boolean, company_name character varying,
    cash numeric, net_worth numeric, owned_aircraft_asset_value numeric,
    leased_aircraft_monthly_exposure numeric, fleet_count integer,
    owned_fleet_count integer, leased_fleet_count integer,
    active_route_count integer, rolling_revenue_30d numeric,
    rolling_expense_30d numeric, rolling_net_30d numeric,
    ledger_window_days integer)
LANGUAGE plpgsql STABLE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM get_finance_snapshot(v_user_id, FALSE);
END;
$function$;


-- ── 6.33 get_global_leaderboard ──

CREATE OR REPLACE FUNCTION public.get_global_leaderboard()
RETURNS TABLE(id uuid, company_name character varying, ceo_name character varying, is_bot boolean, archetype character varying, cash numeric, net_worth numeric, fleet_size integer, monthly_revenue numeric, status character varying)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
BEGIN
    RETURN QUERY SELECT u.id, u.company_name::VARCHAR, u.ceo_name::VARCHAR,
        (u.actor_type = 'AI')::BOOLEAN, COALESCE(u.archetype, 'Player')::VARCHAR,
        get_user_balance(u.id), u.net_worth,
        (SELECT COUNT(*)::INT FROM fleet_aircraft f WHERE f.user_id = u.id AND f.status = 'active'),
        COALESCE((SELECT SUM(bt.amount) FROM bank_transactions bt
                  WHERE bt.user_id = u.id AND bt.transaction_type = 'credit'
                    AND bt.game_date >= u.game_current_time - INTERVAL '30 days'), 0.00)::NUMERIC,
        COALESCE(u.operational_status, 'Active')::VARCHAR
    FROM users u;
END;
$function$;


-- ── 6.34 get_competitor_insights ──

CREATE OR REPLACE FUNCTION public.get_competitor_insights(p_id uuid, p_is_bot boolean)
RETURNS TABLE(company_name character varying, ceo_name character varying, cash numeric, net_worth numeric, status character varying, fleet_breakdown jsonb, network_routes jsonb)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE
    v_company VARCHAR; v_ceo VARCHAR; v_cash NUMERIC; v_net_worth NUMERIC;
    v_status VARCHAR; v_fleet JSONB; v_routes JSONB;
BEGIN
    SELECT u.company_name, u.ceo_name, u.net_worth, COALESCE(u.operational_status, 'Active')
    INTO v_company, v_ceo, v_net_worth, v_status
    FROM users u WHERE u.id = p_id;

    v_cash := get_user_balance(p_id);

    SELECT COALESCE(jsonb_object_agg(model_label, count_val), '{}'::jsonb) INTO v_fleet
    FROM (SELECT (m.manufacturer || ' ' || m.model_name || ' (' || f.acquisition_type || ')') AS model_label,
                 COUNT(*)::INT AS count_val
          FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id
          WHERE f.user_id = p_id AND f.status = 'active'
          GROUP BY m.manufacturer, m.model_name, f.acquisition_type) d;

    SELECT COALESCE(jsonb_agg(route_label), '[]'::jsonb) INTO v_routes
    FROM (SELECT (origin_iata || '-' || destination_iata) AS route_label
          FROM route_assignments WHERE user_id = p_id) r;

    RETURN QUERY SELECT v_company::VARCHAR, v_ceo::VARCHAR, v_cash, v_net_worth,
        v_status::VARCHAR, v_fleet, v_routes;
END;
$function$;


-- ── 6.35 record_rank_snapshot ──

CREATE OR REPLACE FUNCTION public.record_rank_snapshot(p_game_date date)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
BEGIN
    INSERT INTO rank_history (user_id, is_bot, game_date, rank_position, net_worth, fleet_size, monthly_revenue)
    SELECT sub.id, (sub.actor_type = 'AI'), p_game_date,
           ROW_NUMBER() OVER (ORDER BY sub.net_worth DESC), sub.net_worth, sub.fleet_count, sub.monthly_rev
    FROM (SELECT u.id, u.actor_type,
                 get_user_balance(u.id) + COALESCE((SELECT SUM(am.purchase_price * 0.7)
                     FROM fleet_aircraft uf JOIN aircraft_models am ON uf.aircraft_model_id = am.id
                     WHERE uf.user_id = u.id AND uf.status = 'active'), 0) AS net_worth,
                 (SELECT COUNT(*)::INT FROM fleet_aircraft WHERE user_id = u.id AND status = 'active') AS fleet_count,
                 COALESCE((SELECT SUM(amount) FROM bank_transactions
                           WHERE user_id = u.id AND transaction_type = 'credit'
                             AND game_date >= u.game_current_time - INTERVAL '30 days'), 0.00) AS monthly_rev
          FROM users u
          WHERE COALESCE(u.operational_status, 'Active') != 'Bankrupt') sub;
END;
$function$;


-- ── 6.36 process_world_tick ──

CREATE OR REPLACE FUNCTION public.process_world_tick(p_season_id uuid DEFAULT NULL::uuid, p_max_ticks integer DEFAULT 10)
RETURNS TABLE(season_id uuid, ticks_processed integer, game_time_after timestamp with time zone, players_processed integer, bots_processed integer)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    r_season RECORD;
    v_game_time_after TIMESTAMPTZ;
    v_ticks_processed INT := 0;
    v_players_processed INT := 0;
    v_bots_processed INT := 0;
    r_user RECORD;
    r_player_result RECORD;
    v_lock_key BIGINT;
    v_error_msg TEXT;
BEGIN
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

    IF date_trunc('day', r_season.current_game_time)::DATE <> date_trunc('day', v_game_time_after)::DATE THEN
        PERFORM record_rank_snapshot((v_game_time_after AT TIME ZONE 'UTC')::DATE);
        PERFORM execute_bot_decisions();
    END IF;

    UPDATE season_clock
    SET current_game_time = v_game_time_after, last_tick_at = NOW(), updated_at = NOW()
    WHERE id = r_season.id;

    v_ticks_processed := 1;

    season_id := r_season.id;
    ticks_processed := v_ticks_processed;
    game_time_after := v_game_time_after;
    players_processed := v_players_processed;
    bots_processed := v_bots_processed;
    RETURN NEXT;
END;
$function$;


-- ── 6.37 ensure_world_current ──

CREATE OR REPLACE FUNCTION public.ensure_world_current(p_season_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(season_id uuid, ticks_processed integer, game_time_after timestamp with time zone, players_processed integer, bots_processed integer)
LANGUAGE plpgsql VOLATILE AS $function$
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
$function$;


-- ── 6.38 get_credit_report ──

CREATE OR REPLACE FUNCTION public.get_credit_report()
RETURNS TABLE(current_score integer, fleet_health integer,
    revenue_stability integer, debt_ratio integer, cash_reserve integer,
    profit_history integer, credit_tier character varying,
    max_unsecured_loan numeric, max_secured_loan numeric,
    max_financing_amount numeric, base_interest_rate numeric,
    suggestions text[])
LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $function$
DECLARE v_user_id UUID; v_score RECORD; v_tier VARCHAR(20); v_config JSONB; v_tier_cfg JSONB; v_sugg TEXT[] := '{}';
BEGIN
    v_user_id := require_current_user_id();
    SELECT credit_tier_config INTO v_config FROM global_game_settings WHERE id = 1;
    SELECT * INTO v_score FROM calculate_credit_score(v_user_id) LIMIT 1;
    IF NOT FOUND THEN current_score := 500; fleet_health := 100; revenue_stability := 100; debt_ratio := 100; cash_reserve := 100; profit_history := 100; credit_tier := 'Standard'; max_unsecured_loan := 5000000; max_secured_loan := 25000000; max_financing_amount := 20000000; base_interest_rate := 0.07; suggestions := ARRAY['Build your fleet and routes to establish credit history.']; RETURN NEXT; RETURN; END IF;
    v_tier := resolve_credit_tier(v_score.total_score);
    UPDATE users SET credit_score = v_score.total_score, credit_tier = v_tier WHERE id = v_user_id;
    INSERT INTO credit_scores (user_id, score, tier, fleet_health_score, revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score, computed_at) VALUES (v_user_id, v_score.total_score, v_tier, v_score.fleet_health, v_score.revenue_stability, v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history, NOW()) ON CONFLICT (user_id) DO UPDATE SET score = EXCLUDED.score, tier = EXCLUDED.tier, fleet_health_score = EXCLUDED.fleet_health_score, revenue_stability_score = EXCLUDED.revenue_stability_score, debt_ratio_score = EXCLUDED.debt_ratio_score, cash_reserves_score = EXCLUDED.cash_reserves_score, profit_history_score = EXCLUDED.profit_history_score, computed_at = EXCLUDED.computed_at;
    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);
    current_score := v_score.total_score; fleet_health := v_score.fleet_health; revenue_stability := v_score.revenue_stability; debt_ratio := v_score.debt_ratio; cash_reserve := v_score.cash_reserve; profit_history := v_score.profit_history; credit_tier := v_tier;
    max_unsecured_loan := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000); max_secured_loan := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000); max_financing_amount := COALESCE((v_tier_cfg->>'max_financing')::NUMERIC, 20000000); base_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
    v_sugg := '{}';
    IF v_score.fleet_health < 100 THEN v_sugg := array_append(v_sugg, 'Repair grounded aircraft to improve fleet health.'); END IF;
    IF v_score.debt_ratio < 100 THEN v_sugg := array_append(v_sugg, 'Reduce outstanding debt to improve your debt ratio.'); END IF;
    IF v_score.cash_reserve < 100 THEN v_sugg := array_append(v_sugg, 'Build cash reserves for financial stability.'); END IF;
    IF v_score.revenue_stability < 100 THEN v_sugg := array_append(v_sugg, 'Establish consistent revenue from routes.'); END IF;
    IF array_length(v_sugg, 1) IS NULL THEN v_sugg := ARRAY['Your credit profile is healthy. Keep it up!']; END IF;
    suggestions := v_sugg; RETURN NEXT;
END;
$function$;


-- ── 6.39 save_airline_settings ──

CREATE OR REPLACE FUNCTION public.save_airline_settings(
    p_company_name character varying, p_auto_grounding_threshold numeric,
    p_hq_airport_iata character varying
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM save_airline_settings(v_user_id, p_company_name, p_auto_grounding_threshold, p_hq_airport_iata);
END;
$function$;


-- ── 6.40 configure_aircraft_seats ──

CREATE OR REPLACE FUNCTION public.configure_aircraft_seats(
    p_fleet_id uuid, p_economy_seats integer,
    p_business_seats integer, p_first_class_seats integer
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM configure_aircraft_seats(v_user_id, p_fleet_id, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;


-- ── 6.41 create_route ──

CREATE OR REPLACE FUNCTION public.create_route(
    p_origin_iata character varying, p_destination_iata character varying,
    p_distance_km numeric, p_ticket_price numeric, p_flights_per_week integer
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM create_route(v_user_id, p_origin_iata, p_destination_iata, p_distance_km, p_ticket_price, p_flights_per_week);
END;
$function$;


-- ── 6.42 delete_route ──

CREATE OR REPLACE FUNCTION public.delete_route(p_route_id uuid)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM delete_route(v_user_id, p_route_id);
END;
$function$;


-- ── 6.43 assign_aircraft_to_route ──

CREATE OR REPLACE FUNCTION public.assign_aircraft_to_route(p_route_id uuid, p_aircraft_id uuid)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM assign_aircraft_to_route(v_user_id, p_route_id, p_aircraft_id);
END;
$function$;


-- ── 6.44 update_route_frequency_and_price ──

CREATE OR REPLACE FUNCTION public.update_route_frequency_and_price(
    p_route_id uuid, p_ticket_price numeric, p_flights_per_week integer
)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.require_current_user_id();
    RETURN QUERY SELECT * FROM update_route_frequency_and_price(v_user_id, p_route_id, p_ticket_price, p_flights_per_week);
END;
$function$;


COMMIT;
