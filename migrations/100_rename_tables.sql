-- ============================================================================
-- Migration 100: Rename user_fleet → fleet_aircraft, user_routes → route_assignments
-- Clean break — no backward-compat views.
--
-- Tables were already renamed by migration 101 (merge_ai_into_users).
-- This migration ensures ALL remaining function references are updated.
-- ============================================================================

-- ── Fix trg_ai_competitor_bankruptcy (still referenced user_fleet) ──
CREATE OR REPLACE FUNCTION public.trg_ai_competitor_bankruptcy()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.operational_status = 'Bankrupt' AND NEW.actor_type = 'AI' THEN
        UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = NEW.id;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── Verification (run manually) ──
-- SELECT tablename FROM pg_tables WHERE schemaname = 'public'
--   AND tablename IN ('user_fleet', 'user_routes', 'fleet_aircraft', 'route_assignments');
-- Should show: fleet_aircraft, route_assignments only.
--
-- SELECT proname FROM pg_proc WHERE pronamespace = 'public'::regnamespace
--   AND (pg_get_functiondef(oid) LIKE '%user_fleet%' OR pg_get_functiondef(oid) LIKE '%user_routes%');
-- Should return 0 rows.
