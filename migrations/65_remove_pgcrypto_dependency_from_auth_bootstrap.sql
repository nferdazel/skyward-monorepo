-- ============================================================================
-- SKYWARD SECURITY PHASE 2.2: REMOVE PGCRYPTO DEPENDENCY FROM AUTH BOOTSTRAP
-- ============================================================================
-- The auth bootstrap trigger runs as SECURITY DEFINER with a restricted
-- search_path. Depending on the live Supabase extension schema layout,
-- unqualified crypt()/gen_salt() calls can fail inside the trigger even though
-- older session RPCs still work.
--
-- Since password_hash is now only a legacy compatibility column during the
-- Supabase Auth cutover, the bootstrap path does not need a bcrypt hash at all.
-- A deterministic placeholder is enough until custom-session auth is retired.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER AS $$
DECLARE
    v_username TEXT;
    v_expected_email TEXT;
    v_company_name TEXT;
    v_ceo_name TEXT;
    v_starting_cash NUMERIC;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.users u
        WHERE u.auth_user_id = NEW.id
    ) THEN
        RETURN NEW;
    END IF;

    v_username := public.normalize_username(NEW.raw_user_meta_data ->> 'username');
    v_company_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'company_name', '')), '');
    v_ceo_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'ceo_name', '')), '');

    IF v_username IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.username';
    END IF;

    IF v_company_name IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.company_name';
    END IF;

    IF v_ceo_name IS NULL THEN
        RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.ceo_name';
    END IF;

    v_expected_email := public.build_synthetic_auth_email(v_username);
    IF lower(COALESCE(NEW.email, '')) <> v_expected_email THEN
        RAISE EXCEPTION 'Auth bootstrap email mismatch for username %', v_username;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.users u
        WHERE u.username = v_username
    ) THEN
        RAISE EXCEPTION 'Username % is already registered.', v_username;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.users u
        WHERE u.company_name = v_company_name
    ) THEN
        RAISE EXCEPTION 'Company name % is already registered.', v_company_name;
    END IF;

    SELECT COALESCE(
        (SELECT g.starting_cash::NUMERIC FROM public.global_game_settings g LIMIT 1),
        15000000.00
    )
    INTO v_starting_cash;

    INSERT INTO public.users (
        auth_user_id,
        username,
        password_hash,
        company_name,
        ceo_name,
        cash,
        net_worth,
        last_active_at
    )
    VALUES (
        NEW.id,
        v_username,
        'supabase-auth:' || NEW.id::TEXT,
        v_company_name,
        v_ceo_name,
        v_starting_cash,
        v_starting_cash,
        NOW()
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog;

COMMENT ON FUNCTION public.handle_new_auth_user() IS
'Bootstraps a public.users actor row from a newly-created auth.users identity using normalized username metadata and the synthetic Skyward auth email convention. Uses a non-crypto legacy placeholder password_hash because Supabase Auth is now the real identity source.';
