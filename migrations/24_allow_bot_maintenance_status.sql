-- ============================================================================
-- SKYWARD BOT MAINTENANCE STATUS CONSTRAINT FIX
-- ============================================================================
-- Migration 22 introduced a backend-only 'Maintenance' status for AI
-- competitors, but the table constraint still only allowed:
--   Active, Distress, Bankrupt
-- This caused process_simulation_delta() to fail when execute_bot_decisions()
-- attempted to mark a bot as Maintenance.
-- ============================================================================

ALTER TABLE ai_competitors
DROP CONSTRAINT IF EXISTS ai_competitors_status_check;

ALTER TABLE ai_competitors
ADD CONSTRAINT ai_competitors_status_check
CHECK (status IN ('Active', 'Distress', 'Maintenance', 'Bankrupt'));
