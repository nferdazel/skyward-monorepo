-- ============================================================================
-- FIX: Missing bank/credit system objects
-- ============================================================================

-- Fix 1: credit_score_history table (was in migration 85 but lost)
CREATE TABLE IF NOT EXISTS credit_score_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id),
    score INT NOT NULL,
    tier VARCHAR(10) NOT NULL,
    fleet_health_score INT DEFAULT 0,
    revenue_stability_score INT DEFAULT 0,
    debt_ratio_score INT DEFAULT 0,
    cash_reserves_score INT DEFAULT 0,
    profit_history_score INT DEFAULT 0,
    game_date TIMESTAMPTZ NOT NULL,
    computed_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE credit_score_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY credit_score_history_select_own ON credit_score_history FOR SELECT TO authenticated
USING (user_id = (SELECT id FROM users WHERE auth_user_id = auth.uid()));
GRANT SELECT ON credit_score_history TO authenticated;
CREATE INDEX IF NOT EXISTS credit_score_history_user_date_idx ON credit_score_history(user_id, game_date DESC);

-- Fix 2: rank_history table (migration 82 was never applied)
CREATE TABLE IF NOT EXISTS rank_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    is_bot BOOLEAN DEFAULT false,
    game_date DATE NOT NULL,
    rank_position INT NOT NULL,
    net_worth NUMERIC NOT NULL,
    fleet_size INT DEFAULT 0,
    monthly_revenue NUMERIC DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE rank_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY rank_history_select_authenticated ON rank_history FOR SELECT TO authenticated USING (true);
GRANT SELECT ON rank_history TO authenticated;
CREATE INDEX IF NOT EXISTS rank_history_user_date_idx ON rank_history(user_id, game_date DESC);

-- Fix 3: get_credit_report function
CREATE OR REPLACE FUNCTION get_credit_report(p_user_id UUID)
RETURNS TABLE(
    score INT,
    tier VARCHAR,
    fleet_health_score INT,
    revenue_stability_score INT,
    debt_ratio_score INT,
    cash_reserves_score INT,
    profit_history_score INT,
    max_unsecured_loan NUMERIC,
    max_secured_loan NUMERIC,
    interest_rate NUMERIC,
    suggestions TEXT[]
) AS $$
DECLARE
    v_score INT;
    v_tier VARCHAR;
    v_fleet INT;
    v_revenue INT;
    v_debt INT;
    v_cash INT;
    v_profit INT;
    v_max_unsecured NUMERIC;
    v_max_secured NUMERIC;
    v_rate NUMERIC;
    v_suggestions TEXT[] := '{}';
BEGIN
    -- Get or compute credit score
    SELECT cs.score, cs.tier, cs.fleet_health_score, cs.revenue_stability_score,
           cs.debt_ratio_score, cs.cash_reserves_score, cs.profit_history_score
    INTO v_score, v_tier, v_fleet, v_revenue, v_debt, v_cash, v_profit
    FROM credit_scores cs WHERE cs.user_id = p_user_id;

    -- If no credit score exists, compute it
    IF v_score IS NULL THEN
        SELECT * INTO v_score, v_fleet, v_revenue, v_debt, v_cash, v_profit
        FROM calculate_credit_score(p_user_id);
        v_tier := CASE
            WHEN v_score >= 900 THEN 'Platinum'
            WHEN v_score >= 750 THEN 'Gold'
            WHEN v_score >= 600 THEN 'Silver'
            WHEN v_score >= 400 THEN 'Standard'
            ELSE 'Subprime'
        END;
    END IF;

    -- Determine limits based on tier
    CASE v_tier
        WHEN 'Platinum' THEN v_max_unsecured := 50000000; v_max_secured := 100000000; v_rate := 0.03;
        WHEN 'Gold' THEN v_max_unsecured := 30000000; v_max_secured := 75000000; v_rate := 0.04;
        WHEN 'Silver' THEN v_max_unsecured := 15000000; v_max_secured := 50000000; v_rate := 0.05;
        WHEN 'Standard' THEN v_max_unsecured := 5000000; v_max_secured := 25000000; v_rate := 0.07;
        ELSE v_max_unsecured := 1000000; v_max_secured := 10000000; v_rate := 0.10;
    END CASE;

    -- Generate suggestions
    IF v_fleet < 150 THEN v_suggestions := array_append(v_suggestions, 'Improve fleet condition to boost score'); END IF;
    IF v_revenue < 150 THEN v_suggestions := array_append(v_suggestions, 'Stabilize revenue with consistent routes'); END IF;
    IF v_debt < 150 THEN v_suggestions := array_append(v_suggestions, 'Reduce debt-to-asset ratio'); END IF;
    IF v_cash < 150 THEN v_suggestions := array_append(v_suggestions, 'Build cash reserves for longer runway'); END IF;
    IF v_profit < 150 THEN v_suggestions := array_append(v_suggestions, 'Maintain profitable operations streak'); END IF;

    RETURN QUERY SELECT v_score, v_tier, v_fleet, v_revenue, v_debt, v_cash, v_profit,
                        v_max_unsecured, v_max_secured, v_rate, v_suggestions;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;

-- Fix 4: refinance_loan function
CREATE OR REPLACE FUNCTION refinance_loan(p_loan_id UUID)
RETURNS TABLE(success BOOLEAN, message TEXT, new_rate NUMERIC, savings NUMERIC) AS $$
DECLARE
    v_user_id UUID;
    v_loan RECORD;
    v_new_rate NUMERIC;
    v_old_total NUMERIC;
    v_new_total NUMERIC;
    v_savings NUMERIC;
    v_tier VARCHAR;
BEGIN
    v_user_id := require_current_user_id();
    SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active';

    IF v_loan IS NULL THEN
        RETURN QUERY SELECT false, 'Loan not found or not active.'::TEXT, 0::NUMERIC, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT tier INTO v_tier FROM credit_scores WHERE user_id = v_user_id;
    v_new_rate := CASE COALESCE(v_tier, 'Standard')
        WHEN 'Platinum' THEN 0.03 WHEN 'Gold' THEN 0.04 WHEN 'Silver' THEN 0.05
        WHEN 'Standard' THEN 0.07 ELSE 0.10
    END;

    IF v_new_rate >= v_loan.interest_rate THEN
        RETURN QUERY SELECT false, 'Current rate is not better than existing rate.'::TEXT, 0::NUMERIC, 0::NUMERIC;
        RETURN;
    END IF;

    v_old_total := v_loan.remaining_balance;
    v_new_total := v_loan.principal * (1 + v_new_rate);
    v_savings := GREATEST(0, v_old_total - v_new_total);

    UPDATE loans SET interest_rate = v_new_rate WHERE id = p_loan_id;

    RETURN QUERY SELECT true, 'Loan refinanced successfully.'::TEXT, v_new_rate, v_savings;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog;
