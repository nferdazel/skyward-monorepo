-- ============================================================================
-- Migration 28: Add bank transaction retention
-- Goal:
--   restore simple ledger cleanup without reintroducing summary/archive
--   surfaces by pruning old bank transaction rows using in-game time.
-- ============================================================================

INSERT INTO public.game_config (key, value, category, unit, description)
VALUES (
  'bank_txn_raw_retention_game_days',
  '180'::jsonb,
  'ops',
  'game_days',
  'Retention for raw bank transactions before prune'
)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.prune_bank_transactions(
  p_dry_run boolean DEFAULT true
)
RETURNS TABLE(action text, detail text, row_count bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_retention_days INT;
v_season_game_time TIMESTAMPTZ;
v_cutoff TIMESTAMPTZ;
v_count BIGINT := 0;
BEGIN
SELECT current_game_time
  INTO v_season_game_time
  FROM season_clock
 WHERE status = 'active'
 ORDER BY created_at ASC
 LIMIT 1;

IF v_season_game_time IS NULL THEN
  action := 'skip';
  detail := 'No active season clock found';
  row_count := 0;
  RETURN NEXT;
  RETURN;
END IF;

v_retention_days := COALESCE(
  get_config_int('bank_txn_raw_retention_game_days'),
  180
);
v_cutoff := v_season_game_time - (v_retention_days || ' days')::INTERVAL;

SELECT COUNT(*)
  INTO v_count
  FROM bank_transactions
 WHERE game_date IS NOT NULL
   AND game_date < v_cutoff;

IF NOT p_dry_run AND v_count > 0 THEN
  DELETE FROM bank_transactions
   WHERE game_date IS NOT NULL
     AND game_date < v_cutoff;
END IF;

action := 'delete';
detail := CASE
  WHEN p_dry_run THEN 'Rows that would be deleted'
  ELSE 'Rows deleted'
END;
row_count := v_count;
RETURN NEXT;
END;
$function$;

DO $$
DECLARE
  v_job_id BIGINT;
BEGIN
  SELECT jobid
    INTO v_job_id
    FROM cron.job
   WHERE jobname = 'skyward_prune_bank_transactions'
   LIMIT 1;

  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;
END;
$$;

SELECT cron.schedule(
  'skyward_prune_bank_transactions',
  '30 3 * * *',
  'SELECT prune_bank_transactions(false)'
);
