-- Fix: Transition financed aircraft to owned when loan is fully repaid
-- Bug: repay_loan() did not update fleet_aircraft.acquisition_type when an
-- aircraft_financing loan was paid off, leaving the aircraft unsellable.

CREATE OR REPLACE FUNCTION public.repay_loan(p_loan_id uuid, p_amount numeric DEFAULT NULL::numeric)
RETURNS TABLE(success boolean, message text, new_cash numeric, paid_off boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_user_id UUID; v_loan RECORD; v_payment NUMERIC; v_cash NUMERIC;
  v_is_paid_off BOOLEAN := false; v_game_time TIMESTAMPTZ;
BEGIN
  v_user_id := require_current_user_id();
  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';
  IF NOT FOUND THEN RETURN QUERY SELECT false, 'Loan not found or already paid off.'::TEXT, 0::NUMERIC, false; RETURN; END IF;
  IF p_amount IS NULL THEN v_payment := v_loan.remaining_balance;
  ELSE v_payment := LEAST(p_amount, v_loan.remaining_balance); END IF;
  IF v_payment <= 0 THEN RETURN QUERY SELECT false, 'Payment amount must be positive.'::TEXT, 0::NUMERIC, false; RETURN; END IF;
  v_cash := get_user_balance(v_user_id);
  SELECT game_current_time INTO v_game_time
  FROM users
  WHERE id = v_user_id
  FOR UPDATE;
  IF v_cash < v_payment THEN
    RETURN QUERY SELECT false, 'Insufficient cash. Need $' || v_payment::TEXT || ', have $' || v_cash::TEXT || '.'::TEXT, v_cash, false; RETURN;
  END IF;
  PERFORM debit_bank_account(v_user_id, v_payment, 'financing', 'loan_repayment',
    CASE WHEN v_loan.remaining_balance - v_payment <= 0 THEN 'Loan fully repaid' ELSE 'Loan partial repayment' END,
    v_game_time);
  UPDATE loans
  SET remaining_balance = remaining_balance - v_payment,
      status = CASE WHEN remaining_balance - v_payment <= 0 THEN 'paid_off'::VARCHAR ELSE status END
  WHERE id = p_loan_id;
  v_is_paid_off := (SELECT remaining_balance <= 0 FROM loans WHERE id = p_loan_id);
  -- Transition financed aircraft to owned when loan is fully repaid
  IF v_is_paid_off AND v_loan.loan_type = 'aircraft_financing' AND v_loan.collateral_aircraft_id IS NOT NULL THEN
    UPDATE fleet_aircraft
    SET acquisition_type = 'purchase'
    WHERE id = v_loan.collateral_aircraft_id
      AND user_id = v_user_id
      AND acquisition_type = 'finance';
  END IF;
  v_cash := get_user_balance(v_user_id);
  RETURN QUERY SELECT true,
    CASE WHEN v_is_paid_off THEN 'Loan fully repaid!'
    ELSE 'Payment of $' || v_payment::TEXT || ' applied.' END::TEXT,
    v_cash, v_is_paid_off;
END;
$function$;
