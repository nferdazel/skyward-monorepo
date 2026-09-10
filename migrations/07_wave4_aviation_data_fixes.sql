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
-- E195 (original/E1, 116 seats) is kept; E195-E1 duplicated it.
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
UPDATE aircraft_models SET lease_price_per_month = 134750.0  WHERE model_name = '717-200';
UPDATE aircraft_models SET lease_price_per_month = 151900.0  WHERE model_name = '737-500';
UPDATE aircraft_models SET lease_price_per_month = 186200.0  WHERE model_name = '737-600';
UPDATE aircraft_models SET lease_price_per_month = 218050.0  WHERE model_name = '737-700';
UPDATE aircraft_models SET lease_price_per_month = 259700.0  WHERE model_name = '737-800';
UPDATE aircraft_models SET lease_price_per_month = 274400.0  WHERE model_name = '737-900ER';
UPDATE aircraft_models SET lease_price_per_month = 328300.0  WHERE model_name = '737 MAX 10';
UPDATE aircraft_models SET lease_price_per_month = 301350.0  WHERE model_name = '737 MAX 200';
UPDATE aircraft_models SET lease_price_per_month = 245000.0  WHERE model_name = '737 MAX 7';
UPDATE aircraft_models SET lease_price_per_month = 296450.0  WHERE model_name = '737 MAX 8';
UPDATE aircraft_models SET lease_price_per_month = 313600.0  WHERE model_name = '737 MAX 9';
UPDATE aircraft_models SET lease_price_per_month = 1024100.0 WHERE model_name = '747-8';
UPDATE aircraft_models SET lease_price_per_month = 281750.0  WHERE model_name = '757-200';
UPDATE aircraft_models SET lease_price_per_month = 318500.0  WHERE model_name = '757-300';
UPDATE aircraft_models SET lease_price_per_month = 492450.0  WHERE model_name = '767-300ER';
UPDATE aircraft_models SET lease_price_per_month = 563500.0  WHERE model_name = '767-400ER';
UPDATE aircraft_models SET lease_price_per_month = 749700.0  WHERE model_name = '777-200ER';
UPDATE aircraft_models SET lease_price_per_month = 847700.0  WHERE model_name = '777-200LR';
UPDATE aircraft_models SET lease_price_per_month = 808500.0  WHERE model_name = '777-300';
UPDATE aircraft_models SET lease_price_per_month = 918750.0  WHERE model_name = '777-300ER';
UPDATE aircraft_models SET lease_price_per_month = 1004500.0 WHERE model_name = '777-8';
UPDATE aircraft_models SET lease_price_per_month = 1082900.0 WHERE model_name = '777-9';
UPDATE aircraft_models SET lease_price_per_month = 828100.0  WHERE model_name = '787-10';
UPDATE aircraft_models SET lease_price_per_month = 607600.0  WHERE model_name = '787-8';
UPDATE aircraft_models SET lease_price_per_month = 715400.0  WHERE model_name = '787-9';
UPDATE aircraft_models SET lease_price_per_month = 196000.0  WHERE model_name = 'A220-100';
UPDATE aircraft_models SET lease_price_per_month = 220500.0  WHERE model_name = 'A220-300';
UPDATE aircraft_models SET lease_price_per_month = 171500.0  WHERE model_name = 'A318-100';
UPDATE aircraft_models SET lease_price_per_month = 225400.0  WHERE model_name = 'A319ceo';
UPDATE aircraft_models SET lease_price_per_month = 249900.0  WHERE model_name = 'A319neo';
UPDATE aircraft_models SET lease_price_per_month = 245000.0  WHERE model_name = 'A320ceo';
UPDATE aircraft_models SET lease_price_per_month = 269500.0  WHERE model_name = 'A320neo';
UPDATE aircraft_models SET lease_price_per_month = 289100.0  WHERE model_name = 'A321ceo';
UPDATE aircraft_models SET lease_price_per_month = 330750.0  WHERE model_name = 'A321LR';
UPDATE aircraft_models SET lease_price_per_month = 316050.0  WHERE model_name = 'A321neo';
UPDATE aircraft_models SET lease_price_per_month = 347900.0  WHERE model_name = 'A321XLR';
UPDATE aircraft_models SET lease_price_per_month = 583100.0  WHERE model_name = 'A330-200';
UPDATE aircraft_models SET lease_price_per_month = 646800.0  WHERE model_name = 'A330-300';
UPDATE aircraft_models SET lease_price_per_month = 637000.0  WHERE model_name = 'A330-800neo';
UPDATE aircraft_models SET lease_price_per_month = 725200.0  WHERE model_name = 'A330-900neo';
UPDATE aircraft_models SET lease_price_per_month = 896700.0  WHERE model_name = 'A350-1000';
UPDATE aircraft_models SET lease_price_per_month = 776650.0  WHERE model_name = 'A350-900';
UPDATE aircraft_models SET lease_price_per_month = 1090250.0 WHERE model_name = 'A380-800';
UPDATE aircraft_models SET lease_price_per_month = 93100.0   WHERE model_name = 'ARJ21-700';
UPDATE aircraft_models SET lease_price_per_month = 34300.0   WHERE model_name = 'ATR 42-500';
UPDATE aircraft_models SET lease_price_per_month = 39200.0   WHERE model_name = 'ATR 42-600';
UPDATE aircraft_models SET lease_price_per_month = 53900.0   WHERE model_name = 'ATR 72-500';
UPDATE aircraft_models SET lease_price_per_month = 63700.0   WHERE model_name = 'ATR 72-600';
UPDATE aircraft_models SET lease_price_per_month = 19600.0   WHERE model_name = 'C-212 Aviocar';
UPDATE aircraft_models SET lease_price_per_month = 242550.0  WHERE model_name = 'C919';
UPDATE aircraft_models SET lease_price_per_month = 124950.0  WHERE model_name = 'CRJ-1000';
UPDATE aircraft_models SET lease_price_per_month = 83300.0   WHERE model_name = 'CRJ-550';
UPDATE aircraft_models SET lease_price_per_month = 98000.0   WHERE model_name = 'CRJ-700';
UPDATE aircraft_models SET lease_price_per_month = 117600.0  WHERE model_name = 'CRJ-900';
UPDATE aircraft_models SET lease_price_per_month = 44100.0   WHERE model_name = 'Dash 8 Q300';
UPDATE aircraft_models SET lease_price_per_month = 78400.0   WHERE model_name = 'Dash 8 Q400';
UPDATE aircraft_models SET lease_price_per_month = 100450.0  WHERE model_name = 'E170';
UPDATE aircraft_models SET lease_price_per_month = 107800.0  WHERE model_name = 'E175';
UPDATE aircraft_models SET lease_price_per_month = 139650.0  WHERE model_name = 'E175-E2';
UPDATE aircraft_models SET lease_price_per_month = 127400.0  WHERE model_name = 'E190';
UPDATE aircraft_models SET lease_price_per_month = 147000.0  WHERE model_name = 'E190-E2';
UPDATE aircraft_models SET lease_price_per_month = 134750.0  WHERE model_name = 'E195';
UPDATE aircraft_models SET lease_price_per_month = 159250.0  WHERE model_name = 'E195-E2';
UPDATE aircraft_models SET lease_price_per_month = 232750.0  WHERE model_name = 'MC-21-300';
UPDATE aircraft_models SET lease_price_per_month = 85750.0   WHERE model_name = 'Superjet SSJ-100';

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
    WHEN iata IN ('NKG','CSX','CGO','TAO','TSN','DLC','XMN','FOC','HRB','SHE','URC','KWE','NNG','SYX','HAK','SJW','TYN','HET','TNA','WNZ','NGB','TFU','INC','CGQ','ZUH','SWA','KWL','JJN') THEN 70
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
-- WSI is legitimate but was mislabelled "[Duplicate]".
DELETE FROM airports WHERE iata IN ('REP', 'RML');
UPDATE airports
   SET name = 'Western Sydney International Airport'
 WHERE iata = 'WSI';

COMMIT;
