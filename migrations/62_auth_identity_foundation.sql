-- ============================================================================
-- SKYWARD SECURITY PHASE 1: AUTH IDENTITY FOUNDATION
-- ============================================================================
-- Introduces the durable linkage needed for the future Supabase Auth cutover
-- while leaving the current custom-session gameplay flow intact for now.
--
-- Phase 1 scope:
--   1. Add users.auth_user_id as the future identity anchor to auth.users.
--   2. Add deterministic helpers for username normalization and synthetic
--      email derivation so Flutter, Edge Functions, and SQL share one format.
--   3. Add helper lookups for auth.uid() -> public.users ownership resolution.
--   4. Keep existing runtime behavior unchanged until the later cutover phases.
-- ============================================================================

ALTER TABLE public.users
ADD COLUMN IF NOT EXISTS auth_user_id UUID;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'users_auth_user_id_fkey'
    ) THEN
        ALTER TABLE public.users
        ADD CONSTRAINT users_auth_user_id_fkey
        FOREIGN KEY (auth_user_id)
        REFERENCES auth.users(id)
        ON DELETE SET NULL;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS users_auth_user_id_unique_idx
ON public.users(auth_user_id)
WHERE auth_user_id IS NOT NULL;


CREATE OR REPLACE FUNCTION public.normalize_username(
    p_username TEXT
)
RETURNS TEXT AS $$
    SELECT NULLIF(
        regexp_replace(
            lower(trim(COALESCE(p_username, ''))),
            '[^a-z0-9._-]+',
            '-',
            'g'
        ),
        ''
    );
$$ LANGUAGE sql IMMUTABLE;


CREATE OR REPLACE FUNCTION public.build_synthetic_auth_email(
    p_username TEXT
)
RETURNS TEXT AS $$
    SELECT public.normalize_username(p_username) || '@skyward.sachiel.id';
$$ LANGUAGE sql IMMUTABLE;


CREATE OR REPLACE FUNCTION public.get_user_id_for_auth_uid(
    p_auth_user_id UUID DEFAULT auth.uid()
)
RETURNS UUID AS $$
    SELECT u.id
    FROM public.users u
    WHERE u.auth_user_id = p_auth_user_id
    LIMIT 1;
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION public.get_current_user_id()
RETURNS UUID AS $$
    SELECT public.get_user_id_for_auth_uid(auth.uid());
$$ LANGUAGE sql STABLE;


COMMENT ON COLUMN public.users.auth_user_id IS
'Future Supabase Auth identity anchor. Custom sessions remain active until the auth cutover phases replace them.';

COMMENT ON FUNCTION public.normalize_username(TEXT) IS
'Normalizes a user-facing username into a lowercase slug-safe identifier for future auth and uniqueness workflows.';

COMMENT ON FUNCTION public.build_synthetic_auth_email(TEXT) IS
'Builds the synthetic Supabase Auth email address used by the planned username-only login flow.';

COMMENT ON FUNCTION public.get_user_id_for_auth_uid(UUID) IS
'Resolves a Supabase Auth user id to the matching public.users actor row.';

COMMENT ON FUNCTION public.get_current_user_id() IS
'Convenience helper for future authenticated RPCs to resolve auth.uid() to public.users.id.';
