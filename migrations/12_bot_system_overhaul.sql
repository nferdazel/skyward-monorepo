-- =============================================================================
-- SKYWARD SYSTEM UPDATE: ADVANCED AI BOT ENGINE OVERHAUL (v3.3)
-- 1. Equips bots with human-equivalent starting capital ($15,000,000 cash/net_worth).
-- 2. Sets custom Local HQs to prevent silent origin_iata NULL constraint violations.
-- 3. Enables bots to log consolidated ledger rows (Ticket Sales, Ops, Leases) daily.
-- 4. Automatically purges all bot data across all tables upon bankruptcy.
-- =============================================================================

-- ── 1. ALTER FINANCIAL_LEDGER SCHEMA ──
-- Make user_id nullable to allow bot ledger entries
ALTER TABLE financial_ledger ALTER COLUMN user_id DROP NOT NULL;

-- Add ai_competitor_id column referencing competitors
ALTER TABLE financial_ledger ADD COLUMN IF NOT EXISTS ai_competitor_id UUID REFERENCES ai_competitors(id) ON DELETE CASCADE;

-- Add check constraint to ensure exactly one owner (Player or Bot)
ALTER TABLE financial_ledger DROP CONSTRAINT IF EXISTS chk_ledger_owner;
ALTER TABLE financial_ledger ADD CONSTRAINT chk_ledger_owner 
    CHECK ((user_id IS NOT NULL AND ai_competitor_id IS NULL) OR (user_id IS NULL AND ai_competitor_id IS NOT NULL));


-- ── 2. SEED BOTS WITH PROPER LOCAL HQS & ASSETS ──
-- Purge existing bots to avoid foreign key/HQ constraint anomalies
DELETE FROM user_routes WHERE ai_competitor_id IS NOT NULL;
DELETE FROM user_fleet WHERE ai_competitor_id IS NOT NULL;
DELETE FROM financial_ledger WHERE ai_competitor_id IS NOT NULL;
DELETE FROM ai_competitors;

-- Seed bots with $15,000,000.00 cash/net_worth, custom HQs, and synchronized game times
INSERT INTO ai_competitors (company_name, ceo_name, archetype, hq_airport_iata, cash, net_worth, status, game_current_time, last_active_at) VALUES
('Apex Aero', 'Edward Falcon', 'Aggressive', 'SIN', 15000000.00, 15000000.00, 'Active', '2020-01-01 00:00:00+00'::TIMESTAMP WITH TIME ZONE, NOW()),
('Vanguard Premium', 'Sophia Rothschild', 'Premium', 'KUL', 15000000.00, 15000000.00, 'Active', '2020-01-01 00:00:00+00'::TIMESTAMP WITH TIME ZONE, NOW()),
('Nusantara Link', 'Ahmad Hidayat', 'Regional', 'CGK', 15000000.00, 15000000.00, 'Active', '2020-01-01 00:00:00+00'::TIMESTAMP WITH TIME ZONE, NOW()),
('Red Star Wings', 'Viktor Reznov', 'Aggressive', 'BKK', 15000000.00, 15000000.00, 'Active', '2020-01-01 00:00:00+00'::TIMESTAMP WITH TIME ZONE, NOW()),
('Mekong Express', 'Linh Nguyen', 'Regional', 'SGN', 15000000.00, 15000000.00, 'Active', '2020-01-01 00:00:00+00'::TIMESTAMP WITH TIME ZONE, NOW())
ON CONFLICT (company_name) DO NOTHING;

-- Add transaction buffers to competitors to facilitate player-matched daily consolidation
ALTER TABLE ai_competitors ADD COLUMN IF NOT EXISTS buffered_revenue NUMERIC(20,2) DEFAULT 0.00;
ALTER TABLE ai_competitors ADD COLUMN IF NOT EXISTS buffered_ops_cost NUMERIC(20,2) DEFAULT 0.00;
ALTER TABLE ai_competitors ADD COLUMN IF NOT EXISTS buffered_lease_cost NUMERIC(20,2) DEFAULT 0.00;


-- ── 3. RECREATE BOT ENGINE SERVER-SIDE DECISION MAKER ──
CREATE OR REPLACE FUNCTION execute_bot_decisions()
RETURNS VOID AS $$
DECLARE
    r_bot RECORD;
    v_model_id UUID;
    v_model_name VARCHAR;
    v_lease_price NUMERIC;
    v_purchase_price NUMERIC;
    v_capacity INT;
    v_deposit_pct NUMERIC;
    v_deposit_amount NUMERIC;
    v_tail VARCHAR(20);
    v_new_aircraft_id UUID;
    v_origin_iata VARCHAR(3);
    v_dest_iata VARCHAR(3);
    v_distance DOUBLE PRECISION;
    v_fleet_count INT;
BEGIN
    SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1;
    v_deposit_pct := COALESCE(v_deposit_pct, 0.10);

    FOR r_bot IN SELECT * FROM ai_competitors LOOP
        
        -- ── REQUIREMENT 4: WIPE ALL BOT DATA UPON BANKRUPTCY ──
        IF r_bot.status = 'Bankrupt' OR r_bot.cash < -5000000.00 THEN
            DELETE FROM user_routes WHERE ai_competitor_id = r_bot.id;
            DELETE FROM user_fleet WHERE ai_competitor_id = r_bot.id;
            DELETE FROM financial_ledger WHERE ai_competitor_id = r_bot.id;
            DELETE FROM ai_competitors WHERE id = r_bot.id;
            CONTINUE;
        END IF;

        SELECT COUNT(*)::INT INTO v_fleet_count FROM user_fleet WHERE ai_competitor_id = r_bot.id;
        
        -- ── REQUIREMENT 1: HUMAN-LIKE BEHAVIOR (DECISIONS AND EXPANSIONS) ──
        IF v_fleet_count < 12 AND r_bot.cash > 5000000.00 AND random() < 0.15 THEN
            IF r_bot.archetype = 'Regional' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity 
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity 
                FROM aircraft_models 
                WHERE model_name = 'ATR 72-600' LIMIT 1;
            ELSIF r_bot.archetype = 'Aggressive' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity 
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity 
                FROM aircraft_models 
                WHERE model_name = 'Airbus A320neo' LIMIT 1;
            ELSE
                -- Premium
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity 
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity 
                FROM aircraft_models 
                WHERE model_name = '787-9 Dreamliner' LIMIT 1;
            END IF;

            v_deposit_amount := v_lease_price * (v_deposit_pct * 10.0);
            
            IF v_model_id IS NOT NULL AND r_bot.cash >= v_deposit_amount THEN
                v_tail := generate_tail_number(r_bot.hq_airport_iata);
                v_new_aircraft_id := gen_random_uuid();
                
                -- Add fleet aircraft
                INSERT INTO user_fleet (id, ai_competitor_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
                VALUES (v_new_aircraft_id, r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_capacity, 0, 0);
                
                -- Deduct deposit cash
                UPDATE ai_competitors SET cash = cash - v_deposit_amount WHERE id = r_bot.id;
                
                -- ── REQUIREMENT 3: WRITE DOWNPAYMENT TO THE LEDGER ──
                INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                VALUES (
                    r_bot.id,
                    'expense',
                    'aircraft_lease',
                    v_deposit_amount,
                    'Leased aircraft ' || v_model_name || ' with Call Sign: ' || v_tail || ' - Downpayment deposit',
                    r_bot.game_current_time
                );

                v_origin_iata := r_bot.hq_airport_iata;
                
                -- Select destination (CGK, SIN, KUL, BKK, etc.) excluding origin
                SELECT iata INTO v_dest_iata 
                FROM airports 
                WHERE iata != v_origin_iata 
                ORDER BY demand_index DESC, random() LIMIT 1;
                
                IF v_dest_iata IS NOT NULL THEN
                    v_distance := 800.0;
                    INSERT INTO user_routes (ai_competitor_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week)
                    VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, 150.00, v_new_aircraft_id, 14)
                    ON CONFLICT DO NOTHING;
                END IF;
            END IF;
        END IF;

        -- Handle financial distress / bankruptcy updates
        IF r_bot.cash < 0.00 THEN
            UPDATE ai_competitors 
            SET consecutive_negative_days = consecutive_negative_days + 1,
                status = 'Distress'
            WHERE id = r_bot.id;
        ELSE
            UPDATE ai_competitors 
            SET consecutive_negative_days = 0,
                status = 'Active'
            WHERE id = r_bot.id;
        END IF;

        -- Bankruptcy check
        IF r_bot.consecutive_negative_days >= 3 THEN
            UPDATE ai_competitors SET status = 'Bankrupt' WHERE id = r_bot.id;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;


-- ── 4. RECREATE BOTS TICK SIMULATOR (BUFFERED DAILY CONSOLIDATION) ──
CREATE OR REPLACE FUNCTION process_all_bots_simulation()
RETURNS VOID AS $$
DECLARE
    r_bot RECORD;
    v_now TIMESTAMP WITH TIME ZONE;
    v_real_sec DOUBLE PRECISION;
    v_game_sec DOUBLE PRECISION;
    v_game_days DOUBLE PRECISION;
    v_route RECORD;
    v_fleet RECORD;
    v_flights DOUBLE PRECISION;
    v_revenue NUMERIC(20,2);
    v_fuel_cost NUMERIC(20,2);
    v_maint_cost NUMERIC(20,2);
    v_tax_cost NUMERIC(20,2);
    v_total_cost NUMERIC(20,2);
    v_total_revenue NUMERIC(20,2);
    v_total_cost_accum NUMERIC(20,2);
    v_net NUMERIC(20,2);
    v_demand_multiplier NUMERIC(6,4);
    v_passengers INT;
    v_flight_duration DOUBLE PRECISION;
    v_wear_per_flight NUMERIC(5,2);
    v_lease_cost NUMERIC(20,2);
    v_fuel_price NUMERIC;
    v_game_current_time_new TIMESTAMP WITH TIME ZONE;
    
    -- Accumulation buffers
    v_buffered_rev_accum NUMERIC(20,2);
    v_buffered_ops_accum NUMERIC(20,2);
    v_buffered_lease_accum NUMERIC(20,2);
BEGIN
    v_now := NOW();
    
    -- Fetch active fuel price
    SELECT fuel_price_per_liter INTO v_fuel_price FROM global_game_settings LIMIT 1;
    v_fuel_price := COALESCE(v_fuel_price, 0.85);

    FOR r_bot IN SELECT * FROM ai_competitors WHERE status != 'Bankrupt' LOOP
        v_real_sec := COALESCE(EXTRACT(EPOCH FROM (v_now - r_bot.last_active_at)), 0.0);
        
        IF v_real_sec > 1209600 THEN
            v_real_sec := 1209600;
        END IF;

        IF v_real_sec >= 2 THEN
            v_game_sec := v_real_sec * 30.0;
            v_game_days := v_game_sec / 86400.0;
            v_game_current_time_new := r_bot.game_current_time + (v_game_sec * INTERVAL '1 second');
            
            -- Deduct recurring leases
            v_lease_cost := 0.00;
            FOR v_fleet IN 
                SELECT f.*, m.lease_price_per_month 
                FROM user_fleet f
                JOIN aircraft_models m ON f.aircraft_model_id = m.id
                WHERE f.ai_competitor_id = r_bot.id AND f.acquisition_type = 'lease'
            LOOP
                v_lease_cost := v_lease_cost + COALESCE((v_game_days * (v_fleet.lease_price_per_month / 30.0)), 0.00);
            END LOOP;
            v_lease_cost := GREATEST(0.00, COALESCE(v_lease_cost, 0.00));

            -- Process flights
            v_total_revenue := 0.00;
            v_total_cost_accum := 0.00;

            FOR v_route IN 
                SELECT r.*, 
                       f.id AS fleet_aircraft_id, f.condition, f.status,
                       m.capacity, m.speed_kmh, m.fuel_burn_per_km, m.maintenance_cost_per_hour,
                       org.demand_index AS org_demand, org.airport_tax AS org_tax,
                       dst.demand_index AS dst_demand, dst.airport_tax AS dst_tax
                FROM user_routes r
                JOIN user_fleet f ON r.assigned_aircraft_id = f.id
                JOIN aircraft_models m ON f.aircraft_model_id = m.id
                JOIN airports org ON r.origin_iata = org.iata
                JOIN airports dst ON r.destination_iata = dst.iata
                WHERE r.ai_competitor_id = r_bot.id
            LOOP
                -- Auto-ground low condition or grounded status
                IF COALESCE(v_route.condition, 0.00) < COALESCE(r_bot.auto_grounding_threshold, 40.00) OR COALESCE(v_route.status, 'grounded') != 'active' THEN
                    CONTINUE;
                END IF;

                v_flight_duration := COALESCE((v_route.distance_km / NULLIF(v_route.speed_kmh, 0)), 0.0) + 1.0;
                v_flights := COALESCE(v_game_days * (v_route.flights_per_week / 7.0), 0.0);
                
                IF v_flights > 0.0001 THEN
                    v_demand_multiplier := 1.5 - 0.8 * POWER((COALESCE(v_route.ticket_price, 0.00) / NULLIF((50.0 + (COALESCE(v_route.distance_km, 0.0) * 0.12)), 0)), 2);
                    v_demand_multiplier := GREATEST(0.00, LEAST(1.50, COALESCE(v_demand_multiplier, 0.00)));
                    
                    v_passengers := FLOOR(COALESCE(v_route.capacity, 0) * 0.75 * v_demand_multiplier);
                    v_passengers := GREATEST(0, LEAST(COALESCE(v_route.capacity, 0), v_passengers));
                    
                    v_revenue := COALESCE(v_flights * v_passengers * v_route.ticket_price, 0.00);
                    v_fuel_cost := COALESCE(v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price, 0.00);
                    v_maint_cost := COALESCE(v_flights * v_flight_duration * v_route.maintenance_cost_per_hour, 0.00);
                    v_tax_cost := COALESCE(v_flights * (COALESCE(v_route.org_tax, 0.00) + COALESCE(v_route.dst_tax, 0.00)), 0.00);
                    v_total_cost := GREATEST(0.00, v_fuel_cost + v_maint_cost + v_tax_cost);
                    
                    v_wear_per_flight := 0.50 + (COALESCE(v_route.distance_km, 0.0) * 0.0001);
                    
                    -- Damage wear
                    UPDATE user_fleet 
                    SET condition = GREATEST(0.00, condition - (v_flights * v_wear_per_flight))
                    WHERE id = v_route.fleet_aircraft_id;
                    
                    -- Ground if below auto grounding threshold
                    UPDATE user_fleet
                    SET status = 'grounded'
                    WHERE id = v_route.fleet_aircraft_id AND condition < r_bot.auto_grounding_threshold;

                    v_total_revenue := v_total_revenue + v_revenue;
                    v_total_cost_accum := v_total_cost_accum + v_total_cost;
                END IF;
            END LOOP;

            v_total_revenue := GREATEST(0.00, COALESCE(v_total_revenue, 0.00));
            v_total_cost_accum := GREATEST(0.00, COALESCE(v_total_cost_accum, 0.00));
            v_net := v_total_revenue - v_total_cost_accum - v_lease_cost;
            
            -- Accumulate into bot buffers (Requirement 3)
            v_buffered_rev_accum := COALESCE(r_bot.buffered_revenue, 0.00) + v_total_revenue;
            v_buffered_ops_accum := COALESCE(r_bot.buffered_ops_cost, 0.00) + v_total_cost_accum;
            v_buffered_lease_accum := COALESCE(r_bot.buffered_lease_cost, 0.00) + v_lease_cost;

            -- Flush bot daily consolidated ledger entries (Requirement 3)
            IF date_trunc('day', v_game_current_time_new) > date_trunc('day', r_bot.game_current_time) THEN
                -- Flush Ticket Sales
                IF v_buffered_rev_accum > 0 THEN
                    INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                    VALUES (r_bot.id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active bot routes', date_trunc('day', v_game_current_time_new));
                END IF;
                
                -- Flush Operations
                IF v_buffered_ops_accum > 0 THEN
                    INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                    VALUES (r_bot.id, 'expense', 'operations', v_buffered_ops_accum, 'Consolidated operations fuel, crew, & airport landing fees', date_trunc('day', v_game_current_time_new));
                END IF;
                
                -- Flush Leases
                IF v_buffered_lease_accum > 0 THEN
                    INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
                    VALUES (r_bot.id, 'expense', 'aircraft_lease', v_buffered_lease_accum, 'Consolidated leasing fees for active bot fleet', date_trunc('day', v_game_current_time_new));
                END IF;

                -- Prune bot ledger records older than 30 game days
                DELETE FROM financial_ledger 
                WHERE ai_competitor_id = r_bot.id 
                  AND game_date < (v_game_current_time_new - INTERVAL '30 days');

                v_buffered_rev_accum := 0.00;
                v_buffered_ops_accum := 0.00;
                v_buffered_lease_accum := 0.00;
            END IF;

            -- Update bot state authoritatively
            UPDATE ai_competitors
            SET cash = cash + v_net,
                game_current_time = v_game_current_time_new,
                last_active_at = v_now,
                buffered_revenue = v_buffered_rev_accum,
                buffered_ops_cost = v_buffered_ops_accum,
                buffered_lease_cost = v_buffered_lease_accum
            WHERE id = r_bot.id;
        END IF;
    END LOOP;

    -- Run AI decisions
    PERFORM execute_bot_decisions();
END;
$$ LANGUAGE plpgsql;
