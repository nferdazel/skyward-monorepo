-- WAVE 5 corrective — AVIATION-28 (China demand tail)
--
-- Migration 07's China tiering CASE ... ELSE 40 unintentionally downgraded
-- LXA (Lhasa Gonggar) and XNN (Xining Caojiabao), which were both at 87 in the
-- audit, to 40. 08_wave4_corrective.sql restored the major hubs but missed
-- these two. 07 has since been corrected for fresh applies; this reconciles
-- the live DB.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

UPDATE airports SET demand_index = 70 WHERE iata IN ('LXA', 'XNN');

COMMIT;
