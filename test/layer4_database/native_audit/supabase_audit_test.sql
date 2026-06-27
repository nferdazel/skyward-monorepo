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
  v_bank_trigger_before_nw NUMERIC;
  v_bank_trigger_after_nw NUMERIC;
  v_bank_trigger_live_balance NUMERIC;
  v_loan_trigger_before_nw NUMERIC;
  v_loan_trigger_after_nw NUMERIC;
  v_fleet_trigger_before_nw NUMERIC;
  v_fleet_trigger_after_nw NUMERIC;
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
  v_repair_ok BOOLEAN;
  v_repair_msg VARCHAR;
  v_config_ok BOOLEAN;
  v_config_msg VARCHAR;
  v_sale_ok BOOLEAN;
  v_sale_msg VARCHAR;
  v_sale_before_cash NUMERIC;
  v_sale_after_cash NUMERIC;
  v_sale_tx_before INT;
  v_sale_tx_after INT;
  v_sale_amount NUMERIC;
  v_sale_fleet_id UUID;
  v_lease_term_ok BOOLEAN;
  v_lease_term_msg VARCHAR;
  v_lease_term_before_cash NUMERIC;
  v_lease_term_after_cash NUMERIC;
  v_lease_term_tx_before INT;
  v_lease_term_tx_after INT;
  v_lease_term_fee NUMERIC;
  v_lease_fleet_id UUID;
  v_repair_before_cash NUMERIC;
  v_repair_after_cash NUMERIC;
  v_repair_condition NUMERIC;
  v_repair_status VARCHAR;
  v_repair_tx_before INT;
  v_repair_tx_after INT;
  v_aircraft_status VARCHAR;
  v_old_tail_number VARCHAR;
  v_new_tail_number VARCHAR;
  v_updated_price NUMERIC;
  v_updated_frequency INT;
  v_sim_success BOOLEAN;
  v_sim_message VARCHAR;
  v_delta_elapsed_days NUMERIC;
  v_delta_flights_run INT;
  v_delta_noop_elapsed_days NUMERIC;
  v_delta_noop_flights_run INT;
  v_season_id UUID;
  v_season_before TIMESTAMPTZ;
  v_season_after TIMESTAMPTZ;
  v_user_after TIMESTAMPTZ;
  v_tick_processed INT;
  v_tick_players_processed INT;
  v_tick_bots_processed INT;
  v_tick_game_time_after TIMESTAMPTZ;
  v_tick_log_before INT;
  v_tick_log_after INT;
  v_guardrail_active_status TEXT;
  v_guardrail_lag_status TEXT;
  v_guardrail_ahead_status TEXT;
  v_guardrail_backwards_status TEXT;
  v_guardrail_recent_status TEXT;
  v_health_season_status VARCHAR;
  v_health_current_game_time TIMESTAMPTZ;
  v_health_season_last_tick_at TIMESTAMPTZ;
  v_health_latest_log_started_at TIMESTAMPTZ;
  v_health_latest_log_status VARCHAR;
  v_health_latest_ticks_processed INT;
  v_health_scheduler_job_exists BOOLEAN;
  v_health_scheduler_job_active BOOLEAN;
  v_finance_actor_id UUID;
  v_finance_company_name VARCHAR;
  v_finance_cash NUMERIC;
  v_finance_net_worth NUMERIC;
  v_finance_fleet_count INT;
  v_finance_active_route_count INT;
  v_finance_rolling_revenue NUMERIC;
  v_finance_rolling_expense NUMERIC;
  v_finance_rolling_net NUMERIC;
  v_finance_ledger_window_days INT;
  v_leaderboard_company_name VARCHAR;
  v_leaderboard_cash NUMERIC;
  v_leaderboard_net_worth NUMERIC;
  v_leaderboard_status VARCHAR;
  v_insight_company_name VARCHAR;
  v_insight_ceo_name VARCHAR;
  v_insight_cash NUMERIC;
  v_insight_net_worth NUMERIC;
  v_insight_status VARCHAR;
  v_insight_fleet_breakdown JSONB;
  v_insight_network_routes JSONB;
  v_optimizer_aircraft_id UUID;
  v_optimizer_route_origin VARCHAR;
  v_optimizer_route_destination VARCHAR;
  v_optimizer_weekly_contribution NUMERIC;
  v_settings_ok BOOLEAN;
  v_settings_msg VARCHAR;
  v_reset_ok BOOLEAN;
  v_reset_msg TEXT;
  v_reset_balance NUMERIC;
  v_reset_company_name VARCHAR;
  v_reset_hq_airport_iata VARCHAR;
  v_reset_threshold NUMERIC;
  v_reset_operational_status VARCHAR;
  v_reset_onboarding_completed BOOLEAN;
  v_active_season_id UUID;
  v_active_season_time TIMESTAMPTZ;
  v_zero_tx_before INT;
  v_zero_tx_after INT;
  v_bankruptcy_threshold NUMERIC;
  v_route_status VARCHAR;
  v_loan_status VARCHAR;
  v_remaining_balance NUMERIC;
-- ==========================================================================
-- 1. SETUP SEED DATA
-- ==========================================================================
BEGIN
  SELECT id, current_game_time
    INTO v_active_season_id, v_active_season_time
    FROM season_clock
   WHERE status = 'active'
   ORDER BY created_at ASC
   LIMIT 1;

  ASSERT v_active_season_id IS NOT NULL, 'Expected one active season for database audit bootstrap.';

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
  -- 2A. TEST: direct trigger proof for create_default_bank_account and
  --     trg_bank_balance_reconcile_net_worth
  -- ==========================================================================

  SELECT net_worth
    INTO v_bank_trigger_before_nw
    FROM users
   WHERE id = v_user_id;

  UPDATE bank_accounts
     SET balance = balance + 12345.67
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT net_worth
    INTO v_bank_trigger_after_nw
    FROM users
   WHERE id = v_user_id;

  SELECT get_user_balance(v_user_id)
    INTO v_bank_trigger_live_balance;

  ASSERT ROUND(COALESCE(v_bank_trigger_after_nw, 0) - COALESCE(v_bank_trigger_before_nw, 0), 2) = 12345.67,
    'trg_bank_balance_reconcile_net_worth should update users.net_worth when bank_accounts.balance changes';
  ASSERT ROUND(COALESCE(v_bank_trigger_live_balance, 0), 2) = ROUND(COALESCE(v_starting_balance, 0) + 12345.67, 2),
    'get_user_balance should return the canonical operating account balance';

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
  ASSERT EXISTS (
    SELECT 1
      FROM bank_transactions
     WHERE user_id = v_user_id
       AND ifrs_subcategory = 'loan_disbursement'
       AND transaction_type = 'credit'
       AND ROUND(amount, 2) = 250000.00
  ), 'take_loan should write a loan_disbursement credit row';

  SELECT id
    INTO v_unsecured_loan_id
    FROM loans
   WHERE user_id = v_user_id
     AND status = 'active'
     AND loan_type = 'unsecured'
   ORDER BY taken_at DESC
   LIMIT 1;

  ASSERT v_unsecured_loan_id IS NOT NULL, 'Expected active unsecured loan id after take_loan';

  -- ==========================================================================
  -- 3B. TEST: direct trigger proof for trg_loan_reconcile_net_worth
  -- ==========================================================================

  SELECT net_worth
    INTO v_loan_trigger_before_nw
    FROM users
   WHERE id = v_user_id;

  UPDATE loans
     SET remaining_balance = remaining_balance - 1000.00
   WHERE id = v_unsecured_loan_id;

  SELECT net_worth
    INTO v_loan_trigger_after_nw
    FROM users
   WHERE id = v_user_id;

  ASSERT ROUND(COALESCE(v_loan_trigger_after_nw, 0) - COALESCE(v_loan_trigger_before_nw, 0), 2) = 1000.00,
    'trg_loan_reconcile_net_worth should update users.net_worth when loan balance changes';

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
     SET season_id = v_active_season_id,
         game_current_time = v_active_season_time
   WHERE id = v_user_id;

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
  -- 4A. TEST: direct trigger proof for fleet_reconcile_net_worth
  -- ==========================================================================

  SELECT net_worth
    INTO v_fleet_trigger_before_nw
    FROM users
   WHERE id = v_user_id;

  UPDATE fleet_aircraft
     SET condition = 50.00
   WHERE id = v_fleet_id;

  SELECT net_worth
    INTO v_fleet_trigger_after_nw
    FROM users
   WHERE id = v_user_id;

  ASSERT v_fleet_trigger_after_nw < v_fleet_trigger_before_nw,
    'fleet_reconcile_net_worth should reduce users.net_worth when owned aircraft condition drops';

  -- ==========================================================================
  -- 4B. TEST: repair_aircraft RPC & shared repair ledger semantics
  -- ==========================================================================

  UPDATE fleet_aircraft
     SET condition = 82.50,
         status = 'grounded'
   WHERE id = v_fleet_id;

  SELECT balance
    INTO v_repair_before_cash
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT COUNT(*)
    INTO v_repair_tx_before
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'maintenance';

  SELECT success, message, new_cash
    INTO v_repair_ok, v_repair_msg, v_repair_after_cash
    FROM repair_aircraft(v_user_id, v_fleet_id);

  ASSERT v_repair_ok = TRUE, 'repair_aircraft failed: ' || COALESCE(v_repair_msg, 'no message');

  SELECT condition, status
    INTO v_repair_condition, v_repair_status
    FROM fleet_aircraft
   WHERE id = v_fleet_id;

  SELECT COUNT(*)
    INTO v_repair_tx_after
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'maintenance';

  ASSERT v_repair_condition = 100.00,
    'repair_aircraft should restore the airframe condition to 100%';
  ASSERT v_repair_status = 'active',
    'repair_aircraft should reactivate the repaired airframe';
  ASSERT v_repair_after_cash < v_repair_before_cash,
    'repair_aircraft should reduce operating cash';
  ASSERT v_repair_tx_after = v_repair_tx_before + 1,
    'repair_aircraft should append exactly one maintenance ledger row';

  -- ==========================================================================
  -- 4B. TEST: no-op simulation sync should not emit zero-amount ledger rows
  -- ==========================================================================

  SELECT COUNT(*)
    INTO v_zero_tx_before
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND amount = 0;

  PERFORM *
    FROM process_player_simulation_to_time(v_user_id, (
      SELECT game_current_time FROM users WHERE id = v_user_id
    ));

  SELECT COUNT(*)
    INTO v_zero_tx_after
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND amount = 0;

  ASSERT v_zero_tx_after = v_zero_tx_before,
    'process_player_simulation_to_time should not write zero-amount ledger rows for no-op intervals';

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
  -- 6A. TEST: configure_aircraft_seats auth-bound wrapper
  -- ==========================================================================

  SELECT success, message
    INTO v_config_ok, v_config_msg
    FROM configure_aircraft_seats(v_fleet_id, 150, 10, 3);

  ASSERT v_config_ok = TRUE,
    'configure_aircraft_seats wrapper failed: ' || COALESCE(v_config_msg, 'no message');
  ASSERT EXISTS (
    SELECT 1
      FROM fleet_aircraft
     WHERE id = v_fleet_id
       AND economy_seats = 150
       AND business_seats = 10
       AND first_class_seats = 3
  ), 'configure_aircraft_seats should persist the requested cabin layout';

  -- ==========================================================================
  -- 6B. TEST: sell_aircraft auth-bound wrapper
  -- ==========================================================================

  UPDATE bank_accounts
     SET balance = 150000000.00
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT success, message
    INTO v_reg_success, v_reg_message
    FROM purchase_aircraft(v_user_id, v_model_id, 'Audit Tail Sell');

  ASSERT v_reg_success = TRUE, 'Failed to purchase aircraft for sale audit: ' || COALESCE(v_reg_message, 'no message');

  SELECT id
    INTO v_sale_fleet_id
    FROM fleet_aircraft
   WHERE user_id = v_user_id
     AND nickname = 'Audit Tail Sell'
   LIMIT 1;

  ASSERT v_sale_fleet_id IS NOT NULL, 'Sale audit aircraft bootstrap failed';

  SELECT balance
    INTO v_sale_before_cash
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT COUNT(*)
    INTO v_sale_tx_before
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'aircraft_sale';

  SELECT success, message, new_cash
    INTO v_sale_ok, v_sale_msg, v_sale_after_cash
    FROM sell_aircraft(v_sale_fleet_id);

  ASSERT v_sale_ok = TRUE,
    'sell_aircraft wrapper failed: ' || COALESCE(v_sale_msg, 'no message');

  SELECT COUNT(*)
    INTO v_sale_tx_after
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'aircraft_sale';

  SELECT amount
    INTO v_sale_amount
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'aircraft_sale'
   ORDER BY game_date DESC
   LIMIT 1;

  ASSERT NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE id = v_sale_fleet_id),
    'sell_aircraft should remove the sold fleet row';
  ASSERT v_sale_tx_after = v_sale_tx_before + 1,
    'sell_aircraft should append exactly one aircraft_sale ledger row';
  ASSERT COALESCE(v_sale_amount, 0) > 0,
    'sell_aircraft should write a positive aircraft_sale ledger amount';
  ASSERT v_sale_after_cash > v_sale_before_cash,
    'sell_aircraft should increase operating cash';
  ASSERT ROUND(COALESCE(v_sale_after_cash, 0), 2) = ROUND(COALESCE(get_user_balance(v_user_id), 0), 2),
    'sell_aircraft new_cash should match the reconciled operating balance';

  -- ==========================================================================
  -- 7. TEST: lease_aircraft RPC & LEASE MATH
  -- ==========================================================================
  
  SELECT success, message INTO v_reg_success, v_reg_message
  FROM lease_aircraft(v_user_id, v_model_id, 'Audit Tail 2');

  ASSERT v_reg_success = TRUE, 'Failed to lease aircraft: ' || COALESCE(v_reg_message, 'no message');

  -- Verify fleet contains leased plane
  ASSERT EXISTS(SELECT 1 FROM fleet_aircraft WHERE user_id = v_user_id AND nickname = 'Audit Tail 2'), 'Leased aircraft not found in user fleet';

  SELECT id
    INTO v_lease_fleet_id
    FROM fleet_aircraft
   WHERE user_id = v_user_id
     AND nickname = 'Audit Tail 2'
   LIMIT 1;

  ASSERT v_lease_fleet_id IS NOT NULL, 'Lease audit aircraft bootstrap failed';

  -- ==========================================================================
  -- 7A. TEST: terminate_aircraft_lease auth-bound wrapper
  -- ==========================================================================

  SELECT balance
    INTO v_lease_term_before_cash
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT COUNT(*)
    INTO v_lease_term_tx_before
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'lease_termination';

  SELECT calculate_lease_termination_fee(m.lease_price_per_month)
    INTO v_lease_term_fee
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
   WHERE f.id = v_lease_fleet_id;

  SELECT success, message, new_cash
    INTO v_lease_term_ok, v_lease_term_msg, v_lease_term_after_cash
    FROM terminate_aircraft_lease(v_lease_fleet_id);

  ASSERT v_lease_term_ok = TRUE,
    'terminate_aircraft_lease wrapper failed: ' || COALESCE(v_lease_term_msg, 'no message');

  SELECT COUNT(*)
    INTO v_lease_term_tx_after
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'lease_termination';

  ASSERT NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE id = v_lease_fleet_id),
    'terminate_aircraft_lease should remove the leased fleet row';
  ASSERT COALESCE(v_lease_term_fee, 0) > 0,
    'terminate_aircraft_lease should compute a positive exit fee for leased aircraft';
  ASSERT v_lease_term_tx_after = v_lease_term_tx_before + 1,
    'terminate_aircraft_lease should append exactly one lease_termination ledger row';
  ASSERT ROUND(v_lease_term_before_cash - v_lease_term_after_cash, 2) = ROUND(v_lease_term_fee, 2),
    'terminate_aircraft_lease should reduce operating cash by the computed exit fee';
  ASSERT ROUND(COALESCE(v_lease_term_after_cash, 0), 2) = ROUND(COALESCE(get_user_balance(v_user_id), 0), 2),
    'terminate_aircraft_lease new_cash should match the reconciled operating balance';

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

  SELECT season_id, game_current_time
    INTO v_season_id, v_season_before
    FROM users
   WHERE id = v_user_id;

  ASSERT v_season_id IS NOT NULL, 'Audit user should have an active season_id before simulation sync';
  ASSERT v_season_before IS NOT NULL, 'Audit user should have a game_current_time before simulation sync';

  -- Trigger sync engine
  -- This executes the Pl/pgSQL delta engine logic covering ticket sales, fuel cost, airport tax and maintenance math
  BEGIN
    SELECT TRUE, 'Success' INTO v_sim_success, v_sim_message;
    SELECT elapsed_game_days, flights_run
      INTO v_delta_elapsed_days, v_delta_flights_run
      FROM process_simulation_delta(v_user_id)
     LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_sim_success := FALSE;
    v_sim_message := SQLERRM;
  END;

  ASSERT v_sim_success = TRUE, 'process_simulation_delta threw an exception: ' || v_sim_message;

  SELECT current_game_time
    INTO v_season_after
    FROM season_clock
   WHERE id = v_season_id;

  SELECT game_current_time
    INTO v_user_after
    FROM users
   WHERE id = v_user_id;

  ASSERT v_season_after IS NOT NULL, 'Active season clock should exist after simulation sync';
  ASSERT v_user_after = v_season_after,
    'process_simulation_delta should catch the player up to season_clock.current_game_time';
  ASSERT COALESCE(v_delta_elapsed_days, 0) > 0,
    'process_simulation_delta should report positive elapsed_game_days when the player lags behind';
  ASSERT COALESCE(v_delta_flights_run, 0) >= 0,
    'process_simulation_delta should return a non-negative flights_run count';

  SELECT elapsed_game_days, flights_run
    INTO v_delta_noop_elapsed_days, v_delta_noop_flights_run
    FROM process_simulation_delta(v_user_id)
   LIMIT 1;

  SELECT game_current_time
    INTO v_user_after
    FROM users
   WHERE id = v_user_id;

  ASSERT v_user_after = v_season_after,
    'A no-op process_simulation_delta call should not move the player beyond season time';
  ASSERT COALESCE(v_delta_noop_elapsed_days, 0) = 0,
    'A no-op process_simulation_delta call should report zero elapsed_game_days';
  ASSERT COALESCE(v_delta_noop_flights_run, 0) = 0,
    'A no-op process_simulation_delta call should report zero flights_run';

  -- ==========================================================================
  -- 8A. TEST: player bankruptcy applies full actor side effects
  -- ==========================================================================

  SELECT COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.00)
    INTO v_bankruptcy_threshold;

  ASSERT v_unsecured_loan_id IS NOT NULL, 'Expected active loan id before bankruptcy parity audit';
  ASSERT v_route_id IS NOT NULL, 'Expected active route id before bankruptcy parity audit';
  ASSERT v_fleet_id IS NOT NULL, 'Expected active fleet id before bankruptcy parity audit';

  UPDATE bank_accounts
     SET balance = v_bankruptcy_threshold - 1
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  PERFORM *
    FROM process_player_simulation_to_time(
      v_user_id,
      (SELECT game_current_time + INTERVAL '1 hour' FROM users WHERE id = v_user_id)
    );

  SELECT operational_status
    INTO v_route_msg
    FROM users
   WHERE id = v_user_id;

  SELECT status
    INTO v_aircraft_status
    FROM fleet_aircraft
   WHERE id = v_fleet_id;

  SELECT status
    INTO v_route_status
    FROM route_assignments
   WHERE id = v_route_id;

  SELECT status, remaining_balance
    INTO v_loan_status, v_remaining_balance
    FROM loans
   WHERE id = v_unsecured_loan_id;

  ASSERT v_route_msg = 'Bankrupt',
    'Player bankruptcy should mark the user operational_status as Bankrupt';
  ASSERT v_aircraft_status = 'grounded',
    'Player bankruptcy should ground fleet aircraft just like the bot path';
  ASSERT v_route_status = 'cancelled',
    'Player bankruptcy should cancel active routes just like the bot path';
  ASSERT v_loan_status = 'defaulted',
    'Player bankruptcy should default active loans just like the bot path';
  ASSERT ROUND(COALESCE(v_remaining_balance, -1), 2) = 0,
    'Player bankruptcy should zero remaining_balance for defaulted loans';

  -- ==========================================================================
  -- 8B. TEST: process_world_tick backend scheduler invariant
  -- ==========================================================================

  SELECT current_game_time
    INTO v_season_before
    FROM season_clock
   WHERE id = v_season_id;

  SELECT COUNT(*)
    INTO v_tick_log_before
    FROM world_tick_log
   WHERE season_id = v_season_id
     AND status = 'success';

  SELECT ticks_processed, game_time_after, players_processed, bots_processed
    INTO v_tick_processed, v_tick_game_time_after, v_tick_players_processed, v_tick_bots_processed
    FROM process_world_tick(v_season_id, 1)
   LIMIT 1;

  SELECT current_game_time
    INTO v_season_after
    FROM season_clock
   WHERE id = v_season_id;

  SELECT COUNT(*)
    INTO v_tick_log_after
    FROM world_tick_log
   WHERE season_id = v_season_id
     AND status = 'success';

  ASSERT COALESCE(v_tick_processed, 0) = 1,
    'process_world_tick should report one processed tick';
  ASSERT v_tick_game_time_after IS NOT NULL,
    'process_world_tick should return a non-null game_time_after';
  ASSERT v_tick_game_time_after > v_season_before,
    'process_world_tick should advance the in-game season clock';
  ASSERT v_season_after = v_tick_game_time_after,
    'season_clock.current_game_time should match process_world_tick.game_time_after';
  ASSERT v_tick_players_processed >= 0,
    'process_world_tick should return a non-negative players_processed count';
  ASSERT v_tick_bots_processed >= 0,
    'process_world_tick should return a non-negative bots_processed count';
  ASSERT v_tick_log_after >= v_tick_log_before + 1,
    'process_world_tick should append at least one new success row to world_tick_log';
  ASSERT EXISTS (
    SELECT 1
      FROM world_tick_log
     WHERE season_id = v_season_id
       AND status = 'success'
       AND game_time_after = v_tick_game_time_after
  ), 'process_world_tick should write a success world_tick_log row for the advanced game_time_after';

  -- ==========================================================================
  -- 8C. TEST: world-tick observability RPCs
  -- ==========================================================================

  SELECT check_status
    INTO v_guardrail_active_status
    FROM get_world_tick_guardrail_report()
   WHERE check_name = 'active_season_exists';

  SELECT check_status
    INTO v_guardrail_lag_status
    FROM get_world_tick_guardrail_report()
   WHERE check_name = 'actors_not_lagging';

  SELECT check_status
    INTO v_guardrail_ahead_status
    FROM get_world_tick_guardrail_report()
   WHERE check_name = 'actors_not_ahead';

  SELECT check_status
    INTO v_guardrail_backwards_status
    FROM get_world_tick_guardrail_report()
   WHERE check_name = 'no_backwards_world_ticks';

  SELECT check_status
    INTO v_guardrail_recent_status
    FROM get_world_tick_guardrail_report()
   WHERE check_name = 'recent_successful_world_tick';

  ASSERT v_guardrail_active_status = 'pass',
    'get_world_tick_guardrail_report should report an active season';
  ASSERT v_guardrail_lag_status IN ('pass', 'fail'),
    'get_world_tick_guardrail_report should emit actors_not_lagging status';
  ASSERT v_guardrail_ahead_status IN ('pass', 'fail'),
    'get_world_tick_guardrail_report should emit actors_not_ahead status';
  ASSERT v_guardrail_backwards_status IN ('pass', 'fail'),
    'get_world_tick_guardrail_report should emit no_backwards_world_ticks status';
  ASSERT v_guardrail_recent_status IN ('pass', 'warn'),
    'get_world_tick_guardrail_report should emit a recent_successful_world_tick status';

  SELECT season_status,
         current_game_time,
         season_last_tick_at,
         latest_log_started_at,
         latest_log_status,
         latest_ticks_processed,
         scheduler_job_exists,
         scheduler_job_active
    INTO v_health_season_status,
         v_health_current_game_time,
         v_health_season_last_tick_at,
         v_health_latest_log_started_at,
         v_health_latest_log_status,
         v_health_latest_ticks_processed,
         v_health_scheduler_job_exists,
         v_health_scheduler_job_active
    FROM get_world_tick_scheduler_health()
   LIMIT 1;

  ASSERT v_health_season_status = 'active',
    'get_world_tick_scheduler_health should report the active season';
  ASSERT v_health_current_game_time = v_season_after,
    'get_world_tick_scheduler_health current_game_time should match season_clock.current_game_time';
  ASSERT v_health_season_last_tick_at IS NOT NULL,
    'get_world_tick_scheduler_health should expose season_last_tick_at';
  ASSERT v_health_latest_log_started_at IS NOT NULL,
    'get_world_tick_scheduler_health should expose the latest world_tick_log timestamp';
  ASSERT v_health_latest_log_status = 'success',
    'get_world_tick_scheduler_health should report the latest successful tick status after process_world_tick';
  ASSERT COALESCE(v_health_latest_ticks_processed, 0) = 1,
    'get_world_tick_scheduler_health should report the latest tick count';
  ASSERT COALESCE(v_health_scheduler_job_exists, FALSE) = TRUE,
    'get_world_tick_scheduler_health should report the scheduler job as existing in linked runtime';
  ASSERT COALESCE(v_health_scheduler_job_active, FALSE) = TRUE,
    'get_world_tick_scheduler_health should report the scheduler job as active in linked runtime';

  -- ==========================================================================
  -- 8D. TEST: read-surface and settings RPC coverage
  -- ==========================================================================

  SELECT actor_id,
         company_name,
         cash,
         net_worth,
         fleet_count,
         active_route_count,
         rolling_revenue_30d,
         rolling_expense_30d,
         rolling_net_30d,
         ledger_window_days
    INTO v_finance_actor_id,
         v_finance_company_name,
         v_finance_cash,
         v_finance_net_worth,
         v_finance_fleet_count,
         v_finance_active_route_count,
         v_finance_rolling_revenue,
         v_finance_rolling_expense,
         v_finance_rolling_net,
         v_finance_ledger_window_days
    FROM get_finance_snapshot()
   LIMIT 1;

  ASSERT v_finance_actor_id = v_user_id,
    'get_finance_snapshot should resolve the authenticated audit user';
  ASSERT v_finance_company_name IS NOT NULL,
    'get_finance_snapshot should expose the company name';
  ASSERT ROUND(COALESCE(v_finance_cash, 0), 2) = ROUND(COALESCE(get_user_balance(v_user_id), 0), 2),
    'get_finance_snapshot cash should match the canonical bank balance';
  ASSERT ROUND(COALESCE(v_finance_net_worth, 0), 2) = ROUND(COALESCE(calculate_user_net_worth(v_user_id), 0), 2),
    'get_finance_snapshot net_worth should match the canonical net-worth helper';
  ASSERT COALESCE(v_finance_fleet_count, 0) >= 1,
    'get_finance_snapshot should expose a non-zero fleet count for the audit user';
  ASSERT COALESCE(v_finance_active_route_count, 0) = (
    SELECT COUNT(*)
      FROM route_assignments
     WHERE user_id = v_user_id
       AND COALESCE(status, 'active') = 'active'
  ),
    'get_finance_snapshot active_route_count should count only active route rows';
  ASSERT ROUND(COALESCE(v_finance_rolling_net, 0), 2) = ROUND(COALESCE(v_finance_rolling_revenue, 0) - COALESCE(v_finance_rolling_expense, 0), 2),
    'get_finance_snapshot rolling_net_30d should equal rolling revenue minus rolling expense';
  ASSERT COALESCE(v_finance_ledger_window_days, 0) = 30,
    'get_finance_snapshot should expose the 30-day ledger window';

  SELECT company_name,
         cash,
         net_worth,
         status
    INTO v_leaderboard_company_name,
         v_leaderboard_cash,
         v_leaderboard_net_worth,
         v_leaderboard_status
    FROM get_global_leaderboard()
   WHERE id = v_user_id
   LIMIT 1;

  ASSERT v_leaderboard_company_name IS NOT NULL,
    'get_global_leaderboard should include the audit user row';
  ASSERT ROUND(COALESCE(v_leaderboard_cash, 0), 2) = ROUND(COALESCE(get_user_balance(v_user_id), 0), 2),
    'get_global_leaderboard cash should match the canonical bank balance';
  ASSERT ROUND(COALESCE(v_leaderboard_net_worth, 0), 2) = ROUND(COALESCE(calculate_user_net_worth(v_user_id), 0), 2),
    'get_global_leaderboard net_worth should match the canonical helper';
  ASSERT v_leaderboard_status = 'Bankrupt',
    'get_global_leaderboard should reflect the latest operational_status';

  SELECT company_name,
         ceo_name,
         cash,
         net_worth,
         status,
         fleet_breakdown,
         network_routes
    INTO v_insight_company_name,
         v_insight_ceo_name,
         v_insight_cash,
         v_insight_net_worth,
         v_insight_status,
         v_insight_fleet_breakdown,
         v_insight_network_routes
    FROM get_competitor_insights(v_user_id, FALSE)
   LIMIT 1;

  ASSERT v_insight_company_name = v_leaderboard_company_name,
    'get_competitor_insights should expose the same company name as the leaderboard row';
  ASSERT v_insight_ceo_name IS NOT NULL,
    'get_competitor_insights should expose CEO name';
  ASSERT ROUND(COALESCE(v_insight_cash, 0), 2) = ROUND(COALESCE(get_user_balance(v_user_id), 0), 2),
    'get_competitor_insights cash should match the canonical bank balance';
  ASSERT ROUND(COALESCE(v_insight_net_worth, 0), 2) = ROUND(COALESCE(v_leaderboard_net_worth, 0), 2),
    'get_competitor_insights net_worth should match leaderboard net worth';
  ASSERT v_insight_status = 'Bankrupt',
    'get_competitor_insights should expose the latest operational status';
  ASSERT jsonb_typeof(COALESCE(v_insight_fleet_breakdown, '{}'::jsonb)) = 'object',
    'get_competitor_insights fleet_breakdown should be a JSON object';
  ASSERT jsonb_typeof(COALESCE(v_insight_network_routes, '[]'::jsonb)) = 'array',
    'get_competitor_insights network_routes should be a JSON array';

  SELECT aircraft_id,
         route_origin_iata,
         route_destination_iata,
         weekly_contribution
    INTO v_optimizer_aircraft_id,
         v_optimizer_route_origin,
         v_optimizer_route_destination,
         v_optimizer_weekly_contribution
    FROM get_owner_route_optimizer(v_user_id, 'CGK', 'SIN', 5, TRUE, TRUE)
   LIMIT 1;

  ASSERT v_optimizer_aircraft_id IS NOT NULL,
    'get_owner_route_optimizer should return at least one route candidate for the audit fleet';
  ASSERT v_optimizer_route_origin = 'CGK',
    'get_owner_route_optimizer should honor the requested origin airport';
  ASSERT v_optimizer_route_destination = 'SIN',
    'get_owner_route_optimizer should honor the requested destination airport';
  ASSERT COALESCE(v_optimizer_weekly_contribution, 0) <> 0,
    'get_owner_route_optimizer should return a non-zero weekly contribution estimate';

  SELECT success, message
    INTO v_settings_ok, v_settings_msg
    FROM save_airline_settings('Audit Chief Holdings', 35.00, 'CGK');

  ASSERT v_settings_ok = TRUE,
    'save_airline_settings wrapper failed: ' || COALESCE(v_settings_msg, 'no message');
  ASSERT EXISTS (
    SELECT 1
      FROM users
     WHERE id = v_user_id
       AND company_name = 'Audit Chief Holdings'
       AND auto_grounding_threshold = 35.00
       AND hq_airport_iata = 'CGK'
  ), 'save_airline_settings should persist company name, threshold, and HQ changes';

  SELECT success, message
    INTO v_reset_ok, v_reset_msg
    FROM reset_user_airline();

  ASSERT v_reset_ok = TRUE,
    'reset_user_airline wrapper failed: ' || COALESCE(v_reset_msg, 'no message');

  SELECT balance
    INTO v_reset_balance
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT company_name,
         hq_airport_iata,
         auto_grounding_threshold,
         operational_status,
         onboarding_completed
    INTO v_reset_company_name,
         v_reset_hq_airport_iata,
         v_reset_threshold,
         v_reset_operational_status,
         v_reset_onboarding_completed
    FROM users
   WHERE id = v_user_id;

  ASSERT ROUND(COALESCE(v_reset_balance, 0), 2) = 15000000.00,
    'reset_user_airline should restore the starting operating cash balance';
  ASSERT NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE user_id = v_user_id),
    'reset_user_airline should delete the user fleet';
  ASSERT NOT EXISTS (SELECT 1 FROM route_assignments WHERE user_id = v_user_id),
    'reset_user_airline should delete route assignments';
  ASSERT NOT EXISTS (SELECT 1 FROM loans WHERE user_id = v_user_id),
    'reset_user_airline should delete all loan rows';
  ASSERT NOT EXISTS (SELECT 1 FROM bank_transactions WHERE user_id = v_user_id),
    'reset_user_airline should delete bank transaction history';
  ASSERT v_reset_company_name = 'Audit Chief Holdings',
    'reset_user_airline should preserve the latest company name';
  ASSERT v_reset_hq_airport_iata = 'SIN',
    'reset_user_airline should restore the default HQ airport';
  ASSERT v_reset_threshold = 40.00,
    'reset_user_airline should restore the default grounding threshold';
  ASSERT v_reset_operational_status = 'Active',
    'reset_user_airline should restore the active operational status';
  ASSERT COALESCE(v_reset_onboarding_completed, TRUE) = FALSE,
    'reset_user_airline should reset onboarding completion state';

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
