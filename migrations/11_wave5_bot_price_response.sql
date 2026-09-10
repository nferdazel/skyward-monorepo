-- WAVE 5 — GAME-22: strengthen bot price response
--
-- Bots only reacted when undercut by more than 20% and moved ~2% per review,
-- so a player could undercut once and dominate a route permanently. Tighten
-- the competitive threshold so bots notice smaller undercuts; the engine now
-- also moves a larger fraction toward the competitor (see bots.go).
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

UPDATE game_config
   SET value = '0.08'::jsonb
 WHERE key = 'bot_competitive_price_threshold';

COMMIT;
