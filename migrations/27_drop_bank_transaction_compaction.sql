-- ============================================================================
-- Migration 27: Drop bank transaction compaction surface
-- Goal:
--   remove dormant bank compaction cron/function/table surfaces now that the
--   Flutter runtime no longer reads summarized history and no app consumer
--   remains for the archive path.
-- ============================================================================

DO $$
DECLARE
  v_job_id BIGINT;
BEGIN
  SELECT jobid
    INTO v_job_id
    FROM cron.job
   WHERE jobname = 'skyward_compact_bank_transactions'
   LIMIT 1;

  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_account()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_user_id UUID;
BEGIN
v_user_id := require_current_user_id();
-- Delete in dependency order (children before parents)
-- bank_transactions (FK: account_id -> bank_accounts, user_id -> users)
DELETE FROM bank_transactions WHERE user_id = v_user_id;
-- bank_accounts (FK: user_id -> users)
DELETE FROM bank_accounts WHERE user_id = v_user_id;
-- achievements (FK: user_id -> users)
DELETE FROM achievements WHERE user_id = v_user_id;
-- credit_score_history (FK: user_id -> users)
DELETE FROM credit_score_history WHERE user_id = v_user_id;
-- credit_scores (FK: user_id -> users, PK is user_id)
DELETE FROM credit_scores WHERE user_id = v_user_id;
-- route_assignments (FK: user_id -> users, assigned_aircraft_id -> fleet_aircraft)
DELETE FROM route_assignments WHERE user_id = v_user_id;
-- loans (FK: user_id -> users, collateral_aircraft_id/fleet_aircraft_id -> fleet_aircraft)
DELETE FROM loans WHERE user_id = v_user_id;
-- fleet_aircraft (FK: user_id -> users)
DELETE FROM fleet_aircraft WHERE user_id = v_user_id;
-- bot_profiles (FK: user_id -> users ON DELETE CASCADE, but explicit is cleaner)
DELETE FROM bot_profiles WHERE user_id = v_user_id;
-- Finally, the user row itself
DELETE FROM users WHERE id = v_user_id;
RETURN TRUE;
END;
$function$;

DROP FUNCTION IF EXISTS public.compact_bank_transactions(boolean);

DELETE FROM public.game_config
WHERE key = 'bank_txn_raw_retention_days';

DROP TABLE IF EXISTS public.bank_transactions_archive;
DROP TABLE IF EXISTS public.bank_transaction_daily_summary;
