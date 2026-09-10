-- WAVE 4 corrective — AVIATION-28/31
--
-- Migration 07 was applied while its China tiering still used a CASE ... ELSE 40
-- that unintentionally downgraded Chinese airports which already had distinct
-- values (PKX 85, SHA 82) to 40, and RKZ (set to 20 by 07) was later clobbered
-- back to 40. 07 has since been corrected for fresh applies; this migration
-- reconciles the live DB to the intended end state.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

-- Major hubs downgraded by 07's ELSE.
UPDATE airports SET demand_index = 85 WHERE iata IN ('PKX', 'SZX');
UPDATE airports SET demand_index = 82 WHERE iata = 'SHA';
UPDATE airports SET demand_index = 80 WHERE iata IN ('CTU', 'KMG', 'XIY', 'CKG', 'HGH', 'WUH');

-- Military airbase must stay low (07's tiering overwrote the earlier value).
UPDATE airports SET demand_index = 20 WHERE iata = 'RKZ';

COMMIT;
