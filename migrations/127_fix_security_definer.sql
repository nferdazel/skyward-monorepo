-- =============================================================================
-- Migration 127: Fix SECURITY DEFINER on all player-callable RPCs
-- =============================================================================
-- Problem: Migration 118 revoked INSERT/UPDATE/DELETE grants from the
--   `authenticated` role on core tables. Many RPCs that were RE-CREATED in
--   subsequent migrations (119-126) lost their SECURITY DEFINER flag because
--   CREATE OR REPLACE does not preserve it — you must re-declare it.
--
--   This means the RPCs run as the calling user (authenticated) which has
--   NO write permission → "permission denied" on every player action.
--
-- Fix: Set ALL player-callable RPCs to SECURITY DEFINER via ALTER FUNCTION.
--   This makes the functions execute as the function owner (postgres) which
--   has full table access, bypassing both RLS and revoked GRANT permissions.
--
-- Approach: Use a DO block that queries pg_proc for exact function signatures
--   via pg_get_function_identity_arguments(), then executes ALTER FUNCTION
--   dynamically. This is resilient to parameter name differences.
-- =============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- Apply SECURITY DEFINER to all player-callable RPCs (all overloads)
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  fn_name TEXT;
  fn RECORD;
  applied_count INT := 0;
  skipped_count INT := 0;
  -- All function names that need SECURITY DEFINER
  fn_names TEXT[] := ARRAY[
    -- Fleet (mutation RPCs)
    'repair_aircraft',
    'lease_aircraft',
    'purchase_aircraft',
    'sell_aircraft',
    'terminate_aircraft_lease',
    'configure_aircraft_seats',
    -- Routes (mutation RPCs)
    'create_route',
    'delete_route',
    'assign_aircraft_to_route',
    'update_route_frequency_and_price',
    -- Bank (mutation RPCs)
    'take_loan',
    'finance_aircraft',
    'deposit_to_savings',
    'withdraw_from_savings',
    'refinance_loan',
    'repay_loan',
    -- Settings (mutation RPCs)
    'save_airline_settings',
    'reset_user_airline',
    -- Read-only RPCs (need SECURITY DEFINER for RLS bypass)
    'get_credit_report',
    'get_global_leaderboard',
    'get_finance_snapshot',
    -- Simulation / tick (CRITICAL — these write player state on tick)
    'process_player_simulation_to_time',
    'process_aircraft_financing_payments',
    'accrue_savings_interest',
    'process_world_tick',
    'ensure_world_current',
    -- Net worth / helpers (called from triggers and RPCs)
    'calculate_user_net_worth',
    'reconcile_all_net_worths',
    -- Auth helpers (need to read users table via RLS bypass)
    'get_current_user_id',
    'require_current_user_id',
    'get_user_id_for_auth_uid'
  ];
BEGIN
  FOREACH fn_name IN ARRAY fn_names
  LOOP
    FOR fn IN
      SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prosecdef
      FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname = fn_name
    LOOP
      IF fn.prosecdef THEN
        RAISE NOTICE '  SKIP (already SD): public.% (%)', fn.proname, fn.args;
        skipped_count := skipped_count + 1;
      ELSE
        EXECUTE format(
          'ALTER FUNCTION public.%I(%s) SECURITY DEFINER',
          fn.proname,
          fn.args
        );
        RAISE NOTICE '  FIXED: public.% (%)', fn.proname, fn.args;
        applied_count := applied_count + 1;
      END IF;
    END LOOP;
  END LOOP;

  RAISE NOTICE '=== Applied SECURITY DEFINER to % function(s), skipped % already-SD ===', applied_count, skipped_count;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Verify: list any remaining non-SD public functions (excluding pure utilities)
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  fn RECORD;
  remaining_count INT := 0;
  -- These are pure utility/internal functions that don't need SECURITY DEFINER
  excluded TEXT[] := ARRAY[
    'haversine_distance',
    'normalize_username',
    'build_synthetic_auth_email',
    'generate_tail_number',
    'get_hq_prefix',
    'get_tail_suffix',
    -- Bot/admin-only functions (called by service_role, not authenticated)
    'generate_game_events',
    'execute_bot_decisions',
    'process_all_bots_simulation_to_time',
    'compact_financial_ledger',
    'compact_world_tick_log',
    'deactivate_expired_events',
    'record_rank_snapshot',
    'bot_take_loan',
    'bot_finance_aircraft',
    -- Pure calculation helpers
    'calculate_route_base_fare',
    'calculate_route_demand_multiplier',
    'calculate_route_expected_passengers',
    'calculate_route_max_weekly_flights',
    'calculate_airport_congestion_factor',
    'calculate_airport_demand_factor',
    'calculate_effective_passenger_capacity',
    'calculate_hub_bonus',
    'calculate_lease_termination_fee',
    'get_hub_bonus_percentage',
    -- Trigger functions (execute as trigger invoker, not direct RPCs)
    'trg_assign_active_season_id',
    'trg_create_default_bank_account',
    'trg_fleet_reconcile_net_worth',
    'trg_set_acquired_game_date',
    'trg_set_default_fare_buckets',
    'trg_sync_checking_balance',
    'trg_sync_tail_numbers_on_hq_change',
    'trg_update_user_net_worth',
    'handle_new_auth_user',
    -- Season/world helpers
    'resolve_active_season_id',
    -- Admin/report functions
    'get_database_size_report',
    'get_world_tick_guardrail_report',
    -- Test functions
    'test_121',
    'test_func',
    'test_func_125'
  ];
BEGIN
  RAISE NOTICE '=== Post-migration: Public functions still WITHOUT SECURITY DEFINER ===';
  FOR fn IN
    SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prosecdef = false
      AND NOT (p.proname = ANY(excluded))
    ORDER BY p.proname
  LOOP
    RAISE NOTICE '  STILL MISSING: public.% (%)', fn.proname, fn.args;
    remaining_count := remaining_count + 1;
  END LOOP;

  IF remaining_count = 0 THEN
    RAISE NOTICE '  All player-callable RPCs are now SECURITY DEFINER';
  ELSE
    RAISE WARNING '  % function(s) still missing SECURITY DEFINER — review above', remaining_count;
  END IF;
END $$;

COMMIT;

-- ─────────────────────────────────────────────────────────────────────────────
-- Post-commit verification query
-- ─────────────────────────────────────────────────────────────────────────────
-- Run this to confirm all mutation RPCs are SECURITY DEFINER:
--
-- SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prosecdef
-- FROM pg_proc p
-- WHERE p.pronamespace = 'public'::regnamespace
--   AND p.prosecdef = false
-- ORDER BY p.proname;
