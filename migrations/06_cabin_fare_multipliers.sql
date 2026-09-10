-- Migration 06: GAME-03 — cabin fares and premium willingness
-- Source: docs/reviews/wave2-design-doc.md; multipliers calibrated by sweep so
-- that a real trade-off exists (thin pool -> premium mix wins; thick pool ->
-- all-economy wins). Approved: business 1.5x, first 2.5x; willingness
-- economy 80%, business 15%, first 5%.
--
-- Cabin configuration now affects revenue. The daily demand pool is allocated
-- across cabins by willingness-to-pay: only `business_willing_share` of
-- passengers will pay for business, `first_willing_share` for first; the rest
-- travel economy. Premium seats configured beyond the willing share cannot be
-- sold to economy passengers, so over-configuring premium wastes capacity.
-- `aircraft_models.capacity` remains the seat-slot budget (premium seats cost
-- 2-3 slots each) used only as a fallback when no cabin is configured.
-- Go fallbacks in simulation.go must stay in sync.

INSERT INTO public.game_config (key, value, category, unit, description, updated_at)
VALUES
    ('business_fare_multiplier', '1.5'::jsonb, 'simulation', 'multiplier',
     'GAME-03: business-class fare as a multiple of the route economy ticket price.', NOW()),
    ('first_fare_multiplier', '2.5'::jsonb, 'simulation', 'multiplier',
     'GAME-03: first-class fare as a multiple of the route economy ticket price.', NOW()),
    ('economy_willing_share', '0.80'::jsonb, 'simulation', 'ratio',
     'GAME-03: share of the demand pool willing to travel economy.', NOW()),
    ('business_willing_share', '0.15'::jsonb, 'simulation', 'ratio',
     'GAME-03: share of the demand pool willing to pay for business class.', NOW()),
    ('first_willing_share', '0.05'::jsonb, 'simulation', 'ratio',
     'GAME-03: share of the demand pool willing to pay for first class.', NOW())
ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value,
        category = EXCLUDED.category,
        unit = EXCLUDED.unit,
        description = EXCLUDED.description,
        updated_at = NOW();


