BEGIN;

-- ============================================================================
-- Migration: IFRS subcategory naming alignment, cargo revenue split,
--            negative amount guard, and missing transaction types
-- ============================================================================
-- Fixes:
--   1. COGS subcategories: fuel→fuel_cost, crew→crew_cost, maintenance→maintenance_cost
--   2. Cargo revenue split: separate cargo_revenue from ticket_revenue
--   3. Negative amount guard in credit_bank_account / debit_bank_account
--   4. Add accrual and refund to bank_transactions.transaction_type CHECK
-- ============================================================================

-- ============================================================================
-- FIX 4: Extend transaction_type CHECK constraint
-- ============================================================================
ALTER TABLE public.bank_transactions
    DROP CONSTRAINT IF EXISTS bank_transactions_transaction_type_check;
ALTER TABLE public.bank_transactions
    ADD CONSTRAINT bank_transactions_transaction_type_check
    CHECK (transaction_type IN (
        'debit','credit','payment','deposit','disbursement',
        'refinance','late_fee','accrual','refund'
    ));

-- ============================================================================
-- FIX 1 (backfill): Rename existing COGS subcategories
-- ============================================================================
UPDATE public.bank_transactions
SET ifrs_subcategory = 'fuel_cost'
WHERE ifrs_subcategory = 'fuel';

UPDATE public.bank_transactions
SET ifrs_subcategory = 'crew_cost'
WHERE ifrs_subcategory = 'crew';

UPDATE public.bank_transactions
SET ifrs_subcategory = 'maintenance_cost'
WHERE ifrs_subcategory = 'maintenance';

-- ============================================================================
-- FIX 3a: Negative amount guard — credit_bank_account
-- ============================================================================
DO $fix_credit_guard$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
BEGIN
SELECT id INTO v_account_id
$old$;
    v_new_snippet TEXT := $new$
BEGIN
IF COALESCE(p_amount, 0) < 0 THEN
    RAISE EXCEPTION 'Amount must be non-negative: %', p_amount;
END IF;
SELECT id INTO v_account_id
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.credit_bank_account(uuid,numeric,character varying,character varying,text,timestamp with time zone)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for credit_bank_account()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'credit_bank_account negative guard already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_credit_guard$;

-- ============================================================================
-- FIX 3b: Negative amount guard — debit_bank_account
-- ============================================================================
DO $fix_debit_guard$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
BEGIN
SELECT id INTO v_account_id
$old$;
    v_new_snippet TEXT := $new$
BEGIN
IF COALESCE(p_amount, 0) < 0 THEN
    RAISE EXCEPTION 'Amount must be non-negative: %', p_amount;
END IF;
SELECT id INTO v_account_id
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.debit_bank_account(uuid,numeric,character varying,character varying,text,timestamp with time zone)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for debit_bank_account()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'debit_bank_account negative guard already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_debit_guard$;

-- ============================================================================
-- FIX 1+2: Player simulation — cargo revenue split + COGS subcategory naming
-- ============================================================================
DO $fix_player_ifrs$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
        v_total_revenue := v_revenue + v_cargo_rev;
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
        IF v_total_fuel_cost > 0 THEN
            PERFORM debit_bank_account(
                p_user_id,
                v_total_fuel_cost,
                'cogs',
                'fuel',
                'Fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
        END IF;
        IF v_total_crew_cost > 0 THEN
            PERFORM debit_bank_account(
                p_user_id,
                v_total_crew_cost,
                'cogs',
                'crew',
                'Crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
        END IF;
        IF v_total_maint_cost > 0 THEN
            PERFORM debit_bank_account(
                p_user_id,
                v_total_maint_cost,
                'cogs',
                'maintenance',
                'Maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
        END IF;
$old$;
    v_new_snippet TEXT := $new$
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
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_player_simulation_to_time(uuid,timestamp with time zone)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_player_simulation_to_time()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'player IFRS subcategory + cargo split already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_player_ifrs$;

-- ============================================================================
-- FIX 1+2a: Bot simulation — cargo revenue percentage from game_config
-- ============================================================================
DO $fix_bot_cargo_pct$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
            v_cargo_rev := v_revenue * 0.05;
$old$;
    v_new_snippet TEXT := $new$
            v_cargo_rev := v_revenue * COALESCE(get_config_numeric('cargo_revenue_percentage'), 0.05);
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_all_bots_simulation_to_time(timestamp with time zone,uuid)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_all_bots_simulation_to_time()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'bot cargo_revenue_percentage already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_bot_cargo_pct$;

-- ============================================================================
-- FIX 1+2b: Bot simulation — cargo revenue split + COGS subcategory naming
-- ============================================================================
DO $fix_bot_ifrs$
DECLARE
    v_function_def TEXT;
    v_old_snippet TEXT := $old$
            PERFORM credit_bank_account(
                r_bot.id,
                v_revenue + v_cargo_rev,
                'revenue',
                'ticket_revenue',
                'Bot route ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_fuel_cost,
                'cogs',
                'fuel',
                'Bot fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_crew_cost,
                'cogs',
                'crew',
                'Bot crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
            PERFORM debit_bank_account(
                r_bot.id,
                v_maint_cost,
                'cogs',
                'maintenance',
                'Bot maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time
            );
$old$;
    v_new_snippet TEXT := $new$
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
$new$;
BEGIN
    SELECT pg_get_functiondef(
        'public.process_all_bots_simulation_to_time(timestamp with time zone,uuid)'::regprocedure
    )
    INTO v_function_def;

    IF v_function_def IS NULL THEN
        RAISE EXCEPTION 'Function definition not found for process_all_bots_simulation_to_time()';
    END IF;

    IF position(v_old_snippet IN v_function_def) = 0 THEN
        RAISE NOTICE 'bot IFRS subcategory + cargo split already applied or snippet not found — skipping';
        RETURN;
    END IF;

    v_function_def := replace(v_function_def, v_old_snippet, v_new_snippet);
    EXECUTE v_function_def;
END;
$fix_bot_ifrs$;

COMMIT;
