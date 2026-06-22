-- Migration: Fix bot route distances using Haversine formula
-- Bot routes were hardcoded with 800km distance instead of real airport-to-airport distance.

-- 1. Create Haversine distance function
CREATE OR REPLACE FUNCTION haversine_distance(lat1 DOUBLE PRECISION, lon1 DOUBLE PRECISION, lat2 DOUBLE PRECISION, lon2 DOUBLE PRECISION)
RETURNS DOUBLE PRECISION AS $$
DECLARE
    R DOUBLE PRECISION := 6371.0;
    dlat DOUBLE PRECISION;
    dlon DOUBLE PRECISION;
    a DOUBLE PRECISION;
    c DOUBLE PRECISION;
BEGIN
    dlat := radians(lat2 - lat1);
    dlon := radians(lon2 - lon1);
    a := sin(dlat / 2) ^ 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ^ 2;
    c := 2 * atan2(sqrt(a), sqrt(1 - a));
    RETURN R * c;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 2. Fix existing bot routes with correct distances
UPDATE user_routes r
SET distance_km = haversine_distance(
    org.latitude, org.longitude,
    dst.latitude, dst.longitude
)
FROM airports org, airports dst
WHERE r.ai_competitor_id IS NOT NULL
  AND r.origin_iata = org.iata
  AND r.destination_iata = dst.iata
  AND ABS(r.distance_km - 800.0) < 1.0;

-- 3. Update the bot system overhaul function to calculate real distance
CREATE OR REPLACE FUNCTION process_bot_simulation(p_bot_id UUID DEFAULT NULL)
RETURNS void AS $$
DECLARE
    r_bot RECORD;
    r_route RECORD;
    v_model_id UUID;
    v_model_name VARCHAR;
    v_lease_price NUMERIC;
    v_purchase_price NUMERIC;
    v_capacity INT;
    v_deposit_pct NUMERIC := 0.10;
    v_deposit_amount NUMERIC;
    v_tail VARCHAR;
    v_new_aircraft_id UUID;
    v_origin_iata VARCHAR;
    v_dest_iata VARCHAR;
    v_distance NUMERIC;
    v_origin_lat NUMERIC;
    v_origin_lon NUMERIC;
    v_dest_lat NUMERIC;
    v_dest_lon NUMERIC;
    v_flights INT;
    v_flight_duration NUMERIC;
    v_fuel_price NUMERIC;
    v_fuel_cost NUMERIC;
    v_ticket_revenue NUMERIC;
    v_demand_multiplier NUMERIC;
    v_wear_per_flight NUMERIC;
    v_daily_revenue NUMERIC;
    v_daily_expense NUMERIC;
    v_daily_profit NUMERIC;
    v_game_current_time_new TIMESTAMP WITH TIME ZONE;
    v_elapsed_days NUMERIC;
    v_buffered_rev_accum NUMERIC := 0.0;
BEGIN
    -- Fetch fuel price
    SELECT fuel_price_per_liter INTO v_fuel_price FROM global_game_settings LIMIT 1;
    v_fuel_price := COALESCE(v_fuel_price, 0.85);

    FOR r_bot IN 
        SELECT * FROM ai_competitors 
        WHERE (p_bot_id IS NULL OR id = p_bot_id)
        AND status != 'bankrupt'
    LOOP
        v_elapsed_days := EXTRACT(EPOCH FROM (NOW() - r_bot.last_active_at)) / 86400.0 * 30.0;
        v_game_current_time_new := r_bot.game_current_time + (v_elapsed_days || ' days')::INTERVAL;

        -- Acquire fleet if needed
        IF NOT EXISTS (SELECT 1 FROM user_fleet WHERE ai_competitor_id = r_bot.id) THEN
            IF r_bot.archetype = 'Regional' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity 
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity 
                FROM aircraft_models 
                WHERE model_name = 'ATR 72-600' LIMIT 1;
            ELSIF r_bot.archetype = 'Aggressive' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity 
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity 
                FROM aircraft_models 
                WHERE model_name = 'A320neo' LIMIT 1;
            ELSE
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity 
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity 
                FROM aircraft_models 
                WHERE model_name = '787-9 Dreamliner' LIMIT 1;
            END IF;

            v_deposit_amount := v_lease_price * (v_deposit_pct * 10.0);
            
            IF v_model_id IS NOT NULL AND r_bot.cash >= v_deposit_amount THEN
                v_tail := generate_tail_number(r_bot.hq_airport_iata);
                v_new_aircraft_id := gen_random_uuid();
                
                INSERT INTO user_fleet (id, ai_competitor_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
                VALUES (v_new_aircraft_id, r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_capacity, 0, 0);
                
                UPDATE ai_competitors SET cash = cash - v_deposit_amount WHERE id = r_bot.id;
                
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
                
                -- Get origin coordinates
                SELECT latitude, longitude INTO v_origin_lat, v_origin_lon 
                FROM airports WHERE iata = v_origin_iata;
                
                -- Select destination excluding origin
                SELECT iata INTO v_dest_iata 
                FROM airports 
                WHERE iata != v_origin_iata 
                ORDER BY demand_index DESC, random() LIMIT 1;
                
                IF v_dest_iata IS NOT NULL THEN
                    -- Calculate real distance using Haversine
                    SELECT latitude, longitude INTO v_dest_lat, v_dest_lon 
                    FROM airports WHERE iata = v_dest_iata;
                    
                    v_distance := haversine_distance(v_origin_lat, v_origin_lon, v_dest_lat, v_dest_lon);
                    
                    INSERT INTO user_routes (ai_competitor_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week)
                    VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, 150.00, v_new_aircraft_id, 14)
                    ON CONFLICT DO NOTHING;
                END IF;
            END IF;
        END IF;

        -- Process existing routes for revenue
        v_buffered_rev_accum := 0.0;
        
        FOR r_route IN 
            SELECT r.*, m.fuel_burn_per_km, m.speed_kmh, m.capacity
            FROM user_routes r
            JOIN user_fleet f ON r.assigned_aircraft_id = f.id
            JOIN aircraft_models m ON f.aircraft_model_id = m.id
            WHERE r.ai_competitor_id = r_bot.id
        LOOP
            IF COALESCE(r_route.condition, 0.00) < COALESCE(r_bot.auto_grounding_threshold, 40.00) OR COALESCE(r_route.status, 'grounded') != 'active' THEN
                UPDATE user_fleet SET status = 'grounded' WHERE id = r_route.fleet_aircraft_id;
                CONTINUE;
            END IF;

            v_flights := LEAST(r_route.flights_per_week, 168);
            v_flight_duration := COALESCE((r_route.distance_km / NULLIF(r_route.speed_kmh, 0)), 0.0) + 1.0;
            
            IF (v_flights * v_flight_duration) > 168.0 THEN
                v_flights := FLOOR(168.0 / v_flight_duration);
            END IF;

            v_demand_multiplier := 1.5 - 0.8 * POWER((COALESCE(r_route.ticket_price, 0.00) / NULLIF((50.0 + (COALESCE(r_route.distance_km, 0.0) * 0.12)), 0)), 2);
            v_demand_multiplier := GREATEST(0.0, LEAST(1.5, v_demand_multiplier));

            v_ticket_revenue := v_flights * r_route.ticket_price * LEAST(r_route.capacity, FLOOR((50 + 50) * v_demand_multiplier * 10));
            v_fuel_cost := COALESCE(v_flights * r_route.distance_km * r_route.fuel_burn_per_km * v_fuel_price, 0.00);
            v_wear_per_flight := 0.50 + (COALESCE(r_route.distance_km, 0.0) * 0.0001);

            v_daily_revenue := v_ticket_revenue;
            v_daily_expense := v_fuel_cost;
            v_daily_profit := v_daily_revenue - v_daily_expense;

            v_buffered_rev_accum := v_buffered_rev_accum + v_daily_revenue;

            UPDATE user_routes SET 
                load_factor = LEAST(100.0, GREATEST(0.0, v_demand_multiplier * 66.67)),
                expected_passengers = FLOOR(LEAST(r_route.capacity, FLOOR((100) * v_demand_multiplier * 10))),
                demand_multiplier = v_demand_multiplier,
                weekly_ask = v_flights * r_route.capacity * r_route.distance_km,
                weekly_rpk = v_flights * FLOOR(LEAST(r_route.capacity, FLOOR((100) * v_demand_multiplier * 10))) * r_route.distance_km
            WHERE id = r_route.id;

            UPDATE user_fleet SET 
                condition = GREATEST(0.0, condition - (v_wear_per_flight * v_flights))
            WHERE id = r_route.fleet_aircraft_id;

            IF r_route.condition < r_bot.auto_grounding_threshold THEN
                UPDATE user_fleet SET status = 'grounded' WHERE id = r_route.fleet_aircraft_id;
            END IF;
        END LOOP;

        -- Write consolidated revenue to ledger
        IF v_buffered_rev_accum > 0 THEN
            INSERT INTO financial_ledger (ai_competitor_id, transaction_type, category, amount, description, game_date)
            VALUES (r_bot.id, 'revenue', 'ticket_sales', v_buffered_rev_accum, 'Consolidated ticket sales revenue for active bot routes', date_trunc('day', v_game_current_time_new));
        END IF;

        -- Update bot financials
        UPDATE ai_competitors SET 
            cash = cash + v_daily_profit,
            net_worth = cash + (SELECT COALESCE(SUM(purchase_price), 0) FROM user_fleet WHERE ai_competitor_id = r_bot.id),
            game_current_time = v_game_current_time_new,
            last_active_at = NOW()
        WHERE id = r_bot.id;

        -- Handle financial distress / bankruptcy
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

        IF r_bot.consecutive_negative_days >= 30 THEN
            UPDATE ai_competitors SET status = 'bankrupt' WHERE id = r_bot.id;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
