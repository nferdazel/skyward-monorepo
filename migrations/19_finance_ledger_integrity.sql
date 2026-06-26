-- ============================================================================
-- Migration 19: Finance ledger integrity
-- Goal:
--   keep bank_transactions strictly cash-moving by removing zero-amount
--   refinance ledger rows and cleaning up the legacy data already written.
-- ============================================================================

DELETE FROM public.bank_transactions
WHERE ifrs_subcategory = 'loan_refinance'
  AND amount = 0;

CREATE OR REPLACE FUNCTION public.refinance_loan(p_loan_id uuid)
RETURNS TABLE(success boolean, message text, new_rate numeric, savings numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_user_id UUID; v_loan RECORD; v_new_rate NUMERIC; v_old_total NUMERIC; v_new_total NUMERIC;
v_savings NUMERIC; v_tier VARCHAR; v_weekly_payment NUMERIC; v_monthly_payment NUMERIC;
BEGIN
v_user_id := require_current_user_id();
SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';
IF NOT FOUND THEN RETURN QUERY SELECT false, 'Loan not found or not active.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF;
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
