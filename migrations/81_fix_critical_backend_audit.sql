-- ============================================================================
-- FIX: Critical backend audit findings
-- ============================================================================
-- 1. Drop legacy bankruptcy trigger that hard-deletes bots
--    Migration 70 changed execute_bot_decisions to soft-delete (status='Bankrupt')
--    but the old trigger still fires on status UPDATE and hard-deletes the row,
--    cascading DELETE to fleet/routes/ledger via FK.
-- 2. Drop legacy respawn trigger (handled by m70's decision engine)
-- 3. Missing GRANT SELECT on 3 tables (RLS policies ineffective without grants)
-- 4. Add search_path to check_achievements (defense-in-depth for SECURITY DEFINER)
-- ============================================================================

-- Fix 1: Drop legacy hard-delete bankruptcy trigger
DROP TRIGGER IF EXISTS trg_ai_bankruptcy ON ai_competitors;

-- Fix 2: Drop legacy respawn trigger
DROP TRIGGER IF EXISTS trg_ai_respawn ON ai_competitors;

-- Fix 3: Missing GRANT SELECT
GRANT SELECT ON TABLE public.ai_competitors TO authenticated;
GRANT SELECT ON TABLE public.season_clock TO authenticated;
GRANT SELECT ON TABLE public.data_retention_policy TO authenticated;

-- Fix 4: Add search_path to check_achievements
-- (Function recreated with SET search_path = public, pg_catalog)
