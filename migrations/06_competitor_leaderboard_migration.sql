-- =============================================================================
-- SKYWARD SIMULATION ENGINE - AI COMPETITORS & GLOBAL LEADERBOARD MIGRATION
-- =============================================================================

-- 1. CREATE AI COMPETITORS TABLE
CREATE TABLE IF NOT EXISTS ai_competitors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_name VARCHAR(100) UNIQUE NOT NULL,
    ceo_name VARCHAR(100) NOT NULL,
    archetype VARCHAR(30) NOT NULL CHECK (archetype IN ('Aggressive', 'Premium', 'Regional')),
    cash NUMERIC(20, 2) NOT NULL DEFAULT 15000000.00 CHECK (cash >= -1000000000.00),
    net_worth NUMERIC(20, 2) NOT NULL DEFAULT 15000000.00,
    last_evaluated_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    status VARCHAR(20) NOT NULL DEFAULT 'Active' CHECK (status IN ('Active', 'Distress', 'Bankrupt')),
    consecutive_negative_days INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. ALTER USERS TABLE TO SUPPORT NET WORTH AND DEFAULT CASH TO 15,000,000
ALTER TABLE users ADD COLUMN IF NOT EXISTS net_worth NUMERIC(20, 2) DEFAULT 15000000.00;
ALTER TABLE users ALTER COLUMN cash SET DEFAULT 15000000.00;

-- 3. ALTER USER_FLEET TABLE TO SUPPORT AI OWNERSHIP
-- Make user_id nullable
ALTER TABLE user_fleet ALTER COLUMN user_id DROP NOT NULL;

-- Add ai_competitor_id column
ALTER TABLE user_fleet ADD COLUMN IF NOT EXISTS ai_competitor_id UUID REFERENCES ai_competitors(id) ON DELETE CASCADE;

-- Add exclusive owner check constraint
-- Drop if it already exists to prevent duplicate failures
ALTER TABLE user_fleet DROP CONSTRAINT IF EXISTS exclusive_owner_fleet;
ALTER TABLE user_fleet ADD CONSTRAINT exclusive_owner_fleet 
    CHECK ((user_id IS NOT NULL AND ai_competitor_id IS NULL) OR (user_id IS NULL AND ai_competitor_id IS NOT NULL));

-- 4. ALTER USER_ROUTES TABLE TO SUPPORT AI OWNERSHIP
-- Make user_id nullable
ALTER TABLE user_routes ALTER COLUMN user_id DROP NOT NULL;

-- Add ai_competitor_id column
ALTER TABLE user_routes ADD COLUMN IF NOT EXISTS ai_competitor_id UUID REFERENCES ai_competitors(id) ON DELETE CASCADE;

-- Add exclusive owner check constraint
ALTER TABLE user_routes DROP CONSTRAINT IF EXISTS exclusive_owner_routes;
ALTER TABLE user_routes ADD CONSTRAINT exclusive_owner_routes 
    CHECK ((user_id IS NOT NULL AND ai_competitor_id IS NULL) OR (user_id IS NULL AND ai_competitor_id IS NOT NULL));

-- Replace unique route constraint
ALTER TABLE user_routes DROP CONSTRAINT IF EXISTS unique_user_route;

-- Create unique indexes to handle human vs AI route uniqueness cleanly
DROP INDEX IF EXISTS unique_human_route;
CREATE UNIQUE INDEX unique_human_route ON user_routes (user_id, origin_iata, destination_iata) 
WHERE user_id IS NOT NULL;

DROP INDEX IF EXISTS unique_ai_route;
CREATE UNIQUE INDEX unique_ai_route ON user_routes (ai_competitor_id, origin_iata, destination_iata) 
WHERE ai_competitor_id IS NOT NULL;


-- 5. FUNCTION TO RECONCILE NET WORTH FOR A USER OR AI

CREATE OR REPLACE FUNCTION calculate_user_net_worth(p_user_id UUID)
RETURNS NUMERIC AS $$
DECLARE
    v_cash NUMERIC;
    v_fleet_value NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    
    SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
    INTO v_fleet_value
    FROM user_fleet f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.user_id = p_user_id AND f.acquisition_type = 'purchase';
    
    RETURN COALESCE(v_cash, 0) + v_fleet_value;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION calculate_ai_net_worth(p_ai_id UUID)
RETURNS NUMERIC AS $$
DECLARE
    v_cash NUMERIC;
    v_fleet_value NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM ai_competitors WHERE id = p_ai_id;
    
    SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
    INTO v_fleet_value
    FROM user_fleet f
    JOIN aircraft_models m ON f.aircraft_model_id = m.id
    WHERE f.ai_competitor_id = p_ai_id AND f.acquisition_type = 'purchase';
    
    RETURN COALESCE(v_cash, 0) + v_fleet_value;
END;
$$ LANGUAGE plpgsql;


-- 6. TRIGGERS TO AUTOMATICALLY UPDATE NET WORTH
-- A. Trigger for User Cash Update
CREATE OR REPLACE FUNCTION trg_update_user_net_worth()
RETURNS TRIGGER AS $$
BEGIN
    NEW.net_worth := calculate_user_net_worth(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_user_cash_change ON users;
CREATE TRIGGER trg_user_cash_change
    BEFORE UPDATE OF cash ON users
    FOR EACH ROW
    EXECUTE FUNCTION trg_update_user_net_worth();

-- B. Trigger for AI Cash Update
CREATE OR REPLACE FUNCTION trg_update_ai_net_worth()
RETURNS TRIGGER AS $$
BEGIN
    NEW.net_worth := calculate_ai_net_worth(NEW.id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ai_cash_change ON ai_competitors;
CREATE TRIGGER trg_ai_cash_change
    BEFORE UPDATE OF cash ON ai_competitors
    FOR EACH ROW
    EXECUTE FUNCTION trg_update_ai_net_worth();

-- C. Trigger for Fleet Changes (restoring asset valuation on purchase or repair)
CREATE OR REPLACE FUNCTION trg_fleet_reconcile_net_worth()
RETURNS TRIGGER AS $$
BEGIN
    -- If row was deleted, use OLD; if inserted/updated, use NEW
    IF TG_OP = 'DELETE' THEN
        IF OLD.user_id IS NOT NULL THEN
            UPDATE users SET net_worth = calculate_user_net_worth(OLD.user_id) WHERE id = OLD.user_id;
        ELSIF OLD.ai_competitor_id IS NOT NULL THEN
            UPDATE ai_competitors SET net_worth = calculate_ai_net_worth(OLD.ai_competitor_id) WHERE id = OLD.ai_competitor_id;
        END IF;
        RETURN OLD;
    ELSE
        IF NEW.user_id IS NOT NULL THEN
            UPDATE users SET net_worth = calculate_user_net_worth(NEW.user_id) WHERE id = NEW.user_id;
        ELSIF NEW.ai_competitor_id IS NOT NULL THEN
            UPDATE ai_competitors SET net_worth = calculate_ai_net_worth(NEW.ai_competitor_id) WHERE id = NEW.ai_competitor_id;
        END IF;
        
        -- If ownership swapped (e.g. transfer), reconcile old owner too
        IF TG_OP = 'UPDATE' THEN
            IF OLD.user_id IS NOT NULL AND OLD.user_id != COALESCE(NEW.user_id, gen_random_uuid()) THEN
                UPDATE users SET net_worth = calculate_user_net_worth(OLD.user_id) WHERE id = OLD.user_id;
            ELSIF OLD.ai_competitor_id IS NOT NULL AND OLD.ai_competitor_id != COALESCE(NEW.ai_competitor_id, gen_random_uuid()) THEN
                UPDATE ai_competitors SET net_worth = calculate_ai_net_worth(OLD.ai_competitor_id) WHERE id = OLD.ai_competitor_id;
            END IF;
        END IF;
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_fleet_change ON user_fleet;
CREATE TRIGGER trg_fleet_change
    AFTER INSERT OR UPDATE OF condition, status, user_id, ai_competitor_id OR DELETE ON user_fleet
    FOR EACH ROW
    EXECUTE FUNCTION trg_fleet_reconcile_net_worth();


-- 7. RECONCILE PROCEDURE FOR BATCH PROGRESS
CREATE OR REPLACE FUNCTION reconcile_all_net_worths()
RETURNS VOID AS $$
BEGIN
    UPDATE users u SET net_worth = calculate_user_net_worth(u.id);
    UPDATE ai_competitors ai SET net_worth = calculate_ai_net_worth(ai.id);
END;
$$ LANGUAGE plpgsql;


-- 8. SEED INITIAL AI COMPETITORS
INSERT INTO ai_competitors (company_name, ceo_name, archetype, cash, net_worth) VALUES
('Apex Aero', 'Edward Falcon', 'Aggressive', 15000000.00, 15000000.00),
('Vanguard Premium', 'Sophia Rothschild', 'Premium', 18000000.00, 18000000.00),
('Nusantara Link', 'Ahmad Hidayat', 'Regional', 12000000.00, 12000000.00),
('Red Star Wings', 'Viktor Reznov', 'Aggressive', 14000000.00, 14000000.00),
('Mekong Express', 'Linh Nguyen', 'Regional', 13500000.00, 13500000.00)
ON CONFLICT (company_name) DO NOTHING;

-- Initial execution of Net Worth calculation
SELECT reconcile_all_net_worths();


-- =============================================================================
-- 9. GLOBAL LEADERBOARD AGGREGATION RPC
-- =============================================================================
CREATE OR REPLACE FUNCTION get_global_leaderboard()
RETURNS TABLE (
    id UUID,
    company_name VARCHAR,
    ceo_name VARCHAR,
    is_bot BOOLEAN,
    archetype VARCHAR,
    cash NUMERIC,
    net_worth NUMERIC,
    fleet_size INT,
    monthly_revenue NUMERIC,
    status VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    -- 1. Human Players
    SELECT 
        u.id,
        u.company_name::VARCHAR,
        u.ceo_name::VARCHAR,
        FALSE AS is_bot,
        'Player'::VARCHAR AS archetype,
        u.cash,
        u.net_worth,
        (SELECT COUNT(*)::INT FROM user_fleet WHERE user_id = u.id AND status = 'active') AS fleet_size,
        COALESCE((
            SELECT SUM(amount) 
            FROM financial_ledger 
            WHERE user_id = u.id 
              AND transaction_type = 'revenue' 
              AND game_date >= u.game_current_time - INTERVAL '30 days'
        ), 0.00)::NUMERIC AS monthly_revenue,
        'Active'::VARCHAR AS status
    FROM users u
    
    UNION ALL
    
    -- 2. AI Competitors
    SELECT 
        ai.id,
        ai.company_name::VARCHAR,
        ai.ceo_name::VARCHAR,
        TRUE AS is_bot,
        ai.archetype::VARCHAR AS archetype,
        ai.cash,
        ai.net_worth,
        (SELECT COUNT(*)::INT FROM user_fleet WHERE ai_competitor_id = ai.id AND status = 'active') AS fleet_size,
        -- Dynamic monthly revenue projection for bots based on active flight operations
        COALESCE((
            SELECT SUM(r.flights_per_week * r.ticket_price * LEAST(m.capacity, FLOOR((org.demand_index + dst.demand_index) * GREATEST(0.0, 1.5 - 0.8 * POWER(r.ticket_price / (50.00 + r.distance_km * 0.12), 2)) * 10))) * 4.33
            FROM user_routes r
            JOIN user_fleet f ON r.assigned_aircraft_id = f.id
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            JOIN airports org ON r.origin_iata = org.iata
            JOIN airports dst ON r.destination_iata = dst.iata
            WHERE r.ai_competitor_id = ai.id 
              AND f.condition >= 40.0 
              AND f.status = 'active'
        ), 0.00)::NUMERIC AS monthly_revenue,
        ai.status::VARCHAR AS status
    FROM ai_competitors ai;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- 10. DETAILED COMPETITOR INSIGHTS AGGREGATION RPC
-- =============================================================================
CREATE OR REPLACE FUNCTION get_competitor_insights(p_id UUID, p_is_bot BOOLEAN)
RETURNS TABLE (
    company_name VARCHAR,
    ceo_name VARCHAR,
    cash NUMERIC,
    net_worth NUMERIC,
    status VARCHAR,
    fleet_breakdown JSONB,
    network_routes JSONB
) AS $$
DECLARE
    v_company VARCHAR;
    v_ceo VARCHAR;
    v_cash NUMERIC;
    v_net_worth NUMERIC;
    v_status VARCHAR;
    v_fleet JSONB;
    v_routes JSONB;
BEGIN
    IF p_is_bot THEN
        SELECT ai.company_name, ai.ceo_name, ai.cash, ai.net_worth, ai.status
        INTO v_company, v_ceo, v_cash, v_net_worth, v_status
        FROM ai_competitors ai
        WHERE ai.id = p_id;
        
        -- Fleet breakdown aggregation: e.g. "{"Airbus A320neo (lease)": 3, "ATR 72-600 (purchase)": 1}"
        SELECT COALESCE(jsonb_object_agg(model_label, count_val), '{}'::jsonb)
        INTO v_fleet
        FROM (
            SELECT (m.manufacturer || ' ' || m.model_name || ' (' || f.acquisition_type || ')') AS model_label, COUNT(*)::INT AS count_val
            FROM user_fleet f
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            WHERE f.ai_competitor_id = p_id
            GROUP BY m.manufacturer, m.model_name, f.acquisition_type
        ) d;
        
        -- Route list: e.g. "["CGK-SIN", "SIN-KUL"]"
        SELECT COALESCE(jsonb_agg(route_label), '[]'::jsonb)
        INTO v_routes
        FROM (
            SELECT (origin_iata || '-' || destination_iata) AS route_label
            FROM user_routes
            WHERE ai_competitor_id = p_id
        ) r;
    ELSE
        SELECT u.company_name, u.ceo_name, u.cash, u.net_worth, 'Active'
        INTO v_company, v_ceo, v_cash, v_net_worth, v_status
        FROM users u
        WHERE u.id = p_id;
        
        SELECT COALESCE(jsonb_object_agg(model_label, count_val), '{}'::jsonb)
        INTO v_fleet
        FROM (
            SELECT (m.manufacturer || ' ' || m.model_name || ' (' || f.acquisition_type || ')') AS model_label, COUNT(*)::INT AS count_val
            FROM user_fleet f
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            WHERE f.user_id = p_id
            GROUP BY m.manufacturer, m.model_name, f.acquisition_type
        ) d;
        
        SELECT COALESCE(jsonb_agg(route_label), '[]'::jsonb)
        INTO v_routes
        FROM (
            SELECT (origin_iata || '-' || destination_iata) AS route_label
            FROM user_routes
            WHERE user_id = p_id
        ) r;
    END IF;
    
    RETURN QUERY SELECT v_company::VARCHAR, v_ceo::VARCHAR, v_cash, v_net_worth, v_status::VARCHAR, v_fleet, v_routes;
END;
$$ LANGUAGE plpgsql;
