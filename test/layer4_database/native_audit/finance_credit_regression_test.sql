-- ============================================================================
-- SKYWARD FINANCE / CREDIT REGRESSION AUDIT
-- ============================================================================
-- Focus:
--   1. net worth = cash + owned assets - open debt
--   2. aircraft financing stores a real weekly servicing amount
--   3. idle leased aircraft incur recurring carrying cost
--
-- Safe to run manually inside a rollback transaction.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  v_user_id UUID;
  v_finance_model_id UUID;
  v_lease_model_id UUID;
  v_finance_ok BOOLEAN;
  v_finance_msg TEXT;
  v_finance_cash NUMERIC;
  v_finance_loan_id UUID;
  v_finance_weekly NUMERIC;
  v_finance_monthly NUMERIC;
  v_finance_deposit_game_date TIMESTAMPTZ;
  v_finance_user_game_time TIMESTAMPTZ;
  v_finance_originated_game_date TIMESTAMPTZ;
  v_finance_balance_before NUMERIC;
  v_finance_balance_after NUMERIC;
  v_finance_deposit_rows INT;
  v_finance_deposit_amount NUMERIC;
  v_financing_payment_rows INT;
  v_financing_payment_amount NUMERIC;
  v_financing_late_fee_rows INT;
  v_owned_assets NUMERIC;
  v_open_debt NUMERIC;
  v_cash NUMERIC;
  v_expected_net_worth NUMERIC;
  v_actual_net_worth NUMERIC;
  v_lease_ok BOOLEAN;
  v_lease_msg TEXT;
  v_lease_cash_before NUMERIC;
  v_lease_cash_after NUMERIC;
  v_idle_lease_rows INT;
  v_idle_lease_amount NUMERIC;
  v_idle_lease_rows_before_noop INT;
  v_idle_lease_rows_after_noop INT;
BEGIN
  -- Clean residual audit user if any.
  DELETE FROM users WHERE username = 'finance_regression';

  INSERT INTO users (
    username,
    company_name,
    ceo_name,
    last_active_at
  )
  VALUES (
    'finance_regression',
    'Finance Regression Airways',
    'Regression CFO',
    NOW()
  )
  RETURNING id INTO v_user_id;

  ASSERT v_user_id IS NOT NULL, 'Failed to create finance regression user.';

  UPDATE bank_accounts
     SET balance = 300000000.00
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  UPDATE users
     SET game_current_time = '2020-01-01 00:00:00+00'
   WHERE id = v_user_id;

  SELECT id
    INTO v_finance_model_id
    FROM aircraft_models
   WHERE purchase_price <= 25000000
   ORDER BY purchase_price DESC
   LIMIT 1;

  SELECT id
    INTO v_lease_model_id
    FROM aircraft_models
   WHERE lease_price_per_month <= 250000
   ORDER BY lease_price_per_month DESC
   LIMIT 1;

  ASSERT v_finance_model_id IS NOT NULL, 'No finance audit aircraft model found.';
  ASSERT v_lease_model_id IS NOT NULL, 'No lease audit aircraft model found.';

  -- ------------------------------------------------------------------------
  -- 1. Aircraft financing should produce a weekly servicing amount.
  -- ------------------------------------------------------------------------
  SELECT success, message, new_cash
    INTO v_finance_ok, v_finance_msg, v_finance_cash
    FROM finance_aircraft(v_user_id, v_finance_model_id, 0.20, 36);

  ASSERT v_finance_ok = TRUE, 'finance_aircraft failed: ' || COALESCE(v_finance_msg, 'no message');

  SELECT id, weekly_payment, monthly_payment, originated_game_date
    INTO v_finance_loan_id, v_finance_weekly, v_finance_monthly, v_finance_originated_game_date
    FROM loans
   WHERE user_id = v_user_id
     AND loan_type = 'aircraft_financing'
   ORDER BY taken_at DESC
   LIMIT 1;

  ASSERT v_finance_loan_id IS NOT NULL, 'Aircraft financing loan was not created.';
  ASSERT COALESCE(v_finance_weekly, 0) > 0, 'Aircraft financing weekly_payment must be > 0.';
  ASSERT COALESCE(v_finance_monthly, 0) > COALESCE(v_finance_weekly, 0), 'monthly_payment should remain larger than weekly_payment.';
  ASSERT v_finance_originated_game_date IS NOT NULL,
    'finance_aircraft should stamp loans.originated_game_date';

  SELECT COUNT(*), COALESCE(SUM(ABS(amount)), 0)
    INTO v_finance_deposit_rows, v_finance_deposit_amount
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'aircraft_purchase_deposit';

  ASSERT v_finance_deposit_rows = 1,
    'finance_aircraft should write exactly one aircraft_purchase_deposit ledger row';
  ASSERT v_finance_deposit_amount > 0,
    'finance_aircraft down-payment ledger amount must be positive';
  ASSERT NOT EXISTS (
    SELECT 1
      FROM bank_transactions
     WHERE user_id = v_user_id
       AND ifrs_subcategory = 'aircraft_purchase_deposit'
       AND amount = 0
  ), 'finance_aircraft should not write zero-amount aircraft_purchase_deposit rows';

  SELECT MAX(game_date)
    INTO v_finance_deposit_game_date
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'aircraft_purchase_deposit';

  SELECT game_current_time
    INTO v_finance_user_game_time
    FROM users
   WHERE id = v_user_id;

  ASSERT v_finance_deposit_game_date > '2020-01-01 00:00:00+00'::timestamptz,
    'finance_aircraft should not stamp the down-payment ledger row with the stale bootstrap game time';
  ASSERT v_finance_user_game_time = v_finance_deposit_game_date,
    'finance_aircraft should catch the player up before writing the down-payment ledger row';
  ASSERT v_finance_originated_game_date = v_finance_deposit_game_date,
    'finance_aircraft loan origination game time should match the down-payment ledger row';

  SELECT remaining_balance
    INTO v_finance_balance_before
    FROM loans
   WHERE id = v_finance_loan_id;

  -- ------------------------------------------------------------------------
  -- 2. Net worth must equal cash + owned assets - open debt.
  -- ------------------------------------------------------------------------
  SELECT COALESCE(balance, 0)
    INTO v_cash
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating'
   LIMIT 1;

  SELECT COALESCE(SUM(
      CASE
        WHEN f.acquisition_type IN ('purchase', 'finance')
          THEN m.purchase_price * (f.condition / 100.00)
        ELSE 0
      END
    ), 0)
    INTO v_owned_assets
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
   WHERE f.user_id = v_user_id;

  SELECT COALESCE(SUM(remaining_balance), 0)
    INTO v_open_debt
    FROM loans
   WHERE user_id = v_user_id
     AND COALESCE(remaining_balance, 0) > 0
     AND COALESCE(status, 'active') <> 'paid_off';

  v_expected_net_worth := v_cash + v_owned_assets - v_open_debt;
  v_actual_net_worth := calculate_user_net_worth(v_user_id);

  ASSERT ROUND(v_actual_net_worth, 2) = ROUND(v_expected_net_worth, 2),
    'Net worth formula mismatch. expected=' || v_expected_net_worth::TEXT || ' actual=' || v_actual_net_worth::TEXT;

  -- ------------------------------------------------------------------------
  -- 3. Idle leased aircraft must incur carrying cost during simulation.
  -- ------------------------------------------------------------------------
  SELECT success, message, new_cash
    INTO v_lease_ok, v_lease_msg, v_finance_cash
    FROM lease_aircraft(v_user_id, v_lease_model_id, 'Regression Lease');

  ASSERT v_lease_ok = TRUE, 'lease_aircraft failed: ' || COALESCE(v_lease_msg, 'no message');

  SELECT balance
    INTO v_lease_cash_before
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  PERFORM process_player_simulation_to_time(
    v_user_id,
    (SELECT game_current_time + INTERVAL '7 days' FROM users WHERE id = v_user_id)
  );

  SELECT balance
    INTO v_lease_cash_after
    FROM bank_accounts
   WHERE user_id = v_user_id
     AND account_type = 'operating';

  SELECT remaining_balance
    INTO v_finance_balance_after
    FROM loans
   WHERE id = v_finance_loan_id;

  SELECT COUNT(*), COALESCE(SUM(ABS(amount)), 0)
    INTO v_idle_lease_rows, v_idle_lease_amount
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'aircraft_lease_idle';

  ASSERT v_idle_lease_rows > 0, 'Idle lease carrying cost row was not written.';
  ASSERT v_idle_lease_amount > 0, 'Idle lease carrying cost amount must be positive.';
  ASSERT v_lease_cash_after < v_lease_cash_before, 'Idle lease carrying cost should reduce cash.';
  ASSERT v_finance_balance_after < v_finance_balance_before,
    'Simulation should reduce aircraft financing remaining_balance when cash is sufficient.';

  SELECT COUNT(*), COALESCE(SUM(ABS(amount)), 0)
    INTO v_financing_payment_rows, v_financing_payment_amount
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'financing_payment';

  SELECT COUNT(*)
    INTO v_financing_late_fee_rows
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'financing_late_fee';

  ASSERT v_financing_payment_rows > 0,
    'Simulation should write at least one financing_payment ledger row.';
  ASSERT v_financing_payment_amount > 0,
    'financing_payment ledger amount must be positive.';
  ASSERT v_financing_late_fee_rows = 0,
    'Aircraft financing should not accrue late fees when the audit user has sufficient cash.';
  ASSERT NOT EXISTS (
    SELECT 1
      FROM bank_transactions
     WHERE user_id = v_user_id
       AND ifrs_subcategory = 'financing_payment'
       AND amount = 0
  ), 'Simulation should not write zero-amount financing_payment rows.';
  ASSERT NOT EXISTS (
    SELECT 1
      FROM bank_transactions
     WHERE user_id = v_user_id
       AND ifrs_subcategory = 'aircraft_lease_idle'
       AND amount = 0
  ), 'Idle lease carrying cost should not write zero-amount ledger rows.';

  SELECT COUNT(*)
    INTO v_idle_lease_rows_before_noop
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'aircraft_lease_idle';

  PERFORM process_player_simulation_to_time(
    v_user_id,
    (SELECT game_current_time FROM users WHERE id = v_user_id)
  );

  SELECT COUNT(*)
    INTO v_idle_lease_rows_after_noop
    FROM bank_transactions
   WHERE user_id = v_user_id
     AND ifrs_subcategory = 'aircraft_lease_idle';

  ASSERT v_idle_lease_rows_after_noop = v_idle_lease_rows_before_noop,
    'No-op player simulation should not append extra aircraft_lease_idle rows.';

  RAISE NOTICE 'FINANCE / CREDIT REGRESSION AUDIT PASSED';
END $$;

ROLLBACK;
