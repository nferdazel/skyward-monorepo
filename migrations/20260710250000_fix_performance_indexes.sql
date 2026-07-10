-- Fix SQL performance issues: missing indexes and index/query mismatch

BEGIN;

-- Fix 1: Missing index on bank_transactions.game_date
CREATE INDEX IF NOT EXISTS idx_bank_transactions_game_date
    ON bank_transactions(game_date);

-- Fix 2: Missing index on route_assignments for competitor queries
CREATE INDEX IF NOT EXISTS idx_route_assignments_origin_dest_status
    ON route_assignments(origin_iata, destination_iata)
    WHERE status = 'active';

-- Fix 3: Fix idx_users_active_bots index mismatch
-- Previous index used WHERE operational_status != 'Bankrupt'
-- but queries use COALESCE(operational_status, 'Active') != 'Bankrupt'.
-- Drop and recreate to match actual query patterns.
DROP INDEX IF EXISTS idx_users_active_bots;
CREATE INDEX idx_users_active_bots
    ON users(id)
    WHERE COALESCE(operational_status, 'Active') != 'Bankrupt'
      AND actor_type = 'AI';

COMMIT;
