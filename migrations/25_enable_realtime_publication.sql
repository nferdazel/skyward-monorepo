-- ============================================================================
-- SKYWARD REALTIME PUBLICATION ENABLEMENT
-- ============================================================================
-- Enables Supabase Realtime Postgres Changes for the tables that the Flutter
-- client now subscribes to for UI freshness.
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'users'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.users;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'user_fleet'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.user_fleet;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'user_routes'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.user_routes;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'financial_ledger'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.financial_ledger;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'ai_competitors'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.ai_competitors;
    END IF;
END;
$$;
