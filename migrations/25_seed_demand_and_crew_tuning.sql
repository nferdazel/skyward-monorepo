-- 25_seed_demand_and_crew_tuning.sql — pindahkan konstanta ekonomi yang masih
-- hardcoded di Go ke game_config.
--
-- LATAR: 16 knob ekonomi utama sudah DB-backed lewat tick snapshot
-- (`snap.num`), tapi nilai tuning yang menentukan BENTUK kurva masih hanya ada
-- di kode Go:
--
--   * `distanceDemandFactor` — 500 km, 12000 km, 0.35
--   * price elasticity      — 1.5, 0.8
--   * `crewCostFor`         — anchor 180 kursi, batas 0.5x .. 2.5x
--
-- Akibatnya menyeimbangkan ekonomi berarti mengubah kode, build, dan deploy —
-- bukan satu UPDATE. Ini juga yang membuat kalibrasi di migrasi 05 hanya bisa
-- dijelaskan lewat komentar, bukan lewat config.
--
-- NILAI DI BAWAH = fallback Go yang berlaku sekarang, jadi perilaku TIDAK
-- berubah sedetik pun. Yang berubah hanya di mana nilainya hidup.
-- `ON CONFLICT DO NOTHING` supaya environment yang sudah punya baris (prod)
-- tidak tersentuh; nilai prod baru berubah kalau operator memang meng-UPDATE-nya.
--
-- Catatan kalibrasi GAME-02 (migrasi 05): referensi demand_index 90/90, 800 km,
-- harga di reference fare → `demand_pool_scale` 290 menghasilkan ~162 pax/hari.
-- Angka itu bergantung pada `distance_demand_short_km`/`long_km`/`min_factor`
-- di sini; kalau salah satu diubah, ulangi kalibrasi dan perbarui komentar 05.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

INSERT INTO game_config (key, value, category, unit, description) VALUES
  ('distance_demand_short_km', '500.0', 'simulation', 'km',
   'Rute <= jarak ini memakai distance demand factor maksimum (distanceDemandFactor)'),
  ('distance_demand_long_km', '12000.0', 'simulation', 'km',
   'Rute >= jarak ini memakai distance demand factor minimum (distanceDemandFactor)'),
  ('distance_demand_min_factor', '0.35', 'simulation', NULL,
   'Faktor permintaan terendah untuk rute sangat jauh; 1.0 di short_km turun linear ke nilai ini'),
  ('price_elasticity_max', '1.5', 'simulation', NULL,
   'Batas atas price elasticity pada routeDailyDemand (harga di reference fare)'),
  ('price_elasticity_quadratic', '0.8', 'simulation', NULL,
   'Koefisien kuadrat penurunan permintaan saat harga di atas reference fare'),
  ('crew_cost_anchor_capacity', '180.0', 'simulation', 'seats',
   'Kapasitas yang membuat crewCostFor memakai tarif dasar crew_cost_per_hour tanpa skala'),
  ('crew_cost_min_mult', '0.5', 'simulation', NULL,
   'Batas bawah pengali crewCostFor untuk pesawat kecil'),
  ('crew_cost_max_mult', '2.5', 'simulation', NULL,
   'Batas atas pengali crewCostFor untuk pesawat besar')
ON CONFLICT (key) DO NOTHING;

COMMIT;
