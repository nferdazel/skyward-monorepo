-- 23_reconcile_fk_constraints.sql — kembalikan FK yang hilang di prod (refactor plan 0.2d)
--
-- LATAR: `scripts/drift-check.sh` (item 0.3b) membandingkan schema prod dengan
-- schema hasil migrasi dan menemukan tiga foreign key yang DIDEKLARASIKAN
-- `00_baseline.sql` tetapi tidak ada di database prod:
--
--   users.hq_airport_iata    -> airports(iata)
--   users.season_id          -> season_clock(id)
--   world_tick_log.season_id -> season_clock(id) ON DELETE CASCADE
--
-- Constraint ini hilang di jalur Supabase -> self-host. Data prod tidak
-- melanggar satu pun (diperiksa 2026-09-16: hq_airport_iata invalid 0,
-- users.season_id invalid 0, world_tick_log.season_id invalid 0), jadi
-- menambahkannya aman dan mengembalikan model integritas yang baseline
-- deklarasikan. Jalur tulis juga sudah memvalidasi input (lihat
-- `settings.go` yang memeriksa HQ IATA ke tabel `airports`).
--
-- Idempoten: `ADD CONSTRAINT` tidak punya `IF NOT EXISTS`, jadi keberadaannya
-- diperiksa lewat `pg_constraint` (nama + relasi). No-op di prod setelah ini.
--
-- Apply: make migrate

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'users_hq_airport_iata_fkey'
      AND conrelid = 'public.users'::regclass
  ) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_hq_airport_iata_fkey
      FOREIGN KEY (hq_airport_iata) REFERENCES public.airports(iata);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'users_season_id_fkey'
      AND conrelid = 'public.users'::regclass
  ) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_season_id_fkey
      FOREIGN KEY (season_id) REFERENCES public.season_clock(id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'world_tick_log_season_id_fkey'
      AND conrelid = 'public.world_tick_log'::regclass
  ) THEN
    ALTER TABLE public.world_tick_log
      ADD CONSTRAINT world_tick_log_season_id_fkey
      FOREIGN KEY (season_id) REFERENCES public.season_clock(id) ON DELETE CASCADE;
  END IF;
END
$$;

COMMIT;
