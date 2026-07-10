-- Rename stale constraint/index names left over from the user_fleet / user_routes
-- era in 00_baseline.sql.  These names no longer match the current table names
-- (fleet_aircraft, route_assignments) and cause confusion during audits.
--
-- Safe to run on existing databases: RENAME does not lock the table.

BEGIN;

-- fleet_aircraft constraints
ALTER TABLE fleet_aircraft RENAME CONSTRAINT user_fleet_condition_check TO fleet_aircraft_condition_check;
ALTER TABLE fleet_aircraft RENAME CONSTRAINT user_fleet_status_check TO fleet_aircraft_status_check;

-- route_assignments constraints
ALTER TABLE route_assignments RENAME CONSTRAINT user_routes_flights_per_week_check TO route_assignments_flights_per_week_check;
ALTER TABLE route_assignments RENAME CONSTRAINT user_routes_ticket_price_check TO route_assignments_ticket_price_check;

-- fleet_aircraft indexes
ALTER INDEX IF EXISTS user_fleet_user_id_idx RENAME TO fleet_aircraft_user_id_idx;

-- route_assignments indexes
ALTER INDEX IF EXISTS user_routes_assigned_aircraft_id_idx RENAME TO route_assignments_assigned_aircraft_id_idx;
ALTER INDEX IF EXISTS user_routes_user_id_iata_idx RENAME TO route_assignments_user_id_iata_idx;

COMMIT;
