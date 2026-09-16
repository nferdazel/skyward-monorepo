-- 22_role_provisioning.sql — role bootstrap untuk cluster baru (refactor plan 0.2c, keputusan D1)
--
-- LATAR: `00_baseline.sql` adalah dump Supabase. Dua asumsi role-nya tidak
-- berlaku di cluster yang di-bootstrap sendiri:
--
--   1. Hampir semua objek ditutup dengan `ALTER ... OWNER TO "postgres"` dan
--      blok `ALTER DEFAULT PRIVILEGES FOR ROLE "postgres"`. Image postgres resmi
--      TIDAK membuat role bernama `postgres` begitu `POSTGRES_USER` diisi nama
--      lain (ia menjadikan user itu superuser), jadi dump ini gagal di tengah
--      dengan `role "postgres" does not exist` — persis yang terjadi di CI.
--   2. API Go connect sebagai `skyward_app` (login, non-super, tanpa keanggotaan
--      role). Role itu ADA di prod tapi tidak dibuat oleh migrasi mana pun, dan
--      grant-nya juga tidak: fresh env harus di-setup tangan.
--
-- Di prod, migrasi ini praktis no-op: role `postgres` dan `skyward_app` sudah
-- ada, dan 119 grant (7 privilege x 17 tabel) sudah terpasang. Yang benar-benar
-- berubah hanya `ALTER DEFAULT PRIVILEGES` — prod saat ini punya 0 default ACL di
-- `public`, sehingga tabel yang dibuat migrasi BARU tidak otomatis bisa diakses
-- app role (itu sebabnya `schema_migrations` satu-satunya tabel tanpa grant).
-- Default privileges di bawah menutup celah itu dan menyamakan prod dengan
-- cluster hasil migrasi.
--
-- Identitas app role sengaja TIDAK diberi password di sini: file migrasi masuk
-- git, password tidak. Operator menjalankan `scripts/set-app-role-password.sh`.
--
-- Idempoten. Apply: make migrate

BEGIN;

-- 1. Role `postgres` — dibutuhkan oleh `OWNER TO "postgres"` dan
--    `DEFAULT PRIVILEGES FOR ROLE "postgres"` di baseline. Dibuat NOLOGIN:
--    hanya dipakai sebagai pemilik objek, tidak ada yang login sebagai ini.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres') THEN
    CREATE ROLE postgres NOLOGIN;
  END IF;
END
$$;

-- 2. Role aplikasi. NOLOGIN tidak dipakai: API memang login sebagai role ini.
--    Tanpa password sampai operator memasangnya.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skyward_app') THEN
    CREATE ROLE skyward_app LOGIN;
  END IF;
END
$$;

-- 3. Grant data untuk app role. Daftar tabel dan privilege-nya disalin dari prod
--    (7 privilege x 17 tabel = 119 grant). `schema_migrations` sengaja TIDAK
--    ikut: itu buku besar migrasi, bukan tabel aplikasi.
GRANT SELECT, INSERT, UPDATE, DELETE, REFERENCES, TRIGGER, TRUNCATE ON TABLE
    public.achievements,
    public.aircraft_models,
    public.airports,
    public.bank_accounts,
    public.bank_transactions,
    public.bot_profiles,
    public.credit_score_history,
    public.credit_scores,
    public.finance_snapshots,
    public.fleet_aircraft,
    public.game_config,
    public.game_events,
    public.loans,
    public.route_assignments,
    public.season_clock,
    public.users,
    public.world_tick_log
TO skyward_app;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO skyward_app;

-- 4. Default privileges: objek yang dibuat NANTI ikut ter-grant.
--    Tanpa `FOR ROLE` = berlaku untuk role yang menjalankan migrasi (qouver di
--    prod, apa pun di cluster baru). `FOR ROLE postgres` menutup jalur objek yang
--    dibuat sebagai owner dump.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE, REFERENCES, TRIGGER, TRUNCATE ON TABLES TO skyward_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO skyward_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE, REFERENCES, TRIGGER, TRUNCATE ON TABLES TO skyward_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO skyward_app;

COMMIT;
