-- ============================================================================
-- SKYWARD SECURITY PHASE 6: LEGACY CLEANUP & SESSIONS DESTRUCTION
-- ============================================================================
-- 1. Revoke and drop legacy custom-session RPC functions.
-- 2. Drop legacy sessions table completely.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. DROP LEGACY RPC FUNCTIONS
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.register_company(text, text, text, text);
DROP FUNCTION IF EXISTS public.login_company(text, text);
DROP FUNCTION IF EXISTS public.validate_session(uuid);

-- ----------------------------------------------------------------------------
-- 2. DROP LEGACY SESSIONS TABLE
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS public.sessions CASCADE;
