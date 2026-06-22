-- ============================================================================
-- SKYWARD BOT SEED MODEL SELECTION FIX
-- ============================================================================
-- Fixes dormant bot archetypes caused by stale aircraft model-name lookups.
-- Aggressive bots must resolve to A320neo, Premium bots to 787-9.
-- Also adds simple fallback ordering so minor catalog label drift does not
-- silently block bot bootstrap again.
-- ============================================================================

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
        IF r_bot.status = 'Bankrupt' OR r_bot.cash < -5000000.00 THEN
            DELETE FROM user_routes WHERE ai_competitor_id = r_bot.id;
            DELETE FROM user_fleet WHERE ai_competitor_id = r_bot.id;
            DELETE FROM financial_ledger WHERE ai_competitor_id = r_bot.id;
            DELETE FROM ai_competitors WHERE id = r_bot.id;
            CONTINUE;
        END IF;

        SELECT COUNT(*)::INT INTO v_fleet_count FROM user_fleet WHERE ai_competitor_id = r_bot.id;

        IF v_fleet_count < 12 AND r_bot.cash > 5000000.00 AND random() < 0.15 THEN
            v_model_id := NULL;
            v_model_name := NULL;
            v_lease_price := NULL;
            v_purchase_price := NULL;
            v_capacity := NULL;

            IF r_bot.archetype = 'Regional' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity
                FROM aircraft_models
                WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600'
                LIMIT 1;
            ELSIF r_bot.archetype = 'Aggressive' THEN
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity
                FROM aircraft_models
                WHERE manufacturer = 'Airbus' AND model_name = 'A320neo'
                LIMIT 1;
            ELSE
                SELECT id, model_name, lease_price_per_month, purchase_price, capacity
                INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity
                FROM aircraft_models
                WHERE manufacturer = 'Boeing' AND model_name = '787-9'
                LIMIT 1;
            END IF;

            -- Defensive fallback if the exact catalog label drifts in the future.
            IF v_model_id IS NULL THEN
                IF r_bot.archetype = 'Regional' THEN
                    SELECT id, model_name, lease_price_per_month, purchase_price, capacity
                    INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity
                    FROM aircraft_models
                    WHERE manufacturer = 'ATR'
                    ORDER BY capacity DESC
                    LIMIT 1;
                ELSIF r_bot.archetype = 'Aggressive' THEN
                    SELECT id, model_name, lease_price_per_month, purchase_price, capacity
                    INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity
                    FROM aircraft_models
                    WHERE manufacturer = 'Airbus'
                    ORDER BY capacity DESC
                    LIMIT 1;
                ELSE
                    SELECT id, model_name, lease_price_per_month, purchase_price, capacity
                    INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity
                    FROM aircraft_models
                    WHERE manufacturer = 'Boeing'
                    ORDER BY capacity DESC
                    LIMIT 1;
                END IF;
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

        IF r_bot.consecutive_negative_days >= 3 THEN
            UPDATE ai_competitors SET status = 'Bankrupt' WHERE id = r_bot.id;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
