-- Fix database constraint issues found in audit
-- All changes are additive (no data loss risk) except NOT NULL which requires data verification.

BEGIN;

-- 1. CRITICAL: bank_accounts.account_type DEFAULT 'checking' vs CHECK 'operating'
--    Fix default to match the CHECK constraint.
ALTER TABLE bank_accounts ALTER COLUMN account_type SET DEFAULT 'operating';

-- 2. MEDIUM: loans.principal missing CHECK > 0
ALTER TABLE loans ADD CONSTRAINT loans_principal_check CHECK (principal > 0);

-- 3. MEDIUM: fleet_aircraft.user_id should be NOT NULL
--    TODO: Verify no NULL user_id rows exist before deploying to production.
--    SELECT count(*) FROM fleet_aircraft WHERE user_id IS NULL;
ALTER TABLE fleet_aircraft ALTER COLUMN user_id SET NOT NULL;

-- 4. MEDIUM: bank_transactions.game_date should be NOT NULL
--    TODO: Verify no NULL game_date rows exist before deploying to production.
--    SELECT count(*) FROM bank_transactions WHERE game_date IS NULL;
ALTER TABLE bank_transactions ALTER COLUMN game_date SET NOT NULL;

-- 5. LOW: bot_profiles.secondary_hub_iata missing FK
--    Only add if airports table exists (defensive).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'airports') THEN
    ALTER TABLE bot_profiles
      ADD CONSTRAINT bot_profiles_secondary_hub_iata_fkey
      FOREIGN KEY (secondary_hub_iata) REFERENCES airports(iata);
  END IF;
END $$;

-- 6. LOW: route_assignments.status missing CHECK
ALTER TABLE route_assignments
  ADD CONSTRAINT route_assignments_status_check
  CHECK (status IN ('active', 'cancelled'));

-- 7. LOW: bot_profiles.distress_stage missing CHECK
ALTER TABLE bot_profiles
  ADD CONSTRAINT bot_profiles_distress_stage_check
  CHECK (distress_stage IN ('stable', 'cautious', 'defensive', 'desperate'));

-- 8. LOW: Several columns should be NOT NULL
--    TODO: Verify no NULL rows exist before deploying to production.
--    SELECT count(*) FROM route_assignments WHERE user_id IS NULL;
--    SELECT count(*) FROM route_assignments WHERE status IS NULL;
--    SELECT count(*) FROM loans WHERE status IS NULL;
--    SELECT count(*) FROM loans WHERE loan_type IS NULL;
ALTER TABLE route_assignments ALTER COLUMN user_id SET NOT NULL;
ALTER TABLE route_assignments ALTER COLUMN status SET NOT NULL;
ALTER TABLE loans ALTER COLUMN status SET NOT NULL;
ALTER TABLE loans ALTER COLUMN loan_type SET NOT NULL;

-- 9. COSMETIC: bank_accounts timestamps should be NOT NULL
--    TODO: Verify no NULL rows exist before deploying to production.
--    SELECT count(*) FROM bank_accounts WHERE created_at IS NULL;
--    SELECT count(*) FROM bank_accounts WHERE updated_at IS NULL;
ALTER TABLE bank_accounts ALTER COLUMN created_at SET NOT NULL;
ALTER TABLE bank_accounts ALTER COLUMN updated_at SET NOT NULL;

-- 10. LOW: Missing index on bot_profiles.archetype
CREATE INDEX IF NOT EXISTS idx_bot_profiles_archetype ON bot_profiles(archetype);

COMMIT;
