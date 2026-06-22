-- ============================================================================
-- SKYWARD SECURITY PHASE 2: AUTH BOOTSTRAP TRIGGER
-- ============================================================================
-- Binds Supabase Auth user creation to the public.users gameplay actor table.
--
-- Expected auth user metadata on creation:
--   - username
--   - company_name
--   - ceo_name
--
-- The future username-only registration flow will:
--   1. build the synthetic auth email from the normalized username
--   2. create an auto-confirmed auth.users row server-side
--   3. let this trigger create the corresponding public.users actor row
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

    SELECT COALESCE(starting_cash, 15000000.00)
    INTO v_starting_cash
    FROM public.global_game_settings
    LIMIT 1;

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
        crypt(gen_random_uuid()::TEXT, gen_salt('bf', 8)),
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

DROP TRIGGER IF EXISTS trg_auth_users_bootstrap_public_user ON auth.users;
CREATE TRIGGER trg_auth_users_bootstrap_public_user
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_auth_user();

COMMENT ON FUNCTION public.handle_new_auth_user() IS
'Bootstraps a public.users actor row from a newly-created auth.users identity using normalized username metadata and the synthetic Skyward auth email convention.';
