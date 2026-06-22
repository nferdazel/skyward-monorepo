-- ============================================================================
-- SKYWARD AIRCRAFT REPLENISHMENT BATCH 01
-- ============================================================================
-- Generated from data/curated/aircraft_replenishment_batch_01_reviewed.csv
-- Scope: missing modern passenger-commercial aircraft families and
-- notable adjacent variants that fit the existing game economy model.
-- ============================================================================

WITH source_rows (
  manufacturer,
  model_name,
  type,
  range_km,
  capacity,
  speed_kmh,
  fuel_burn_per_km,
  maintenance_cost_per_hour,
  purchase_price,
  lease_price_per_month
) AS (
VALUES
  ('Airbus', 'A330-800neo', 'wide_body_jet', 15094, 257, 860, 7.600, 1550.00, 260000000.00, 1300000.00),
  ('ATR', 'ATR 72-500', 'regional_turboprop', 1520, 70, 510, 2.700, 380.00, 22000000.00, 110000.00),
  ('Boeing', '717-200', 'narrow_body_jet', 3815, 134, 822, 3.900, 620.00, 55000000.00, 275000.00),
  ('Boeing', '737 MAX 200', 'narrow_body_jet', 6570, 197, 839, 4.350, 870.00, 123000000.00, 615000.00),
  ('Boeing', '737-600', 'narrow_body_jet', 5600, 123, 838, 4.200, 760.00, 76000000.00, 380000.00),
  ('Boeing', '757-300', 'narrow_body_jet', 6290, 280, 850, 7.300, 1250.00, 130000000.00, 650000.00),
  ('Boeing', '767-400ER', 'wide_body_jet', 10418, 304, 851, 9.800, 1750.00, 230000000.00, 1150000.00),
  ('Boeing', '777-200ER', 'wide_body_jet', 14305, 314, 905, 11.400, 2400.00, 306000000.00, 1530000.00),
  ('Boeing', '777-8', 'wide_body_jet', 16170, 384, 905, 10.100, 2550.00, 410000000.00, 2050000.00),
  ('Bombardier', 'CRJ-550', 'regional_jet', 3000, 50, 829, 3.900, 520.00, 34000000.00, 170000.00),
  ('Embraer', 'E170', 'regional_jet', 3900, 70, 829, 4.000, 560.00, 41000000.00, 205000.00),
  ('Embraer', 'E175-E2', 'regional_jet', 5000, 90, 830, 3.800, 620.00, 57000000.00, 285000.00)
)
UPDATE aircraft_models AS target
SET
  type = source.type,
  range_km = source.range_km,
  capacity = source.capacity,
  speed_kmh = source.speed_kmh,
  fuel_burn_per_km = source.fuel_burn_per_km,
  maintenance_cost_per_hour = source.maintenance_cost_per_hour,
  purchase_price = source.purchase_price,
  lease_price_per_month = source.lease_price_per_month
FROM source_rows AS source
WHERE target.manufacturer = source.manufacturer
  AND target.model_name = source.model_name;

WITH source_rows (
  manufacturer,
  model_name,
  type,
  range_km,
  capacity,
  speed_kmh,
  fuel_burn_per_km,
  maintenance_cost_per_hour,
  purchase_price,
  lease_price_per_month
) AS (
VALUES
  ('Airbus', 'A330-800neo', 'wide_body_jet', 15094, 257, 860, 7.600, 1550.00, 260000000.00, 1300000.00),
  ('ATR', 'ATR 72-500', 'regional_turboprop', 1520, 70, 510, 2.700, 380.00, 22000000.00, 110000.00),
  ('Boeing', '717-200', 'narrow_body_jet', 3815, 134, 822, 3.900, 620.00, 55000000.00, 275000.00),
  ('Boeing', '737 MAX 200', 'narrow_body_jet', 6570, 197, 839, 4.350, 870.00, 123000000.00, 615000.00),
  ('Boeing', '737-600', 'narrow_body_jet', 5600, 123, 838, 4.200, 760.00, 76000000.00, 380000.00),
  ('Boeing', '757-300', 'narrow_body_jet', 6290, 280, 850, 7.300, 1250.00, 130000000.00, 650000.00),
  ('Boeing', '767-400ER', 'wide_body_jet', 10418, 304, 851, 9.800, 1750.00, 230000000.00, 1150000.00),
  ('Boeing', '777-200ER', 'wide_body_jet', 14305, 314, 905, 11.400, 2400.00, 306000000.00, 1530000.00),
  ('Boeing', '777-8', 'wide_body_jet', 16170, 384, 905, 10.100, 2550.00, 410000000.00, 2050000.00),
  ('Bombardier', 'CRJ-550', 'regional_jet', 3000, 50, 829, 3.900, 520.00, 34000000.00, 170000.00),
  ('Embraer', 'E170', 'regional_jet', 3900, 70, 829, 4.000, 560.00, 41000000.00, 205000.00),
  ('Embraer', 'E175-E2', 'regional_jet', 5000, 90, 830, 3.800, 620.00, 57000000.00, 285000.00)
)
INSERT INTO aircraft_models (
  manufacturer,
  model_name,
  type,
  range_km,
  capacity,
  speed_kmh,
  fuel_burn_per_km,
  maintenance_cost_per_hour,
  purchase_price,
  lease_price_per_month
)
SELECT
  source.manufacturer,
  source.model_name,
  source.type,
  source.range_km,
  source.capacity,
  source.speed_kmh,
  source.fuel_burn_per_km,
  source.maintenance_cost_per_hour,
  source.purchase_price,
  source.lease_price_per_month
FROM source_rows AS source
WHERE NOT EXISTS (
  SELECT 1
  FROM aircraft_models AS target
  WHERE target.manufacturer = source.manufacturer
    AND target.model_name = source.model_name
);
