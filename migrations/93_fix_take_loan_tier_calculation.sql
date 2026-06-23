-- ============================================================================
-- Migration 93: Centralize credit tier config in global_game_settings
-- ============================================================================
-- Single source of truth for tier limits. Both get_credit_report() and
-- take_loan() read from global_game_settings.credit_tier_config.
-- Frontend displays limits returned by get_credit_report() — no hardcoding.

-- 1. Add credit_tier_config column
ALTER TABLE global_game_settings
ADD COLUMN IF NOT EXISTS credit_tier_config JSONB NOT NULL DEFAULT '{
  "tiers": {
    "Platinum": {
      "min_score": 900,
      "max_unsecured": 50000000,
      "max_secured": 100000000,
      "max_financing": 80000000,
      "rate_unsecured": 0.03,
      "rate_secured": 0.02,
      "rate_financing": 0.03
    },
    "Gold": {
      "min_score": 750,
      "max_unsecured": 30000000,
      "max_secured": 75000000,
      "max_financing": 60000000,
      "rate_unsecured": 0.04,
      "rate_secured": 0.03,
      "rate_financing": 0.04
    },
    "Silver": {
      "min_score": 600,
      "max_unsecured": 15000000,
      "max_secured": 50000000,
      "max_financing": 40000000,
      "rate_unsecured": 0.05,
      "rate_secured": 0.04,
      "rate_financing": 0.05
    },
    "Standard": {
      "min_score": 400,
      "max_unsecured": 5000000,
      "max_secured": 25000000,
      "max_financing": 20000000,
      "rate_unsecured": 0.07,
      "rate_secured": 0.06,
      "rate_financing": 0.07
    },
    "Subprime": {
      "min_score": 0,
      "max_unsecured": 1000000,
      "max_secured": 10000000,
      "max_financing": 5000000,
      "rate_unsecured": 0.10,
      "rate_secured": 0.09,
      "rate_financing": 0.10
    }
  },
  "min_loan": 100000,
  "max_active_loans": 3
}'::JSONB;

COMMENT ON COLUMN global_game_settings.credit_tier_config IS
    'Centralized credit tier configuration. Single source of truth for all loan limits, rates, and tier thresholds.';


-- 2. Helper: resolve tier from score using config
CREATE OR REPLACE FUNCTION resolve_credit_tier(p_score INT)
RETURNS VARCHAR(10) AS $$
DECLARE
    v_config JSONB;
    v_tier_name TEXT;
    v_tier_data JSONB;
BEGIN
    SELECT credit_tier_config INTO v_config
    FROM global_game_settings WHERE id = 1;

    IF v_config IS NULL THEN
        -- Fallback if config missing
        RETURN CASE
            WHEN p_score >= 900 THEN 'Platinum'
            WHEN p_score >= 750 THEN 'Gold'
            WHEN p_score >= 600 THEN 'Silver'
            WHEN p_score >= 400 THEN 'Standard'
            ELSE 'Subprime'
        END;
    END IF;

    -- Iterate tiers in descending score order
    FOR v_tier_name IN
        SELECT key FROM jsonb_each(v_config->'tiers')
        ORDER BY (value->>'min_score')::INT DESC
    LOOP
        v_tier_data := v_config->'tiers'->v_tier_name;
        IF p_score >= (v_tier_data->>'min_score')::INT THEN
            RETURN v_tier_name;
        END IF;
    END LOOP;

    RETURN 'Subprime';
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION resolve_credit_tier(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION resolve_credit_tier(INT) TO authenticated, service_role;


-- 3. Update get_credit_report() to read from config
DROP FUNCTION IF EXISTS get_credit_report();

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
    v_config   JSONB;
    v_tier_cfg JSONB;
    v_sugg     TEXT[] := '{}';
BEGIN
    v_user_id := require_current_user_id();

    SELECT credit_tier_config INTO v_config
    FROM global_game_settings WHERE id = 1;

    SELECT * INTO v_score
    FROM calculate_credit_score(v_user_id)
    LIMIT 1;

    IF NOT FOUND THEN
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

    v_tier := resolve_credit_tier(v_score.total_score);

    -- Read limits from config
    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);

    current_score    := v_score.total_score;
    fleet_health     := v_score.fleet_health;
    revenue_stability := v_score.revenue_stability;
    debt_ratio       := v_score.debt_ratio;
    cash_reserve     := v_score.cash_reserve;
    profit_history   := v_score.profit_history;
    credit_tier      := v_tier;

    max_unsecured_loan  := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
    max_secured_loan    := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
    max_financing_amount := COALESCE((v_tier_cfg->>'max_financing')::NUMERIC, 20000000);
    base_interest_rate  := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);

    -- Improvement suggestions
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
            'Reduce outstanding debt to improve borrowing capacity.');
    END IF;
    IF v_score.cash_reserve < 100 THEN
        v_sugg := array_append(v_sugg,
            'Build cash reserves — low cash hurts your credit score.');
    END IF;
    IF v_score.profit_history < 100 THEN
        v_sugg := array_append(v_sugg,
            'Improve profitability — consistent losses damage your credit.');
    END IF;
    IF v_sugg = '{}'::TEXT[] THEN
        v_sugg := ARRAY['Excellent credit profile. Keep it up!'];
    END IF;
    suggestions := v_sugg;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION get_credit_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_credit_report() TO authenticated;


-- 4. Update take_loan() to read from config
DROP FUNCTION IF EXISTS take_loan(NUMERIC, INT, VARCHAR, UUID);

CREATE OR REPLACE FUNCTION take_loan(
    p_principal NUMERIC,
    p_term_weeks INT DEFAULT 52,
    p_loan_type VARCHAR DEFAULT 'unsecured',
    p_collateral_aircraft_id UUID DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT, new_cash NUMERIC) AS $$
DECLARE
    v_user_id UUID;
    v_existing_loans INT;
    v_credit_score INT;
    v_score_record RECORD;
    v_tier VARCHAR(10);
    v_config JSONB;
    v_tier_cfg JSONB;
    v_min_loan NUMERIC;
    v_max_loans INT;
    v_interest_rate NUMERIC;
    v_weekly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_max_principal NUMERIC;
    v_rate_key TEXT;
BEGIN
    v_user_id := require_current_user_id();

    -- Load config
    SELECT credit_tier_config INTO v_config
    FROM global_game_settings WHERE id = 1;

    v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
    v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);

    -- Check existing loan count
    SELECT COUNT(*) INTO v_existing_loans
    FROM loans WHERE user_id = v_user_id AND status = 'active';
    IF v_existing_loans >= v_max_loans THEN
        RETURN QUERY SELECT false,
            'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    SELECT u.credit_score, u.game_current_time INTO v_credit_score, v_game_time
    FROM users u WHERE u.id = v_user_id;
    v_credit_score := COALESCE(v_credit_score, 500);

    -- Calculate tier on-the-fly
    SELECT * INTO v_score_record
    FROM calculate_credit_score(v_user_id)
    LIMIT 1;

    IF FOUND THEN
        v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE
        v_tier := resolve_credit_tier(v_credit_score);
    END IF;

    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);

    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
        RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Determine max principal and rate from config
    IF p_loan_type = 'unsecured' THEN
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
        v_rate_key := 'rate_unsecured';
    ELSIF p_loan_type = 'secured' THEN
        IF p_collateral_aircraft_id IS NULL THEN
            RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM user_fleet WHERE id = p_collateral_aircraft_id AND user_id = v_user_id) THEN
            RETURN QUERY SELECT false, 'You do not own that aircraft.'::TEXT, 0::NUMERIC;
            RETURN;
        END IF;
        v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
        v_rate_key := 'rate_secured';
    ELSE
        v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
        v_interest_rate := COALESCE((v_tier_cfg->>'rate_financing')::NUMERIC, 0.07);
        v_rate_key := 'rate_financing';
    END IF;

    IF p_principal < v_min_loan OR p_principal > v_max_principal THEN
        RETURN QUERY SELECT false,
            'Loan amount must be between $' ||
            (v_min_loan / 1000)::TEXT || 'K and $' ||
            CASE WHEN v_max_principal >= 1000000
                 THEN (v_max_principal / 1000000)::TEXT || 'M'
                 ELSE (v_max_principal / 1000)::TEXT || 'K'
            END ||
            ' for your ' || v_tier || ' credit tier.'::TEXT,
            0::NUMERIC;
        RETURN;
    END IF;

    -- Calculate weekly payment (simple interest)
    v_total_repayable := p_principal * (1 + v_interest_rate * (p_term_weeks / 52.0));
    v_weekly_payment := v_total_repayable / p_term_weeks;

    -- Check cash
    SELECT cash INTO v_cash FROM users WHERE id = v_user_id FOR UPDATE;
    IF v_cash < 0 THEN
        RETURN QUERY SELECT false, 'Cannot take loan with negative cash balance.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    -- Insert loan record
    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance,
        weekly_payment, status, game_date_taken,
        loan_type, collateral_aircraft_id, credit_score_at_origination
    ) VALUES (
        v_user_id, p_principal, v_interest_rate, v_total_repayable,
        v_weekly_payment, 'active', v_game_time,
        p_loan_type, p_collateral_aircraft_id, v_credit_score
    );

    -- Credit the cash
    UPDATE users SET cash = cash + p_principal WHERE id = v_user_id;
    SELECT cash INTO v_cash FROM users WHERE id = v_user_id;

    RETURN QUERY SELECT true,
        'Loan approved! $' || p_principal::TEXT || ' at ' ||
        (v_interest_rate * 100)::TEXT || '% APR (' || v_tier || ' tier).'::TEXT,
        v_cash;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_catalog;

REVOKE ALL ON FUNCTION take_loan(NUMERIC, INT, VARCHAR, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION take_loan(NUMERIC, INT, VARCHAR, UUID) TO authenticated;

COMMENT ON FUNCTION take_loan(NUMERIC, INT, VARCHAR, UUID) IS
    'Process a loan application. Limits and rates read from global_game_settings.credit_tier_config.';
