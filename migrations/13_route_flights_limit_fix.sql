-- =============================================================================
-- SKYWARD SYSTEM UPDATE: ROUTE WEEKLY FLIGHTS CAP EXTENSION
-- Extends max weekly flights frequency constraint from 56 to 168 to align
-- with the client-side physical turnaround calculations under the 168h weekly cap.
-- =============================================================================

-- 1. Drop the old artificial check constraint of 56 weekly flights
ALTER TABLE user_routes
DROP CONSTRAINT IF EXISTS user_routes_flights_per_week_check;

-- 2. Add the extended check constraint allowing up to 168 weekly flights (1 flight/hr cap)
ALTER TABLE user_routes
ADD CONSTRAINT user_routes_flights_per_week_check CHECK (flights_per_week BETWEEN 1 AND 168);
