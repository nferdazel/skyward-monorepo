-- WAVE 5 — finance_snapshots: schema capture + retention
--
-- finance_snapshots was created directly on the hosted DB and never captured in
-- migrations, so fresh environments lacked the table. It was also written once
-- per world tick (every 60s) per user with no retention, growing unbounded
-- (~100k+ rows/day; the live table reached ~84k rows). It only powers two
-- sparklines (finance cash/net-worth and the dashboard net-worth trend), so we
-- now capture one row per user per GAME DAY and prune old rows.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

-- 1. Capture the table definition (no-op on environments that already have it).
CREATE TABLE IF NOT EXISTS finance_snapshots (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    snapshot_game_time timestamp with time zone NOT NULL,
    cash               numeric NOT NULL DEFAULT 0,
    net_worth          numeric NOT NULL DEFAULT 0,
    revenue_30d        numeric NOT NULL DEFAULT 0,
    expense_30d        numeric NOT NULL DEFAULT 0,
    active_routes      integer NOT NULL DEFAULT 0,
    fleet_count        integer NOT NULL DEFAULT 0,
    created_at         timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT finance_snapshots_user_id_snapshot_game_time_key
        UNIQUE (user_id, snapshot_game_time)
);

-- 2. Index to keep the per-user trend read and the retention prune cheap.
CREATE INDEX IF NOT EXISTS finance_snapshots_user_time_idx
    ON finance_snapshots (user_id, snapshot_game_time DESC);

-- 3. Align the FK with the rest of the schema (cascade) on environments where
--    it was created without it. Drop/recreate only if the current rule differs.
DO $$
DECLARE
    v_deltype "char";
BEGIN
    SELECT confdeltype INTO v_deltype
      FROM pg_constraint
     WHERE conname = 'finance_snapshots_user_id_fkey'
       AND conrelid = 'finance_snapshots'::regclass;
    IF v_deltype IS NOT NULL AND v_deltype <> 'c' THEN
        ALTER TABLE finance_snapshots DROP CONSTRAINT finance_snapshots_user_id_fkey;
        ALTER TABLE finance_snapshots
            ADD CONSTRAINT finance_snapshots_user_id_fkey
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
    END IF;
END $$;

COMMIT;
