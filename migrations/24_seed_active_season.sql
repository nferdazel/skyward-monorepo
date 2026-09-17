-- 24_seed_active_season.sql — season aktif untuk environment baru
--
-- LATAR: tidak ada satu pun migrasi yang membuat baris `season_clock`. Prod
-- punya season aktif ("Season 1"), tapi baris itu datang dari setup manual era
-- Supabase; `00_baseline.sql` adalah dump SCHEMA dan tidak menyisipkannya, dan
-- 20_reference_data_seed.sql hanya mengisi `airports` + `aircraft_models`.
--
-- Akibatnya sebuah database yang dibangun hanya dari migrasi TIDAK BISA
-- BERFUNGSI, dan kegagalannya menyesatkan:
--   - `POST /auth/register` balas 500 `internal error` (bukan pesan yang
--     menjelaskan bahwa season-nya belum ada);
--   - world tick gagal setiap menit dengan "no active season or lock failed";
--   - `POST /simulation/sync` balas 500 "no active season for simulation sync".
-- Ditemukan 2026-09-17 saat menguji apakah schema bisa direproduksi dari
-- migrasi saja.
--
-- Idempotent: `season_clock_one_active_idx` hanya mengizinkan satu baris
-- berstatus 'active', jadi INSERT dijaga `WHERE NOT EXISTS`. Di prod dan
-- database yang sudah punya season, ini no-op.
--
-- `current_game_time` sengaja dibiarkan memakai default kolom
-- ('2020-01-01 00:00:00+00') alih-alih menyontek jam prod: environment baru
-- harus mulai dari awal season, bukan dari posisi waktu prod. Nilai ini juga
-- yang membuat perbedaan prod-vs-migrasi pada kolom itu disengaja, bukan drift.

INSERT INTO season_clock (label, status, current_game_time)
SELECT 'Season 1', 'active', '2020-01-01 00:00:00+00'::timestamptz
WHERE NOT EXISTS (
    SELECT 1 FROM season_clock WHERE status = 'active'
);
