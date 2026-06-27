-- ============================================================================
-- Migration 26: Drop dead legacy helpers
-- Goal:
--   remove superseded bot/utility functions that are no longer referenced by
--   the app surface or the latest simulation/mutation engine.
-- ============================================================================

DROP FUNCTION IF EXISTS public.bot_take_loan(uuid, numeric, integer);
DROP FUNCTION IF EXISTS public.bot_finance_aircraft(uuid, uuid, numeric, integer);
DROP FUNCTION IF EXISTS public.process_bot_loan_payments(uuid, timestamp with time zone);
DROP FUNCTION IF EXISTS public.get_fleet_commonality_discount(uuid);
DROP FUNCTION IF EXISTS public.get_hub_bonus_percentage(character varying, uuid);
