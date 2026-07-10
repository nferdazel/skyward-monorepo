-- ============================================================================
-- Migration 39: Declare auth.users bootstrap trigger
-- Goal:
--   The handle_new_auth_user() function exists in the baseline migration and
--   is live-attached to auth.users, but the trigger attachment was never
--   declared in repo-local migrations. This migration makes that attachment
--   explicit so the repo is the source of truth for the full trigger surface.
-- ============================================================================

BEGIN;

-- Idempotent: drop if it already exists (live DB already has it)
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_auth_user();

COMMIT;
