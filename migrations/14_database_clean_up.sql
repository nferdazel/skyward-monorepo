-- =============================================================================
-- SKYWARD DATABASE CLEANUP: LEDGER & BOT ALIGNMENT
-- Wipes historical high-frequency logs from the old simulation engine and
-- resolves the bot trigger race condition by prunes excess competitors.
-- =============================================================================

-- 1. Purge all high-frequency historical ledger records from the old engine
-- This preserves initial deposits and consolidated daily logs while clearing clutter.
DELETE FROM financial_ledger 
WHERE description LIKE '%game days%' 
   OR description LIKE '%flight cycles%' 
   OR description LIKE '%across active networks%';

-- 2. Prune excess spawned competitors to maintain exactly 5 active bot competitors
-- The respawn trigger (trg_ai_respawn) will evaluate v_missing = 0 and will not spawn replacements.
DELETE FROM ai_competitors 
WHERE company_name NOT IN (
    'Apex Aero', 
    'Vanguard Premium', 
    'Nusantara Link', 
    'Red Star Wings', 
    'Mekong Express'
);
