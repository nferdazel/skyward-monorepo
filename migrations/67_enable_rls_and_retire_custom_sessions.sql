-- ============================================================================
-- SKYWARD SECURITY PHASE 5: ENABLE RLS AND RETIRE CUSTOM SESSIONS
-- ============================================================================
-- 1. Makes auth-bound client RPC wrappers run as SECURITY DEFINER so
--    authenticated clients no longer need direct table write grants.
-- 2. Enables Row Level Security across the app-facing read surface.
-- 3. Restricts direct table grants to the minimum required for authenticated
--    reads and retires the legacy custom-session auth RPCs from client roles.
-- 4. Tightens operator/audit RPC grants by removing unnecessary anon access.
-- ============================================================================

ALTER FUNCTION purchase_aircraft(UUID, VARCHAR, INT, INT, INT)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION lease_aircraft(UUID, VARCHAR, INT, INT, INT)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION configure_aircraft_seats(UUID, INT, INT, INT)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION repair_aircraft(UUID)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION create_route(VARCHAR, VARCHAR, NUMERIC, NUMERIC, INT)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION assign_aircraft_to_route(UUID, UUID)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION update_route_frequency_and_price(UUID, NUMERIC, INT)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION delete_route(UUID)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION save_airline_settings(VARCHAR, NUMERIC, VARCHAR)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION sell_aircraft(UUID)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION terminate_aircraft_lease(UUID)
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION process_simulation_delta()
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION reset_user_airline()
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION get_finance_snapshot()
    SECURITY DEFINER
    SET search_path = public, auth, pg_catalog;

ALTER FUNCTION get_global_leaderboard()
    SECURITY DEFINER
    SET search_path = public, pg_catalog;

ALTER FUNCTION get_competitor_insights(UUID, BOOLEAN)
    SECURITY DEFINER
    SET search_path = public, pg_catalog;


ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_fleet ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_routes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.financial_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.airports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aircraft_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.global_game_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_competitors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.season_clock ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.world_tick_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.world_tick_daily_summary ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.world_tick_scheduler_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.data_retention_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.financial_ledger_summary ENABLE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS users_select_own ON public.users;
CREATE POLICY users_select_own
ON public.users
FOR SELECT
TO authenticated
USING (auth.uid() IS NOT NULL AND auth.uid() = auth_user_id);

DROP POLICY IF EXISTS users_update_own ON public.users;
CREATE POLICY users_update_own
ON public.users
FOR UPDATE
TO authenticated
USING (auth.uid() IS NOT NULL AND auth.uid() = auth_user_id)
WITH CHECK (auth.uid() IS NOT NULL AND auth.uid() = auth_user_id);


DROP POLICY IF EXISTS user_fleet_select_own ON public.user_fleet;
CREATE POLICY user_fleet_select_own
ON public.user_fleet
FOR SELECT
TO authenticated
USING (user_id = public.get_current_user_id());


DROP POLICY IF EXISTS user_routes_select_own ON public.user_routes;
CREATE POLICY user_routes_select_own
ON public.user_routes
FOR SELECT
TO authenticated
USING (user_id = public.get_current_user_id());


DROP POLICY IF EXISTS financial_ledger_select_own ON public.financial_ledger;
CREATE POLICY financial_ledger_select_own
ON public.financial_ledger
FOR SELECT
TO authenticated
USING (user_id = public.get_current_user_id());


DROP POLICY IF EXISTS airports_select_authenticated ON public.airports;
CREATE POLICY airports_select_authenticated
ON public.airports
FOR SELECT
TO authenticated
USING (true);


DROP POLICY IF EXISTS aircraft_models_select_authenticated ON public.aircraft_models;
CREATE POLICY aircraft_models_select_authenticated
ON public.aircraft_models
FOR SELECT
TO authenticated
USING (true);


DROP POLICY IF EXISTS global_game_settings_select_authenticated ON public.global_game_settings;
CREATE POLICY global_game_settings_select_authenticated
ON public.global_game_settings
FOR SELECT
TO authenticated
USING (true);


REVOKE ALL ON TABLE public.users FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.users TO authenticated;

REVOKE ALL ON TABLE public.user_fleet FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.user_fleet TO authenticated;

REVOKE ALL ON TABLE public.user_routes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.user_routes TO authenticated;

REVOKE ALL ON TABLE public.financial_ledger FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.financial_ledger TO authenticated;

REVOKE ALL ON TABLE public.airports FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.airports TO authenticated;

REVOKE ALL ON TABLE public.aircraft_models FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.aircraft_models TO authenticated;

REVOKE ALL ON TABLE public.global_game_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.global_game_settings TO authenticated;

REVOKE ALL ON TABLE public.ai_competitors FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.sessions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.season_clock FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.world_tick_log FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.world_tick_daily_summary FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.world_tick_scheduler_config FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.data_retention_policy FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.financial_ledger_summary FROM PUBLIC, anon, authenticated;


REVOKE ALL ON FUNCTION register_company(VARCHAR, VARCHAR, VARCHAR, VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION register_company(VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO service_role;

REVOKE ALL ON FUNCTION login_company(VARCHAR, VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION login_company(VARCHAR, VARCHAR) TO service_role;

REVOKE ALL ON FUNCTION validate_session(VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION validate_session(VARCHAR) TO service_role;


REVOKE ALL ON FUNCTION get_global_leaderboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_global_leaderboard() TO authenticated, service_role;

REVOKE ALL ON FUNCTION get_competitor_insights(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_competitor_insights(UUID, BOOLEAN) TO authenticated, service_role;

REVOKE ALL ON FUNCTION get_world_tick_scheduler_health() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_world_tick_scheduler_health() TO service_role;

REVOKE ALL ON FUNCTION get_world_tick_guardrail_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_world_tick_guardrail_report() TO service_role;

REVOKE ALL ON FUNCTION get_database_size_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_database_size_report() TO service_role;

REVOKE ALL ON FUNCTION get_table_size_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_table_size_report() TO service_role;

REVOKE ALL ON FUNCTION get_world_tick_log_compaction_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_world_tick_log_compaction_report() TO service_role;

REVOKE ALL ON FUNCTION get_financial_ledger_compaction_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_financial_ledger_compaction_report() TO service_role;


COMMENT ON TABLE public.sessions IS
'Legacy custom-session compatibility table. Flutter auth now uses Supabase Auth sessions; client-role access has been retired.';
