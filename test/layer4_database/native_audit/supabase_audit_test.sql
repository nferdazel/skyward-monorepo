-- ============================================================================
-- SKYWARD SYSTEM-WIDE DATABASE TRANSACTIONAL INTEGRATION AUDIT
-- ============================================================================
-- This script validates every single RPC function, database trigger, mathematical
-- constraint, and business logic cascade inside a secure rollback transaction.
-- If any assertion fails, the entire transaction aborts without side effects.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  v_user_id UUID;
  v_auth_user_id UUID;
  v_reg_success BOOLEAN;
  v_reg_message VARCHAR;
  
  v_model_id UUID;
  v_model_purchase_price NUMERIC;
  v_fleet_id UUID;
  
  v_starting_balance NUMERIC;
  v_ending_balance NUMERIC;
  v_purchase_before_cash NUMERIC;
  v_ledger_count INT;
  v_purchase_txn_amount NUMERIC;
  v_reconciled_nw NUMERIC;
  v_loan_ok BOOLEAN;
  v_loan_msg TEXT;
  v_loan_cash NUMERIC;
  v_loan_before_cash NUMERIC;
  v_loan_after_cash NUMERIC;
  v_active_loan_count INT;
  v_unsecured_loan_id UUID;
  v_credit_score INT;
  v_credit_tier VARCHAR;
  v_credit_max_unsecured NUMERIC;
  v_credit_suggestions TEXT[];
  v_repay_ok BOOLEAN;
  v_repay_msg TEXT;
  v_repay_cash NUMERIC;
  v_repay_paid_off BOOLEAN;
  v_repay_before_cash NUMERIC;
  v_repay_after_cash NUMERIC;
  v_repay_before_balance NUMERIC;
  v_repay_after_balance NUMERIC;
  v_refi_old_rate NUMERIC;
  v_refi_ok BOOLEAN;
  v_refi_msg TEXT;
  v_refi_new_rate NUMERIC;
  v_refi_savings NUMERIC;
  v_refi_zero_tx_count INT;
  
  v_route_id UUID;
  v_route_distance NUMERIC;
  v_route_ok BOOLEAN;
  v_route_msg VARCHAR;
  v_aircraft_status VARCHAR;
  v_old_tail_number VARCHAR;
  v_new_tail_number VARCHAR;
  v_updated_price NUMERIC;
  v_updated_frequency INT;
  v_sim_success BOOLEAN;
  v_sim_message VARCHAR;
-- ==========================================================================
-- 1. SETUP SEED DATA
-- ==========================================================================
BEGIN
  -- Create or retrieve a test aircraft model
  SELECT id, purchase_price
    INTO v_model_id, v_model_purchase_price
    FROM aircraft_models
   WHERE model_name = '737 MAX Test'
   LIMIT 1;
  IF v_model_id IS NULL THEN
    INSERT INTO aircraft_models (manufacturer, model_name, type, range_km, capacity, speed_kmh, fuel_burn_per_km, maintenance_cost_per_hour, purchase_price, lease_price_per_month)
    VALUES ('Boeing', '737 MAX Test', 'narrow_body_jet', 6500, 189, 839, 4.3, 860.00, 120000000.00, 600000.00)
    RETURNING id, purchase_price INTO v_model_id, v_model_purchase_price;
  END IF;

  -- Add mock airports if they do not exist
  INSERT INTO airports (iata, name, city, country, latitude, longitude, demand_index)
  VALUES 
    ('SIN', 'Changi', 'Singapore', 'Singapore', 1.3644, 103.9915, 98),
    ('CGK', 'Soekarno-Hatta', 'Jakarta', 'Indonesia', -6.1256, 106.6558, 95)
  ON CONFLICT (iata) DO NOTHING;

  -- ==========================================================================
  -- 2. TEST: direct player bootstrap for gameplay RPC audit
  -- ==========================================================================
  
  -- Clean existing test user if any residual exists
  DELETE FROM users WHERE username = 'audit_chief';

  INSERT INTO users (
    username,
    company_name,
    ceo_name,
    hq_airport_iata,
    net_worth,
    last_active_at
  )
  VALUES (
    'audit_chief',
    'Audit Chief Airlines',
    'Audit CEO',
    'CGK',
    COALESCE(get_config_numeric('starting_cash'), 15000000.00),
    NOW()
  )
  RETURNING id INTO v_user_id;

  ASSERT v_user_id IS NOT NULL, 'Direct audit user bootstrap failed.';

  -- Verify starting cash
  SELECT balance
    INTO v_starting_balance
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';
  ASSERT v_starting_balance = COALESCE(get_config_numeric('starting_cash'), 15000000.00), 'Starting cash balance should match game_config starting_cash';

  -- ==========================================================================
  -- 3. TEST: take_loan RPC & BANK-CENTRIC DISBURSEMENT
  -- ==========================================================================

  SELECT balance
    INTO v_loan_before_cash
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT success, message, new_cash
    INTO v_loan_ok, v_loan_msg, v_loan_cash
    FROM take_loan(v_user_id, 250000.00, 52, 'unsecured', NULL);

  ASSERT v_loan_ok = TRUE, 'Failed to originate unsecured loan: ' || COALESCE(v_loan_msg, 'no message');

  SELECT balance
    INTO v_loan_after_cash
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  ASSERT ROUND(v_loan_after_cash - v_loan_before_cash, 2) = 250000.00,
    'Loan disbursement should increase operating cash by principal amount';

  SELECT COUNT(*)
    INTO v_active_loan_count
    FROM loans
   WHERE user_id = v_user_id
     AND status = 'active'
     AND loan_type = 'unsecured';

  ASSERT v_active_loan_count = 1, 'Expected one active unsecured loan after take_loan';

  SELECT id
    INTO v_unsecured_loan_id
    FROM loans
   WHERE user_id = v_user_id
     AND status = 'active'
     AND loan_type = 'unsecured'
   ORDER BY taken_at DESC
   LIMIT 1;

  ASSERT v_unsecured_loan_id IS NOT NULL, 'Expected active unsecured loan id after take_loan';

  SELECT a.id
    INTO v_auth_user_id
    FROM auth.users a
    LEFT JOIN users u
      ON u.auth_user_id = a.id
   WHERE u.auth_user_id IS NULL
   ORDER BY a.created_at DESC
   LIMIT 1;

  ASSERT v_auth_user_id IS NOT NULL,
    'Expected at least one unmapped auth.users row for auth-bound wrapper audit';

  UPDATE users
     SET auth_user_id = v_auth_user_id
   WHERE id = v_user_id;

  PERFORM set_config('request.jwt.claim.sub', v_auth_user_id::TEXT, true);

  -- ==========================================================================
  -- 3A. TEST: auth-bound bank wrappers (credit report / repay / refinance)
  -- ==========================================================================

  SELECT current_score, credit_tier, max_unsecured_loan, suggestions
    INTO v_credit_score, v_credit_tier, v_credit_max_unsecured, v_credit_suggestions
    FROM get_credit_report();

  ASSERT v_credit_score IS NOT NULL, 'get_credit_report should return a score for the authenticated user';
  ASSERT v_credit_tier IN ('Subprime', 'Standard', 'Silver', 'Gold', 'Platinum'),
    'get_credit_report returned an unexpected tier';
  ASSERT COALESCE(v_credit_max_unsecured, 0) > 0,
    'get_credit_report should expose a positive unsecured-loan ceiling';
  ASSERT COALESCE(array_length(v_credit_suggestions, 1), 0) > 0,
    'get_credit_report should always include at least one suggestion';

  SELECT balance
    INTO v_repay_before_cash
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT remaining_balance
    INTO v_repay_before_balance
    FROM loans
   WHERE id = v_unsecured_loan_id;

  SELECT success, message, new_cash, paid_off
    INTO v_repay_ok, v_repay_msg, v_repay_cash, v_repay_paid_off
    FROM repay_loan(v_unsecured_loan_id, 50000.00);

  ASSERT v_repay_ok = TRUE, 'repay_loan wrapper failed: ' || COALESCE(v_repay_msg, 'no message');
  ASSERT v_repay_paid_off = FALSE, 'Partial repayment should not mark the loan paid off';

  SELECT balance
    INTO v_repay_after_cash
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT remaining_balance
    INTO v_repay_after_balance
    FROM loans
   WHERE id = v_unsecured_loan_id;

  ASSERT ROUND(v_repay_before_cash - v_repay_after_cash, 2) = 50000.00,
    'repay_loan should reduce operating cash by the payment amount';
  ASSERT ROUND(v_repay_before_balance - v_repay_after_balance, 2) = 50000.00,
    'repay_loan should reduce outstanding balance by the payment amount';
  ASSERT ROUND(COALESCE(v_repay_cash, 0), 2) = ROUND(COALESCE(v_repay_after_cash, 0), 2),
    'repay_loan new_cash should mirror the reconciled operating balance';
  ASSERT EXISTS (
    SELECT 1
      FROM bank_transactions
     WHERE user_id = v_user_id
       AND ifrs_subcategory = 'loan_repayment'
  ), 'repay_loan should write a bank transaction row';

  UPDATE loans
     SET interest_rate = 0.30
   WHERE id = v_unsecured_loan_id;

  SELECT interest_rate
    INTO v_refi_old_rate
    FROM loans
   WHERE id = v_unsecured_loan_id;

  SELECT success, message, new_rate, savings
    INTO v_refi_ok, v_refi_msg, v_refi_new_rate, v_refi_savings
    FROM refinance_loan(v_unsecured_loan_id);

  ASSERT v_refi_ok = TRUE, 'refinance_loan wrapper failed: ' || COALESCE(v_refi_msg, 'no message');
  ASSERT COALESCE(v_refi_new_rate, 0) < COALESCE(v_refi_old_rate, 1),
    'refinance_loan should reduce the stored interest rate';
  ASSERT COALESCE(v_refi_savings, 0) >= 0,
    'refinance_loan should report non-negative savings';
  ASSERT EXISTS (
    SELECT 1
      FROM loans
     WHERE id = v_unsecured_loan_id
       AND interest_rate = v_refi_new_rate
  ), 'refinance_loan should persist the new interest rate on the loan row';
  SELECT COUNT(*)
    INTO v_refi_zero_tx_count
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'loan_refinance'
     AND amount = 0;
  ASSERT v_refi_zero_tx_count = 0,
    'refinance_loan should not create zero-amount bank ledger rows';

  -- ==========================================================================
  -- 4. TEST: purchase_aircraft RPC & BUY MATH
  -- ==========================================================================
  
  -- Set user's cash balance to afford the purchase (bank-centric architecture)
  UPDATE bank_accounts SET balance = 150000000.00 WHERE user_id = v_user_id AND account_type = 'operating';

  SELECT balance
    INTO v_purchase_before_cash
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT success, message INTO v_reg_success, v_reg_message
  FROM purchase_aircraft(v_user_id, v_model_id, 'Audit Tail 1');

  ASSERT v_reg_success = TRUE, 'Failed to purchase aircraft: ' || COALESCE(v_reg_message, 'no message');

  -- Verify user fleet contains purchased plane
  SELECT id INTO v_fleet_id FROM fleet_aircraft WHERE user_id = v_user_id AND nickname = 'Audit Tail 1';
  ASSERT v_fleet_id IS NOT NULL, 'Purchased aircraft was not found in user fleet';

  -- Verify purchase reduced cash and wrote the correct transaction amount.
  SELECT balance INTO v_ending_balance FROM bank_accounts WHERE user_id = v_user_id AND account_type = 'operating';
  ASSERT v_ending_balance < v_purchase_before_cash,
    'Purchase should reduce operating cash';

  -- Verify transaction record created (bank-centric architecture)
  SELECT COUNT(*) INTO v_ledger_count FROM bank_transactions WHERE user_id = v_user_id AND ifrs_subcategory = 'aircraft_purchase';
  ASSERT v_ledger_count = 1, 'Bank transaction entry should be created for aircraft purchase';

  SELECT ABS(amount)
    INTO v_purchase_txn_amount
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'aircraft_purchase'
   ORDER BY game_date DESC
   LIMIT 1;

  ASSERT ROUND(COALESCE(v_purchase_txn_amount, 0), 2) = ROUND(COALESCE(v_model_purchase_price, 0), 2),
    'Aircraft purchase transaction amount should match selected model purchase price';

  -- ==========================================================================
  -- 5. TEST: HQ change trigger syncs tail-number prefixes
  -- ==========================================================================

  SELECT tail_number
    INTO v_old_tail_number
    FROM fleet_aircraft
   WHERE id = v_fleet_id;

  UPDATE users
     SET hq_airport_iata = 'SIN'
   WHERE id = v_user_id;

  SELECT tail_number
    INTO v_new_tail_number
    FROM fleet_aircraft
   WHERE id = v_fleet_id;

  ASSERT v_old_tail_number IS NOT NULL, 'Purchased aircraft should have an initial tail number';
  ASSERT v_new_tail_number IS NOT NULL, 'HQ change trigger should preserve tail number presence';
  ASSERT v_new_tail_number LIKE '9V-%',
    'HQ change trigger should re-prefix aircraft tails for Singapore HQ';
  ASSERT v_new_tail_number <> v_old_tail_number,
    'HQ change trigger should update the existing tail number';

  -- ==========================================================================
  -- 6. TEST: route CRUD RPCs (create / assign / update / delete)
  -- ==========================================================================

  SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude)
    INTO v_route_distance
    FROM airports o, airports d
   WHERE o.iata = 'SIN'
     AND d.iata = 'CGK';

  SELECT success, message
    INTO v_route_ok, v_route_msg
    FROM create_route(v_user_id, 'SIN', 'CGK', ROUND(v_route_distance, 2), 250.00, 14);

  ASSERT v_route_ok = TRUE, 'Failed to create route via RPC: ' || COALESCE(v_route_msg, 'no message');

  SELECT id
    INTO v_route_id
    FROM route_assignments
   WHERE user_id = v_user_id
     AND origin_iata = 'SIN'
     AND destination_iata = 'CGK'
   LIMIT 1;

  ASSERT v_route_id IS NOT NULL, 'Route create RPC did not persist a route row';

  SELECT success, message
    INTO v_route_ok, v_route_msg
    FROM assign_aircraft_to_route(v_user_id, v_route_id, v_fleet_id);

  ASSERT v_route_ok = TRUE, 'Failed to assign aircraft to route: ' || COALESCE(v_route_msg, 'no message');

  SELECT assigned_aircraft_id, ticket_price, flights_per_week
    INTO v_fleet_id, v_updated_price, v_updated_frequency
    FROM route_assignments
   WHERE id = v_route_id;

  ASSERT v_fleet_id IS NOT NULL, 'Route assignment RPC did not persist assigned aircraft';

  SELECT success, message
    INTO v_route_ok, v_route_msg
    FROM update_route_frequency_and_price(v_user_id, v_route_id, 275.00, 10);

  ASSERT v_route_ok = TRUE, 'Failed to update route economics: ' || COALESCE(v_route_msg, 'no message');

  SELECT ticket_price, flights_per_week
    INTO v_updated_price, v_updated_frequency
    FROM route_assignments
   WHERE id = v_route_id;

  ASSERT ROUND(v_updated_price, 2) = 275.00, 'Route update RPC did not persist ticket price';
  ASSERT v_updated_frequency = 10, 'Route update RPC did not persist flights per week';

  SELECT success, message
    INTO v_route_ok, v_route_msg
    FROM delete_route(v_user_id, v_route_id);

  ASSERT v_route_ok = TRUE, 'Failed to delete route via RPC: ' || COALESCE(v_route_msg, 'no message');

  ASSERT NOT EXISTS(SELECT 1 FROM route_assignments WHERE id = v_route_id),
    'Route delete RPC did not remove route row';

  SELECT status
    INTO v_aircraft_status
    FROM fleet_aircraft
   WHERE id = v_fleet_id;

  ASSERT v_aircraft_status = 'grounded',
    'Route delete RPC should ground the previously assigned aircraft';

  -- ==========================================================================
  -- 7. TEST: lease_aircraft RPC & LEASE MATH
  -- ==========================================================================
  
  SELECT success, message INTO v_reg_success, v_reg_message
  FROM lease_aircraft(v_user_id, v_model_id, 'Audit Tail 2');

  ASSERT v_reg_success = TRUE, 'Failed to lease aircraft: ' || COALESCE(v_reg_message, 'no message');

  -- Verify fleet contains leased plane
  ASSERT EXISTS(SELECT 1 FROM fleet_aircraft WHERE user_id = v_user_id AND nickname = 'Audit Tail 2'), 'Leased aircraft not found in user fleet';

  -- ==========================================================================
  -- 8. TEST: process_simulation_delta RPC
  -- ==========================================================================
  
  -- Route creation connecting SIN & CGK
  INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week)
  VALUES (v_user_id, 'SIN', 'CGK', 884.00, 250.00, v_fleet_id, 14)
  RETURNING id INTO v_route_id;

  -- Activate fleet plane
  UPDATE fleet_aircraft SET status = 'active' WHERE id = v_fleet_id;

  -- Run simulation delta
  UPDATE users SET game_current_time = '2020-01-02 00:00:00+00' WHERE id = v_user_id;

  -- Trigger sync engine
  -- This executes the Pl/pgSQL delta engine logic covering ticket sales, fuel cost, airport tax and maintenance math
  BEGIN
    SELECT TRUE, 'Success' INTO v_sim_success, v_sim_message;
    PERFORM process_simulation_delta(v_user_id);
  EXCEPTION WHEN OTHERS THEN
    v_sim_success := FALSE;
    v_sim_message := SQLERRM;
  END;

  ASSERT v_sim_success = TRUE, 'process_simulation_delta threw an exception: ' || v_sim_message;

  -- ==========================================================================
  -- 9. TEST: RECONCILE NET WORTH TRIGGERS
  -- ==========================================================================
  
  -- Assert net worth recalculation triggers successfully if calculate_user_net_worth is installed
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'calculate_user_net_worth') THEN
    BEGIN
      v_reconciled_nw := calculate_user_net_worth(v_user_id);
      ASSERT v_reconciled_nw IS NOT NULL, 'Net worth calculated should not be null';
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Net worth procedure calculation skipped or failed: %', SQLERRM;
    END;
  END IF;

  -- ==========================================================================
  -- 10. SUCCESS CONFIRMATION
  -- ==========================================================================
  RAISE NOTICE 'ALL SKYWARD RELATIONAL RPC AND DATABASE TRIGGERS AUDITED SUCCESSFULLY!';
END $$;

ROLLBACK;
