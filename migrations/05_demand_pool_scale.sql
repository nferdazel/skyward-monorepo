-- Migration 05: GAME-02 — fixed daily demand pool calibration
-- Source: docs/reviews/wave2-design-doc.md (approved)
--
-- Adds the `demand_pool_scale` knob used by the Go engine's routeDailyDemand().
-- The pool is fixed per route and split across the player's flights, so raising
-- frequency past saturation lowers per-flight load factor.
--
-- Calibration: reference route = demand_index 90 both ends, 800 km, priced at
-- reference fare (baseFare + distance*perKM). With price elasticity 0.7 at the
-- reference fare and distanceDemandFactor ≈ 0.983, poolScale 290 yields
-- ~162 pax/day, filling a single 180-seat daily flight to ~90% load.
-- The Go fallback default is 290.0 (simulation.go) — keep them in sync.

INSERT INTO public.game_config (key, value, category, unit, description, updated_at)
VALUES (
    'demand_pool_scale',
    '290.0'::jsonb,
    'simulation',
    'passengers',
    'GAME-02: scale factor for a route''s fixed daily passenger demand pool. The pool is split across the player''s flights on that route.',
    NOW()
)
ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value,
        category = EXCLUDED.category,
        unit = EXCLUDED.unit,
        description = EXCLUDED.description,
        updated_at = NOW();
