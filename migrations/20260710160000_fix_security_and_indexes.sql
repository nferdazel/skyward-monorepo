-- ============================================================================
-- Migration: Security lockdown and missing indexes
-- Fixes:
--   1. REVOKE EXECUTE on inner SECURITY DEFINER overloads (p_user_id)
--   2. REVOKE write grants on sensitive tables
--   3. Add missing performance indexes
-- ============================================================================

BEGIN;

-- ============================================================================
-- FIX 1: Restrict inner overloads — REVOKE from PUBLIC/anon,
--         GRANT only auth-bound wrappers to authenticated
-- ============================================================================
-- Each DO block drops EXECUTE from PUBLIC and anon, then re-grants only on the
-- auth-bound overload (no p_user_id) to authenticated.  IF EXISTS guards
-- prevent failure when a function signature is absent.

-- credit_bank_account
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.credit_bank_account(uuid, numeric, varchar, varchar, text, timestamptz) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

DO $$
BEGIN
  GRANT EXECUTE ON FUNCTION public.credit_bank_account(numeric, varchar, varchar, text, timestamptz) TO authenticated;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- debit_bank_account
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.debit_bank_account(uuid, numeric, varchar, varchar, text, timestamptz) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

DO $$
BEGIN
  GRANT EXECUTE ON FUNCTION public.debit_bank_account(numeric, varchar, varchar, text, timestamptz) TO authenticated;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- apply_actor_bankruptcy_state
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.apply_actor_bankruptcy_state(uuid) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- execute_bot_decisions
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.execute_bot_decisions() FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- spawn_bot
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.spawn_bot() FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- ensure_world_current
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.ensure_world_current(uuid) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- process_world_tick
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.process_world_tick(uuid, int) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- compact_bank_transactions
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.compact_bank_transactions(boolean) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- compact_world_tick_log
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.compact_world_tick_log(boolean) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- prune_world_tick_log
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.prune_world_tick_log() FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- prune_bank_transactions
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.prune_bank_transactions(boolean) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- get_database_size_report
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.get_database_size_report() FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- get_world_tick_scheduler_health
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.get_world_tick_scheduler_health() FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- get_world_tick_guardrail_report
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.get_world_tick_guardrail_report() FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- get_bot_health
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.get_bot_health() FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- create_actor_fleet_aircraft
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.create_actor_fleet_aircraft(uuid, uuid, varchar, varchar, int, int, int) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- create_actor_route_assignment
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.create_actor_route_assignment(uuid, varchar, varchar, double precision, numeric, int, uuid) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- update_actor_route_economics
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.update_actor_route_economics(uuid, uuid, numeric, int) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- delete_actor_route_assignment
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.delete_actor_route_assignment(uuid, uuid, boolean) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- sell_actor_aircraft
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.sell_actor_aircraft(uuid, uuid, timestamptz) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- terminate_actor_lease
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.terminate_actor_lease(uuid, uuid, timestamptz) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- assign_actor_aircraft_to_route
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.assign_actor_aircraft_to_route(uuid, uuid, uuid) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- perform_actor_aircraft_repair
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.perform_actor_aircraft_repair(uuid, uuid, numeric, timestamptz, text) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- get_route_performance
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.get_route_performance(uuid) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- get_competitor_insights
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.get_competitor_insights(uuid, boolean) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- get_owner_route_optimizer
DO $$
BEGIN
  REVOKE EXECUTE ON FUNCTION public.get_owner_route_optimizer(uuid, varchar, varchar, int, boolean, boolean) FROM PUBLIC, anon;
EXCEPTION WHEN undefined_function THEN NULL;
END$$;

-- ============================================================================
-- FIX 2: Revoke write grants on sensitive tables
-- ============================================================================

REVOKE INSERT, UPDATE, DELETE ON public.game_config FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.bot_profiles FROM authenticated;
REVOKE INSERT ON public.users FROM authenticated;

-- ============================================================================
-- FIX 3: Add missing performance indexes
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_fleet_aircraft_model
    ON public.fleet_aircraft(aircraft_model_id);

CREATE INDEX IF NOT EXISTS idx_fleet_aircraft_user_status
    ON public.fleet_aircraft(user_id, status);

CREATE INDEX IF NOT EXISTS idx_route_assignments_user_status
    ON public.route_assignments(user_id)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_users_active_bots
    ON public.users(id)
    WHERE actor_type = 'AI' AND operational_status != 'Bankrupt';

CREATE INDEX IF NOT EXISTS idx_world_tick_log_started
    ON public.world_tick_log(started_at);

CREATE INDEX IF NOT EXISTS idx_game_events_active
    ON public.game_events(event_type, start_game_time, end_game_time)
    WHERE is_active = true;

COMMIT;
