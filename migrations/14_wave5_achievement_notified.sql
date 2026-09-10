-- WAVE 5 corrective — achievement unlock notifications
--
-- GAME-15: achievements can be unlocked by the background world-tick worker.
-- ProcessPlayer only returned achievements inserted during the sync call, so an
-- unlock that happened in the tick was never surfaced as a toast. Track whether
-- a freshly-unlocked achievement has been reported to the client; the sync path
-- returns any un-notified achievements and marks them notified, so no unlock is
-- lost regardless of which process created it.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

ALTER TABLE achievements ADD COLUMN IF NOT EXISTS notified_at timestamp with time zone;

-- Backfill: treat pre-existing rows as already notified so the first sync after
-- deploy does not re-toast a player's entire trophy case.
UPDATE achievements SET notified_at = COALESCE(unlocked_at, NOW())
 WHERE notified_at IS NULL;

COMMIT;
