-- ============================================================================
-- Migration 09: Finance Phase 3 — net worth consistency
-- Target formula:
--   net_worth = cash + owned_aircraft_asset_value - open_loan_balance
--
-- Clean break:
--   - owned aircraft = acquisition_type IN ('purchase', 'finance')
--   - leased aircraft are never counted as owned net-worth assets
--   - open debt remains a liability until paid off
-- ============================================================================

-- ============================================================================
-- FIX 1: canonical net worth helper
-- ============================================================================
CREATE OR REPLACE FUNCTION public.calculate_user_net_worth(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_cash NUMERIC := 0;
    v_owned_asset_value NUMERIC := 0;
    v_open_loan_balance NUMERIC := 0;
BEGIN
    v_cash := COALESCE(get_user_balance(p_user_id), 0);

    SELECT COALESCE(
        SUM(
            CASE
                WHEN f.acquisition_type IN ('purchase', 'finance')
                    THEN m.purchase_price * (f.condition / 100.00)
                ELSE 0
            END
        ),
        0
    )
    INTO v_owned_asset_value
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.user_id = p_user_id;

    SELECT COALESCE(SUM(l.remaining_balance), 0)
    INTO v_open_loan_balance
    FROM loans l
    WHERE l.user_id = p_user_id
      AND COALESCE(l.remaining_balance, 0) > 0
      AND COALESCE(l.status, 'active') <> 'paid_off';

    RETURN v_cash + v_owned_asset_value - v_open_loan_balance;
END;
$function$;

-- ============================================================================
-- FIX 2: fleet and bank triggers delegate to canonical helper
-- ============================================================================
CREATE OR REPLACE FUNCTION public.trg_fleet_reconcile_net_worth()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := COALESCE(NEW.user_id, OLD.user_id);

    UPDATE users
    SET net_worth = calculate_user_net_worth(v_user_id)
    WHERE id = v_user_id;

    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_update_user_net_worth()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.net_worth := calculate_user_net_worth(NEW.id);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_bank_balance_reconcile_net_worth()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE users
    SET net_worth = calculate_user_net_worth(NEW.user_id)
    WHERE id = NEW.user_id;

    RETURN NEW;
END;
$function$;

-- ============================================================================
-- FIX 3: loan trigger to keep liability-driven net worth changes in sync
-- ============================================================================
CREATE OR REPLACE FUNCTION public.trg_loan_reconcile_net_worth()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := COALESCE(NEW.user_id, OLD.user_id);

    UPDATE users
    SET net_worth = calculate_user_net_worth(v_user_id)
    WHERE id = v_user_id;

    RETURN COALESCE(NEW, OLD);
END;
$function$;

DROP TRIGGER IF EXISTS trg_loan_reconcile_net_worth ON public.loans;
CREATE TRIGGER trg_loan_reconcile_net_worth
    AFTER INSERT OR DELETE OR UPDATE OF remaining_balance, status, user_id
    ON public.loans
    FOR EACH ROW
    EXECUTE FUNCTION trg_loan_reconcile_net_worth();

-- ============================================================================
-- FIX 4: finance snapshot uses the same owned/liability treatment
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_finance_snapshot(
    p_id uuid,
    p_is_bot boolean DEFAULT false
)
RETURNS TABLE(
    actor_id uuid,
    is_bot boolean,
    company_name character varying,
    cash numeric,
    net_worth numeric,
    owned_aircraft_asset_value numeric,
    leased_aircraft_monthly_exposure numeric,
    fleet_count integer,
    owned_fleet_count integer,
    leased_fleet_count integer,
    active_route_count integer,
    rolling_revenue_30d numeric,
    rolling_expense_30d numeric,
    rolling_net_30d numeric,
    ledger_window_days integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_company_name VARCHAR;
    v_cash NUMERIC := 0.00;
    v_net_worth NUMERIC := 0.00;
    v_owned_asset_value NUMERIC := 0.00;
    v_leased_monthly_exposure NUMERIC := 0.00;
    v_fleet_count INT := 0;
    v_owned_fleet_count INT := 0;
    v_leased_fleet_count INT := 0;
    v_active_route_count INT := 0;
    v_revenue_30d NUMERIC := 0.00;
    v_expense_30d NUMERIC := 0.00;
    v_ledger_window_days INT := 30;
    v_game_current_time TIMESTAMPTZ;
BEGIN
    SELECT u.company_name, u.game_current_time
    INTO v_company_name, v_game_current_time
    FROM users u
    WHERE u.id = p_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_cash := get_user_balance(p_id);
    v_net_worth := calculate_user_net_worth(p_id);

    SELECT
        COUNT(*)::INT,
        COUNT(*) FILTER (
            WHERE f.acquisition_type IN ('purchase', 'finance')
        )::INT,
        COUNT(*) FILTER (WHERE f.acquisition_type = 'lease')::INT,
        COALESCE(
            SUM(
                CASE
                    WHEN f.acquisition_type IN ('purchase', 'finance')
                        THEN m.purchase_price * (f.condition / 100.00)
                    ELSE 0
                END
            ),
            0.00
        ),
        COALESCE(
            SUM(
                CASE
                    WHEN f.acquisition_type = 'lease'
                        THEN m.lease_price_per_month
                    ELSE 0
                END
            ),
            0.00
        )
    INTO
        v_fleet_count,
        v_owned_fleet_count,
        v_leased_fleet_count,
        v_owned_asset_value,
        v_leased_monthly_exposure
    FROM fleet_aircraft f
    JOIN aircraft_models m ON m.id = f.aircraft_model_id
    WHERE f.user_id = p_id;

    SELECT COUNT(*)::INT
    INTO v_active_route_count
    FROM route_assignments r
    WHERE r.user_id = p_id;

    SELECT
        COALESCE(
            SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END),
            0.00
        ),
        COALESCE(
            SUM(CASE WHEN transaction_type = 'debit' THEN ABS(amount) ELSE 0 END),
            0.00
        )
    INTO v_revenue_30d, v_expense_30d
    FROM bank_transactions
    WHERE user_id = p_id
      AND game_date >= v_game_current_time - INTERVAL '30 days';

    RETURN QUERY
    SELECT
        p_id,
        p_is_bot,
        v_company_name::VARCHAR,
        v_cash,
        v_net_worth,
        v_owned_asset_value,
        v_leased_monthly_exposure,
        v_fleet_count,
        v_owned_fleet_count,
        v_leased_fleet_count,
        v_active_route_count,
        v_revenue_30d,
        v_expense_30d,
        v_revenue_30d - v_expense_30d,
        v_ledger_window_days;
END;
$function$;

-- ============================================================================
-- FIX 5: leaderboard reads canonical net worth, not potentially stale column
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_global_leaderboard()
RETURNS TABLE(
    id uuid,
    company_name character varying,
    ceo_name character varying,
    is_bot boolean,
    archetype character varying,
    cash numeric,
    net_worth numeric,
    fleet_size integer,
    monthly_revenue numeric,
    status character varying
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        u.id,
        u.company_name::VARCHAR,
        u.ceo_name::VARCHAR,
        (u.actor_type = 'AI')::BOOLEAN,
        COALESCE(bp.archetype, 'Player')::VARCHAR,
        get_user_balance(u.id),
        calculate_user_net_worth(u.id),
        (
            SELECT COUNT(*)::INT
            FROM fleet_aircraft f
            WHERE f.user_id = u.id
              AND f.status = 'active'
        ),
        COALESCE(
            (
                SELECT SUM(bt.amount)
                FROM bank_transactions bt
                WHERE bt.user_id = u.id
                  AND bt.transaction_type = 'credit'
                  AND bt.game_date >= u.game_current_time - INTERVAL '30 days'
            ),
            0.00
        )::NUMERIC,
        COALESCE(u.operational_status, 'Active')::VARCHAR
    FROM users u
    LEFT JOIN bot_profiles bp ON bp.user_id = u.id;
END;
$function$;

-- ============================================================================
-- FIX 6: achievement thresholds use the canonical helper
-- ============================================================================
CREATE OR REPLACE FUNCTION public.check_achievements(
    p_user_id uuid,
    p_game_time timestamp with time zone
)
RETURNS TABLE(achievement_name character varying, achievement_type character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_cash NUMERIC; v_net_worth NUMERIC; v_fleet_count INT; v_route_count INT;
v_hub_routes INT; v_has_first_class BOOLEAN; v_distress_recovered BOOLEAN;
BEGIN
v_cash := get_user_balance(p_user_id);
v_net_worth := calculate_user_net_worth(p_user_id);
SELECT COUNT(*) INTO v_fleet_count FROM fleet_aircraft WHERE user_id = p_user_id AND status = 'active';
SELECT COUNT(*) INTO v_route_count FROM route_assignments WHERE user_id = p_user_id AND status = 'active';
SELECT COUNT(*) INTO v_hub_routes FROM route_assignments ra
JOIN users u ON u.id = ra.user_id
WHERE ra.user_id = p_user_id AND ra.origin_iata = u.hq_airport_iata AND ra.status = 'active';
SELECT EXISTS(SELECT 1 FROM fleet_aircraft WHERE user_id = p_user_id AND first_class_seats > 0 AND status = 'active')
INTO v_has_first_class;
SELECT EXISTS(SELECT 1 FROM users WHERE id = p_user_id AND consecutive_negative_days >= 7 AND recovery_streak_days >= 30)
INTO v_distress_recovered;
IF v_cash >= 1000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'cash_millionaire', 'Cash Millionaire', 'Reach $1M in liquid cash', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_net_worth >= 1000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'millionaire', 'Millionaire', 'Net worth exceeds $1M', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_net_worth >= 10000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'multi_millionaire', 'Multi-Millionaire', 'Net worth exceeds $10M', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_net_worth >= 100000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'hundred_million', 'Aviation Mogul', 'Net worth exceeds $100M', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_net_worth >= 1000000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'billionaire', 'Aviation Billionaire', 'Net worth exceeds $1B', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_fleet_count >= 5 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'fleet_builder', 'Fleet Builder', 'Operate 5 active aircraft', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_fleet_count >= 20 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'fleet_empire', 'Fleet Empire', 'Operate 20 active aircraft', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_route_count >= 10 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'network_starter', 'Network Starter', 'Launch 10 active routes', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_route_count >= 50 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'network_empire', 'Network Empire', 'Launch 50 active routes', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_hub_routes >= 8 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'hub_operator', 'Hub Operator', 'Operate 8 routes from your home hub', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_has_first_class THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'premium_service', 'Premium Service', 'Operate an aircraft with first class seats', p_game_time) ON CONFLICT DO NOTHING; END IF;
IF v_distress_recovered THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'comeback_story', 'Comeback Story', 'Recover from 7 days of distress and sustain 30 days positive operations', p_game_time) ON CONFLICT DO NOTHING; END IF;
RETURN QUERY
SELECT a.achievement_name::VARCHAR, a.achievement_type::VARCHAR
FROM achievements a
WHERE a.user_id = p_user_id
AND a.game_date = p_game_time;
END;
$function$;

-- ============================================================================
-- FIX 7: backfill stored users.net_worth to the canonical formula
-- ============================================================================
UPDATE users u
SET net_worth = calculate_user_net_worth(u.id);
