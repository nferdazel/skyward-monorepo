-- ============================================================================
-- SKYWARD BOT MUTATION NATIVE SQL AUDIT
-- ============================================================================
-- This script validates bot-specific mutation paths through the shared actor
-- helpers, bankruptcy, repair, day-boundary, and distress-stage columns.
-- Everything runs inside a secure rollback transaction so no side effects
-- persist if any assertion fails.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  v_season_id       UUID;
  v_season_time     TIMESTAMPTZ;
  v_model_id        UUID;
  v_model_name      VARCHAR;
  v_model_capacity  INT;
  v_model_range     INT;
  v_model_speed     INT;
  v_model_purchase  NUMERIC;
  v_model_lease     NUMERIC;

  -- A1 variables
  v_bot1_id         UUID;
  v_a1_success      BOOLEAN;
  v_a1_message      VARCHAR;
  v_a1_cash         NUMERIC;
  v_a1_fleet_id     UUID;
  v_a1_tail         VARCHAR;
  v_a1_fleet_count  INT;
  v_a1_tx_count     INT;

  -- A2 variables
  v_bot2_id         UUID;
  v_bot2_aircraft   UUID;
  v_a2_success      BOOLEAN;
  v_a2_message      VARCHAR;
  v_a2_route_id     UUID;
  v_a2_route_count  INT;
  v_a2_origin       VARCHAR;
  v_a2_dest         VARCHAR;
  v_a2_distance     NUMERIC;

  -- A3 variables
  v_bot3_id         UUID;
  v_bot3_aircraft   UUID;
  v_bot3_route_id   UUID;
  v_bot3_loan_id    UUID;
  v_a3_status       VARCHAR;
  v_a3_fleet_status VARCHAR;
  v_a3_loan_status  VARCHAR;
  v_a3_route_status VARCHAR;
  v_a3_remaining    NUMERIC;

  -- A4 variables
  v_bot4_id         UUID;
  v_bot4_aircraft   UUID;
  v_a4_success      BOOLEAN;
  v_a4_message      VARCHAR;
  v_a4_cash         NUMERIC;
  v_a4_cost         NUMERIC;
  v_a4_condition    NUMERIC;
  v_a4_status       VARCHAR;
  v_a4_tx_before    INT;
  v_a4_tx_after     INT;

  -- A5 variables
  v_bot5_id         UUID;
  v_a5_balance      NUMERIC;
  v_a5_loan_id      UUID;
  v_a5_loan_status  VARCHAR;
  v_a5_loan_balance_before NUMERIC;
  v_a5_loan_balance_after  NUMERIC;
  v_a5_credit_score INT;
  v_a5_credit_tier  VARCHAR;
  v_a5_target_date  TIMESTAMPTZ;

  -- A6 variables
  v_bot6_id         UUID;
  v_a6_distress     VARCHAR;
  v_a6_growth_at    TIMESTAMPTZ;
  v_a6_route_at     TIMESTAMPTZ;
  v_a6_pricing_at   TIMESTAMPTZ;
  v_a6_repair_at    TIMESTAMPTZ;

BEGIN
  -- ==========================================================================
  -- 0. BOOTSTRAP: resolve active season and seed data
  -- ==========================================================================

  SELECT id, current_game_time
    INTO v_season_id, v_season_time
    FROM season_clock
   WHERE status = 'active'
   ORDER BY created_at ASC
   LIMIT 1;

  ASSERT v_season_id IS NOT NULL, 'Expected one active season for bot audit bootstrap.';

  -- Ensure test airports exist
  INSERT INTO airports (iata, name, city, country, latitude, longitude, demand_index)
  VALUES
    ('SIN', 'Changi', 'Singapore', 'Singapore', 1.3644, 103.9915, 98),
    ('CGK', 'Soekarno-Hatta', 'Jakarta', 'Indonesia', -6.1256, 106.6558, 95),
    ('KUL', 'KLIA', 'Kuala Lumpur', 'Malaysia', 2.7456, 101.7072, 90),
    ('BKK', 'Suvarnabhumi', 'Bangkok', 'Thailand', 13.6900, 100.7501, 88)
  ON CONFLICT (iata) DO NOTHING;

  -- Use or create a known test model with enough range for SIN-KUL
  SELECT id, model_name, capacity, range_km, speed_kmh, purchase_price, lease_price_per_month
    INTO v_model_id, v_model_name, v_model_capacity, v_model_range, v_model_speed, v_model_purchase, v_model_lease
    FROM aircraft_models
   WHERE model_name = '737 MAX Test'
   LIMIT 1;

  IF v_model_id IS NULL THEN
    INSERT INTO aircraft_models (
      manufacturer, model_name, type, range_km, capacity, speed_kmh,
      fuel_burn_per_km, maintenance_cost_per_hour, purchase_price, lease_price_per_month
    ) VALUES (
      'Boeing', '737 MAX Test', 'narrow_body_jet', 6500, 189, 839,
      4.3, 860.00, 120000000.00, 600000.00
    )
    RETURNING id, model_name, capacity, range_km, speed_kmh, purchase_price, lease_price_per_month
      INTO v_model_id, v_model_name, v_model_capacity, v_model_range, v_model_speed, v_model_purchase, v_model_lease;
  END IF;

  ASSERT v_model_id IS NOT NULL, 'Failed to resolve test aircraft model.';

  -- Clean residual test data from prior failed runs
  DELETE FROM bot_profiles WHERE user_id IN (
    SELECT id FROM users WHERE username LIKE 'bot_audit_%'
  );
  DELETE FROM route_assignments WHERE user_id IN (
    SELECT id FROM users WHERE username LIKE 'bot_audit_%'
  );
  DELETE FROM fleet_aircraft WHERE user_id IN (
    SELECT id FROM users WHERE username LIKE 'bot_audit_%'
  );
  DELETE FROM loans WHERE user_id IN (
    SELECT id FROM users WHERE username LIKE 'bot_audit_%'
  );
  DELETE FROM bank_transactions WHERE user_id IN (
    SELECT id FROM users WHERE username LIKE 'bot_audit_%'
  );
  DELETE FROM bank_accounts WHERE user_id IN (
    SELECT id FROM users WHERE username LIKE 'bot_audit_%'
  );
  DELETE FROM credit_scores WHERE user_id IN (
    SELECT id FROM users WHERE username LIKE 'bot_audit_%'
  );
  DELETE FROM users WHERE username LIKE 'bot_audit_%';

  -- ==========================================================================
  -- A1. TEST: Bot fleet growth via shared helper (create_actor_fleet_aircraft)
  -- ==========================================================================

  -- Create a bot user with sufficient cash
  INSERT INTO users (
    username, company_name, ceo_name, actor_type,
    hq_airport_iata, game_current_time, operational_status,
    net_worth, consecutive_negative_days, recovery_streak_days,
    auto_grounding_threshold, season_id
  ) VALUES (
    'bot_audit_a1', 'Audit Bot A1 Airlines', 'Bot A1 CEO', 'AI',
    'SIN', v_season_time, 'Active',
    20000000.00, 0, 0,
    40.00, v_season_id
  ) RETURNING id INTO v_bot1_id;

  INSERT INTO bot_profiles (user_id, archetype)
  VALUES (v_bot1_id, 'Balanced');

  -- Fund the bank account generously
  UPDATE bank_accounts
     SET balance = 20000000.00
   WHERE user_id = v_bot1_id
     AND account_type = 'operating';

  -- Call the shared fleet helper — lease acquisition with a charge
  SELECT success, message, new_cash, fleet_id, tail_number
    INTO v_a1_success, v_a1_message, v_a1_cash, v_a1_fleet_id, v_a1_tail
    FROM create_actor_fleet_aircraft(
      v_bot1_id,
      v_model_id,
      'Audit Bot A1 Plane',
      'lease',
      FLOOR(v_model_capacity * 0.70)::INT,
      FLOOR(v_model_capacity * 0.20)::INT,
      FLOOR(v_model_capacity * 0.10)::INT,
      600000.00,
      'investing',
      'aircraft_lease_deposit',
      NULL,
      v_season_time
    );

  ASSERT v_a1_success = TRUE,
    'A1: create_actor_fleet_aircraft should succeed for a bot with sufficient cash: ' || COALESCE(v_a1_message, 'no message');
  ASSERT v_a1_fleet_id IS NOT NULL,
    'A1: create_actor_fleet_aircraft should return a fleet_id';
  ASSERT v_a1_tail IS NOT NULL AND LENGTH(v_a1_tail) > 0,
    'A1: create_actor_fleet_aircraft should generate a tail number';

  -- Verify fleet_aircraft row exists for this bot
  SELECT COUNT(*) INTO v_a1_fleet_count
    FROM fleet_aircraft
   WHERE user_id = v_bot1_id
     AND id = v_a1_fleet_id;

  ASSERT v_a1_fleet_count = 1,
    'A1: fleet_aircraft row should exist for the bot after create_actor_fleet_aircraft';

  -- Verify bank_transactions has a debit row for the lease deposit
  SELECT COUNT(*) INTO v_a1_tx_count
    FROM bank_transactions
   WHERE user_id = v_bot1_id
     AND ifrs_subcategory = 'aircraft_lease_deposit'
     AND transaction_type = 'debit';

  ASSERT v_a1_tx_count >= 1,
    'A1: bank_transactions should have at least one debit row for aircraft_lease_deposit';

  -- ==========================================================================
  -- A2. TEST: Bot route creation via shared helper
  --         (create_actor_route_assignment)
  -- ==========================================================================

  -- Create a second bot with an aircraft already in its fleet
  INSERT INTO users (
    username, company_name, ceo_name, actor_type,
    hq_airport_iata, game_current_time, operational_status,
    net_worth, consecutive_negative_days, recovery_streak_days,
    auto_grounding_threshold, season_id
  ) VALUES (
    'bot_audit_a2', 'Audit Bot A2 Airlines', 'Bot A2 CEO', 'AI',
    'SIN', v_season_time, 'Active',
    20000000.00, 0, 0,
    40.00, v_season_id
  ) RETURNING id INTO v_bot2_id;

  INSERT INTO bot_profiles (user_id, archetype)
  VALUES (v_bot2_id, 'Balanced');

  UPDATE bank_accounts
     SET balance = 20000000.00
   WHERE user_id = v_bot2_id
     AND account_type = 'operating';

  -- Create an aircraft for this bot
  SELECT success, fleet_id
    INTO v_a1_success, v_bot2_aircraft
    FROM create_actor_fleet_aircraft(
      v_bot2_id,
      v_model_id,
      'Audit Bot A2 Plane',
      'purchase',
      FLOOR(v_model_capacity * 0.70)::INT,
      FLOOR(v_model_capacity * 0.20)::INT,
      FLOOR(v_model_capacity * 0.10)::INT,
      v_model_purchase,
      'investing',
      'aircraft_purchase',
      NULL,
      v_season_time
    );

  ASSERT v_a1_success = TRUE,
    'A2: setup — fleet aircraft creation should succeed for bot A2';
  ASSERT v_bot2_aircraft IS NOT NULL,
    'A2: setup — fleet_id should be returned';

  -- Calculate distance SIN-KUL for the route
  SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude)
    INTO v_a2_distance
    FROM airports o, airports d
   WHERE o.iata = 'SIN' AND d.iata = 'KUL';

  ASSERT v_a2_distance > 0,
    'A2: setup — SIN-KUL distance should be positive';

  -- Call the shared route helper
  SELECT success, message, route_id
    INTO v_a2_success, v_a2_message, v_a2_route_id
    FROM create_actor_route_assignment(
      v_bot2_id,
      'SIN',
      'KUL',
      v_a2_distance,
      150.00,
      7,
      v_bot2_aircraft
    );

  ASSERT v_a2_success = TRUE,
    'A2: create_actor_route_assignment should succeed for a bot with a valid aircraft: ' || COALESCE(v_a2_message, 'no message');
  ASSERT v_a2_route_id IS NOT NULL,
    'A2: create_actor_route_assignment should return a route_id';

  -- Verify route_assignments row exists with valid origin/dest
  SELECT COUNT(*), MIN(origin_iata), MIN(destination_iata)
    INTO v_a2_route_count, v_a2_origin, v_a2_dest
    FROM route_assignments
   WHERE user_id = v_bot2_id
     AND id = v_a2_route_id;

  ASSERT v_a2_route_count = 1,
    'A2: route_assignments row should exist for the bot';
  ASSERT v_a2_origin = 'SIN' AND v_a2_dest = 'KUL',
    'A2: route should have SIN origin and KUL destination';

  -- ==========================================================================
  -- A3. TEST: Bot bankruptcy parity (apply_actor_bankruptcy_state)
  -- ==========================================================================

  -- Create a bot with an active loan, route, and fleet — then bankrupt it
  INSERT INTO users (
    username, company_name, ceo_name, actor_type,
    hq_airport_iata, game_current_time, operational_status,
    net_worth, consecutive_negative_days, recovery_streak_days,
    auto_grounding_threshold, season_id
  ) VALUES (
    'bot_audit_a3', 'Audit Bot A3 Airlines', 'Bot A3 CEO', 'AI',
    'CGK', v_season_time, 'Active',
    -10000000.00, 0, 0,
    40.00, v_season_id
  ) RETURNING id INTO v_bot3_id;

  INSERT INTO bot_profiles (user_id, archetype)
  VALUES (v_bot3_id, 'Aggressive');

  UPDATE bank_accounts
     SET balance = -10000000.00
   WHERE user_id = v_bot3_id
     AND account_type = 'operating';

  -- Create a grounded aircraft for this bot
  INSERT INTO fleet_aircraft (
    user_id, aircraft_model_id, nickname, tail_number,
    acquisition_type, condition, status,
    economy_seats, business_seats, first_class_seats
  ) VALUES (
    v_bot3_id, v_model_id, 'Audit Bot A3 Plane', 'BNK-001',
    'purchase', 100.00, 'active',
    FLOOR(v_model_capacity * 0.70)::INT,
    FLOOR(v_model_capacity * 0.20)::INT,
    FLOOR(v_model_capacity * 0.10)::INT
  ) RETURNING id INTO v_bot3_aircraft;

  -- Create a route for this bot
  INSERT INTO route_assignments (
    user_id, origin_iata, destination_iata,
    distance_km, ticket_price, assigned_aircraft_id, flights_per_week
  ) VALUES (
    v_bot3_id, 'CGK', 'SIN', 886.0, 120.00, v_bot3_aircraft, 7
  ) RETURNING id INTO v_bot3_route_id;

  -- Create an active loan for this bot
  INSERT INTO loans (
    user_id, principal, remaining_balance, interest_rate,
    weekly_payment, status, loan_type, term_months
  ) VALUES (
    v_bot3_id, 5000000.00, 3000000.00, 0.05,
    100000.00, 'active', 'unsecured', 52
  ) RETURNING id INTO v_bot3_loan_id;

  -- Apply bankruptcy
  PERFORM apply_actor_bankruptcy_state(v_bot3_id);

  -- Assert: operational_status = 'Bankrupt'
  SELECT operational_status
    INTO v_a3_status
    FROM users
   WHERE id = v_bot3_id;

  ASSERT v_a3_status = 'Bankrupt',
    'A3: apply_actor_bankruptcy_state should set operational_status to Bankrupt';

  -- Assert: fleet grounded
  SELECT status
    INTO v_a3_fleet_status
    FROM fleet_aircraft
   WHERE id = v_bot3_aircraft;

  ASSERT v_a3_fleet_status = 'grounded',
    'A3: apply_actor_bankruptcy_state should ground all fleet aircraft';

  -- Assert: loans defaulted
  SELECT status, remaining_balance
    INTO v_a3_loan_status, v_a3_remaining
    FROM loans
   WHERE id = v_bot3_loan_id;

  ASSERT v_a3_loan_status = 'defaulted',
    'A3: apply_actor_bankruptcy_state should default active loans';
  ASSERT v_a3_remaining = 0,
    'A3: apply_actor_bankruptcy_state should zero out remaining_balance on defaulted loans';

  -- Assert: routes cancelled
  SELECT status
    INTO v_a3_route_status
    FROM route_assignments
   WHERE id = v_bot3_route_id;

  ASSERT v_a3_route_status = 'cancelled',
    'A3: apply_actor_bankruptcy_state should cancel active route assignments';

  -- ==========================================================================
  -- A4. TEST: Bot repair via shared helper (perform_actor_aircraft_repair)
  -- ==========================================================================

  -- Create a bot with a degraded aircraft and enough cash for repairs
  INSERT INTO users (
    username, company_name, ceo_name, actor_type,
    hq_airport_iata, game_current_time, operational_status,
    net_worth, consecutive_negative_days, recovery_streak_days,
    auto_grounding_threshold, season_id
  ) VALUES (
    'bot_audit_a4', 'Audit Bot A4 Airlines', 'Bot A4 CEO', 'AI',
    'SIN', v_season_time, 'Active',
    10000000.00, 0, 0,
    40.00, v_season_id
  ) RETURNING id INTO v_bot4_id;

  INSERT INTO bot_profiles (user_id, archetype)
  VALUES (v_bot4_id, 'Balanced');

  UPDATE bank_accounts
     SET balance = 10000000.00
   WHERE user_id = v_bot4_id
     AND account_type = 'operating';

  -- Create a degraded aircraft (low condition, grounded)
  INSERT INTO fleet_aircraft (
    user_id, aircraft_model_id, nickname, tail_number,
    acquisition_type, condition, status,
    economy_seats, business_seats, first_class_seats
  ) VALUES (
    v_bot4_id, v_model_id, 'Audit Bot A4 Plane', 'RPR-001',
    'purchase', 35.00, 'grounded',
    FLOOR(v_model_capacity * 0.70)::INT,
    FLOOR(v_model_capacity * 0.20)::INT,
    FLOOR(v_model_capacity * 0.10)::INT
  ) RETURNING id INTO v_bot4_aircraft;

  -- Count maintenance ledger rows before repair
  SELECT COUNT(*)
    INTO v_a4_tx_before
    FROM bank_transactions
   WHERE user_id = v_bot4_id
     AND ifrs_subcategory = 'maintenance';

  -- Call the shared repair helper
  SELECT success, message, new_cash, repair_cost
    INTO v_a4_success, v_a4_message, v_a4_cash, v_a4_cost
    FROM perform_actor_aircraft_repair(
      v_bot4_id,
      v_bot4_aircraft,
      0,
      v_season_time,
      'Bot A4 maintenance recovery'
    );

  ASSERT v_a4_success = TRUE,
    'A4: perform_actor_aircraft_repair should succeed for a bot with sufficient cash: ' || COALESCE(v_a4_message, 'no message');
  ASSERT v_a4_cost > 0,
    'A4: repair cost should be positive for a degraded aircraft';

  -- Verify aircraft condition restored and status = 'active'
  SELECT condition, status
    INTO v_a4_condition, v_a4_status
    FROM fleet_aircraft
   WHERE id = v_bot4_aircraft;

  ASSERT v_a4_condition = 100.00,
    'A4: perform_actor_aircraft_repair should restore condition to 100%';
  ASSERT v_a4_status = 'active',
    'A4: perform_actor_aircraft_repair should set status to active';

  -- Verify maintenance ledger row was written
  SELECT COUNT(*)
    INTO v_a4_tx_after
    FROM bank_transactions
   WHERE user_id = v_bot4_id
     AND ifrs_subcategory = 'maintenance';

  ASSERT v_a4_tx_after = v_a4_tx_before + 1,
    'A4: perform_actor_aircraft_repair should append exactly one maintenance ledger row';

  -- ==========================================================================
  -- A5. TEST: Day-boundary processing (process_actor_day_boundary)
  -- ==========================================================================

  -- Create a bot with an active loan to trigger loan payment processing
  INSERT INTO users (
    username, company_name, ceo_name, actor_type,
    hq_airport_iata, game_current_time, operational_status,
    net_worth, consecutive_negative_days, recovery_streak_days,
    auto_grounding_threshold, season_id
  ) VALUES (
    'bot_audit_a5', 'Audit Bot A5 Airlines', 'Bot A5 CEO', 'AI',
    'BKK', v_season_time, 'Active',
    8000000.00, 0, 0,
    40.00, v_season_id
  ) RETURNING id INTO v_bot5_id;

  INSERT INTO bot_profiles (user_id, archetype)
  VALUES (v_bot5_id, 'Balanced');

  UPDATE bank_accounts
     SET balance = 8000000.00
   WHERE user_id = v_bot5_id
     AND account_type = 'operating';

  -- Create an active loan with a known remaining balance
  INSERT INTO loans (
    user_id, principal, remaining_balance, interest_rate,
    weekly_payment, status, loan_type, term_months
  ) VALUES (
    v_bot5_id, 2000000.00, 1500000.00, 0.05,
    50000.00, 'active', 'unsecured', 52
  ) RETURNING id INTO v_a5_loan_id;

  SELECT remaining_balance
    INTO v_a5_loan_balance_before
    FROM loans
   WHERE id = v_a5_loan_id;

  -- Target date is one week ahead to trigger loan payment
  v_a5_target_date := v_season_time + INTERVAL '7 days';

  -- Call the day-boundary helper
  PERFORM process_actor_day_boundary(v_bot5_id, v_a5_target_date);

  -- Assert: loan payment was processed (remaining balance should decrease or
  -- loan may be paid off)
  SELECT remaining_balance, status
    INTO v_a5_loan_balance_after, v_a5_loan_status
    FROM loans
   WHERE id = v_a5_loan_id;

  IF v_a5_loan_status = 'active' THEN
    ASSERT v_a5_loan_balance_after < v_a5_loan_balance_before,
      'A5: process_actor_day_boundary should reduce loan remaining_balance via loan payment processing';
  ELSE
    ASSERT v_a5_loan_status = 'paid_off',
      'A5: process_actor_day_boundary should mark the loan as paid_off when balance reaches zero';
  END IF;

  -- Assert: credit score was evaluated (credit_scores row should exist)
  SELECT score, tier
    INTO v_a5_credit_score, v_a5_credit_tier
    FROM credit_scores
   WHERE user_id = v_bot5_id;

  ASSERT v_a5_credit_score IS NOT NULL,
    'A5: process_actor_day_boundary should trigger credit evaluation (credit_scores row should exist)';
  ASSERT v_a5_credit_tier IN ('Subprime', 'Standard', 'Silver', 'Gold', 'Platinum'),
    'A5: credit tier should be a valid tier value';

  -- Verify the bot's cash was debited for the loan payment
  SELECT get_user_balance(v_bot5_id)
    INTO v_a5_balance;

  ASSERT v_a5_balance < 8000000.00,
    'A5: process_actor_day_boundary should reduce operating cash via loan payment';

  -- ==========================================================================
  -- A6. TEST: Distress stage column verification
  --         (bot_profiles columns from migration 16)
  -- ==========================================================================

  -- Create a bot to verify all distress/inertia columns
  INSERT INTO users (
    username, company_name, ceo_name, actor_type,
    hq_airport_iata, game_current_time, operational_status,
    net_worth, consecutive_negative_days, recovery_streak_days,
    auto_grounding_threshold, season_id
  ) VALUES (
    'bot_audit_a6', 'Audit Bot A6 Airlines', 'Bot A6 CEO', 'AI',
    'CGK', v_season_time, 'Active',
    15000000.00, 0, 0,
    40.00, v_season_id
  ) RETURNING id INTO v_bot6_id;

  -- Insert with all inertia columns set
  INSERT INTO bot_profiles (
    user_id, archetype, distress_stage,
    last_growth_action_at, last_route_change_at,
    last_pricing_review_at, last_repair_action_at
  ) VALUES (
    v_bot6_id, 'Balanced', 'stable',
    v_season_time - INTERVAL '1 day',
    v_season_time - INTERVAL '1 day',
    v_season_time - INTERVAL '1 day',
    v_season_time - INTERVAL '1 day'
  );

  -- Read back and verify all columns accepted valid values
  SELECT distress_stage,
         last_growth_action_at,
         last_route_change_at,
         last_pricing_review_at,
         last_repair_action_at
    INTO v_a6_distress,
         v_a6_growth_at,
         v_a6_route_at,
         v_a6_pricing_at,
         v_a6_repair_at
    FROM bot_profiles
   WHERE user_id = v_bot6_id;

  ASSERT v_a6_distress = 'stable',
    'A6: distress_stage column should accept and return valid value';
  ASSERT v_a6_growth_at IS NOT NULL,
    'A6: last_growth_action_at column should accept timestamptz values';
  ASSERT v_a6_route_at IS NOT NULL,
    'A6: last_route_change_at column should accept timestamptz values';
  ASSERT v_a6_pricing_at IS NOT NULL,
    'A6: last_pricing_review_at column should accept timestamptz values';
  ASSERT v_a6_repair_at IS NOT NULL,
    'A6: last_repair_action_at column should accept timestamptz values';

  -- Verify all valid distress_stage values are accepted
  UPDATE bot_profiles SET distress_stage = 'cautious'  WHERE user_id = v_bot6_id;
  UPDATE bot_profiles SET distress_stage = 'defensive' WHERE user_id = v_bot6_id;
  UPDATE bot_profiles SET distress_stage = 'desperate' WHERE user_id = v_bot6_id;
  UPDATE bot_profiles SET distress_stage = 'stable'    WHERE user_id = v_bot6_id;

  SELECT distress_stage INTO v_a6_distress
    FROM bot_profiles WHERE user_id = v_bot6_id;

  ASSERT v_a6_distress = 'stable',
    'A6: distress_stage should cycle through all valid values (stable, cautious, defensive, desperate) without error';

  -- ==========================================================================
  -- SUCCESS CONFIRMATION
  -- ==========================================================================

  RAISE NOTICE 'ALL SKYWARD BOT MUTATION AUDIT TESTS PASSED!';
END $$;

ROLLBACK;
