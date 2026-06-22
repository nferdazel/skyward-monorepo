-- ============================================================================
-- SKYWARD SECURITY PHASE 6: DROP LEGACY CUSTOM-SESSION AUTH
-- ============================================================================
-- Removes the final database remnants of the pre-Supabase-Auth login model.
-- Flutter no longer uses these functions, client-role execute access has
-- already been revoked, and the authenticated runtime is now bound to auth.uid.
-- ============================================================================

DROP FUNCTION IF EXISTS validate_session(VARCHAR);
DROP FUNCTION IF EXISTS login_company(VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS register_company(VARCHAR, VARCHAR, VARCHAR, VARCHAR);

DROP TABLE IF EXISTS public.sessions;
