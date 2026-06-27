-- ============================================================================
-- Migration 31: Use in-game time for loan mutation ledger rows
-- Goal:
--   ensure repayment and refinance ledger chronology follows the shared game
--   clock instead of wall-clock NOW().
-- ============================================================================

CREATE OR REPLACE FUNCTION public.refinance_loan(p_loan_id uuid)
RETURNS TABLE(success boolean, message text, new_rate numeric, savings numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_user_id UUID; v_loan RECORD; v_new_rate NUMERIC; v_old_total NUMERIC; v_new_total NUMERIC;
v_savings NUMERIC; v_tier VARCHAR; v_weekly_payment NUMERIC; v_monthly_payment NUMERIC;
v_cash NUMERIC; v_game_time TIMESTAMPTZ;
BEGIN
v_user_id := require_current_user_id();
SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';
IF NOT FOUND THEN RETURN QUERY SELECT false, 'Loan not found or not active.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF;
SELECT game_current_time INTO v_game_time
FROM users
WHERE id = v_user_id
FOR UPDATE;
SELECT tier INTO v_tier FROM credit_scores WHERE user_id = v_user_id;
v_new_rate := CASE COALESCE(v_tier, 'Standard')
WHEN 'Platinum' THEN 0.03 WHEN 'Gold' THEN 0.04
WHEN 'Silver' THEN 0.05 WHEN 'Standard' THEN 0.07
ELSE 0.10
END;
IF v_new_rate >= v_loan.interest_rate THEN
RETURN QUERY SELECT false, 'Current rate is not better than existing rate.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN;
END IF;
v_old_total := v_loan.remaining_balance;
v_new_total := v_loan.principal * (1 + v_new_rate);
v_savings := GREATEST(0, v_old_total - v_new_total);
IF v_loan.term_months IS NOT NULL AND v_loan.term_months > 0 THEN
v_monthly_payment := v_new_total / v_loan.term_months;
v_weekly_payment := v_monthly_payment / 4.33;
ELSE
v_weekly_payment := v_new_total / 52;
v_monthly_payment := v_weekly_payment * 4.33;
END IF;
UPDATE loans SET interest_rate = v_new_rate, remaining_balance = v_new_total,
weekly_payment = v_weekly_payment, monthly_payment = v_monthly_payment
WHERE id = p_loan_id;
RETURN QUERY SELECT true, 'Loan refinanced successfully.'::TEXT, v_new_rate, v_savings;
END;
$function$;

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
v_cash := get_user_balance(v_user_id);
RETURN QUERY SELECT true,
CASE WHEN v_is_paid_off THEN 'Loan fully repaid!'
ELSE 'Payment of $' || v_payment::TEXT || ' applied.' END::TEXT,
v_cash, v_is_paid_off;
END;
$function$;
