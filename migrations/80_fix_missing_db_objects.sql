-- ============================================================================
-- FIX: Missing database objects from earlier migrations
-- ============================================================================
-- 1. Recreate calculate_effective_passenger_capacity (from migration 52)
--    This function was lost between migrations — possibly overwritten by a
--    CREATE OR REPLACE that had a different signature.
-- 2. Add status column to user_routes (referenced by migration 76+ functions)
--    The calculate_route_expected_passengers function filters by status='active'
--    but the column was never added to user_routes.
-- 3. Create 2-param calculate_route_max_weekly_flights (from migration 52)
--    The 3-param version exists (migration 77) but the simulation code calls
--    the 2-param version with (distance, speed).
-- ============================================================================

-- Fix 1: Recreate calculate_effective_passenger_capacity
CREATE OR REPLACE FUNCTION calculate_effective_passenger_capacity(
    p_model_capacity INT,
    p_economy_seats INT,
    p_business_seats INT,
    p_first_class_seats INT
)
RETURNS INT AS $$
    SELECT GREATEST(
        0,
        COALESCE(
            NULLIF(
                COALESCE(p_economy_seats, 0) +
                COALESCE(p_business_seats, 0) +
                COALESCE(p_first_class_seats, 0),
                0
            ),
            COALESCE(p_model_capacity, 0)
        )
    );
$$ LANGUAGE sql IMMUTABLE;

-- Fix 2: Add status column to user_routes
ALTER TABLE user_routes ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'active';
UPDATE user_routes SET status = 'active' WHERE status IS NULL;

-- Fix 3: Create 2-param calculate_route_max_weekly_flights
CREATE OR REPLACE FUNCTION calculate_route_max_weekly_flights(
    p_distance_km DOUBLE PRECISION,
    p_speed_kmh INT
)
RETURNS INT AS $$
    SELECT CASE
        WHEN COALESCE(p_distance_km, 0.0) <= 0.0 OR COALESCE(p_speed_kmh, 0) <= 0 THEN 0
        ELSE FLOOR(
            168.0 / ((p_distance_km / p_speed_kmh) + 1.0)
        )::INT
    END;
$$ LANGUAGE sql IMMUTABLE;
