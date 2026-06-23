-- Migration 107: Trigger audit and cleanup
-- Drops trg_ai_assign_season which is redundant with trg_users_assign_active_season_id.
-- Both fire on INSERT to users and call the same function (assign_active_season_id).
-- The existing trigger handles both REAL and AI users since AI users are now in the users table.

-- Step 1: Drop the redundant AI-specific trigger
DROP TRIGGER IF EXISTS trg_ai_assign_season ON users;

-- Step 2: Verify final trigger inventory (should be 8 triggers after cleanup)
DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM information_schema.triggers
    WHERE trigger_schema = 'public';

    IF v_count != 8 THEN
        RAISE WARNING 'Expected 8 triggers after cleanup, found %', v_count;
    ELSE
        RAISE NOTICE 'Trigger audit complete: 8 triggers confirmed';
    END IF;
END $$;
