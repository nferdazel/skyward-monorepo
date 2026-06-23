-- ============================================================================
-- CRITICAL DATABASE FIXES
-- ============================================================================
-- Addresses six issues accumulated across migrations 85–91:
--
--   1. credit_score_history column names: migration 85 created the table with
--      short names (fleet_health, …) but migration 88 expected _score suffix.
--      Rename the m85 columns so the Dart model matches.
--   2. check_achievements search_path: SECURITY DEFINER without a fixed
--      search_path is a privilege-escalation vector.
--   3. Missing indexes for bot queries on user_routes, user_fleet,
--      and financial_ledger.
--   4. Document that process_simulation_delta decouples bot processing from
--      player sync (bots run only via ensure_world_current → world_tick).
--   5. Drop the dead 4-parameter finance_aircraft overload from migration 85;
--      the 3-parameter version from migration 87 is canonical.
--   6. Add FK constraint for user_fleet.ai_competitor_id → ai_competitors.
-- ============================================================================


-- ============================================================================
-- FIX 1: credit_score_history column alignment
-- ============================================================================
-- Migration 85 created the table with columns: fleet_health, revenue_stability,
-- debt_ratio, cash_reserve, profit_history.  Migration 88's CREATE TABLE was a
-- no-op because the table already existed.  Rename to the _score suffix that
-- the Dart CreditScoreHistory model and get_credit_report() expect.

DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'credit_score_history' AND column_name = 'fleet_health'
  ) THEN
    ALTER TABLE credit_score_history RENAME COLUMN fleet_health TO fleet_health_score;
    ALTER TABLE credit_score_history RENAME COLUMN revenue_stability TO revenue_stability_score;
    ALTER TABLE credit_score_history RENAME COLUMN debt_ratio TO debt_ratio_score;
    ALTER TABLE credit_score_history RENAME COLUMN cash_reserve TO cash_reserves_score;
    ALTER TABLE credit_score_history RENAME COLUMN profit_history TO profit_history_score;
  END IF;
END $$;

-- Add tier column if missing (migration 88 expected it but the table was already created by 85)
ALTER TABLE credit_score_history ADD COLUMN IF NOT EXISTS tier VARCHAR(10) DEFAULT 'Standard';


-- ============================================================================
-- FIX 2: check_achievements search_path
-- ============================================================================
-- The function is SECURITY DEFINER but was created without SET search_path,
-- which allows search_path injection attacks.  Pin it to public, pg_catalog.

ALTER FUNCTION check_achievements(UUID, TIMESTAMPTZ)
  SET search_path = public, pg_catalog;


-- ============================================================================
-- FIX 3: Missing indexes for bot queries
-- ============================================================================
-- Bot routing decisions query user_routes by (user_id, origin_iata, dest_iata)
-- and several tables by ai_competitor_id with a NULL filter.  Without these
-- indexes the bot tick does sequential scans on every iteration.

CREATE INDEX IF NOT EXISTS user_routes_user_id_iata_idx
  ON user_routes(user_id, origin_iata, destination_iata);

CREATE INDEX IF NOT EXISTS user_fleet_ai_competitor_id_idx
  ON user_fleet(ai_competitor_id) WHERE ai_competitor_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS user_routes_ai_competitor_id_idx
  ON user_routes(ai_competitor_id) WHERE ai_competitor_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS financial_ledger_ai_competitor_id_idx
  ON financial_ledger(ai_competitor_id) WHERE ai_competitor_id IS NOT NULL;


-- ============================================================================
-- FIX 4: Document bot simulation decoupling
-- ============================================================================
-- process_simulation_delta(UUID) must NOT call execute_bot_decisions() or
-- process_all_bots_simulation() directly.  Bots are processed exclusively
-- through the world tick path:
--
--   process_simulation_delta(UUID)
--     → ensure_world_current(season_id)
--       → process_world_tick(season_id, 100)
--         → process_all_bots_simulation_to_time(target_time, season_id)
--           → execute_bot_decisions()
--
-- This ensures bots tick exactly once per world-clock advance, not once per
-- player sync.  The comment below documents this invariant on the function.

COMMENT ON FUNCTION process_simulation_delta(UUID) IS
  'Compatibility RPC for Flutter. Ensures the world clock is current via ensure_world_current → process_world_tick, then syncs the player actor to season_clock. Bot simulation runs ONLY inside process_world_tick; this function must never call execute_bot_decisions or process_all_bots_simulation directly.';


-- ============================================================================
-- FIX 5: Drop dead finance_aircraft overload
-- ============================================================================
-- Migration 85 created finance_aircraft(UUID, UUID, INT, NUMERIC) which takes
-- (aircraft_model_id, fleet_id, term_months, down_payment_pct).  Migration 87
-- replaced it with finance_aircraft(UUID, NUMERIC, INT) taking
-- (aircraft_model_id, down_payment_pct, term_months) and also creates the fleet
-- entry itself.  The old 4-parameter version is dead code — drop it.

DROP FUNCTION IF EXISTS finance_aircraft(UUID, UUID, INT, NUMERIC);


-- ============================================================================
-- FIX 6: Add FK constraint for user_fleet.ai_competitor_id
-- ============================================================================
-- user_fleet.ai_competitor_id references ai_competitors(id) but was never
-- given an explicit FK constraint.  ON DELETE SET NULL so deleting a bot
-- leaves its former aircraft in the table (orphaned but auditable).

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'user_fleet_ai_competitor_fk'
  ) THEN
    ALTER TABLE user_fleet
      ADD CONSTRAINT user_fleet_ai_competitor_fk
      FOREIGN KEY (ai_competitor_id) REFERENCES ai_competitors(id) ON DELETE SET NULL;
  END IF;
END $$;
