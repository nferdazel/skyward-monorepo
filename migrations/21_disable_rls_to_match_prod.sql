-- 21_disable_rls_to_match_prod.sql — converge the RLS posture (refactor plan 0.2b, decision D5)
--
-- LATAR: `01_security_phase5_rls.sql` meng-ENABLE RLS di 14 tabel dan membuat 15
-- policy berbasis `auth.uid()`. Itu sisa era Supabase, ketika PostgREST memakai
-- JWT + role `anon`/`authenticated`.
--
-- Sejak API Go (`apps/api`) jadi satu-satunya otoritas, prod berjalan dengan RLS
-- **nonaktif** dan **nol policy** (diverifikasi 2026-09-16: tabel ber-RLS = 0,
-- `pg_policies` = 0 di `skyward` maupun `skyward_test`). API juga connect sebagai
-- `skyward_app`, bukan owner tabel, jadi RLS aktif membuat database hasil
-- migrasi tidak berfungsi untuk API — sementara prod tidak terpengaruh. Itu
-- berarti "fresh env" dan "prod" tidak berada di konfigurasi yang sama.
--
-- Otorisasi sekarang hidup di Go: middleware JWT + predikat `user_id` di query.
-- Migrasi ini menyamakan keduanya: mematikan RLS di 14 tabel dan menghapus 15
-- policy lama. Idempoten — di prod semuanya no-op.
--
-- Apply: make migrate

BEGIN;

-- --------------------------------------------------------------------------
-- 1. MATIKAN RLS
-- --------------------------------------------------------------------------

ALTER TABLE IF EXISTS public.users                 DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.bank_accounts         DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.bank_transactions     DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.fleet_aircraft        DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.route_assignments     DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.loans                 DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.credit_scores         DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.credit_score_history  DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.achievements          DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.aircraft_models       DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.airports              DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.game_config           DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.season_clock          DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.bot_profiles          DISABLE ROW LEVEL SECURITY;

-- --------------------------------------------------------------------------
-- 2. HAPUS POLICY LAMA (public read pada tabel definisi game)
-- --------------------------------------------------------------------------

DROP POLICY IF EXISTS "Allow public read access on aircraft_models" ON public.aircraft_models;
DROP POLICY IF EXISTS "Allow public read access on airports"        ON public.airports;
DROP POLICY IF EXISTS "Allow public read access on game_config"     ON public.game_config;
DROP POLICY IF EXISTS "Allow public read access on season_clock"    ON public.season_clock;
DROP POLICY IF EXISTS "Allow public read access on bot_profiles"    ON public.bot_profiles;

-- --------------------------------------------------------------------------
-- 3. HAPUS POLICY LAMA (isolasi tenant)
-- --------------------------------------------------------------------------

DROP POLICY IF EXISTS "Users can view their own profile or public leaderboard data" ON public.users;
DROP POLICY IF EXISTS "Users can update their own profile"                          ON public.users;
DROP POLICY IF EXISTS "Users can access their own bank accounts"                    ON public.bank_accounts;
DROP POLICY IF EXISTS "Users can access their own transactions"                     ON public.bank_transactions;
DROP POLICY IF EXISTS "Users can access their own fleet"                            ON public.fleet_aircraft;
DROP POLICY IF EXISTS "Users can access their own route assignments"                ON public.route_assignments;
DROP POLICY IF EXISTS "Users can access their own loans"                            ON public.loans;
DROP POLICY IF EXISTS "Users can view their own credit score"                       ON public.credit_scores;
DROP POLICY IF EXISTS "Users can view their own credit score history"               ON public.credit_score_history;
DROP POLICY IF EXISTS "Users can view their own achievements"                       ON public.achievements;

-- --------------------------------------------------------------------------
-- 4. BUKTI KONVERGENSI — gagal keras kalau masih ada sisa
-- --------------------------------------------------------------------------

DO $$
DECLARE
  rls_tables int;
  policies   int;
BEGIN
  SELECT count(*) INTO rls_tables
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity;

  SELECT count(*) INTO policies
    FROM pg_policies WHERE schemaname = 'public';

  IF rls_tables <> 0 OR policies <> 0 THEN
    RAISE EXCEPTION 'RLS belum konvergen: % tabel masih ber-RLS, % policy tersisa',
      rls_tables, policies;
  END IF;
END $$;

COMMIT;
