-- 19_schema_migrations.sql — applied-migrations ledger (refactor plan 0.3)
--
-- LATAR: migrasi diterapkan manual lewat `psql` tanpa catatan apa pun, jadi
-- tidak ada cara membedakan "sudah diterapkan" dari "belum". Migrasi 18 pernah
-- drift ke prod tanpa pernah di-commit; itu kelas masalah yang tabel ini tutup.
--
-- Tabel ini mencatat setiap filename + checksum + waktu apply. Baris 00–18
-- di-backfill karena semua environment yang kita tahu (prod `skyward`,
-- `skyward_test`) sudah menerapkannya. Checksum backfill = NULL (tidak
-- diketahui); `scripts/migrate.sh` hanya memverifikasi checksum untuk migrasi
-- yang dicatatnya sendiri.
--
-- Idempoten: CREATE TABLE IF NOT EXISTS + ON CONFLICT DO NOTHING.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 < this.sql

BEGIN;

CREATE TABLE IF NOT EXISTS schema_migrations (
    filename   text PRIMARY KEY,
    checksum   text,
    applied_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO schema_migrations (filename) VALUES
    ('00_baseline.sql'),
    ('01_security_phase5_rls.sql'),
    ('02_security_phase6_legacy_cleanup.sql'),
    ('03_sync_user_game_time_to_season_clock.sql'),
    ('04_wave1_game_review_fixes.sql'),
    ('05_demand_pool_scale.sql'),
    ('06_cabin_fare_multipliers.sql'),
    ('07_wave4_aviation_data_fixes.sql'),
    ('08_wave4_corrective.sql'),
    ('09_wave5_starting_cash.sql'),
    ('10_wave5_aircraft_tiers.sql'),
    ('11_wave5_bot_price_response.sql'),
    ('12_wave5_china_demand_corrective.sql'),
    ('13_wave5_reset_starting_cash.sql'),
    ('14_wave5_achievement_notified.sql'),
    ('15_finance_snapshots_retention.sql'),
    ('16_loans_money_scale.sql'),
    ('17_game_config_seed.sql'),
    ('18_retire_pgcron_scheduler_health.sql'),
    ('19_schema_migrations.sql')
ON CONFLICT (filename) DO NOTHING;

COMMIT;
