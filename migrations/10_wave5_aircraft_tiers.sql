-- WAVE 5 — GAME-06: mid-game progression gates
--
-- Add a `min_credit_tier` to aircraft_models and gate purchase/lease by the
-- player's credit tier (credit_scores.tier: Standard < Silver < Gold < Platinum).
-- Curve (approved):
--   regional turboprop / small regional       -> Standard
--   regional jet / small narrowbody (<=150)   -> Silver
--   large narrowbody (>150)                    -> Gold
--   widebody                                    -> Platinum
--
-- Server-side enforcement is added in fleet.go (Purchase/Lease). The client
-- shows tier locks in the fleet catalog.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

ALTER TABLE aircraft_models
  ADD COLUMN IF NOT EXISTS min_credit_tier text NOT NULL DEFAULT 'Standard';

UPDATE aircraft_models SET min_credit_tier = CASE
    WHEN type = 'regional_turboprop'                     THEN 'Standard'
    WHEN type = 'regional_jet'                           THEN 'Silver'
    WHEN type = 'narrow_body_jet' AND capacity <= 150    THEN 'Silver'
    WHEN type = 'narrow_body_jet'                        THEN 'Gold'
    WHEN type = 'wide_body_jet'                          THEN 'Platinum'
    ELSE 'Standard'
  END;

COMMIT;
