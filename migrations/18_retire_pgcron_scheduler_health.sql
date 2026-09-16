-- 18_retire_pgcron_scheduler_health.sql — retire fungsi audit era pg_cron
--
-- LATAR (verifikasi live 2026-09-12): `get_world_tick_scheduler_health()`
-- mereferensikan `cron.job`, tapi ekstensi `pg_cron` TIDAK terpasang di DB
-- skyward (pg_extension hanya `plpgsql`). Akibatnya fungsi ini SELALU error
-- `relation "cron.job" does not exist` — dead sejak world-tick pindah ke
-- worker Go in-process.
--
-- Bukti (live prod 2026-09-12):
--   SELECT extname FROM pg_extension;           -- plpgsql (tidak ada pg_cron)
--   SELECT * FROM get_world_tick_scheduler_health(); -- ERROR: cron.job tidak ada
--   SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--     WHERE n.nspname='public' AND p.prosrc ILIKE '%cron%';  -- 1 (fungsi ini)
--
-- Penggantinya sudah ada: `GET /admin/worker/status` (worker Go) untuk status
-- tick, dan `get_world_tick_guardrail_report()` (masih berfungsi — diverifikasi
-- mengembalikan 5 check `pass` pada 2026-09-12) untuk audit season/actor/tick.
--
-- Tidak ada kode Go maupun route HTTP yang memanggil fungsi ini (hanya docs).
-- Definisi asli tetap ada di `00_baseline.sql` bila perlu dipulihkan.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

DROP FUNCTION IF EXISTS "public"."get_world_tick_scheduler_health"();

COMMIT;
