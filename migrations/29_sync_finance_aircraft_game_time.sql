-- ============================================================================
-- Migration 29: Sync finance_aircraft game time before ledger write
-- Goal:
--   make aircraft financing use the player's current season-aligned game clock
--   before writing the financing down-payment ledger row.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.finance_aircraft(
    p_user_id uuid,
    p_aircraft_model_id uuid,
    p_down_payment_pct numeric DEFAULT 0.20,
    p_term_months integer DEFAULT 36
)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_actor_type VARCHAR(10);
    v_model RECORD;
    v_credit_score INT;
    v_score_record RECORD;
    v_tier VARCHAR(10);
    v_tier_cfg JSONB;
    v_purchase_price NUMERIC;
    v_down_payment NUMERIC;
    v_principal NUMERIC;
    v_interest_rate NUMERIC;
    v_monthly_payment NUMERIC;
    v_weekly_payment NUMERIC;
    v_total_repayable NUMERIC;
    v_cash NUMERIC;
    v_game_time TIMESTAMPTZ;
    v_fleet_id UUID;
    v_hq_iata VARCHAR(3);
    v_max_financing NUMERIC;
    v_economy_seats INT;
    v_business_seats INT;
    v_first_seats INT;
    v_archetype VARCHAR(30);
BEGIN
    PERFORM 1 FROM process_simulation_delta(p_user_id);

    SELECT *
    INTO v_model
    FROM aircraft_models
    WHERE id = p_aircraft_model_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_purchase_price := v_model.purchase_price;

    SELECT u.actor_type, u.game_current_time, u.hq_airport_iata
    INTO v_actor_type, v_game_time, v_hq_iata
    FROM users u
    WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    IF v_actor_type = 'AI' THEN
        SELECT COALESCE(bp.archetype, 'Balanced')
        INTO v_archetype
        FROM bot_profiles bp
        WHERE bp.user_id = p_user_id;
        IF NOT FOUND THEN
            v_archetype := 'Balanced';
        END IF;
    END IF;

    v_cash := get_user_balance(p_user_id);
    SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
    v_credit_score := COALESCE(v_credit_score, 500);

    SELECT * INTO v_score_record FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF FOUND THEN
        v_tier := resolve_credit_tier(v_score_record.total_score);
    ELSE
        v_tier := resolve_credit_tier(v_credit_score);
    END IF;
    v_tier := COALESCE(v_tier, 'Standard');
    v_tier_cfg := get_credit_tier_policy(v_tier);

    v_max_financing := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
    v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.10);

    IF v_purchase_price > v_max_financing THEN
        RETURN QUERY SELECT false, 'Aircraft price ($' || v_purchase_price::TEXT || ') exceeds your financing limit ($' || v_max_financing::TEXT || ') for tier ' || v_tier || '.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;
    IF p_term_months NOT IN (12, 24, 36, 48, 60) THEN
        RETURN QUERY SELECT false, 'Financing term must be 12, 24, 36, 48, or 60 months.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;
    IF p_down_payment_pct < 0.10 OR p_down_payment_pct > 0.50 THEN
        RETURN QUERY SELECT false, 'Down payment must be between 10% and 50%.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    v_down_payment := v_purchase_price * p_down_payment_pct;
    v_principal := v_purchase_price - v_down_payment;
    v_total_repayable := v_principal * (1 + v_interest_rate);
    v_monthly_payment := v_total_repayable / p_term_months;
    v_weekly_payment := v_monthly_payment / 4.33;

    IF v_cash < v_down_payment THEN
        RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC;
        RETURN;
    END IF;

    PERFORM debit_bank_account(
        p_user_id,
        v_down_payment,
        'investing',
        'aircraft_purchase_deposit',
        'Aircraft financing down payment — ' || v_model.model_name,
        v_game_time
    );

    IF v_actor_type = 'AI' THEN
        v_economy_seats := CASE
            WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.80)::INT
            WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)::INT
            ELSE FLOOR(v_model.capacity * 0.50)::INT
        END;
        v_business_seats := CASE
            WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.15)::INT
            WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)::INT
            ELSE FLOOR(v_model.capacity * 0.30)::INT
        END;
        v_first_seats := v_model.capacity - v_economy_seats - v_business_seats;

        INSERT INTO fleet_aircraft (
            user_id, aircraft_model_id, nickname, tail_number, acquisition_type,
            condition, status, economy_seats, business_seats, first_class_seats
        )
        VALUES (
            p_user_id,
            p_aircraft_model_id,
            v_model.model_name,
            generate_tail_number(COALESCE(v_hq_iata, 'CGK')),
            'finance',
            100.00,
            'active',
            v_economy_seats,
            v_business_seats,
            v_first_seats
        )
        RETURNING id INTO v_fleet_id;

        INSERT INTO loans (
            user_id, principal, interest_rate, remaining_balance, weekly_payment,
            status, loan_type, collateral_aircraft_id, term_months, monthly_payment
        )
        VALUES (
            p_user_id,
            v_principal,
            v_interest_rate,
            v_total_repayable,
            v_weekly_payment,
            'active',
            'aircraft_financing',
            v_fleet_id,
            p_term_months,
            v_monthly_payment
        );

        v_cash := get_user_balance(p_user_id);
        RETURN QUERY SELECT true, 'Aircraft financed (bot).'::TEXT, v_cash;
        RETURN;
    END IF;

    INSERT INTO fleet_aircraft (
        user_id, aircraft_model_id, nickname, tail_number, acquisition_type,
        condition, status, economy_seats, business_seats, first_class_seats
    )
    VALUES (
        p_user_id,
        p_aircraft_model_id,
        v_model.model_name,
        generate_tail_number(COALESCE(v_hq_iata, 'CGK')),
        'finance',
        100.00,
        'active',
        v_model.capacity,
        0,
        0
    )
    RETURNING id INTO v_fleet_id;

    INSERT INTO loans (
        user_id, principal, interest_rate, remaining_balance, weekly_payment,
        status, loan_type, collateral_aircraft_id, term_months, monthly_payment
    )
    VALUES (
        p_user_id,
        v_principal,
        v_interest_rate,
        v_total_repayable,
        v_weekly_payment,
        'active',
        'aircraft_financing',
        v_fleet_id,
        p_term_months,
        v_monthly_payment
    );

    v_cash := get_user_balance(p_user_id);
    RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$function$;
