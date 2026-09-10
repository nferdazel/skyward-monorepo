-- WAVE 5 — GAME-08: improve new-player starting position
--
-- New players started with $15M, but the cheapest aircraft is $8M (C-212),
-- leaving little runway for a first route + operating costs. Raise the starting
-- cash to $25M. The registration trigger (trg_create_default_bank_account) and
-- reset flow read starting_cash from game_config, so this single row drives the
-- new-player balance; Go fallbacks are updated to match in the same change.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

UPDATE game_config
   SET value = '25000000'::jsonb
 WHERE key = 'starting_cash';

COMMIT;
