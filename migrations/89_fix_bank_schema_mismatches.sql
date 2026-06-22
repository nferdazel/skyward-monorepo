-- ============================================================================
-- FIX: Bank schema mismatches between DB and client
-- ============================================================================
-- Fixes three issues:
--   1. get_credit_report(UUID) requires a parameter but the client calls it
--      without one. Replace with a parameterless version that resolves the
--      current user via require_current_user_id().
--   2. The return column names of get_credit_report did not match the Dart
--      CreditReport model (e.g. 'score' vs 'current_score', 'tier' vs
--      'credit_tier'). Align them.
--   3. No other schema changes — credit_score_history and aircraft_financing
--      column-name mismatches are fixed on the client side.
-- ============================================================================

-- Drop the old parameterised overload (no internal SQL callers remain after
-- migration 87 replaced take_loan and finance_aircraft).
DROP FUNCTION IF EXISTS get_credit_report(UUID);

-- Recreate as a parameterless function matching the Dart CreditReport model.
CREATE OR REPLACE FUNCTION get_credit_report()
RETURNS TABLE (
    current_score        INT,
    fleet_health         INT,
    revenue_stability    INT,
    debt_ratio           INT,
    cash_reserve         INT,
    profit_history       INT,
    credit_tier          VARCHAR(20),
    max_unsecured_loan   NUMERIC,
    max_secured_loan     NUMERIC,
    max_financing_amount NUMERIC,
    base_interest_rate   NUMERIC,
    suggestions          TEXT[]
) AS $$
DECLARE
    v_user_id  UUID;
    v_score    RECORD;
    v_tier     VARCHAR(20);
    v_max_uns  NUMERIC;
    v_max_sec  NUMERIC;
    v_max_fin  NUMERIC;
    v_rate     NUMERIC;
    v_sugg     TEXT[] := '{}';
BEGIN
    v_user_id := require_current_user_id();

    -- Compute (or recompute) the credit score
    SELECT * INTO v_score
    FROM calculate_credit_score(v_user_id)
    LIMIT 1;

    IF NOT FOUND THEN
        -- Fallback for brand-new users with no data yet
        current_score      := 500;
        fleet_health       := 100;
        revenue_stability  := 100;
        debt_ratio         := 100;
        cash_reserve       := 100;
        profit_history     := 100;
        credit_tier        := 'Standard';
        max_unsecured_loan := 5000000;
        max_secured_loan   := 25000000;
        max_financing_amount := 20000000;
        base_interest_rate := 0.07;
        suggestions        := ARRAY['Build your fleet and routes to establish credit history.'];
        RETURN NEXT;
        RETURN;
    END IF;

    -- Determine tier
    v_tier := CASE
        WHEN v_score.total_score >= 900 THEN 'Platinum'
        WHEN v_score.total_score >= 750 THEN 'Gold'
        WHEN v_score.total_score >= 600 THEN 'Silver'
        WHEN v_score.total_score >= 400 THEN 'Standard'
        ELSE 'Subprime'
    END;

    -- Loan & financing limits by tier
    v_max_uns := CASE
        WHEN v_tier = 'Platinum' THEN 50000000
        WHEN v_tier = 'Gold'     THEN 30000000
        WHEN v_tier = 'Silver'   THEN 15000000
        WHEN v_tier = 'Standard' THEN  5000000
        ELSE 1000000
    END;
    v_max_sec := CASE
        WHEN v_tier = 'Platinum' THEN 100000000
        WHEN v_tier = 'Gold'     THEN  75000000
        WHEN v_tier = 'Silver'   THEN  50000000
        WHEN v_tier = 'Standard' THEN  25000000
        ELSE 10000000
    END;
    v_max_fin := CASE
        WHEN v_tier = 'Platinum' THEN 80000000
        WHEN v_tier = 'Gold'     THEN 60000000
        WHEN v_tier = 'Silver'   THEN 40000000
        WHEN v_tier = 'Standard' THEN 20000000
        ELSE 5000000
    END;
    v_rate := CASE
        WHEN v_tier = 'Platinum' THEN 0.03
        WHEN v_tier = 'Gold'     THEN 0.04
        WHEN v_tier = 'Silver'   THEN 0.05
        WHEN v_tier = 'Standard' THEN 0.07
        ELSE 0.10
    END;

    -- Improvement suggestions based on weakest categories
    IF v_score.fleet_health < 100 THEN
        v_sugg := array_append(v_sugg,
            'Maintain your aircraft — low fleet condition hurts your credit.');
    END IF;
    IF v_score.revenue_stability < 100 THEN
        v_sugg := array_append(v_sugg,
            'Operate routes consistently — irregular revenue lowers your score.');
    END IF;
    IF v_score.debt_ratio < 100 THEN
        v_sugg := array_append(v_sugg,
            'Reduce outstanding debt relative to your net worth.');
    END IF;
    IF v_score.cash_reserve < 100 THEN
        v_sugg := array_append(v_sugg,
            'Build cash reserves — low liquidity increases lending risk.');
    END IF;
    IF v_score.profit_history < 100 THEN
        v_sugg := array_append(v_sugg,
            'Improve profitability — your expenses are outpacing revenue.');
    END IF;
    IF array_length(v_sugg, 1) IS NULL THEN
        v_sugg := ARRAY['Your credit profile is strong. Keep it up!'];
    END IF;

    -- Return with column names matching the Dart CreditReport model
    current_score        := v_score.total_score;
    fleet_health         := v_score.fleet_health;
    revenue_stability    := v_score.revenue_stability;
    debt_ratio           := v_score.debt_ratio;
    cash_reserve         := v_score.cash_reserve;
    profit_history       := v_score.profit_history;
    credit_tier          := v_tier;
    max_unsecured_loan   := v_max_uns;
    max_secured_loan     := v_max_sec;
    max_financing_amount := v_max_fin;
    base_interest_rate   := v_rate;
    suggestions          := v_sugg;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION get_credit_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_credit_report() TO authenticated;

COMMENT ON FUNCTION get_credit_report() IS
    'Returns a full credit report for the current authenticated user: score breakdown, tier, loan limits, interest rate, and improvement suggestions.';
