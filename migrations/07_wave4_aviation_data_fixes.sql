-- WAVE 4 — Aviation data integrity pass
-- Source: docs/reviews/aviation-realism-review-2026-09.md (items AVIATION-01..32)
--
-- All changes are idempotent-ish data corrections to reference tables. Apply:
--   podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql
--
-- Verified against live DB 2026-09-10 (values matched the audit snapshot).

BEGIN;

-- ── AVIATION-01: 747-8 cruise speed (was MMO 988 km/h) ─────────────────────
UPDATE aircraft_models SET speed_kmh = 913
 WHERE manufacturer = 'Boeing' AND model_name = '747-8';

-- ── AVIATION-02: SSJ-100 range over-stated (4400 -> ~3000) ─────────────────
UPDATE aircraft_models SET range_km = 3000
 WHERE manufacturer = 'Sukhoi' AND model_name = 'Superjet SSJ-100';

-- ── AVIATION-03: ARJ21-700 range over-stated (3700 -> ~2225) ───────────────
UPDATE aircraft_models SET range_km = 2225
 WHERE manufacturer = 'COMAC' AND model_name = 'ARJ21-700';

-- ── AVIATION-04: C919 range over-stated (5550 -> ~4075) ────────────────────
UPDATE aircraft_models SET range_km = 4075
 WHERE manufacturer = 'COMAC' AND model_name = 'C919';

-- ── AVIATION-06: CRJ-550 range over-stated (3000 -> ~2600) ─────────────────
UPDATE aircraft_models SET range_km = 2600
 WHERE manufacturer = 'Bombardier' AND model_name = 'CRJ-550';

-- ── AVIATION-07: ATR 72-600 fuel burn (2.5 -> ~2.0 L/km) ───────────────────
UPDATE aircraft_models SET fuel_burn_per_km = 2.0
 WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600';

-- ── AVIATION-05: remove duplicate E195-E1 (identical to E195) ──────────────
-- E195 (original/E1, 116 seats) is kept; E195-E1 duplicated it. Re-point any
-- fleet rows that reference the duplicate to the kept model first so the
-- delete cannot abort on the FK (fleet_aircraft_aircraft_model_id_fkey).
UPDATE fleet_aircraft
   SET aircraft_model_id = (SELECT id FROM aircraft_models
                             WHERE manufacturer='Embraer' AND model_name='E195' LIMIT 1)
 WHERE aircraft_model_id IN (SELECT id FROM aircraft_models
                              WHERE manufacturer='Embraer' AND model_name='E195-E1');
DELETE FROM aircraft_models
 WHERE manufacturer = 'Embraer' AND model_name = 'E195-E1';

-- ── AVIATION-22: normalize narrow-body turnaround times ────────────────────
-- Stretch narrowbodies were 1.5h; real gate turns are <=1.0h. Tier by size:
-- standard (<=220 seats) 0.75h, large/stretch (>220) 1.0h.
UPDATE aircraft_models SET turnaround_hours = 0.75
 WHERE type = 'narrow_body_jet' AND capacity <= 220;
UPDATE aircraft_models SET turnaround_hours = 1.0
 WHERE type = 'narrow_body_jet' AND capacity > 220;

-- ── AVIATION-10: lease prices ~30% above real dry-lease rates ──────────────
-- Absolute target values (original * 0.70, precomputed) so this migration is
-- idempotent and re-running does not compound the discount.
UPDATE aircraft_models SET lease_price_per_month = 192500.0  WHERE model_name = '717-200';
UPDATE aircraft_models SET lease_price_per_month = 217000.0  WHERE model_name = '737-500';
UPDATE aircraft_models SET lease_price_per_month = 266000.0  WHERE model_name = '737-600';
UPDATE aircraft_models SET lease_price_per_month = 311500.0  WHERE model_name = '737-700';
UPDATE aircraft_models SET lease_price_per_month = 371000.0  WHERE model_name = '737-800';
UPDATE aircraft_models SET lease_price_per_month = 392000.0  WHERE model_name = '737-900ER';
UPDATE aircraft_models SET lease_price_per_month = 469000.0  WHERE model_name = '737 MAX 10';
UPDATE aircraft_models SET lease_price_per_month = 430500.0  WHERE model_name = '737 MAX 200';
UPDATE aircraft_models SET lease_price_per_month = 350000.0  WHERE model_name = '737 MAX 7';
UPDATE aircraft_models SET lease_price_per_month = 423500.0  WHERE model_name = '737 MAX 8';
UPDATE aircraft_models SET lease_price_per_month = 448000.0  WHERE model_name = '737 MAX 9';
UPDATE aircraft_models SET lease_price_per_month = 1463000.0 WHERE model_name = '747-8';
UPDATE aircraft_models SET lease_price_per_month = 402500.0  WHERE model_name = '757-200';
UPDATE aircraft_models SET lease_price_per_month = 455000.0  WHERE model_name = '757-300';
UPDATE aircraft_models SET lease_price_per_month = 703500.0  WHERE model_name = '767-300ER';
UPDATE aircraft_models SET lease_price_per_month = 805000.0  WHERE model_name = '767-400ER';
UPDATE aircraft_models SET lease_price_per_month = 1071000.0  WHERE model_name = '777-200ER';
UPDATE aircraft_models SET lease_price_per_month = 1211000.0  WHERE model_name = '777-200LR';
UPDATE aircraft_models SET lease_price_per_month = 1155000.0  WHERE model_name = '777-300';
UPDATE aircraft_models SET lease_price_per_month = 1312500.0  WHERE model_name = '777-300ER';
UPDATE aircraft_models SET lease_price_per_month = 1435000.0 WHERE model_name = '777-8';
UPDATE aircraft_models SET lease_price_per_month = 1547000.0 WHERE model_name = '777-9';
UPDATE aircraft_models SET lease_price_per_month = 1183000.0  WHERE model_name = '787-10';
UPDATE aircraft_models SET lease_price_per_month = 868000.0  WHERE model_name = '787-8';
UPDATE aircraft_models SET lease_price_per_month = 1022000.0  WHERE model_name = '787-9';
UPDATE aircraft_models SET lease_price_per_month = 280000.0  WHERE model_name = 'A220-100';
UPDATE aircraft_models SET lease_price_per_month = 315000.0  WHERE model_name = 'A220-300';
UPDATE aircraft_models SET lease_price_per_month = 245000.0  WHERE model_name = 'A318-100';
UPDATE aircraft_models SET lease_price_per_month = 322000.0  WHERE model_name = 'A319ceo';
UPDATE aircraft_models SET lease_price_per_month = 357000.0  WHERE model_name = 'A319neo';
UPDATE aircraft_models SET lease_price_per_month = 350000.0  WHERE model_name = 'A320ceo';
UPDATE aircraft_models SET lease_price_per_month = 385000.0  WHERE model_name = 'A320neo';
UPDATE aircraft_models SET lease_price_per_month = 413000.0  WHERE model_name = 'A321ceo';
UPDATE aircraft_models SET lease_price_per_month = 472500.0  WHERE model_name = 'A321LR';
UPDATE aircraft_models SET lease_price_per_month = 451500.0  WHERE model_name = 'A321neo';
UPDATE aircraft_models SET lease_price_per_month = 497000.0  WHERE model_name = 'A321XLR';
UPDATE aircraft_models SET lease_price_per_month = 833000.0  WHERE model_name = 'A330-200';
UPDATE aircraft_models SET lease_price_per_month = 924000.0  WHERE model_name = 'A330-300';
UPDATE aircraft_models SET lease_price_per_month = 910000.0  WHERE model_name = 'A330-800neo';
UPDATE aircraft_models SET lease_price_per_month = 1036000.0  WHERE model_name = 'A330-900neo';
UPDATE aircraft_models SET lease_price_per_month = 1281000.0  WHERE model_name = 'A350-1000';
UPDATE aircraft_models SET lease_price_per_month = 1109500.0  WHERE model_name = 'A350-900';
UPDATE aircraft_models SET lease_price_per_month = 1557500.0 WHERE model_name = 'A380-800';
UPDATE aircraft_models SET lease_price_per_month = 133000.0   WHERE model_name = 'ARJ21-700';
UPDATE aircraft_models SET lease_price_per_month = 49000.0   WHERE model_name = 'ATR 42-500';
UPDATE aircraft_models SET lease_price_per_month = 56000.0   WHERE model_name = 'ATR 42-600';
UPDATE aircraft_models SET lease_price_per_month = 77000.0   WHERE model_name = 'ATR 72-500';
UPDATE aircraft_models SET lease_price_per_month = 91000.0   WHERE model_name = 'ATR 72-600';
UPDATE aircraft_models SET lease_price_per_month = 28000.0   WHERE model_name = 'C-212 Aviocar';
UPDATE aircraft_models SET lease_price_per_month = 346500.0  WHERE model_name = 'C919';
UPDATE aircraft_models SET lease_price_per_month = 178500.0  WHERE model_name = 'CRJ-1000';
UPDATE aircraft_models SET lease_price_per_month = 119000.0   WHERE model_name = 'CRJ-550';
UPDATE aircraft_models SET lease_price_per_month = 140000.0   WHERE model_name = 'CRJ-700';
UPDATE aircraft_models SET lease_price_per_month = 168000.0  WHERE model_name = 'CRJ-900';
UPDATE aircraft_models SET lease_price_per_month = 63000.0   WHERE model_name = 'Dash 8 Q300';
UPDATE aircraft_models SET lease_price_per_month = 112000.0   WHERE model_name = 'Dash 8 Q400';
UPDATE aircraft_models SET lease_price_per_month = 143500.0  WHERE model_name = 'E170';
UPDATE aircraft_models SET lease_price_per_month = 154000.0  WHERE model_name = 'E175';
UPDATE aircraft_models SET lease_price_per_month = 199500.0  WHERE model_name = 'E175-E2';
UPDATE aircraft_models SET lease_price_per_month = 182000.0  WHERE model_name = 'E190';
UPDATE aircraft_models SET lease_price_per_month = 210000.0  WHERE model_name = 'E190-E2';
UPDATE aircraft_models SET lease_price_per_month = 192500.0  WHERE model_name = 'E195';
UPDATE aircraft_models SET lease_price_per_month = 227500.0  WHERE model_name = 'E195-E2';
UPDATE aircraft_models SET lease_price_per_month = 332500.0  WHERE model_name = 'MC-21-300';
UPDATE aircraft_models SET lease_price_per_month = 122500.0   WHERE model_name = 'Superjet SSJ-100';

-- ── AVIATION-30/31/32: special-case airports ────────────────────────────────
-- NOTE: these run AFTER the China/India tiering below, because the tiering
-- CASE would otherwise overwrite RKZ (a Chinese airport).

-- ── AVIATION-28: tier Chinese airports (flat 87 -> hub tiers) ──────────────
-- Explicit tiers. Airports that already had distinct values (PKX 85, SHA 82,
-- etc.) are re-asserted so the ELSE only catches the flat-87 long tail.
UPDATE airports SET demand_index = CASE
    WHEN iata IN ('PVG')                                             THEN 95
    WHEN iata IN ('PEK')                                             THEN 94
    WHEN iata IN ('CAN')                                             THEN 92
    WHEN iata IN ('PKX','SZX')                                       THEN 85
    WHEN iata IN ('SHA')                                             THEN 82
    WHEN iata IN ('CTU','KMG','XIY','CKG','HGH','WUH')              THEN 80
    WHEN iata IN ('NKG','CSX','CGO','TAO','TSN','DLC','XMN','FOC','HRB','SHE','URC','KWE','NNG','SYX','HAK','SJW','TYN','HET','TNA','WNZ','NGB','TFU','INC','CGQ','ZUH','SWA','KWL','JJN','LXA','XNN') THEN 70
    WHEN iata IN ('EHU','HFE','HIA','LYG','YIW','WUX','HSN','JHG','KHG','LHW','LJG','DYG','DSN','BAV','DAT','TXN','YCU','YNZ','YNT','ZHA','NDG','JGN','LYA','DNH','HLD','KHN') THEN 55
    ELSE 40
  END
 WHERE country = 'China';

-- ── AVIATION-29: tier Indian airports (flat 78 -> tiers) ───────────────────
-- DEL 92, BOM 90 already set.
UPDATE airports SET demand_index = CASE
    WHEN iata IN ('DEL')                                           THEN 92
    WHEN iata IN ('BOM')                                           THEN 90
    WHEN iata IN ('BLR','HYD','MAA','CCU')                         THEN 85
    WHEN iata IN ('COK','GOI','AMD','PNQ','LKO','JAI','GOX','NMI') THEN 75
    WHEN iata IN ('IXZ','SXR','GAU','ATQ','VNS','IDR','NAG','CJB','CCJ','TRV','IXE','IXC','IXB','VGA','TRZ','TIR','BBI','BDQ','BHO','STV','IMF','VTZ','CNN','HSR','HWR','HSS','ISK','SAG') THEN 60
    ELSE 40
  END
 WHERE country = 'India';

-- ── AVIATION-30: DIA (Doha) closed to commercial traffic since 2014 ────────
UPDATE airports SET demand_index = 30
 WHERE iata = 'DIA';

-- ── AVIATION-31: RKZ (Xigaze) is primarily a military airbase ──────────────
-- Must run after the China tiering.
UPDATE airports SET demand_index = 20
 WHERE iata = 'RKZ';

-- ── AVIATION-32: duplicate / stale airport entries ─────────────────────────
-- REP superseded by SAI (Siem Reap-Angkor, 2023). RML duplicates CMB (Colombo).
-- WSI is legitimate but was mislabelled "[Duplicate]". Re-point any references
-- first (users.hq_airport_iata, route_assignments origin/destination,
-- bot_profiles.secondary_hub_iata) so the delete cannot abort on an FK.
-- The reassignment is guarded on the target airport existing, and routes whose
-- re-pointed (user_id, origin, destination) would collide with an existing row
-- under the unique_human_route index are redirected to CMB/SAI only when safe;
-- otherwise the conflicting legacy route is removed before the delete.
DO $$
DECLARE
    r RECORD;
BEGIN
    IF EXISTS (SELECT 1 FROM airports WHERE iata = 'SAI') THEN
        UPDATE users SET hq_airport_iata = 'SAI' WHERE hq_airport_iata = 'REP';
        UPDATE bot_profiles SET secondary_hub_iata = 'SAI' WHERE secondary_hub_iata = 'REP';
        FOR r IN SELECT id, user_id, origin_iata, destination_iata
                 FROM route_assignments WHERE origin_iata = 'REP' OR destination_iata = 'REP' LOOP
            IF (CASE WHEN r.origin_iata = 'REP' THEN 'SAI' ELSE r.origin_iata END) =
               (CASE WHEN r.destination_iata = 'REP' THEN 'SAI' ELSE r.destination_iata END) THEN
                -- Re-pointing would create a degenerate SAI->SAI self-loop.
                DELETE FROM route_assignments WHERE id = r.id;
            ELSIF EXISTS (SELECT 1 FROM route_assignments
                       WHERE user_id = r.user_id
                         AND origin_iata = CASE WHEN r.origin_iata = 'REP' THEN 'SAI' ELSE r.origin_iata END
                         AND destination_iata = CASE WHEN r.destination_iata = 'REP' THEN 'SAI' ELSE r.destination_iata END
                         AND id <> r.id) THEN
                DELETE FROM route_assignments WHERE id = r.id;
            ELSE
                UPDATE route_assignments
                   SET origin_iata = CASE WHEN r.origin_iata = 'REP' THEN 'SAI' ELSE r.origin_iata END,
                       destination_iata = CASE WHEN r.destination_iata = 'REP' THEN 'SAI' ELSE r.destination_iata END
                 WHERE id = r.id;
            END IF;
        END LOOP;
    END IF;

    IF EXISTS (SELECT 1 FROM airports WHERE iata = 'CMB') THEN
        UPDATE users SET hq_airport_iata = 'CMB' WHERE hq_airport_iata = 'RML';
        UPDATE bot_profiles SET secondary_hub_iata = 'CMB' WHERE secondary_hub_iata = 'RML';
        FOR r IN SELECT id, user_id, origin_iata, destination_iata
                 FROM route_assignments WHERE origin_iata = 'RML' OR destination_iata = 'RML' LOOP
            IF (CASE WHEN r.origin_iata = 'RML' THEN 'CMB' ELSE r.origin_iata END) =
               (CASE WHEN r.destination_iata = 'RML' THEN 'CMB' ELSE r.destination_iata END) THEN
                -- Re-pointing would create a degenerate CMB->CMB self-loop.
                DELETE FROM route_assignments WHERE id = r.id;
            ELSIF EXISTS (SELECT 1 FROM route_assignments
                       WHERE user_id = r.user_id
                         AND origin_iata = CASE WHEN r.origin_iata = 'RML' THEN 'CMB' ELSE r.origin_iata END
                         AND destination_iata = CASE WHEN r.destination_iata = 'RML' THEN 'CMB' ELSE r.destination_iata END
                         AND id <> r.id) THEN
                DELETE FROM route_assignments WHERE id = r.id;
            ELSE
                UPDATE route_assignments
                   SET origin_iata = CASE WHEN r.origin_iata = 'RML' THEN 'CMB' ELSE r.origin_iata END,
                       destination_iata = CASE WHEN r.destination_iata = 'RML' THEN 'CMB' ELSE r.destination_iata END
                 WHERE id = r.id;
            END IF;
        END LOOP;
    END IF;
END $$;
DELETE FROM airports WHERE iata IN ('REP', 'RML');
UPDATE airports
   SET name = 'Western Sydney International Airport'
 WHERE iata = 'WSI';

COMMIT;
