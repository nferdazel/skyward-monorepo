-- ============================================================================
-- SKYWARD — Production Baseline Schema
-- Generated from live Supabase database on 2026-06-24
-- This is the single source of truth. All future changes are incremental migrations.
-- ============================================================================

-- ── Extensions ──
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;

-- ── Sequences ──
CREATE SEQUENCE IF NOT EXISTS public.world_tick_log_id_seq
    AS bigint START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;

-- ============================================================================
-- ── Tables (in dependency order) ──
-- ============================================================================

-- 1. season_clock
CREATE TABLE IF NOT EXISTS public.season_clock (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    label character varying(80) NOT NULL,
    current_game_time timestamp with time zone NOT NULL DEFAULT '2020-01-01 00:00:00+00',
    last_tick_at timestamp with time zone NOT NULL DEFAULT now(),
    time_scale_multiplier numeric(10,2) NOT NULL DEFAULT 60.00,
    tick_interval_seconds integer NOT NULL DEFAULT 60,
    status character varying(20) NOT NULL DEFAULT 'active',
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- 2. airports
CREATE TABLE IF NOT EXISTS public.airports (
    iata character varying(3) PRIMARY KEY,
    name character varying(150) NOT NULL,
    city character varying(100) NOT NULL,
    country character varying(100) NOT NULL,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    demand_index integer NOT NULL DEFAULT 50,
    airport_tax numeric(10,2) NOT NULL DEFAULT 1000.00
);

-- 3. aircraft_models
CREATE TABLE IF NOT EXISTS public.aircraft_models (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    manufacturer character varying(50) NOT NULL,
    model_name character varying(50) NOT NULL,
    type character varying(30) NOT NULL,
    range_km integer NOT NULL,
    capacity integer NOT NULL,
    speed_kmh integer NOT NULL DEFAULT 850,
    fuel_burn_per_km numeric(8,3) NOT NULL,
    maintenance_cost_per_hour numeric(10,2) NOT NULL,
    purchase_price numeric(15,2) NOT NULL,
    lease_price_per_month numeric(15,2) NOT NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    turnaround_hours numeric DEFAULT 1.0
);

-- 4. global_game_settings
CREATE TABLE IF NOT EXISTS public.global_game_settings (
    id integer PRIMARY KEY DEFAULT 1,
    starting_cash bigint NOT NULL DEFAULT 15000000,
    starting_cash_desc text NOT NULL DEFAULT 'Starting capital for human players and bots',
    fuel_price_per_liter numeric(10,4) NOT NULL DEFAULT 0.85,
    fuel_price_per_liter_desc text NOT NULL DEFAULT 'Base price of aviation fuel per liter in USD',
    absolute_minimum_safety_limit numeric(5,2) NOT NULL DEFAULT 30.00,
    absolute_minimum_safety_limit_desc text NOT NULL DEFAULT 'Hard safety limit (30%) below which no aircraft is allowed to fly',
    max_bot_count integer NOT NULL DEFAULT 5,
    max_bot_count_desc text NOT NULL DEFAULT 'Maximum number of active AI competitor bots allowed in the game',
    base_lease_deposit_percentage numeric(5,2) NOT NULL DEFAULT 0.10,
    base_lease_deposit_percentage_desc text NOT NULL DEFAULT 'Down payment percentage required to lease an aircraft (e.g. 0.10 = 10%)',
    created_at timestamp with time zone DEFAULT now(),
    time_scale_multiplier numeric(10,2) NOT NULL DEFAULT 60.00,
    credit_tier_config jsonb NOT NULL DEFAULT '{"tiers":{"Gold":{"min_score":750,"max_secured":75000000,"rate_secured":0.03,"max_financing":60000000,"max_unsecured":30000000,"rate_financing":0.04,"rate_unsecured":0.04},"Silver":{"min_score":600,"max_secured":50000000,"rate_secured":0.04,"max_financing":40000000,"max_unsecured":15000000,"rate_financing":0.05,"rate_unsecured":0.05},"Platinum":{"min_score":900,"max_secured":100000000,"rate_secured":0.02,"max_financing":80000000,"max_unsecured":50000000,"rate_financing":0.03,"rate_unsecured":0.03},"Standard":{"min_score":400,"max_secured":25000000,"rate_secured":0.06,"max_financing":20000000,"max_unsecured":5000000,"rate_financing":0.07,"rate_unsecured":0.07},"Subprime":{"min_score":0,"max_secured":10000000,"rate_secured":0.09,"max_financing":5000000,"max_unsecured":1000000,"rate_financing":0.10,"rate_unsecured":0.10}},"min_loan":100000,"max_active_loans":3}'::jsonb,
    savings_tiers jsonb NOT NULL DEFAULT '{"tiers":[{"rate":0.010,"max_balance":1000000,"min_balance":0},{"rate":0.015,"max_balance":5000000,"min_balance":1000000},{"rate":0.020,"max_balance":10000000,"min_balance":5000000},{"rate":0.025,"max_balance":25000000,"min_balance":10000000},{"rate":0.030,"max_balance":null,"min_balance":25000000}]}'::jsonb,
    crew_cost_per_hour numeric NOT NULL DEFAULT 350.0
);

-- 5. data_retention_policy
CREATE TABLE IF NOT EXISTS public.data_retention_policy (
    key text PRIMARY KEY,
    value_int integer NOT NULL,
    unit text NOT NULL,
    description text NOT NULL,
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- 6. scheduler_config
CREATE TABLE IF NOT EXISTS public.scheduler_config (
    id integer PRIMARY KEY DEFAULT 1,
    job_name text NOT NULL DEFAULT 'skyward_world_tick',
    cron_expression text NOT NULL DEFAULT '* * * * *',
    enabled boolean NOT NULL DEFAULT true,
    max_ticks_per_run integer NOT NULL DEFAULT 100,
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- 7. users
CREATE TABLE IF NOT EXISTS public.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username character varying(50),
    company_name character varying(100) NOT NULL,
    ceo_name character varying(100) NOT NULL,
    cash numeric(20,2) NOT NULL DEFAULT 10000000.00,
    game_current_time timestamp with time zone NOT NULL DEFAULT '2020-01-01 00:00:00+00',
    last_active_at timestamp with time zone NOT NULL DEFAULT now(),
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    net_worth numeric(20,2) DEFAULT 15000000.00,
    hq_airport_iata character varying(3) REFERENCES public.airports(iata),
    auto_grounding_threshold numeric(5,2) DEFAULT 40.00,
    buffered_revenue numeric(20,2) DEFAULT 0.00,
    buffered_ops_cost numeric(20,2) DEFAULT 0.00,
    buffered_lease_cost numeric(20,2) DEFAULT 0.00,
    operational_status character varying NOT NULL DEFAULT 'Active',
    consecutive_negative_days integer NOT NULL DEFAULT 0,
    recovery_streak_days integer NOT NULL DEFAULT 0,
    season_id uuid REFERENCES public.season_clock(id),
    auth_user_id uuid,
    buffered_cargo_revenue numeric(20,2) DEFAULT 0.00,
    onboarding_completed boolean DEFAULT false,
    credit_score integer DEFAULT 500,
    credit_score_updated_at timestamp with time zone,
    credit_tier character varying(10) DEFAULT 'Standard',
    actor_type character varying(10) DEFAULT 'REAL',
    archetype character varying(30)
);

-- 8. fleet_aircraft
CREATE TABLE IF NOT EXISTS public.fleet_aircraft (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid REFERENCES public.users(id),
    aircraft_model_id uuid NOT NULL REFERENCES public.aircraft_models(id),
    acquisition_type character varying(10) NOT NULL,
    condition numeric(5,2) NOT NULL DEFAULT 100.00,
    status character varying(20) NOT NULL DEFAULT 'grounded',
    acquired_at timestamp with time zone NOT NULL DEFAULT now(),
    tail_number character varying(20) NOT NULL,
    economy_seats integer DEFAULT 0,
    business_seats integer DEFAULT 0,
    first_class_seats integer DEFAULT 0,
    nickname character varying(100),
    total_flights integer DEFAULT 0,
    last_a_check_at integer DEFAULT 0,
    last_c_check_at integer DEFAULT 0,
    acquired_game_date timestamp with time zone,
    CONSTRAINT fleet_aircraft_tail_number_key UNIQUE (tail_number)
);

-- 9. route_assignments
CREATE TABLE IF NOT EXISTS public.route_assignments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid REFERENCES public.users(id),
    origin_iata character varying(3) NOT NULL REFERENCES public.airports(iata),
    destination_iata character varying(3) NOT NULL REFERENCES public.airports(iata),
    distance_km double precision NOT NULL,
    ticket_price numeric(10,2) NOT NULL,
    assigned_aircraft_id uuid REFERENCES public.fleet_aircraft(id),
    flights_per_week integer NOT NULL DEFAULT 7,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    status character varying(20) DEFAULT 'active',
    economy_fare numeric,
    business_fare numeric,
    first_fare numeric,
    CONSTRAINT route_assignments_user_origin_dest_key UNIQUE (user_id, origin_iata, destination_iata)
);

-- 10. financial_ledger
CREATE TABLE IF NOT EXISTS public.financial_ledger (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid REFERENCES public.users(id),
    transaction_type character varying(10) NOT NULL,
    category character varying(50) NOT NULL,
    amount numeric(20,2) NOT NULL,
    description text,
    game_date timestamp with time zone NOT NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);

-- 11. financial_ledger_summary
CREATE TABLE IF NOT EXISTS public.financial_ledger_summary (
    actor_id uuid NOT NULL,
    is_bot boolean NOT NULL,
    summary_game_date date NOT NULL,
    summary_month date NOT NULL,
    transaction_type character varying(20) NOT NULL,
    category character varying(50) NOT NULL,
    source_row_count bigint NOT NULL,
    total_amount numeric(20,2) NOT NULL,
    first_game_date timestamp with time zone NOT NULL,
    last_game_date timestamp with time zone NOT NULL,
    first_created_at timestamp with time zone,
    last_created_at timestamp with time zone,
    compacted_at timestamp with time zone NOT NULL DEFAULT now(),
    PRIMARY KEY (actor_id, is_bot, summary_game_date, transaction_type, category)
);

-- 12. loans
CREATE TABLE IF NOT EXISTS public.loans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid REFERENCES public.users(id),
    principal numeric NOT NULL,
    interest_rate numeric NOT NULL DEFAULT 0.05,
    remaining_balance numeric NOT NULL,
    weekly_payment numeric NOT NULL,
    status character varying(20) DEFAULT 'active',
    taken_at timestamp with time zone DEFAULT now(),
    game_date_taken timestamp with time zone,
    paid_off_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    loan_type character varying(20) DEFAULT 'unsecured',
    collateral_aircraft_id uuid REFERENCES public.fleet_aircraft(id),
    missed_payments integer DEFAULT 0,
    credit_score_at_origination integer,
    covenant_min_cash numeric,
    covenant_max_debt_ratio numeric,
    loan_subtype character varying(30) DEFAULT 'cash',
    aircraft_model_id uuid REFERENCES public.aircraft_models(id),
    fleet_aircraft_id uuid REFERENCES public.fleet_aircraft(id),
    purchase_price numeric,
    down_payment numeric,
    term_months integer,
    monthly_payment numeric,
    payments_made integer DEFAULT 0
);

-- 13. credit_scores
CREATE TABLE IF NOT EXISTS public.credit_scores (
    user_id uuid PRIMARY KEY REFERENCES public.users(id),
    score integer NOT NULL DEFAULT 500,
    tier character varying(10) NOT NULL DEFAULT 'Standard',
    fleet_health_score integer DEFAULT 0,
    revenue_stability_score integer DEFAULT 0,
    debt_ratio_score integer DEFAULT 0,
    cash_reserves_score integer DEFAULT 0,
    profit_history_score integer DEFAULT 0,
    computed_at timestamp with time zone DEFAULT now()
);

-- 14. credit_score_history
CREATE TABLE IF NOT EXISTS public.credit_score_history (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id),
    score integer NOT NULL,
    tier character varying(10) NOT NULL,
    fleet_health_score integer DEFAULT 0,
    revenue_stability_score integer DEFAULT 0,
    debt_ratio_score integer DEFAULT 0,
    cash_reserves_score integer DEFAULT 0,
    profit_history_score integer DEFAULT 0,
    game_date timestamp with time zone NOT NULL,
    computed_at timestamp with time zone DEFAULT now(),
    CONSTRAINT credit_score_history_user_game_date_key UNIQUE (user_id, game_date)
);

-- 15. bank_accounts
CREATE TABLE IF NOT EXISTS public.bank_accounts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id),
    account_type character varying(20) NOT NULL DEFAULT 'checking',
    balance numeric(20,2) NOT NULL DEFAULT 0.00,
    interest_rate numeric(6,4) DEFAULT 0.00,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT bank_accounts_user_type_key UNIQUE (user_id, account_type)
);

-- 16. bank_transactions
CREATE TABLE IF NOT EXISTS public.bank_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES public.bank_accounts(id),
    user_id uuid NOT NULL REFERENCES public.users(id),
    transaction_type character varying(20) NOT NULL,
    amount numeric(20,2) NOT NULL,
    balance_after numeric(20,2) NOT NULL,
    description text,
    reference_type character varying(30),
    reference_id uuid,
    game_date timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);

-- 17. achievements
CREATE TABLE IF NOT EXISTS public.achievements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id),
    achievement_type character varying(50) NOT NULL,
    achievement_name character varying(100) NOT NULL,
    description text,
    unlocked_at timestamp with time zone DEFAULT now(),
    game_date timestamp with time zone,
    CONSTRAINT achievements_user_type_name_key UNIQUE (user_id, achievement_type, achievement_name)
);

-- 18. rank_history
CREATE TABLE IF NOT EXISTS public.rank_history (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    is_bot boolean DEFAULT false,
    game_date date NOT NULL,
    rank_position integer NOT NULL,
    net_worth numeric NOT NULL,
    fleet_size integer DEFAULT 0,
    monthly_revenue numeric DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);

-- 19. game_events
CREATE TABLE IF NOT EXISTS public.game_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type character varying(50) NOT NULL,
    title character varying(200) NOT NULL,
    description text,
    effect_type character varying(50) NOT NULL,
    effect_target text,
    effect_value numeric NOT NULL,
    start_game_time timestamp with time zone NOT NULL,
    end_game_time timestamp with time zone NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);

-- 20. world_tick_log
CREATE TABLE IF NOT EXISTS public.world_tick_log (
    id bigint NOT NULL DEFAULT nextval('world_tick_log_id_seq'),
    season_id uuid REFERENCES public.season_clock(id),
    started_at timestamp with time zone NOT NULL DEFAULT now(),
    finished_at timestamp with time zone,
    game_time_before timestamp with time zone,
    game_time_after timestamp with time zone,
    ticks_processed integer NOT NULL DEFAULT 0,
    real_seconds_processed numeric(20,4) NOT NULL DEFAULT 0.0000,
    game_seconds_processed numeric(20,4) NOT NULL DEFAULT 0.0000,
    players_processed integer NOT NULL DEFAULT 0,
    bots_processed integer NOT NULL DEFAULT 0,
    status character varying NOT NULL DEFAULT 'started',
    message text,
    PRIMARY KEY (id)
);

-- 21. world_tick_daily_summary
CREATE TABLE IF NOT EXISTS public.world_tick_daily_summary (
    season_id uuid NOT NULL REFERENCES public.season_clock(id),
    summary_date date NOT NULL,
    status character varying NOT NULL,
    source_row_count bigint NOT NULL,
    first_started_at timestamp with time zone NOT NULL,
    last_finished_at timestamp with time zone,
    first_game_time_before timestamp with time zone,
    last_game_time_after timestamp with time zone,
    total_ticks_processed bigint NOT NULL DEFAULT 0,
    total_real_seconds_processed numeric(20,4) NOT NULL DEFAULT 0.0000,
    total_game_seconds_processed numeric(20,4) NOT NULL DEFAULT 0.0000,
    total_players_processed bigint NOT NULL DEFAULT 0,
    total_bots_processed bigint NOT NULL DEFAULT 0,
    latest_message text,
    compacted_at timestamp with time zone NOT NULL DEFAULT now(),
    PRIMARY KEY (season_id, summary_date, status)
);

-- ============================================================================
-- ── Indexes ──
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_users_season_id ON public.users USING btree (season_id);
CREATE INDEX IF NOT EXISTS idx_users_hq_airport_iata ON public.users USING btree (hq_airport_iata);
CREATE INDEX IF NOT EXISTS idx_users_auth_user_id ON public.users USING btree (auth_user_id);
CREATE INDEX IF NOT EXISTS idx_users_username ON public.users USING btree (username);
CREATE INDEX IF NOT EXISTS idx_users_actor_type ON public.users USING btree (actor_type);

CREATE INDEX IF NOT EXISTS idx_fleet_aircraft_user_id ON public.fleet_aircraft USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_fleet_aircraft_model_id ON public.fleet_aircraft USING btree (aircraft_model_id);
CREATE INDEX IF NOT EXISTS idx_fleet_aircraft_status ON public.fleet_aircraft USING btree (status);
CREATE INDEX IF NOT EXISTS idx_fleet_aircraft_tail_number ON public.fleet_aircraft USING btree (tail_number);

CREATE INDEX IF NOT EXISTS idx_route_assignments_user_id ON public.route_assignments USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_route_assignments_origin ON public.route_assignments USING btree (origin_iata);
CREATE INDEX IF NOT EXISTS idx_route_assignments_destination ON public.route_assignments USING btree (destination_iata);
CREATE INDEX IF NOT EXISTS idx_route_assignments_aircraft ON public.route_assignments USING btree (assigned_aircraft_id);
CREATE INDEX IF NOT EXISTS idx_route_assignments_user_origin_dest ON public.route_assignments USING btree (user_id, origin_iata, destination_iata);
CREATE INDEX IF NOT EXISTS idx_route_assignments_status ON public.route_assignments USING btree (status);

CREATE INDEX IF NOT EXISTS idx_financial_ledger_user_id ON public.financial_ledger USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_financial_ledger_game_date ON public.financial_ledger USING btree (game_date);
CREATE INDEX IF NOT EXISTS idx_financial_ledger_type ON public.financial_ledger USING btree (transaction_type);
CREATE INDEX IF NOT EXISTS idx_financial_ledger_user_date ON public.financial_ledger USING btree (user_id, game_date);

CREATE INDEX IF NOT EXISTS idx_financial_ledger_summary_actor ON public.financial_ledger_summary USING btree (actor_id);
CREATE INDEX IF NOT EXISTS idx_financial_ledger_summary_date ON public.financial_ledger_summary USING btree (summary_game_date);

CREATE INDEX IF NOT EXISTS idx_loans_user_id ON public.loans USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_loans_status ON public.loans USING btree (status);
CREATE INDEX IF NOT EXISTS idx_loans_user_status ON public.loans USING btree (user_id, status);
CREATE INDEX IF NOT EXISTS idx_loans_fleet_aircraft_id ON public.loans USING btree (fleet_aircraft_id);

CREATE INDEX IF NOT EXISTS idx_credit_scores_user_id ON public.credit_scores USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_credit_scores_tier ON public.credit_scores USING btree (tier);

CREATE INDEX IF NOT EXISTS idx_credit_score_history_user ON public.credit_score_history USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_credit_score_history_date ON public.credit_score_history USING btree (game_date);

CREATE INDEX IF NOT EXISTS idx_bank_accounts_user_id ON public.bank_accounts USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_bank_accounts_type ON public.bank_accounts USING btree (account_type);

CREATE INDEX IF NOT EXISTS idx_bank_transactions_account ON public.bank_transactions USING btree (account_id);
CREATE INDEX IF NOT EXISTS idx_bank_transactions_user ON public.bank_transactions USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_bank_transactions_date ON public.bank_transactions USING btree (game_date);

CREATE INDEX IF NOT EXISTS idx_achievements_user_id ON public.achievements USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_achievements_type ON public.achievements USING btree (achievement_type);

CREATE INDEX IF NOT EXISTS idx_rank_history_user ON public.rank_history USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_rank_history_date ON public.rank_history USING btree (game_date);
CREATE INDEX IF NOT EXISTS idx_rank_history_bot_date ON public.rank_history USING btree (is_bot, game_date);

CREATE INDEX IF NOT EXISTS idx_game_events_active ON public.game_events USING btree (is_active);
CREATE INDEX IF NOT EXISTS idx_game_events_type ON public.game_events USING btree (event_type);
CREATE INDEX IF NOT EXISTS idx_game_events_target ON public.game_events USING btree (effect_target);
CREATE INDEX IF NOT EXISTS idx_game_events_time ON public.game_events USING btree (start_game_time, end_game_time);

CREATE INDEX IF NOT EXISTS idx_world_tick_log_season ON public.world_tick_log USING btree (season_id);
CREATE INDEX IF NOT EXISTS idx_world_tick_log_started ON public.world_tick_log USING btree (started_at);
CREATE INDEX IF NOT EXISTS idx_world_tick_log_status ON public.world_tick_log USING btree (status);

CREATE INDEX IF NOT EXISTS idx_world_tick_daily_summary_season ON public.world_tick_daily_summary USING btree (season_id);

CREATE INDEX IF NOT EXISTS idx_airports_country ON public.airports USING btree (country);
CREATE INDEX IF NOT EXISTS idx_airports_demand ON public.airports USING btree (demand_index);

CREATE INDEX IF NOT EXISTS idx_aircraft_models_manufacturer ON public.aircraft_models USING btree (manufacturer);
CREATE INDEX IF NOT EXISTS idx_aircraft_models_type ON public.aircraft_models USING btree (type);

-- ============================================================================
-- ── RLS Policies ──
-- ============================================================================

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fleet_aircraft ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.route_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.financial_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.loans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_score_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users are viewable by everyone" ON public.users;
CREATE POLICY "Users are viewable by everyone" ON public.users FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Users can update own profile" ON public.users;
CREATE POLICY "Users can update own profile" ON public.users FOR UPDATE TO authenticated USING (auth.uid() = auth_user_id);

DROP POLICY IF EXISTS "Fleet aircraft are viewable by everyone" ON public.fleet_aircraft;
CREATE POLICY "Fleet aircraft are viewable by everyone" ON public.fleet_aircraft FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Route assignments are viewable by everyone" ON public.route_assignments;
CREATE POLICY "Route assignments are viewable by everyone" ON public.route_assignments FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Financial ledger is viewable by everyone" ON public.financial_ledger;
CREATE POLICY "Financial ledger is viewable by everyone" ON public.financial_ledger FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Loans are viewable by everyone" ON public.loans;
CREATE POLICY "Loans are viewable by everyone" ON public.loans FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Credit scores are viewable by everyone" ON public.credit_scores;
CREATE POLICY "Credit scores are viewable by everyone" ON public.credit_scores FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Credit score history is viewable by everyone" ON public.credit_score_history;
CREATE POLICY "Credit score history is viewable by everyone" ON public.credit_score_history FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "Bank accounts are viewable by owner" ON public.bank_accounts;
CREATE POLICY "Bank accounts are viewable by owner" ON public.bank_accounts FOR SELECT TO authenticated USING (user_id = public.get_current_user_id());

DROP POLICY IF EXISTS "Bank transactions are viewable by owner" ON public.bank_transactions;
CREATE POLICY "Bank transactions are viewable by owner" ON public.bank_transactions FOR SELECT TO authenticated USING (user_id = public.get_current_user_id());

DROP POLICY IF EXISTS "Achievements are viewable by everyone" ON public.achievements;
CREATE POLICY "Achievements are viewable by everyone" ON public.achievements FOR SELECT TO authenticated USING (true);


-- ============================================================================
-- ── Functions (in dependency order) ──
-- ============================================================================

-- ── Group 1: Utility/Auth (no dependencies) ──

CREATE OR REPLACE FUNCTION public.normalize_username(p_username text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$
    SELECT NULLIF(regexp_replace(lower(trim(COALESCE(p_username, ''))), '[^a-z0-9._-]+', '-', 'g'), '');
$function$;

CREATE OR REPLACE FUNCTION public.build_synthetic_auth_email(p_username text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$
    SELECT public.normalize_username(p_username) || '@skyward.sachiel.id';
$function$;

CREATE OR REPLACE FUNCTION public.get_user_id_for_auth_uid(p_auth_user_id uuid DEFAULT auth.uid())
RETURNS uuid LANGUAGE sql STABLE AS $function$
    SELECT u.id FROM public.users u WHERE u.auth_user_id = p_auth_user_id LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.get_current_user_id()
RETURNS uuid LANGUAGE sql STABLE AS $function$
    SELECT public.get_user_id_for_auth_uid(auth.uid());
$function$;

CREATE OR REPLACE FUNCTION public.require_current_user_id()
RETURNS uuid LANGUAGE plpgsql STABLE AS $function$
DECLARE v_user_id UUID;
BEGIN
    v_user_id := public.get_current_user_id();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authenticated Skyward user profile not found.' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_user_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.haversine_distance(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $function$
DECLARE R NUMERIC := 6371; dlat NUMERIC; dlon NUMERIC; a NUMERIC; c NUMERIC;
BEGIN
    dlat := radians(lat2 - lat1); dlon := radians(lon2 - lon1);
    a := sin(dlat/2)^2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon/2)^2;
    c := 2 * atan2(sqrt(a), sqrt(1-a));
    RETURN R * c;
END;
$function$;

CREATE OR REPLACE FUNCTION public.haversine_distance(lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE AS $function$
DECLARE R DOUBLE PRECISION := 6371.0; dlat DOUBLE PRECISION; dlon DOUBLE PRECISION; a DOUBLE PRECISION; c DOUBLE PRECISION;
BEGIN
    dlat := radians(lat2 - lat1); dlon := radians(lon2 - lon1);
    a := sin(dlat / 2) ^ 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ^ 2;
    c := 2 * atan2(sqrt(a), sqrt(1 - a));
    RETURN R * c;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_hq_prefix(p_airport_iata character varying)
RETURNS character varying LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_country VARCHAR;
BEGIN
    SELECT country INTO v_country FROM airports WHERE iata = p_airport_iata;
    RETURN CASE
        WHEN v_country = 'Indonesia' THEN 'PK-' WHEN v_country = 'Singapore' THEN '9V-'
        WHEN v_country = 'United Kingdom' OR v_country = 'UK' THEN 'G-'
        WHEN v_country = 'Malaysia' THEN '9M-' WHEN v_country = 'Thailand' THEN 'HS-'
        WHEN v_country = 'Philippines' THEN 'RP-' WHEN v_country = 'Vietnam' THEN 'VN-'
        WHEN v_country = 'Japan' THEN 'JA-' WHEN v_country = 'Germany' THEN 'D-'
        WHEN v_country = 'France' THEN 'F-'
        WHEN v_country = 'United States' OR v_country = 'USA' THEN 'N-'
        ELSE '9V-'
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_tail_suffix(p_tail character varying)
RETURNS character varying LANGUAGE plpgsql VOLATILE AS $function$
BEGIN
    IF position('-' in p_tail) > 0 THEN RETURN split_part(p_tail, '-', 2);
    ELSE RETURN right(p_tail, 3); END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_tail_number(p_airport_iata character varying)
RETURNS character varying LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_prefix VARCHAR; v_rand VARCHAR := ''; v_chars VARCHAR := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
BEGIN
    v_prefix := get_hq_prefix(p_airport_iata);
    FOR i IN 1..3 LOOP v_rand := v_rand || substr(v_chars, floor(random() * 26 + 1)::int, 1); END LOOP;
    RETURN v_prefix || v_rand;
END;
$function$;

-- ── Group 2: Calculation helpers ──

CREATE OR REPLACE FUNCTION public.calculate_effective_passenger_capacity(p_model_capacity integer, p_economy_seats integer, p_business_seats integer, p_first_class_seats integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $function$
    SELECT GREATEST(0, COALESCE(NULLIF(COALESCE(p_economy_seats, 0) + COALESCE(p_business_seats, 0) + COALESCE(p_first_class_seats, 0), 0), COALESCE(p_model_capacity, 0)));
$function$;

CREATE OR REPLACE FUNCTION public.calculate_lease_termination_fee(p_lease_price_per_month numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $function$
    SELECT ROUND(COALESCE(p_lease_price_per_month, 0.00) * 0.25, 2);
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_base_fare(p_distance_km double precision)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $function$
    SELECT 50.00 + (COALESCE(p_distance_km, 0.0)::NUMERIC * 0.12);
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_demand_multiplier(p_distance_km double precision, p_ticket_price numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $function$
    SELECT GREATEST(0.00, LEAST(1.50, 1.5 - 0.8 * POWER(COALESCE(p_ticket_price, 0.00) / NULLIF(calculate_route_base_fare(p_distance_km), 0.00), 2)));
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_max_weekly_flights(p_distance_km double precision, p_speed_kmh integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $function$
    SELECT CASE WHEN COALESCE(p_distance_km, 0.0) <= 0.0 OR COALESCE(p_speed_kmh, 0) <= 0 THEN 0
        ELSE FLOOR(168.0 / ((p_distance_km / p_speed_kmh) + 1.0))::INT END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_max_weekly_flights(p_distance_km double precision, p_speed_kmh integer, p_turnaround_hours numeric)
RETURNS integer LANGUAGE sql IMMUTABLE AS $function$
    SELECT CASE WHEN COALESCE(p_distance_km, 0.0) <= 0.0 OR COALESCE(p_speed_kmh, 0) <= 0 THEN 0
        ELSE FLOOR(168.0 / NULLIF((COALESCE(p_distance_km, 0.0) / p_speed_kmh::DOUBLE PRECISION) + COALESCE(p_turnaround_hours, 1.0), 0.0))::INT END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_airport_demand_factor(p_origin_demand integer, p_destination_demand integer)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $function$
    SELECT GREATEST(0.55, LEAST(1.00, 0.55 + (((((COALESCE(p_origin_demand, 50) + COALESCE(p_destination_demand, 50))::NUMERIC) / 2.0) / 100.0) * 0.45)));
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_expected_passengers(p_capacity integer, p_distance_km double precision, p_ticket_price numeric, p_origin_demand integer, p_destination_demand integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $function$
    SELECT GREATEST(0, LEAST(COALESCE(p_capacity, 0), FLOOR(COALESCE(p_capacity, 0) * 0.95 * calculate_airport_demand_factor(p_origin_demand, p_destination_demand) * calculate_route_demand_multiplier(p_distance_km, p_ticket_price))::INT));
$function$;

CREATE OR REPLACE FUNCTION public.calculate_airport_congestion_factor(p_origin_iata character varying)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_total_flights INT;
BEGIN
    SELECT COALESCE(SUM(flights_per_week), 0) INTO v_total_flights FROM route_assignments WHERE origin_iata = p_origin_iata AND status = 'active';
    IF v_total_flights > 50 THEN RETURN GREATEST(0.50, 1.0 - ((v_total_flights - 50) * 0.005)); END IF;
    RETURN 1.0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_hub_bonus(p_origin_iata character varying, p_user_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_hub_routes_count INT;
BEGIN
    SELECT COUNT(*) INTO v_hub_routes_count FROM route_assignments WHERE origin_iata = p_origin_iata AND user_id = p_user_id AND status = 'active';
    IF v_hub_routes_count > 1 THEN RETURN 1.0 + LEAST((v_hub_routes_count - 1) * 0.02, 0.20); END IF;
    RETURN 1.0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_expected_passengers(p_capacity integer, p_distance_km double precision, p_ticket_price numeric, p_origin_demand integer, p_destination_demand integer, p_origin_iata character varying, p_destination_iata character varying, p_user_id uuid)
RETURNS integer LANGUAGE plpgsql STABLE AS $function$
DECLARE v_base_passengers INT; v_competitor_count INT; v_my_frequency INT; v_total_frequency INT; v_competition_factor NUMERIC := 1.0; v_congestion_factor NUMERIC := 1.0; v_hub_bonus NUMERIC := 1.0;
BEGIN
    v_base_passengers := GREATEST(0, LEAST(COALESCE(p_capacity, 0), FLOOR(COALESCE(p_capacity, 0) * 0.95 * calculate_airport_demand_factor(p_origin_demand, p_destination_demand) * calculate_route_demand_multiplier(p_distance_km, p_ticket_price))::INT));
    SELECT COUNT(*) INTO v_competitor_count FROM route_assignments WHERE origin_iata = p_origin_iata AND destination_iata = p_destination_iata AND status = 'active';
    IF v_competitor_count > 1 THEN
        SELECT COALESCE(flights_per_week, 0) INTO v_my_frequency FROM route_assignments WHERE origin_iata = p_origin_iata AND destination_iata = p_destination_iata AND user_id = p_user_id AND status = 'active' LIMIT 1;
        SELECT COALESCE(SUM(flights_per_week), 1) INTO v_total_frequency FROM route_assignments WHERE origin_iata = p_origin_iata AND destination_iata = p_destination_iata AND status = 'active';
        IF v_total_frequency > 0 THEN v_competition_factor := v_my_frequency::NUMERIC / v_total_frequency; END IF;
    END IF;
    v_congestion_factor := calculate_airport_congestion_factor(p_origin_iata);
    v_hub_bonus := calculate_hub_bonus(p_origin_iata, p_user_id);
    RETURN GREATEST(0, FLOOR(v_base_passengers * v_competition_factor * v_congestion_factor * v_hub_bonus)::INT);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_hub_bonus_percentage(p_origin_iata character varying, p_user_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_hub_routes_count INT;
BEGIN
    SELECT COUNT(*) INTO v_hub_routes_count FROM route_assignments WHERE origin_iata = p_origin_iata AND user_id = p_user_id AND status = 'active';
    IF v_hub_routes_count > 1 THEN RETURN LEAST((v_hub_routes_count - 1) * 2.0, 20.0); END IF;
    RETURN 0.0;
END;
$function$;

-- ── Group 3: Trigger functions ──

CREATE OR REPLACE FUNCTION public.trg_assign_active_season_id()
RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE r_season RECORD;
BEGIN
    IF NEW.season_id IS NULL THEN
        SELECT id, current_game_time INTO r_season FROM season_clock WHERE status = 'active' ORDER BY created_at ASC LIMIT 1;
        NEW.season_id := r_season.id;
    ELSE
        SELECT id, current_game_time INTO r_season FROM season_clock WHERE id = NEW.season_id LIMIT 1;
    END IF;
    IF r_season.id IS NOT NULL AND (NEW.game_current_time IS NULL OR NEW.game_current_time < r_season.current_game_time) THEN
        NEW.game_current_time := r_season.current_game_time;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_create_default_bank_account()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    INSERT INTO bank_accounts (user_id, account_type, balance, interest_rate) VALUES (NEW.id, 'checking', NEW.cash, 0.00) ON CONFLICT (user_id, account_type) DO NOTHING;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_fleet_reconcile_net_worth()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.user_id IS NOT NULL THEN UPDATE users SET net_worth = calculate_user_net_worth(OLD.user_id) WHERE id = OLD.user_id; END IF;
        RETURN OLD;
    ELSE
        IF NEW.user_id IS NOT NULL THEN UPDATE users SET net_worth = calculate_user_net_worth(NEW.user_id) WHERE id = NEW.user_id; END IF;
        IF TG_OP = 'UPDATE' THEN IF OLD.user_id IS NOT NULL AND OLD.user_id != COALESCE(NEW.user_id, gen_random_uuid()) THEN UPDATE users SET net_worth = calculate_user_net_worth(OLD.user_id) WHERE id = OLD.user_id; END IF; END IF;
        RETURN NEW;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_set_acquired_game_date()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.acquired_game_date IS NULL THEN
        IF NEW.user_id IS NOT NULL THEN SELECT game_current_time INTO NEW.acquired_game_date FROM users WHERE id = NEW.user_id; END IF;
        NEW.acquired_game_date := COALESCE(NEW.acquired_game_date, NOW());
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_set_default_fare_buckets()
RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE v_base_fare NUMERIC;
BEGIN
    IF NEW.economy_fare IS NULL OR NEW.business_fare IS NULL OR NEW.first_fare IS NULL THEN
        v_base_fare := calculate_route_base_fare(NEW.distance_km);
        NEW.economy_fare  := COALESCE(NEW.economy_fare, v_base_fare);
        NEW.business_fare := COALESCE(NEW.business_fare, ROUND(v_base_fare * 2.5, 2));
        NEW.first_fare    := COALESCE(NEW.first_fare, ROUND(v_base_fare * 4.0, 2));
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_sync_checking_balance()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    UPDATE bank_accounts SET balance = NEW.cash, updated_at = NOW() WHERE user_id = NEW.id AND account_type = 'checking';
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_sync_tail_numbers_on_hq_change()
RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE r_aircraft RECORD; v_prefix VARCHAR; v_suffix VARCHAR; v_new_tail VARCHAR;
BEGIN
    IF OLD.hq_airport_iata IS DISTINCT FROM NEW.hq_airport_iata THEN
        v_prefix := get_hq_prefix(NEW.hq_airport_iata);
        FOR r_aircraft IN SELECT id, tail_number FROM fleet_aircraft WHERE user_id = NEW.id LOOP
            v_suffix := get_tail_suffix(r_aircraft.tail_number); v_new_tail := v_prefix || v_suffix;
            IF EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_new_tail AND id != r_aircraft.id) THEN v_new_tail := generate_tail_number(NEW.hq_airport_iata); END IF;
            UPDATE fleet_aircraft SET tail_number = v_new_tail WHERE id = r_aircraft.id;
        END LOOP;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_update_user_net_worth()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    NEW.net_worth := calculate_user_net_worth(NEW.id);
    RETURN NEW;
END;
$function$;

-- ── Group 4: Core game functions ──

CREATE OR REPLACE FUNCTION public.resolve_active_season_id(p_season_id uuid DEFAULT NULL::uuid)
RETURNS uuid LANGUAGE plpgsql STABLE AS $function$
DECLARE v_season_id UUID;
BEGIN
    IF p_season_id IS NOT NULL THEN RETURN p_season_id; END IF;
    SELECT id INTO v_season_id FROM season_clock WHERE status = 'active' ORDER BY created_at ASC LIMIT 1;
    RETURN v_season_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_credit_tier(p_score integer)
RETURNS character varying LANGUAGE plpgsql STABLE AS $function$
DECLARE v_config JSONB; v_tier_name TEXT; v_tier_data JSONB;
BEGIN
    SELECT credit_tier_config INTO v_config FROM global_game_settings WHERE id = 1;
    IF v_config IS NULL THEN
        RETURN CASE WHEN p_score >= 900 THEN 'Platinum' WHEN p_score >= 750 THEN 'Gold' WHEN p_score >= 600 THEN 'Silver' WHEN p_score >= 400 THEN 'Standard' ELSE 'Subprime' END;
    END IF;
    FOR v_tier_name IN SELECT key FROM jsonb_each(v_config->'tiers') ORDER BY (value->>'min_score')::INT DESC LOOP
        v_tier_data := v_config->'tiers'->v_tier_name;
        IF p_score >= (v_tier_data->>'min_score')::INT THEN RETURN v_tier_name; END IF;
    END LOOP;
    RETURN 'Subprime';
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_user_net_worth(p_user_id uuid)
RETURNS numeric LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_cash NUMERIC; v_fleet_value NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0) INTO v_fleet_value FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = p_user_id AND f.acquisition_type = 'purchase';
    RETURN COALESCE(v_cash, 0) + v_fleet_value;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_credit_score(p_user_id uuid)
RETURNS TABLE(total_score integer, tier character varying, fleet_health integer, revenue_stability integer, debt_ratio integer, cash_reserve integer, profit_history integer)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
    v_user RECORD; v_actor_type VARCHAR(10); v_fleet_count INT := 0; v_avg_condition NUMERIC := 100.0; v_grounded_ratio NUMERIC := 0.0; v_fleet_health NUMERIC := 200.0;
    v_revenue_days INT := 0; v_positive_days INT := 0; v_revenue_stability NUMERIC := 200.0;
    v_total_debt NUMERIC := 0.0; v_net_worth NUMERIC := 0.0; v_debt_ratio NUMERIC := 200.0;
    v_cash NUMERIC := 0.0; v_starting_cash NUMERIC := 15000000.0; v_cash_reserve NUMERIC := 200.0;
    v_total_revenue_30d NUMERIC := 0.0; v_total_expense_30d NUMERIC := 0.0; v_profit_margin NUMERIC := 0.0; v_profit_history NUMERIC := 200.0;
    v_total_score INT; v_tier VARCHAR(10);
BEGIN
    SELECT u.cash, u.net_worth, u.game_current_time, u.actor_type INTO v_user FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN total_score := 500; tier := 'Standard'; fleet_health := 100; revenue_stability := 100; debt_ratio := 100; cash_reserve := 100; profit_history := 100; RETURN NEXT; RETURN; END IF;
    v_actor_type := COALESCE(v_user.actor_type, 'REAL'); v_cash := COALESCE(v_user.cash, 0.0); v_net_worth := COALESCE(v_user.net_worth, 0.0);
    SELECT starting_cash INTO v_starting_cash FROM global_game_settings LIMIT 1; v_starting_cash := COALESCE(v_starting_cash, 15000000.0);
    SELECT COUNT(*)::INT, COALESCE(AVG(condition), 100.0), COALESCE(COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC / NULLIF(COUNT(*), 0), 0.0)
    INTO v_fleet_count, v_avg_condition, v_grounded_ratio FROM fleet_aircraft WHERE user_id = p_user_id;
    IF v_fleet_count > 0 THEN v_fleet_health := (v_avg_condition / 100.0) * 150.0 + 50.0 * (1.0 - v_grounded_ratio); ELSE v_fleet_health := 100.0; END IF;
    SELECT COUNT(*)::INT, COUNT(*) FILTER (WHERE amount > 0)::INT INTO v_revenue_days, v_positive_days FROM financial_ledger WHERE user_id = p_user_id AND transaction_type = 'revenue' AND game_date >= v_user.game_current_time - INTERVAL '30 days';
    IF v_revenue_days > 0 THEN v_revenue_stability := (v_positive_days::NUMERIC / v_revenue_days::NUMERIC) * 200.0; ELSE v_revenue_stability := 100.0; END IF;
    SELECT COALESCE(SUM(remaining_balance), 0) INTO v_total_debt FROM loans WHERE user_id = p_user_id AND status = 'active';
    IF v_net_worth > 0 THEN v_debt_ratio := GREATEST(0, 200.0 - ((v_total_debt / v_net_worth) * 200.0)); ELSE v_debt_ratio := 0.0; END IF;
    IF v_starting_cash > 0 THEN v_cash_reserve := LEAST(200.0, (v_cash / v_starting_cash) * 200.0); ELSE v_cash_reserve := 100.0; END IF;
    SELECT COALESCE(SUM(CASE WHEN transaction_type = 'revenue' THEN amount ELSE 0 END), 0), COALESCE(SUM(CASE WHEN transaction_type = 'expense' THEN amount ELSE 0 END), 0)
    INTO v_total_revenue_30d, v_total_expense_30d FROM financial_ledger WHERE user_id = p_user_id AND game_date >= v_user.game_current_time - INTERVAL '30 days';
    IF v_total_revenue_30d > 0 THEN v_profit_margin := (v_total_revenue_30d - v_total_expense_30d) / v_total_revenue_30d; v_profit_history := LEAST(200.0, 100.0 + (v_profit_margin * 100.0)); ELSE v_profit_history := 100.0; END IF;
    v_total_score := GREATEST(0, LEAST(1000, ROUND(v_fleet_health) + ROUND(v_revenue_stability) + ROUND(v_debt_ratio) + ROUND(v_cash_reserve) + ROUND(v_profit_history)));
    total_score := v_total_score; tier := resolve_credit_tier(v_total_score); fleet_health := ROUND(v_fleet_health)::INT; revenue_stability := ROUND(v_revenue_stability)::INT; debt_ratio := ROUND(v_debt_ratio)::INT; cash_reserve := ROUND(v_cash_reserve)::INT; profit_history := ROUND(v_profit_history)::INT; RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_credit_score(p_user_id uuid, p_game_date timestamp with time zone)
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_score RECORD; v_tier VARCHAR(10);
BEGIN
    SELECT * INTO v_score FROM calculate_credit_score(p_user_id) LIMIT 1;
    IF NOT FOUND THEN RETURN; END IF;
    v_tier := CASE WHEN v_score.total_score >= 900 THEN 'Platinum' WHEN v_score.total_score >= 750 THEN 'Gold' WHEN v_score.total_score >= 600 THEN 'Silver' WHEN v_score.total_score >= 400 THEN 'Standard' ELSE 'Subprime' END;
    INSERT INTO credit_scores (user_id, score, tier, fleet_health_score, revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score, computed_at)
    VALUES (p_user_id, v_score.total_score, v_tier, v_score.fleet_health, v_score.revenue_stability, v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history, NOW())
    ON CONFLICT (user_id) DO UPDATE SET score = EXCLUDED.score, tier = EXCLUDED.tier, fleet_health_score = EXCLUDED.fleet_health_score, revenue_stability_score = EXCLUDED.revenue_stability_score, debt_ratio_score = EXCLUDED.debt_ratio_score, cash_reserves_score = EXCLUDED.cash_reserves_score, profit_history_score = EXCLUDED.profit_history_score, computed_at = EXCLUDED.computed_at;
    UPDATE users SET credit_score = v_score.total_score, credit_tier = v_tier WHERE id = p_user_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_credit_at_day_boundary(p_user_id uuid, p_game_date timestamp with time zone)
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
BEGIN
    PERFORM update_credit_score(p_user_id, p_game_date);
    INSERT INTO credit_score_history (user_id, game_date, score, tier) SELECT p_user_id, p_game_date, cs.score, cs.tier FROM credit_scores cs WHERE cs.user_id = p_user_id ON CONFLICT (user_id, game_date) DO NOTHING;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_credit_report()
RETURNS TABLE(current_score integer, fleet_health integer, revenue_stability integer, debt_ratio integer, cash_reserve integer, profit_history integer, credit_tier character varying, max_unsecured_loan numeric, max_secured_loan numeric, max_financing_amount numeric, base_interest_rate numeric, suggestions text[])
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID; v_score RECORD; v_tier VARCHAR(20); v_config JSONB; v_tier_cfg JSONB; v_sugg TEXT[] := '{}';
BEGIN
    v_user_id := require_current_user_id();
    SELECT credit_tier_config INTO v_config FROM global_game_settings WHERE id = 1;
    SELECT * INTO v_score FROM calculate_credit_score(v_user_id) LIMIT 1;
    IF NOT FOUND THEN current_score := 500; fleet_health := 100; revenue_stability := 100; debt_ratio := 100; cash_reserve := 100; profit_history := 100; credit_tier := 'Standard'; max_unsecured_loan := 5000000; max_secured_loan := 25000000; max_financing_amount := 20000000; base_interest_rate := 0.07; suggestions := ARRAY['Build your fleet and routes to establish credit history.']; RETURN NEXT; RETURN; END IF;
    v_tier := resolve_credit_tier(v_score.total_score);
    UPDATE users SET credit_score = v_score.total_score, credit_tier = v_tier WHERE id = v_user_id;
    INSERT INTO credit_scores (user_id, score, tier, fleet_health_score, revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score, computed_at) VALUES (v_user_id, v_score.total_score, v_tier, v_score.fleet_health, v_score.revenue_stability, v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history, NOW()) ON CONFLICT (user_id) DO UPDATE SET score = EXCLUDED.score, tier = EXCLUDED.tier, fleet_health_score = EXCLUDED.fleet_health_score, revenue_stability_score = EXCLUDED.revenue_stability_score, debt_ratio_score = EXCLUDED.debt_ratio_score, cash_reserves_score = EXCLUDED.cash_reserves_score, profit_history_score = EXCLUDED.profit_history_score, computed_at = EXCLUDED.computed_at;
    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);
    current_score := v_score.total_score; fleet_health := v_score.fleet_health; revenue_stability := v_score.revenue_stability; debt_ratio := v_score.debt_ratio; cash_reserve := v_score.cash_reserve; profit_history := v_score.profit_history; credit_tier := v_tier;
    max_unsecured_loan := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000); max_secured_loan := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000); max_financing_amount := COALESCE((v_tier_cfg->>'max_financing')::NUMERIC, 20000000); base_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
    v_sugg := '{}';
    IF v_score.fleet_health < 100 THEN v_sugg := array_append(v_sugg, 'Repair grounded aircraft to improve fleet health.'); END IF;
    IF v_score.debt_ratio < 100 THEN v_sugg := array_append(v_sugg, 'Reduce outstanding debt to improve your debt ratio.'); END IF;
    IF v_score.cash_reserve < 100 THEN v_sugg := array_append(v_sugg, 'Build cash reserves for financial stability.'); END IF;
    IF v_score.revenue_stability < 100 THEN v_sugg := array_append(v_sugg, 'Establish consistent revenue from routes.'); END IF;
    IF array_length(v_sugg, 1) IS NULL THEN v_sugg := ARRAY['Your credit profile is healthy. Keep it up!']; END IF;
    suggestions := v_sugg; RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_rank_snapshot(p_game_date date)
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
BEGIN
    INSERT INTO rank_history (user_id, is_bot, game_date, rank_position, net_worth, fleet_size, monthly_revenue)
    SELECT sub.id, (sub.actor_type = 'AI'), p_game_date, ROW_NUMBER() OVER (ORDER BY sub.net_worth DESC), sub.net_worth, sub.fleet_count, sub.monthly_rev
    FROM (SELECT u.id, u.actor_type, u.cash + COALESCE((SELECT SUM(am.purchase_price * 0.7) FROM fleet_aircraft uf JOIN aircraft_models am ON uf.aircraft_model_id = am.id WHERE uf.user_id = u.id AND uf.status = 'active'), 0) AS net_worth,
        (SELECT COUNT(*)::INT FROM fleet_aircraft WHERE user_id = u.id AND status = 'active') AS fleet_count,
        COALESCE((SELECT SUM(amount) FROM financial_ledger WHERE user_id = u.id AND transaction_type = 'revenue' AND game_date >= u.game_current_time - INTERVAL '30 days'), 0.00) AS monthly_rev
    FROM users u WHERE COALESCE(u.operational_status, 'Active') != 'Bankrupt') sub;
END;
$function$;

CREATE OR REPLACE FUNCTION public.reconcile_all_net_worths()
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
BEGIN UPDATE users u SET net_worth = calculate_user_net_worth(u.id); END;
$function$;

-- ── Group 5: Simulation functions ──

CREATE OR REPLACE FUNCTION public.generate_game_events(p_game_time timestamp with time zone)
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_roll NUMERIC; v_airport_iata VARCHAR(3); v_effect_value NUMERIC; v_title TEXT; v_description TEXT;
BEGIN
    v_roll := random(); IF v_roll > 0.05 THEN RETURN; END IF;
    CASE floor(random() * 4)
        WHEN 0 THEN v_effect_value := 0.7 + (random() * 0.6); IF v_effect_value > 1.0 THEN v_title := 'Fuel Price Surge'; v_description := 'Global fuel prices have increased by ' || ROUND((v_effect_value - 1) * 100) || '%'; ELSE v_title := 'Fuel Price Drop'; v_description := 'Global fuel prices have decreased by ' || ROUND((1 - v_effect_value) * 100) || '%'; END IF; INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time) VALUES ('fuel_shock', v_title, v_description, 'fuel_price', 'global', v_effect_value, p_game_time, p_game_time + INTERVAL '72 hours');
        WHEN 1 THEN SELECT iata INTO v_airport_iata FROM airports ORDER BY random() LIMIT 1; IF v_airport_iata IS NULL THEN RETURN; END IF; v_effect_value := 1.2 + (random() * 0.3); v_title := 'Demand Surge at ' || v_airport_iata; v_description := 'Increased passenger demand at ' || v_airport_iata || ' airport'; INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time) VALUES ('demand_surge', v_title, v_description, 'demand_index', v_airport_iata, v_effect_value, p_game_time, p_game_time + INTERVAL '48 hours');
        WHEN 2 THEN SELECT iata INTO v_airport_iata FROM airports ORDER BY random() LIMIT 1; IF v_airport_iata IS NULL THEN RETURN; END IF; v_effect_value := 0.5 + (random() * 0.3); v_title := 'Weather Disruption at ' || v_airport_iata; v_description := 'Severe weather reducing capacity at ' || v_airport_iata || ' by ' || ROUND((1 - v_effect_value) * 100) || '%'; INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time) VALUES ('weather_disruption', v_title, v_description, 'demand_index', v_airport_iata, v_effect_value, p_game_time, p_game_time + INTERVAL '24 hours');
        WHEN 3 THEN v_effect_value := 0.85 + (random() * 0.3); v_title := 'Maintenance Cost Change'; v_description := 'Aircraft maintenance costs ' || CASE WHEN v_effect_value > 1.0 THEN 'increased' ELSE 'decreased' END || ' by ' || ROUND(ABS(v_effect_value - 1) * 100) || '%'; INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time) VALUES ('maintenance_shock', v_title, v_description, 'maintenance_cost', 'global', v_effect_value, p_game_time, p_game_time + INTERVAL '96 hours');
    END CASE;
END;
$function$;

CREATE OR REPLACE FUNCTION public.deactivate_expired_events(p_game_time timestamp with time zone)
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
BEGIN UPDATE game_events SET is_active = false WHERE is_active = true AND end_game_time <= p_game_time; END;
$function$;

CREATE OR REPLACE FUNCTION public.process_loan_payments(p_user_id uuid, p_game_date timestamp with time zone)
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_actor_type VARCHAR(10); r_loan RECORD; v_cash NUMERIC; v_payment NUMERIC; v_late_fee NUMERIC;
BEGIN
    SELECT actor_type INTO v_actor_type FROM users WHERE id = p_user_id; IF NOT FOUND THEN RETURN; END IF;
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    FOR r_loan IN SELECT * FROM loans WHERE user_id = p_user_id AND status = 'active' ORDER BY taken_at ASC LOOP
        IF v_actor_type = 'AI' THEN
            IF v_cash >= r_loan.weekly_payment THEN UPDATE users SET cash = cash - r_loan.weekly_payment WHERE id = p_user_id; v_cash := v_cash - r_loan.weekly_payment; UPDATE loans SET remaining_balance = remaining_balance - r_loan.weekly_payment WHERE id = r_loan.id; IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0 WHERE id = r_loan.id; END IF;
            ELSE UPDATE loans SET remaining_balance = remaining_balance * 1.10, missed_payments = missed_payments + 1 WHERE id = r_loan.id; IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id; END IF; END IF;
        ELSE
            v_payment := r_loan.weekly_payment;
            IF v_cash >= v_payment THEN v_cash := v_cash - v_payment; UPDATE users SET cash = v_cash WHERE id = p_user_id; UPDATE loans SET remaining_balance = remaining_balance - v_payment WHERE id = r_loan.id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'expense', 'loan_payment', v_payment, 'Weekly loan payment', p_game_date); IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0 WHERE id = r_loan.id; END IF;
            ELSE v_late_fee := v_payment * 0.10; UPDATE loans SET remaining_balance = remaining_balance + v_late_fee, missed_payments = missed_payments + 1 WHERE id = r_loan.id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'expense', 'loan_late_fee', v_late_fee, 'Loan payment late fee', p_game_date); IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id; IF r_loan.collateral_aircraft_id IS NOT NULL THEN UPDATE fleet_aircraft SET status = 'grounded' WHERE id = r_loan.collateral_aircraft_id; END IF; END IF; END IF;
        END IF;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_aircraft_financing_payments(p_user_id uuid, p_game_date timestamp with time zone)
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_loan RECORD; v_cash NUMERIC; v_payment NUMERIC; v_late_fee NUMERIC;
BEGIN
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    FOR v_loan IN SELECT * FROM loans WHERE user_id = p_user_id AND loan_type = 'aircraft_financing' AND status = 'active' LOOP
        v_payment := v_loan.monthly_payment;
        IF v_cash >= v_payment THEN UPDATE users SET cash = cash - v_payment WHERE id = p_user_id; v_cash := v_cash - v_payment; UPDATE loans SET remaining_balance = remaining_balance - v_payment, payments_made = payments_made + 1 WHERE id = v_loan.id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'expense', 'aircraft_financing', v_payment, 'Aircraft financing payment', p_game_date); IF (SELECT remaining_balance FROM loans WHERE id = v_loan.id) <= 0 THEN UPDATE loans SET status = 'paid_off', paid_off_at = NOW(), remaining_balance = 0 WHERE id = v_loan.id; END IF;
        ELSE v_late_fee := v_payment * 0.05; UPDATE loans SET remaining_balance = remaining_balance + v_late_fee, missed_payments = missed_payments + 1 WHERE id = v_loan.id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'expense', 'aircraft_financing_late_fee', v_late_fee, 'Aircraft financing late fee', p_game_date); IF (SELECT missed_payments FROM loans WHERE id = v_loan.id) >= 3 THEN UPDATE loans SET status = 'repossessed' WHERE id = v_loan.id; IF v_loan.fleet_aircraft_id IS NOT NULL THEN UPDATE fleet_aircraft SET status = 'grounded' WHERE id = v_loan.fleet_aircraft_id; END IF; END IF; END IF;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_bot_loan_payments(p_bot_id uuid, p_game_date timestamp with time zone)
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
BEGIN PERFORM process_loan_payments(p_bot_id, p_game_date); END;
$function$;

CREATE OR REPLACE FUNCTION public.accrue_savings_interest(p_user_id uuid, p_game_date timestamp with time zone)
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
DECLARE r_account RECORD; v_daily_rate NUMERIC; v_interest NUMERIC; v_config JSONB; v_tier JSONB; v_new_rate NUMERIC;
BEGIN
    SELECT savings_tiers INTO v_config FROM global_game_settings WHERE id = 1;
    FOR r_account IN SELECT ba.* FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'savings' AND ba.balance > 0 LOOP
        v_new_rate := 0.01;
        IF v_config IS NOT NULL THEN FOR v_tier IN SELECT jsonb_array_elements(v_config->'tiers') LOOP IF r_account.balance >= (v_tier->>'min_balance')::NUMERIC AND (v_tier->>'max_balance' IS NULL OR r_account.balance < (v_tier->>'max_balance')::NUMERIC) THEN v_new_rate := (v_tier->>'rate')::NUMERIC; EXIT; END IF; END LOOP; END IF;
        IF r_account.interest_rate != v_new_rate THEN UPDATE bank_accounts SET interest_rate = v_new_rate WHERE id = r_account.id; END IF;
        v_daily_rate := v_new_rate / 365.0; v_interest := ROUND(r_account.balance * v_daily_rate, 2);
        IF v_interest > 0 THEN UPDATE bank_accounts SET balance = balance + v_interest, updated_at = NOW() WHERE id = r_account.id; UPDATE users SET cash = cash + v_interest WHERE id = r_account.user_id; INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date) VALUES (r_account.id, r_account.user_id, 'interest', v_interest, r_account.balance + v_interest, 'Daily interest accrual (' || (v_new_rate * 100)::TEXT || '% APY)', p_game_date); END IF;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_achievements(p_user_id uuid, p_game_time timestamp with time zone)
RETURNS TABLE(achievement_name character varying, achievement_type character varying)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_cash NUMERIC; v_net_worth NUMERIC; v_fleet_count INT; v_route_count INT; v_hub_routes INT; v_has_first_class BOOLEAN; v_distress_recovered BOOLEAN; v_achievement_count_before INT; v_achievement_count_after INT;
BEGIN
    SELECT COUNT(*) INTO v_achievement_count_before FROM achievements WHERE user_id = p_user_id;
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id;
    SELECT COUNT(*) INTO v_fleet_count FROM fleet_aircraft WHERE user_id = p_user_id AND status = 'active';
    SELECT COUNT(*) INTO v_route_count FROM route_assignments WHERE user_id = p_user_id AND status = 'active';
    SELECT v_cash + COALESCE(SUM(am.purchase_price * 0.7), 0) INTO v_net_worth FROM fleet_aircraft uf JOIN aircraft_models am ON uf.aircraft_model_id = am.id WHERE uf.user_id = p_user_id AND uf.status = 'active';
    SELECT MAX(cnt) INTO v_hub_routes FROM (SELECT origin_iata, COUNT(*) AS cnt FROM route_assignments WHERE user_id = p_user_id AND status = 'active' GROUP BY origin_iata) sub;
    SELECT EXISTS(SELECT 1 FROM fleet_aircraft WHERE user_id = p_user_id AND first_class_seats > 0) INTO v_has_first_class;
    SELECT COALESCE(recovery_streak_days, 0) >= 3 AND COALESCE(operational_status, 'Active') = 'Active' INTO v_distress_recovered FROM users WHERE id = p_user_id;
    IF v_route_count >= 1 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'first_flight', 'First Flight', 'Established your first route', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_fleet_count >= 10 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'fleet_10', 'Fleet Commander', 'Operate 10 aircraft', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_fleet_count >= 50 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'fleet_50', 'Air Fleet Admiral', 'Operate 50 aircraft', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_net_worth >= 1000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'millionaire', 'Millionaire', 'Net worth exceeds $1M', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_net_worth >= 10000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'multi_millionaire', 'Multi-Millionaire', 'Net worth exceeds $10M', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_net_worth >= 100000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'hundred_million', 'Aviation Mogul', 'Net worth exceeds $100M', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_net_worth >= 1000000000 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'billionaire', 'Aviation Billionaire', 'Net worth exceeds $1B', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_route_count >= 25 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'route_master', 'Route Master', '25 active routes', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF COALESCE(v_hub_routes, 0) >= 10 THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'hub_builder', 'Hub Builder', '10+ routes from a single airport', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_has_first_class THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'first_class', 'First Class', 'Configured first-class cabin', p_game_time) ON CONFLICT DO NOTHING; END IF;
    IF v_distress_recovered THEN INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date) VALUES (p_user_id, 'survivor', 'Survivor', 'Recovered from distress status', p_game_time) ON CONFLICT DO NOTHING; END IF;
    SELECT COUNT(*) INTO v_achievement_count_after FROM achievements WHERE user_id = p_user_id;
    IF v_achievement_count_after > v_achievement_count_before THEN RETURN QUERY SELECT a.achievement_name, a.achievement_type FROM achievements a WHERE a.user_id = p_user_id AND a.id NOT IN (SELECT a2.id FROM achievements a2 WHERE a2.user_id = p_user_id ORDER BY a2.unlocked_at ASC LIMIT v_achievement_count_before); END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    r_bot RECORD; v_model_id UUID; v_model_name VARCHAR; v_lease_price NUMERIC; v_purchase_price NUMERIC; v_capacity INT; v_speed_kmh NUMERIC; v_range_km NUMERIC; v_deposit_pct NUMERIC; v_deposit_amount NUMERIC; v_tail VARCHAR(20); v_new_aircraft_id UUID; v_origin_iata VARCHAR(3); v_dest_iata VARCHAR(3); v_distance DOUBLE PRECISION; v_fleet_count INT; v_route_count INT; v_idle_aircraft_count INT; v_idle_aircraft_id UUID; v_idle_tail VARCHAR(20); v_idle_condition NUMERIC; v_idle_model_name VARCHAR; v_idle_capacity INT; v_idle_speed NUMERIC; v_idle_range NUMERIC; v_grounded_aircraft_id UUID; v_grounded_condition NUMERIC; v_grounded_acquisition_type VARCHAR; v_grounded_model_name VARCHAR; v_grounded_lease_price NUMERIC; v_grounded_purchase_price NUMERIC; v_repair_cost NUMERIC; v_target_fleet_cap INT; v_min_cash_reserve NUMERIC; v_growth_chance NUMERIC; v_target_distance DOUBLE PRECISION; v_target_price_multiplier NUMERIC; v_target_schedule_ratio NUMERIC; v_effective_threshold NUMERIC(5,2); v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00; v_selected_route_id UUID; v_selected_flights INT; v_selected_base_fare NUMERIC; v_max_weekly_flights INT; v_target_flights INT; v_target_price NUMERIC; v_bot_cash NUMERIC; v_grounded_count INT; v_negative_days INT; v_starting_cash NUMERIC := 15000000.00; v_attempts INT; v_inserted BOOLEAN; v_economy INT; v_business INT; v_first INT; r_route RECORD; v_human_competitors INT; v_new_price NUMERIC; v_base_fare NUMERIC; v_purchase_capacity INT; v_active_loans INT; v_loan_record RECORD; v_fin_model_id UUID; v_fin_model_price NUMERIC; v_credit_score INT; v_credit_tier VARCHAR(10);
BEGIN
    SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1; v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
    FOR r_bot IN SELECT * FROM users WHERE actor_type = 'AI' LOOP
        v_bot_cash := COALESCE(r_bot.cash, 0.00); v_origin_iata := r_bot.hq_airport_iata;
        v_effective_threshold := GREATEST(v_absolute_minimum_safety_limit, COALESCE(r_bot.auto_grounding_threshold, 40.00));
        IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < -5000000.00 THEN UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id; UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id; UPDATE loans SET status = 'defaulted', remaining_balance = 0 WHERE user_id = r_bot.id AND status = 'active'; CONTINUE; END IF;
        CASE r_bot.archetype WHEN 'Regional' THEN v_target_fleet_cap := 8; v_min_cash_reserve := 3500000.00; v_growth_chance := 0.20; v_target_distance := 900.0; v_target_price_multiplier := 0.95; v_target_schedule_ratio := 0.72; WHEN 'Aggressive' THEN v_target_fleet_cap := 14; v_min_cash_reserve := 4500000.00; v_growth_chance := 0.26; v_target_distance := 1800.0; v_target_price_multiplier := 1.02; v_target_schedule_ratio := 0.82; ELSE v_target_fleet_cap := 10; v_min_cash_reserve := 7000000.00; v_growth_chance := 0.16; v_target_distance := 4200.0; v_target_price_multiplier := 1.18; v_target_schedule_ratio := 0.58; END CASE;
        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
        SELECT COUNT(*)::INT INTO v_idle_aircraft_count FROM fleet_aircraft f WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);
        SELECT f.id, f.condition, f.acquisition_type, m.model_name, m.lease_price_per_month, m.purchase_price INTO v_grounded_aircraft_id, v_grounded_condition, v_grounded_acquisition_type, v_grounded_model_name, v_grounded_lease_price, v_grounded_purchase_price FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND (f.status = 'grounded' OR f.condition < v_effective_threshold) ORDER BY f.condition DESC LIMIT 1;
        IF v_grounded_aircraft_id IS NOT NULL THEN v_repair_cost := CASE WHEN v_grounded_acquisition_type = 'lease' THEN (100.00 - v_grounded_condition) * (COALESCE(v_grounded_lease_price, 0.00) * 0.50) ELSE (100.00 - v_grounded_condition) * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005) END; IF v_repair_cost > 0 AND v_bot_cash >= (v_repair_cost + 500000.00) THEN UPDATE users SET cash = cash - v_repair_cost WHERE id = r_bot.id; UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = v_grounded_aircraft_id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (r_bot.id, 'expense', 'aircraft_repair', v_repair_cost, 'Bot maintenance recovery completed for ' || v_grounded_model_name, r_bot.game_current_time); v_bot_cash := v_bot_cash - v_repair_cost; END IF; END IF;
        IF v_bot_cash < 3000000.00 OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN SELECT r.id, r.flights_per_week, (50.00 + (r.distance_km * 0.12))::NUMERIC INTO v_selected_route_id, v_selected_flights, v_selected_base_fare FROM route_assignments r WHERE r.user_id = r_bot.id ORDER BY (r.ticket_price / NULLIF((50.00 + (r.distance_km * 0.12)), 0)) DESC, r.flights_per_week DESC LIMIT 1; IF v_selected_route_id IS NOT NULL THEN IF v_selected_flights > 8 THEN UPDATE route_assignments SET flights_per_week = GREATEST(6, flights_per_week - CASE r_bot.archetype WHEN 'Regional' THEN 6 WHEN 'Aggressive' THEN 4 ELSE 2 END), ticket_price = GREATEST(ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2), ROUND((ticket_price * 0.90)::numeric, 2)) WHERE id = v_selected_route_id; ELSE DELETE FROM route_assignments WHERE id = v_selected_route_id; END IF; END IF; END IF;
        IF v_fleet_count < v_target_fleet_cap AND v_bot_cash > v_min_cash_reserve AND COALESCE(r_bot.consecutive_negative_days, 0) = 0 AND v_idle_aircraft_count = 0 AND v_route_count >= v_fleet_count AND random() < v_growth_chance THEN
            v_model_id := NULL; v_model_name := NULL; v_lease_price := NULL; v_purchase_price := NULL; v_capacity := NULL;
            IF r_bot.archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600' LIMIT 1; ELSIF r_bot.archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' AND model_name = 'A320neo' LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' AND model_name = '787-9' LIMIT 1; END IF;
            IF v_model_id IS NULL THEN IF r_bot.archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' ORDER BY capacity DESC LIMIT 1; ELSIF r_bot.archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' ORDER BY capacity DESC LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' ORDER BY capacity DESC LIMIT 1; END IF; END IF;
            v_deposit_amount := COALESCE(v_lease_price, 0.00) * (v_deposit_pct * 10.0);
            IF v_model_id IS NOT NULL AND v_bot_cash >= v_deposit_amount THEN v_tail := generate_tail_number(r_bot.hq_airport_iata); v_new_aircraft_id := gen_random_uuid(); IF r_bot.archetype = 'Regional' THEN v_economy := FLOOR(v_capacity * 0.80); v_business := FLOOR(v_capacity * 0.15); v_first := v_capacity - v_economy - v_business; ELSIF r_bot.archetype = 'Aggressive' THEN v_economy := FLOOR(v_capacity * 0.70); v_business := FLOOR(v_capacity * 0.20); v_first := v_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_capacity * 0.50); v_business := FLOOR(v_capacity * 0.30); v_first := v_capacity - v_economy - v_business; END IF; INSERT INTO fleet_aircraft (id, user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats) VALUES (v_new_aircraft_id, r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first); UPDATE users SET cash = cash - v_deposit_amount WHERE id = r_bot.id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (r_bot.id, 'expense', 'aircraft_lease', v_deposit_amount, 'Leased aircraft ' || v_model_name || ' with Call Sign: ' || v_tail || ' - Downpayment deposit', r_bot.game_current_time); v_bot_cash := v_bot_cash - v_deposit_amount; END IF;
        END IF;
        IF v_bot_cash > (v_starting_cash * 3) AND v_fleet_count < v_target_fleet_cap THEN SELECT id, purchase_price, capacity INTO v_model_id, v_purchase_price, v_purchase_capacity FROM aircraft_models WHERE range_km >= v_target_distance ORDER BY purchase_price ASC LIMIT 1; IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN IF r_bot.archetype = 'Regional' THEN v_economy := FLOOR(v_purchase_capacity * 0.80); v_business := FLOOR(v_purchase_capacity * 0.15); v_first := v_purchase_capacity - v_economy - v_business; ELSIF r_bot.archetype = 'Aggressive' THEN v_economy := FLOOR(v_purchase_capacity * 0.70); v_business := FLOOR(v_purchase_capacity * 0.20); v_first := v_purchase_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_purchase_capacity * 0.50); v_business := FLOOR(v_purchase_capacity * 0.30); v_first := v_purchase_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (user_id, aircraft_model_id, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats) VALUES (r_bot.id, v_model_id, v_tail, 'purchase', 100.00, 'active', v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN UPDATE users SET cash = cash - v_purchase_price WHERE id = r_bot.id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (r_bot.id, 'expense', 'acquisition', v_purchase_price, 'Aircraft purchase: ' || v_tail, r_bot.game_current_time); v_bot_cash := v_bot_cash - v_purchase_price; END IF; END IF; END IF;
        SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
        SELECT f.id, f.tail_number, f.condition, m.model_name, m.capacity, m.speed_kmh, m.range_km INTO v_idle_aircraft_id, v_idle_tail, v_idle_condition, v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id) ORDER BY f.condition DESC LIMIT 1;
        IF v_idle_aircraft_id IS NOT NULL AND v_route_count < v_target_fleet_cap THEN v_attempts := 0; v_inserted := false; WHILE v_attempts < 20 AND NOT v_inserted LOOP SELECT iata INTO v_dest_iata FROM airports WHERE iata != v_origin_iata ORDER BY demand_index DESC, random() LIMIT 1; IF v_dest_iata IS NULL THEN EXIT; END IF; SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude) INTO v_distance FROM airports o, airports d WHERE o.iata = v_origin_iata AND d.iata = v_dest_iata; IF v_distance > 0 AND v_distance <= v_idle_range THEN v_base_fare := 50.00 + (v_distance * 0.12); v_target_price := ROUND(v_base_fare * v_target_price_multiplier, 2); v_max_weekly_flights := calculate_route_max_weekly_flights(v_distance, v_idle_speed); v_target_flights := GREATEST(1, FLOOR(v_max_weekly_flights * v_target_schedule_ratio)); BEGIN INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week) VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, v_target_price, v_idle_aircraft_id, v_target_flights); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; ELSE v_attempts := v_attempts + 1; END IF; END LOOP; END IF;
        FOR r_route IN SELECT ra.*, m.speed_kmh, m.range_km, m.turnaround_hours FROM route_assignments ra JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id JOIN aircraft_models m ON m.id = fa.aircraft_model_id WHERE ra.user_id = r_bot.id AND ra.status = 'active' LOOP SELECT COUNT(*) INTO v_human_competitors FROM route_assignments WHERE origin_iata = r_route.origin_iata AND destination_iata = r_route.destination_iata AND status = 'active' AND user_id != r_bot.id AND user_id IN (SELECT id FROM users WHERE actor_type = 'REAL'); IF v_human_competitors > 0 THEN v_base_fare := 50.00 + (r_route.distance_km * 0.12); v_new_price := ROUND(v_base_fare * v_target_price_multiplier * CASE WHEN r_route.ticket_price > v_base_fare * 1.3 THEN 0.95 ELSE 1.0 END, 2); IF v_new_price != r_route.ticket_price THEN UPDATE route_assignments SET ticket_price = v_new_price WHERE id = r_route.id; END IF; END IF; END LOOP;
        SELECT COUNT(*) INTO v_active_loans FROM loans WHERE user_id = r_bot.id AND status = 'active'; IF v_active_loans = 0 AND v_bot_cash < v_starting_cash * 0.5 AND v_bot_cash > 1000000 THEN PERFORM bot_take_loan(r_bot.id, LEAST(5000000, v_starting_cash - v_bot_cash)); END IF;
        UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_player_simulation_to_time(p_user_id uuid, p_target_game_time timestamp with time zone)
RETURNS TABLE(game_time timestamp with time zone, cash numeric, flights_run integer, elapsed_days numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE r_user RECORD; v_route RECORD; v_flight_hours NUMERIC; v_revenue NUMERIC; v_ops_cost NUMERIC; v_lease_cost NUMERIC; v_net NUMERIC := 0; v_flights_run INT := 0; v_cash_after NUMERIC; v_elapsed_days NUMERIC; v_wear_per_cycle NUMERIC(8,4); v_gross_damage NUMERIC(20,4); v_self_healing_credit NUMERIC(20,4); v_net_damage NUMERIC(20,4); v_buffered_rev_accum NUMERIC(20,2) := 0.00; v_buffered_ops_accum NUMERIC(20,2) := 0.00; v_buffered_lease_accum NUMERIC(20,2) := 0.00; v_buffered_cargo_accum NUMERIC(20,2) := 0.00; v_cargo_rev NUMERIC(20,2); v_turnaround_hours NUMERIC; v_demand_multiplier NUMERIC; v_crew_cost NUMERIC; v_fuel_price NUMERIC; v_seasonal_factor NUMERIC;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'User not found: %', p_user_id; END IF;
    SELECT COALESCE(fuel_price_per_liter, 0.85), COALESCE(crew_cost_per_hour, 350.0) INTO v_fuel_price, v_crew_cost FROM global_game_settings LIMIT 1;
    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;
    FOR v_route IN SELECT ur.*, am.fuel_burn_per_km, am.speed_kmh, am.turnaround_hours, am.capacity, am.lease_price_per_month, a1.demand_index AS origin_demand, a2.demand_index AS dest_demand FROM route_assignments ur JOIN fleet_aircraft fa ON fa.id = ur.assigned_aircraft_id JOIN aircraft_models am ON am.id = fa.aircraft_model_id JOIN airports a1 ON a1.iata = ur.origin_iata JOIN airports a2 ON a2.iata = ur.destination_iata WHERE ur.user_id = p_user_id AND ur.status = 'active' AND fa.status = 'active' AND fa.condition >= COALESCE(r_user.auto_grounding_threshold, 40.00) LOOP
        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0); v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours; IF v_flight_hours <= 0 THEN CONTINUE; END IF;
        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price); v_seasonal_factor := 1.0;
        v_revenue := v_route.flights_per_week * v_route.ticket_price * LEAST(v_route.capacity, FLOOR(v_route.capacity * 0.95 * v_demand_multiplier * v_seasonal_factor));
        v_ops_cost := v_route.flights_per_week * (v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price + v_flight_hours * v_crew_cost);
        v_lease_cost := CASE WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2 WHERE fa2.id = v_route.assigned_aircraft_id AND fa2.acquisition_type = 'lease') THEN COALESCE(v_route.lease_price_per_month, 0) / 4.0 ELSE 0 END;
        v_cargo_rev := v_revenue * 0.05; v_buffered_rev_accum := v_buffered_rev_accum + v_revenue; v_buffered_ops_accum := v_buffered_ops_accum + v_ops_cost; v_buffered_lease_accum := v_buffered_lease_accum + v_lease_cost; v_buffered_cargo_accum := v_buffered_cargo_accum + v_cargo_rev;
        v_wear_per_cycle := 0.50 + (v_route.distance_km * 0.0001); v_gross_damage := v_wear_per_cycle * v_route.flights_per_week * v_elapsed_days / 7.0; v_self_healing_credit := v_gross_damage * 0.10; v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);
        UPDATE fleet_aircraft SET condition = GREATEST(0, condition - v_net_damage), total_flights = total_flights + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT WHERE id = v_route.assigned_aircraft_id;
        v_flights_run := v_flights_run + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
    END LOOP;
    v_net := v_buffered_rev_accum + v_buffered_cargo_accum - v_buffered_ops_accum - v_buffered_lease_accum;
    UPDATE users SET cash = cash + v_net, game_current_time = p_target_game_time, buffered_revenue = buffered_revenue + v_buffered_rev_accum, buffered_ops_cost = buffered_ops_cost + v_buffered_ops_accum, buffered_lease_cost = buffered_lease_cost + v_buffered_lease_accum, buffered_cargo_revenue = buffered_cargo_revenue + v_buffered_cargo_accum, last_active_at = NOW() WHERE id = p_user_id RETURNING cash INTO v_cash_after;
    IF v_elapsed_days >= 1.0 THEN PERFORM process_loan_payments(p_user_id, p_target_game_time); PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time); PERFORM accrue_savings_interest(p_user_id, p_target_game_time); PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time); PERFORM check_achievements(p_user_id, p_target_game_time); IF v_net < 0 THEN UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1 WHERE id = p_user_id; ELSE UPDATE users SET consecutive_negative_days = 0, recovery_streak_days = recovery_streak_days + 1 WHERE id = p_user_id; END IF; END IF;
    game_time := p_target_game_time; cash := v_cash_after; flights_run := v_flights_run; elapsed_days := v_elapsed_days; RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_all_bots_simulation_to_time(p_target_game_time timestamp with time zone, p_season_id uuid DEFAULT NULL::uuid)
RETURNS integer LANGUAGE plpgsql VOLATILE AS $function$
DECLARE r_bot RECORD; v_game_sec DOUBLE PRECISION; v_game_days DOUBLE PRECISION; v_route RECORD; v_flights DOUBLE PRECISION; v_revenue NUMERIC(20,2) := 0; v_fuel_cost NUMERIC(20,2) := 0; v_maint_cost NUMERIC(20,2) := 0; v_crew_cost NUMERIC(20,2) := 0; v_total_cost NUMERIC(20,2) := 0; v_net NUMERIC(20,2) := 0; v_passengers INT; v_flight_duration DOUBLE PRECISION; v_turnaround_hours NUMERIC; v_lease_cost NUMERIC(20,2) := 0; v_fuel_price NUMERIC; v_fuel_price_multiplier NUMERIC; v_crew_cost_per_hour NUMERIC; v_absolute_minimum_safety_limit NUMERIC(5,2); v_effective_grounding_threshold NUMERIC(5,2); v_max_weekly_flights INT; v_wear_per_cycle NUMERIC(8,4); v_gross_damage NUMERIC(20,4); v_self_healing_credit NUMERIC(20,4); v_net_damage NUMERIC(20,4); v_buffered_rev_accum NUMERIC(20,2); v_buffered_ops_accum NUMERIC(20,2); v_buffered_lease_accum NUMERIC(20,2); v_buffered_cargo_accum NUMERIC(20,2); v_cargo_rev NUMERIC(20,2); v_processed INT := 0; v_demand_multiplier NUMERIC; v_seasonal_multiplier NUMERIC; v_total_revenue NUMERIC(20,2); v_total_cost_accum NUMERIC(20,2);
BEGIN
    SELECT fuel_price_per_liter, absolute_minimum_safety_limit, COALESCE(crew_cost_per_hour, 350.0) INTO v_fuel_price, v_absolute_minimum_safety_limit, v_crew_cost_per_hour FROM global_game_settings LIMIT 1;
    v_fuel_price := COALESCE(v_fuel_price, 0.85); v_fuel_price_multiplier := 1.0; v_seasonal_multiplier := 1.0;
    FOR r_bot IN SELECT * FROM users WHERE actor_type = 'AI' AND COALESCE(operational_status, 'Active') != 'Bankrupt' LOOP
        v_effective_grounding_threshold := GREATEST(COALESCE(r_bot.auto_grounding_threshold, 40.00), v_absolute_minimum_safety_limit);
        v_game_sec := EXTRACT(EPOCH FROM (p_target_game_time - r_bot.game_current_time)); v_game_days := v_game_sec / 86400.0; IF v_game_days <= 0 THEN CONTINUE; END IF;
        v_buffered_rev_accum := 0.00; v_buffered_ops_accum := 0.00; v_buffered_lease_accum := 0.00; v_buffered_cargo_accum := 0.00;
        FOR v_route IN SELECT ra.*, am.fuel_burn_per_km, am.speed_kmh, am.capacity, am.turnaround_hours, am.maintenance_cost_per_hour, am.lease_price_per_month, a1.demand_index AS origin_demand, a2.demand_index AS dest_demand FROM route_assignments ra JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id JOIN aircraft_models am ON am.id = fa.aircraft_model_id JOIN airports a1 ON a1.iata = ra.origin_iata JOIN airports a2 ON a2.iata = ra.destination_iata WHERE ra.user_id = r_bot.id AND ra.status = 'active' AND fa.status = 'active' AND fa.condition >= v_effective_grounding_threshold LOOP
            v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0); v_flight_duration := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours; IF v_flight_duration <= 0 THEN CONTINUE; END IF;
            v_max_weekly_flights := FLOOR(168.0 / v_flight_duration)::INT; v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);
            v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price);
            v_passengers := LEAST(v_route.capacity, FLOOR(v_route.capacity * 0.95 * v_demand_multiplier * v_seasonal_multiplier));
            v_revenue := v_flights * v_route.ticket_price * v_passengers; v_fuel_cost := v_flights * v_route.distance_km * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier; v_crew_cost := v_flights * v_flight_duration * v_crew_cost_per_hour; v_maint_cost := v_flights * v_route.distance_km * v_route.maintenance_cost_per_hour / NULLIF(v_route.speed_kmh, 0); v_cargo_rev := v_revenue * 0.05; v_lease_cost := CASE WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2 WHERE fa2.id = v_route.assigned_aircraft_id AND fa2.acquisition_type = 'lease') THEN COALESCE(v_route.lease_price_per_month, 0) / 4.0 ELSE 0 END;
            v_total_cost := v_fuel_cost + v_crew_cost + v_maint_cost; v_net := v_revenue + v_cargo_rev - v_total_cost - v_lease_cost;
            v_buffered_rev_accum := v_buffered_rev_accum + v_revenue; v_buffered_ops_accum := v_buffered_ops_accum + v_total_cost; v_buffered_lease_accum := v_buffered_lease_accum + v_lease_cost; v_buffered_cargo_accum := v_buffered_cargo_accum + v_cargo_rev;
            v_wear_per_cycle := 0.50 + (v_route.distance_km * 0.0001); v_gross_damage := v_wear_per_cycle * v_flights * v_game_days / 7.0; v_self_healing_credit := v_gross_damage * 0.10; v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);
            UPDATE fleet_aircraft SET condition = GREATEST(0, condition - v_net_damage), total_flights = total_flights + (v_flights * v_game_days / 7.0)::INT WHERE id = v_route.assigned_aircraft_id;
        END LOOP;
        v_total_revenue := v_buffered_rev_accum + v_buffered_cargo_accum; v_total_cost_accum := v_buffered_ops_accum + v_buffered_lease_accum; v_net := v_total_revenue - v_total_cost_accum;
        UPDATE users SET cash = cash + v_net, game_current_time = p_target_game_time, buffered_revenue = buffered_revenue + v_buffered_rev_accum, buffered_ops_cost = buffered_ops_cost + v_buffered_ops_accum, buffered_lease_cost = buffered_lease_cost + v_buffered_lease_accum, buffered_cargo_revenue = buffered_cargo_revenue + v_buffered_cargo_accum, last_active_at = NOW() WHERE id = r_bot.id;
        IF v_game_days >= 1.0 THEN PERFORM process_loan_payments(r_bot.id, p_target_game_time); PERFORM process_aircraft_financing_payments(r_bot.id, p_target_game_time); PERFORM process_credit_at_day_boundary(r_bot.id, p_target_game_time); IF v_net < 0 THEN UPDATE users SET consecutive_negative_days = consecutive_negative_days + 1 WHERE id = r_bot.id; ELSE UPDATE users SET consecutive_negative_days = 0 WHERE id = r_bot.id; END IF; IF (SELECT consecutive_negative_days FROM users WHERE id = r_bot.id) >= 30 THEN UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id; UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id; END IF; END IF;
        v_processed := v_processed + 1;
    END LOOP;
    RETURN v_processed;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_world_tick(p_season_id uuid DEFAULT NULL::uuid, p_max_ticks integer DEFAULT 10)
RETURNS TABLE(season_id uuid, ticks_processed integer, game_time_after timestamp with time zone, players_processed integer, bots_processed integer)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE r_season RECORD; v_game_time_after TIMESTAMPTZ; v_ticks_processed INT := 0; v_players_processed INT := 0; v_bots_processed INT := 0; r_user RECORD; r_player_result RECORD; v_lock_key BIGINT;
BEGIN
    IF p_season_id IS NOT NULL THEN SELECT * INTO r_season FROM season_clock WHERE id = p_season_id; ELSE SELECT * INTO r_season FROM season_clock WHERE status = 'active' LIMIT 1; END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'No active season found'; END IF;
    v_lock_key := hashtext(r_season.id::text); IF NOT pg_try_advisory_lock(v_lock_key) THEN RAISE EXCEPTION 'World tick already in progress for season %', r_season.id; END IF;
    v_game_time_after := r_season.current_game_time + (r_season.tick_interval_seconds * r_season.time_scale_multiplier * INTERVAL '1 second');
    PERFORM generate_game_events(v_game_time_after); PERFORM deactivate_expired_events(v_game_time_after);
    FOR r_user IN SELECT u.id, u.game_current_time FROM users u WHERE u.season_id = r_season.id AND u.actor_type = 'REAL' AND u.operational_status != 'Bankrupt' LOOP SELECT * INTO r_player_result FROM process_player_simulation_to_time(r_user.id, v_game_time_after) LIMIT 1; IF COALESCE(r_player_result.elapsed_days, 0.0) > 0.0 THEN v_players_processed := v_players_processed + 1; END IF; END LOOP;
    v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);
    IF date_trunc('day', r_season.current_game_time)::DATE <> date_trunc('day', v_game_time_after)::DATE THEN PERFORM record_rank_snapshot((v_game_time_after AT TIME ZONE 'UTC')::DATE); PERFORM execute_bot_decisions(); END IF;
    UPDATE season_clock SET current_game_time = v_game_time_after, last_tick_at = NOW(), updated_at = NOW() WHERE id = r_season.id;
    v_ticks_processed := 1; PERFORM pg_advisory_unlock(v_lock_key);
    season_id := r_season.id; ticks_processed := v_ticks_processed; game_time_after := v_game_time_after; players_processed := v_players_processed; bots_processed := v_bots_processed; RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.ensure_world_current(p_season_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(season_id uuid, ticks_processed integer, game_time_after timestamp with time zone, players_processed integer, bots_processed integer)
LANGUAGE plpgsql VOLATILE AS $function$
BEGIN RETURN QUERY SELECT * FROM process_world_tick(p_season_id, 10); END;
$function$;

-- ── Group 6: Player action functions ──

CREATE OR REPLACE FUNCTION public.purchase_aircraft(p_user_id uuid, p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_cash NUMERIC; v_price NUMERIC; v_model_name VARCHAR; v_capacity INT; v_hq_iata VARCHAR(3); v_tail VARCHAR(20); v_economy INT; v_business INT; v_first INT; v_slots_used INT;
BEGIN PERFORM 1 FROM process_simulation_delta(p_user_id); SELECT cash, hq_airport_iata INTO v_cash, v_hq_iata FROM users WHERE id = p_user_id FOR UPDATE; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC; RETURN; END IF; SELECT purchase_price, model_name, capacity INTO v_price, v_model_name, v_capacity FROM aircraft_models WHERE id = p_model_id; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash; RETURN; END IF; v_economy := COALESCE(p_economy_seats, v_capacity); v_business := COALESCE(p_business_seats, 0); v_first := COALESCE(p_first_class_seats, 0); v_slots_used := v_economy + (v_business * 2) + (v_first * 3); IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash; RETURN; END IF; IF v_cash < v_price THEN RETURN QUERY SELECT FALSE, ('Insufficient funds to purchase ' || v_model_name || '.')::VARCHAR, v_cash; RETURN; END IF; LOOP v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK')); EXIT WHEN NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_tail); END LOOP; UPDATE users SET cash = cash - v_price WHERE id = p_user_id RETURNING cash INTO v_cash; INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats) VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'purchase', 100.00, 'active', v_tail, v_economy, v_business, v_first); INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'expense', 'acquisition', v_price, 'Purchased aircraft ' || v_model_name || ' [' || v_tail || ']', (SELECT game_current_time FROM users WHERE id = p_user_id)); RETURN QUERY SELECT TRUE, 'Successfully purchased ' || v_model_name || ' [' || v_tail || ']'::VARCHAR, v_cash; END;
$function$;

CREATE OR REPLACE FUNCTION public.purchase_aircraft(p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM purchase_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats); END;
$function$;

CREATE OR REPLACE FUNCTION public.lease_aircraft(p_user_id uuid, p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_cash NUMERIC; v_lease_price NUMERIC; v_model_name VARCHAR; v_capacity INT; v_hq_iata VARCHAR(3); v_tail VARCHAR(20); v_deposit_pct NUMERIC; v_lease_deposit NUMERIC; v_economy INT; v_business INT; v_first INT; v_slots_used INT;
BEGIN PERFORM 1 FROM process_simulation_delta(p_user_id); SELECT cash, hq_airport_iata INTO v_cash, v_hq_iata FROM users WHERE id = p_user_id FOR UPDATE; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC; RETURN; END IF; SELECT lease_price_per_month, model_name, capacity INTO v_lease_price, v_model_name, v_capacity FROM aircraft_models WHERE id = p_model_id; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash; RETURN; END IF; SELECT base_lease_deposit_percentage INTO v_deposit_pct FROM global_game_settings LIMIT 1; v_deposit_pct := COALESCE(v_deposit_pct, 0.10); v_lease_deposit := v_lease_price * (v_deposit_pct * 10.0); v_economy := COALESCE(p_economy_seats, v_capacity); v_business := COALESCE(p_business_seats, 0); v_first := COALESCE(p_first_class_seats, 0); v_slots_used := v_economy + (v_business * 2) + (v_first * 3); IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash; RETURN; END IF; IF v_cash < v_lease_deposit THEN RETURN QUERY SELECT FALSE, ('Insufficient funds for lease down payment of ' || v_model_name || '. Required: $' || ROUND(v_lease_deposit, 2))::VARCHAR, v_cash; RETURN; END IF; LOOP v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK')); EXIT WHEN NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_tail); END LOOP; UPDATE users SET cash = cash - v_lease_deposit WHERE id = p_user_id RETURNING cash INTO v_cash; INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats) VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first); INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'expense', 'aircraft_lease', v_lease_deposit, 'Leased aircraft ' || v_model_name || ' [' || v_tail || '] - down payment', (SELECT game_current_time FROM users WHERE id = p_user_id)); RETURN QUERY SELECT TRUE, 'Successfully leased ' || v_model_name || ' [' || v_tail || ']'::VARCHAR, v_cash; END;
$function$;

CREATE OR REPLACE FUNCTION public.lease_aircraft(p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM lease_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats); END;
$function$;

CREATE OR REPLACE FUNCTION public.sell_aircraft(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user RECORD; v_fleet RECORD; v_base_value NUMERIC(20,2); v_age_years NUMERIC; v_depreciation_factor NUMERIC; v_sale_value NUMERIC(20,2);
BEGIN PERFORM 1 FROM process_simulation_delta(p_user_id); SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF; SELECT f.*, m.model_name, m.purchase_price INTO v_fleet FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = p_fleet_id AND f.user_id = p_user_id FOR UPDATE; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF; IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'purchase' THEN RETURN QUERY SELECT FALSE, 'Only owned aircraft can be sold.'::VARCHAR, NULL::NUMERIC; RETURN; END IF; IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC; RETURN; END IF; v_base_value := v_fleet.purchase_price * (v_fleet.condition / 100.00); IF v_fleet.acquired_game_date IS NOT NULL AND v_user.game_current_time IS NOT NULL THEN v_age_years := EXTRACT(EPOCH FROM (v_user.game_current_time - v_fleet.acquired_game_date)) / (365.25 * 86400.0); v_depreciation_factor := GREATEST(0.10, 1.0 - (0.05 * COALESCE(v_age_years, 0))); v_sale_value := ROUND(v_base_value * v_depreciation_factor, 2); ELSE v_sale_value := v_base_value; END IF; UPDATE users SET cash = cash + v_sale_value WHERE id = p_user_id RETURNING cash INTO new_cash; DELETE FROM fleet_aircraft WHERE id = p_fleet_id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'revenue', 'aircraft_sale', v_sale_value, 'Sold aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']', v_user.game_current_time); RETURN QUERY SELECT TRUE, 'Aircraft sold for $' || ROUND(v_sale_value, 2)::TEXT || '.'::VARCHAR, new_cash; END;
$function$;

CREATE OR REPLACE FUNCTION public.sell_aircraft(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM sell_aircraft(v_user_id, p_fleet_id); END;
$function$;

CREATE OR REPLACE FUNCTION public.repair_aircraft(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_cash NUMERIC; v_condition NUMERIC; v_purchase_price NUMERIC; v_lease_price NUMERIC; v_model_name VARCHAR; v_repair_cost NUMERIC; v_acquisition_type VARCHAR;
BEGIN SELECT f.condition, f.acquisition_type, m.purchase_price, m.lease_price_per_month, m.model_name INTO v_condition, v_acquisition_type, v_purchase_price, v_lease_price, v_model_name FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.id = p_fleet_id AND f.user_id = p_user_id; SELECT cash INTO v_cash FROM users WHERE id = p_user_id FOR UPDATE; IF v_model_name IS NULL THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, v_cash; RETURN; END IF; IF v_condition >= 100.00 THEN RETURN QUERY SELECT FALSE, ('Aircraft ' || v_model_name || ' is already in pristine condition.')::VARCHAR, v_cash; RETURN; END IF; v_repair_cost := CASE WHEN v_acquisition_type = 'lease' THEN (100.00 - v_condition) * (COALESCE(v_lease_price, 0.00) * 0.50) ELSE (100.00 - v_condition) * (COALESCE(v_purchase_price, 0.00) * 0.0005) END; IF v_cash < v_repair_cost THEN RETURN QUERY SELECT FALSE, ('Insufficient funds for repair. Required: $' || ROUND(v_repair_cost, 2))::VARCHAR, v_cash; RETURN; END IF; UPDATE users SET cash = cash - v_repair_cost WHERE id = p_user_id RETURNING cash INTO v_cash; UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = p_fleet_id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'expense', 'aircraft_repair', v_repair_cost, 'Maintenance check completed for ' || v_model_name || ' - restored condition from ' || ROUND(v_condition::numeric, 2) || '% to 100%', (SELECT game_current_time FROM users WHERE id = p_user_id)); RETURN QUERY SELECT TRUE, 'Aircraft maintenance complete. Health restored to 100%!'::VARCHAR, v_cash; END;
$function$;

CREATE OR REPLACE FUNCTION public.repair_aircraft(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM repair_aircraft(v_user_id, p_fleet_id); END;
$function$;

CREATE OR REPLACE FUNCTION public.terminate_aircraft_lease(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user RECORD; v_fleet RECORD; v_exit_fee NUMERIC(20,2);
BEGIN PERFORM 1 FROM process_simulation_delta(p_user_id); SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF; SELECT f.*, m.model_name, m.lease_price_per_month INTO v_fleet FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = p_fleet_id AND f.user_id = p_user_id FOR UPDATE; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF; IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'lease' THEN RETURN QUERY SELECT FALSE, 'Only leased aircraft can be terminated through this action.'::VARCHAR, NULL::NUMERIC; RETURN; END IF; IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC; RETURN; END IF; v_exit_fee := calculate_lease_termination_fee(v_fleet.lease_price_per_month); UPDATE users SET cash = cash - v_exit_fee WHERE id = p_user_id RETURNING cash INTO new_cash; IF v_exit_fee > 0 THEN INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'expense', 'aircraft_lease_exit', v_exit_fee, 'Terminated leased aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']', date_trunc('day', v_user.game_current_time)); END IF; DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id; RETURN QUERY SELECT TRUE, 'Lease terminated successfully!'::VARCHAR, new_cash; END;
$function$;

CREATE OR REPLACE FUNCTION public.terminate_aircraft_lease(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM terminate_aircraft_lease(v_user_id, p_fleet_id); END;
$function$;

CREATE OR REPLACE FUNCTION public.configure_aircraft_seats(p_user_id uuid, p_fleet_id uuid, p_economy_seats integer, p_business_seats integer, p_first_class_seats integer)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_capacity INT; v_slots_used INT;
BEGIN PERFORM 1 FROM process_simulation_delta(p_user_id); SELECT m.capacity INTO v_capacity FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = p_fleet_id AND f.user_id = p_user_id; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR; RETURN; END IF; v_slots_used := p_economy_seats + (p_business_seats * 2) + (p_first_class_seats * 3); IF p_economy_seats < 0 OR p_business_seats < 0 OR p_first_class_seats < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR; RETURN; END IF; UPDATE fleet_aircraft SET economy_seats = p_economy_seats, business_seats = p_business_seats, first_class_seats = p_first_class_seats WHERE id = p_fleet_id AND user_id = p_user_id; RETURN QUERY SELECT TRUE, 'Successfully updated seat configuration!'::VARCHAR; END;
$function$;

CREATE OR REPLACE FUNCTION public.configure_aircraft_seats(p_fleet_id uuid, p_economy_seats integer, p_business_seats integer, p_first_class_seats integer)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM configure_aircraft_seats(v_user_id, p_fleet_id, p_economy_seats, p_business_seats, p_first_class_seats); END;
$function$;

CREATE OR REPLACE FUNCTION public.create_route(p_user_id uuid, p_origin_iata character varying, p_destination_iata character varying, p_distance_km numeric, p_ticket_price numeric, p_flights_per_week integer)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_actual_distance NUMERIC;
BEGIN PERFORM 1 FROM process_simulation_delta(p_user_id); IF p_origin_iata = p_destination_iata THEN RETURN QUERY SELECT FALSE, 'Origin and destination must be different.'::VARCHAR; RETURN; END IF; IF p_distance_km <= 0 OR p_ticket_price <= 0 OR p_flights_per_week < 1 OR p_flights_per_week > 168 THEN RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR; RETURN; END IF; IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR; RETURN; END IF; IF NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_origin_iata) OR NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_destination_iata) THEN RETURN QUERY SELECT FALSE, 'Route airport not found.'::VARCHAR; RETURN; END IF; SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude) INTO v_actual_distance FROM airports o, airports d WHERE o.iata = p_origin_iata AND d.iata = p_destination_iata; IF v_actual_distance > 0 AND ABS(p_distance_km - v_actual_distance) / v_actual_distance > 0.10 THEN RETURN QUERY SELECT FALSE, ('Distance validation failed. Expected ~' || ROUND(v_actual_distance, 1)::TEXT || ' km.')::VARCHAR; RETURN; END IF; IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND origin_iata = p_origin_iata AND destination_iata = p_destination_iata) THEN RETURN QUERY SELECT FALSE, 'Route already exists.'::VARCHAR; RETURN; END IF; INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, flights_per_week) VALUES (p_user_id, p_origin_iata, p_destination_iata, p_distance_km, p_ticket_price, p_flights_per_week); RETURN QUERY SELECT TRUE, 'Route established successfully!'::VARCHAR; END;
$function$;

CREATE OR REPLACE FUNCTION public.create_route(p_origin_iata character varying, p_destination_iata character varying, p_distance_km numeric, p_ticket_price numeric, p_flights_per_week integer)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM create_route(v_user_id, p_origin_iata, p_destination_iata, p_distance_km, p_ticket_price, p_flights_per_week); END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_route(p_user_id uuid, p_route_id uuid)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_assigned_aircraft_id UUID;
BEGIN PERFORM 1 FROM process_simulation_delta(p_user_id); SELECT assigned_aircraft_id INTO v_assigned_aircraft_id FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR; RETURN; END IF; IF v_assigned_aircraft_id IS NOT NULL THEN UPDATE fleet_aircraft SET status = 'grounded' WHERE id = v_assigned_aircraft_id AND user_id = p_user_id; END IF; DELETE FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id; RETURN QUERY SELECT TRUE, 'Route closed and aircraft grounded successfully!'::VARCHAR; END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_route(p_route_id uuid)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM delete_route(v_user_id, p_route_id); END;
$function$;

CREATE OR REPLACE FUNCTION public.assign_aircraft_to_route(p_user_id uuid, p_route_id uuid, p_aircraft_id uuid)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_current_aircraft_id UUID; v_effective_threshold NUMERIC(5,2); v_route_distance_km DOUBLE PRECISION; v_route_flights_per_week INT; v_aircraft_range_km INT; v_aircraft_speed_kmh INT; v_max_weekly_flights INT;
BEGIN PERFORM 1 FROM process_simulation_delta(p_user_id); SELECT assigned_aircraft_id, distance_km, flights_per_week INTO v_current_aircraft_id, v_route_distance_km, v_route_flights_per_week FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR; RETURN; END IF; IF p_aircraft_id IS NOT NULL THEN SELECT GREATEST(COALESCE(u.auto_grounding_threshold, 40.00), COALESCE(g.absolute_minimum_safety_limit, 30.00)) INTO v_effective_threshold FROM users u CROSS JOIN global_game_settings g WHERE u.id = p_user_id LIMIT 1; SELECT m.range_km, m.speed_kmh INTO v_aircraft_range_km, v_aircraft_speed_kmh FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = p_aircraft_id AND f.user_id = p_user_id AND f.condition >= COALESCE(v_effective_threshold, 40.00); IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft is unavailable or below the safety threshold.'::VARCHAR; RETURN; END IF; IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN RETURN QUERY SELECT FALSE, 'Aircraft range is insufficient for this route.'::VARCHAR; RETURN; END IF; v_max_weekly_flights := calculate_route_max_weekly_flights(v_route_distance_km, v_aircraft_speed_kmh); IF v_max_weekly_flights > 0 AND COALESCE(v_route_flights_per_week, 0) > v_max_weekly_flights THEN RETURN QUERY SELECT FALSE, 'Route frequency exceeds this aircraft''s weekly operating capacity.'::VARCHAR; RETURN; END IF; IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_aircraft_id AND id <> p_route_id) THEN RETURN QUERY SELECT FALSE, 'Aircraft is already assigned to another route.'::VARCHAR; RETURN; END IF; END IF; UPDATE route_assignments SET assigned_aircraft_id = p_aircraft_id WHERE id = p_route_id AND user_id = p_user_id; IF p_aircraft_id IS NOT NULL THEN UPDATE fleet_aircraft SET status = 'active' WHERE id = p_aircraft_id AND user_id = p_user_id; END IF; RETURN QUERY SELECT TRUE, 'Aircraft assigned to route successfully!'::VARCHAR; END;
$function$;

CREATE OR REPLACE FUNCTION public.assign_aircraft_to_route(p_route_id uuid, p_aircraft_id uuid)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM assign_aircraft_to_route(v_user_id, p_route_id, p_aircraft_id); END;
$function$;

CREATE OR REPLACE FUNCTION public.update_route_frequency_and_price(p_user_id uuid, p_route_id uuid, p_ticket_price numeric, p_flights_per_week integer)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_route_distance_km DOUBLE PRECISION; v_assigned_aircraft_id UUID; v_aircraft_range_km INT; v_aircraft_speed_kmh INT; v_max_weekly_flights INT;
BEGIN PERFORM 1 FROM process_simulation_delta(p_user_id); IF p_ticket_price <= 0 OR p_flights_per_week < 1 OR p_flights_per_week > 168 THEN RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR; RETURN; END IF; SELECT distance_km, assigned_aircraft_id INTO v_route_distance_km, v_assigned_aircraft_id FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR; RETURN; END IF; IF v_assigned_aircraft_id IS NOT NULL THEN SELECT m.range_km, m.speed_kmh INTO v_aircraft_range_km, v_aircraft_speed_kmh FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = v_assigned_aircraft_id AND f.user_id = p_user_id; IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN RETURN QUERY SELECT FALSE, 'Assigned aircraft range is insufficient for this route.'::VARCHAR; RETURN; END IF; v_max_weekly_flights := calculate_route_max_weekly_flights(v_route_distance_km, v_aircraft_speed_kmh); IF v_max_weekly_flights > 0 AND p_flights_per_week > v_max_weekly_flights THEN RETURN QUERY SELECT FALSE, 'Route frequency exceeds the assigned aircraft''s weekly operating capacity.'::VARCHAR; RETURN; END IF; END IF; UPDATE route_assignments SET ticket_price = p_ticket_price, flights_per_week = p_flights_per_week WHERE id = p_route_id AND user_id = p_user_id; RETURN QUERY SELECT TRUE, 'Route frequency and pricing adjusted!'::VARCHAR; END;
$function$;

CREATE OR REPLACE FUNCTION public.update_route_frequency_and_price(p_route_id uuid, p_ticket_price numeric, p_flights_per_week integer)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM update_route_frequency_and_price(v_user_id, p_route_id, p_ticket_price, p_flights_per_week); END;
$function$;

CREATE OR REPLACE FUNCTION public.finance_aircraft(p_user_id uuid, p_aircraft_model_id uuid, p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 36)
RETURNS TABLE(success boolean, message text, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_actor_type VARCHAR(10); v_model RECORD; v_credit_score INT; v_tier VARCHAR(10); v_purchase_price NUMERIC; v_down_payment NUMERIC; v_principal NUMERIC; v_interest_rate NUMERIC; v_monthly_payment NUMERIC; v_total_repayable NUMERIC; v_cash NUMERIC; v_game_time TIMESTAMPTZ; v_fleet_id UUID; v_hq_iata VARCHAR(3); v_max_financing NUMERIC; v_economy_seats INT; v_business_seats INT; v_first_seats INT; v_archetype VARCHAR(30);
BEGIN
    SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id; IF NOT FOUND THEN RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC; RETURN; END IF; v_purchase_price := v_model.purchase_price;
    SELECT u.actor_type, u.credit_score, u.game_current_time, u.hq_airport_iata, u.archetype INTO v_actor_type, v_credit_score, v_game_time, v_hq_iata, v_archetype FROM users u WHERE u.id = p_user_id; IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;
    IF v_actor_type = 'AI' THEN SELECT cash INTO v_cash FROM users WHERE id = p_user_id; v_down_payment := v_purchase_price * p_down_payment_pct; v_principal := v_purchase_price - v_down_payment; v_interest_rate := 0.05; v_total_repayable := v_principal * (1 + v_interest_rate); v_monthly_payment := v_total_repayable / p_term_months; IF v_cash < v_down_payment THEN RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN; END IF; UPDATE users SET cash = cash - v_down_payment WHERE id = p_user_id; v_economy_seats := CASE WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.80)::INT WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)::INT ELSE FLOOR(v_model.capacity * 0.50)::INT END; v_business_seats := CASE WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.15)::INT WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)::INT ELSE FLOOR(v_model.capacity * 0.30)::INT END; v_first_seats := v_model.capacity - v_economy_seats - v_business_seats; INSERT INTO fleet_aircraft (user_id, aircraft_model_id, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats) VALUES (p_user_id, p_aircraft_model_id, 'BOT-' || left(p_user_id::text, 4), 'finance', 100.00, 'active', v_economy_seats, v_business_seats, v_first_seats) RETURNING id INTO v_fleet_id; INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made) VALUES (p_user_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0); INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'expense', 'aircraft_financing_down', v_down_payment, 'Aircraft financing down payment — ' || v_model.model_name, v_game_time); SELECT cash INTO v_cash FROM users WHERE id = p_user_id; RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash; RETURN; END IF;
    SELECT cash, game_current_time, hq_airport_iata INTO v_cash, v_game_time, v_hq_iata FROM users u WHERE u.id = p_user_id; v_credit_score := COALESCE(v_credit_score, 500); SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = p_user_id; v_tier := COALESCE(v_tier, 'Standard');
    v_max_financing := CASE WHEN v_tier = 'Platinum' THEN 80000000 WHEN v_tier = 'Gold' THEN 60000000 WHEN v_tier = 'Silver' THEN 40000000 WHEN v_tier = 'Standard' THEN 20000000 ELSE 5000000 END;
    IF v_purchase_price > v_max_financing THEN RETURN QUERY SELECT false, 'Aircraft price ($' || v_purchase_price::TEXT || ') exceeds your financing limit ($' || v_max_financing::TEXT || ') for tier ' || v_tier || '.'::TEXT, 0::NUMERIC; RETURN; END IF;
    IF p_term_months NOT IN (12, 24, 36, 48, 60) THEN RETURN QUERY SELECT false, 'Financing term must be 12, 24, 36, 48, or 60 months.'::TEXT, 0::NUMERIC; RETURN; END IF;
    IF p_down_payment_pct < 0.10 OR p_down_payment_pct > 0.50 THEN RETURN QUERY SELECT false, 'Down payment must be between 10% and 50%.'::TEXT, 0::NUMERIC; RETURN; END IF;
    v_down_payment := v_purchase_price * p_down_payment_pct; v_principal := v_purchase_price - v_down_payment;
    v_interest_rate := CASE WHEN v_tier = 'Platinum' THEN 0.03 WHEN v_tier = 'Gold' THEN 0.04 WHEN v_tier = 'Silver' THEN 0.05 WHEN v_tier = 'Standard' THEN 0.07 ELSE 0.10 END;
    v_total_repayable := v_principal * (1 + v_interest_rate); v_monthly_payment := v_total_repayable / p_term_months;
    IF v_cash < v_down_payment THEN RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN; END IF;
    UPDATE users SET cash = cash - v_down_payment WHERE id = p_user_id;
    INSERT INTO fleet_aircraft (user_id, aircraft_model_id, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats) VALUES (p_user_id, p_aircraft_model_id, generate_tail_number(COALESCE(v_hq_iata, 'CGK')), 'finance', 100.00, 'active', v_model.capacity, 0, 0) RETURNING id INTO v_fleet_id;
    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made) VALUES (p_user_id, v_principal, v_interest_rate, v_total_repayable, 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0);
    INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_user_id, 'expense', 'aircraft_financing_down', v_down_payment, 'Aircraft financing down payment — ' || v_model.model_name, v_game_time);
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id; RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$function$;

CREATE OR REPLACE FUNCTION public.finance_aircraft(p_aircraft_model_id uuid, p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 36)
RETURNS TABLE(success boolean, message text, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := require_current_user_id(); RETURN QUERY SELECT * FROM finance_aircraft(v_user_id, p_aircraft_model_id, p_down_payment_pct, p_term_months); END;
$function$;

CREATE OR REPLACE FUNCTION public.bot_take_loan(p_bot_id uuid, p_principal numeric, p_term_weeks integer DEFAULT 52)
RETURNS boolean LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_existing_loans INT; v_cash NUMERIC; v_interest_rate NUMERIC := 0.05; v_total_repayable NUMERIC; v_weekly_payment NUMERIC; v_game_time TIMESTAMPTZ;
BEGIN SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_bot_id AND status = 'active'; IF v_existing_loans >= 3 THEN RETURN false; END IF; IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN false; END IF; SELECT cash, game_current_time INTO v_cash, v_game_time FROM users WHERE id = p_bot_id; v_total_repayable := p_principal * (1 + v_interest_rate * (p_term_weeks / 52.0)); v_weekly_payment := v_total_repayable / p_term_weeks; INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type) VALUES (p_bot_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', v_game_time, 'unsecured'); UPDATE users SET cash = cash + p_principal WHERE id = p_bot_id; INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_bot_id, 'revenue', 'loan', p_principal, 'Bot loan disbursement', v_game_time); RETURN true; END;
$function$;

CREATE OR REPLACE FUNCTION public.bot_finance_aircraft(p_bot_id uuid, p_aircraft_model_id uuid, p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 60)
RETURNS boolean LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_model RECORD; v_purchase_price NUMERIC; v_down_payment NUMERIC; v_principal NUMERIC; v_interest_rate NUMERIC := 0.05; v_monthly_payment NUMERIC; v_cash NUMERIC; v_game_time TIMESTAMPTZ; v_fleet_id UUID;
BEGIN SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id; IF NOT FOUND THEN RETURN false; END IF; v_purchase_price := v_model.purchase_price; v_down_payment := v_purchase_price * p_down_payment_pct; v_principal := v_purchase_price - v_down_payment; v_monthly_payment := (v_principal * (1 + v_interest_rate)) / p_term_months; SELECT cash, game_current_time INTO v_cash, v_game_time FROM users WHERE id = p_bot_id; IF v_cash < v_down_payment THEN RETURN false; END IF; UPDATE users SET cash = cash - v_down_payment WHERE id = p_bot_id; INSERT INTO fleet_aircraft (user_id, aircraft_model_id, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats) VALUES (p_bot_id, p_aircraft_model_id, 'finance', 100.00, 'active', 'BOT-' || left(p_bot_id::text, 4), FLOOR(v_model.capacity * 0.70)::INT, FLOOR(v_model.capacity * 0.20)::INT, FLOOR(v_model.capacity * 0.10)::INT) RETURNING id INTO v_fleet_id; INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, game_date_taken, loan_type, aircraft_model_id, fleet_aircraft_id, purchase_price, down_payment, term_months, monthly_payment, payments_made) VALUES (p_bot_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', v_game_time, 'aircraft_financing', p_aircraft_model_id, v_fleet_id, v_purchase_price, v_down_payment, p_term_months, v_monthly_payment, 0); INSERT INTO financial_ledger (user_id, transaction_type, category, amount, description, game_date) VALUES (p_bot_id, 'expense', 'aircraft_financing_down', v_down_payment, 'Aircraft financing down payment — ' || v_model.model_name, v_game_time); RETURN true; END;
$function$;

-- ── Group 7: Banking functions ──

CREATE OR REPLACE FUNCTION public.take_loan(p_user_id uuid, p_principal numeric, p_term_weeks integer DEFAULT 52, p_loan_type character varying DEFAULT 'unsecured', p_collateral_aircraft_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(success boolean, message text, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_actor_type VARCHAR(10); v_existing_loans INT; v_credit_score INT; v_score_record RECORD; v_tier VARCHAR(10); v_config JSONB; v_tier_cfg JSONB; v_min_loan NUMERIC; v_max_loans INT; v_interest_rate NUMERIC; v_weekly_payment NUMERIC; v_total_repayable NUMERIC; v_cash NUMERIC; v_game_time TIMESTAMPTZ; v_max_principal NUMERIC; v_rate_key TEXT; v_loan_id UUID;
BEGIN
    SELECT u.actor_type, u.credit_score, u.game_current_time INTO v_actor_type, v_credit_score, v_game_time FROM users u WHERE u.id = p_user_id; IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;
    IF v_actor_type = 'AI' THEN SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active'; IF v_existing_loans >= 3 THEN RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC; RETURN; END IF; IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN QUERY SELECT false, 'Bot loan amount must be between $100K and $5M.'::TEXT, 0::NUMERIC; RETURN; END IF; v_interest_rate := 0.05; v_total_repayable := p_principal * (1 + v_interest_rate); v_weekly_payment := v_total_repayable / p_term_weeks; INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, game_date_taken, status) VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, v_game_time, 'active') RETURNING id INTO v_loan_id; UPDATE users SET cash = cash + p_principal WHERE id = p_user_id; INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, reference_type, reference_id, game_date) SELECT ba.id, p_user_id, 'disbursement', p_principal, ba.balance + p_principal, 'Loan disbursement', 'loan', v_loan_id, v_game_time FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'checking' LIMIT 1; SELECT cash INTO v_cash FROM users WHERE id = p_user_id; RETURN QUERY SELECT true, 'Loan disbursed.'::TEXT, v_cash; RETURN; END IF;
    SELECT credit_tier_config INTO v_config FROM global_game_settings WHERE id = 1; v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000); v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);
    SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active'; IF v_existing_loans >= v_max_loans THEN RETURN QUERY SELECT false, 'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC; RETURN; END IF;
    SELECT u.credit_score, u.game_current_time INTO v_credit_score, v_game_time FROM users u WHERE u.id = p_user_id; v_credit_score := COALESCE(v_credit_score, 500); SELECT * INTO v_score_record FROM calculate_credit_score(p_user_id) LIMIT 1; IF FOUND THEN v_tier := resolve_credit_tier(v_score_record.total_score); ELSE v_tier := resolve_credit_tier(v_credit_score); END IF;
    v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);
    IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC; RETURN; END IF;
    IF p_loan_type = 'unsecured' THEN v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000); v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07); v_rate_key := 'rate_unsecured';
    ELSIF p_loan_type = 'secured' THEN IF p_collateral_aircraft_id IS NULL THEN RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC; RETURN; END IF; v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000); v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06); v_rate_key := 'rate_secured';
    ELSE v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000) * 0.5; v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07) + 0.02; v_rate_key := 'rate_credit_line'; END IF;
    IF p_principal < v_min_loan THEN RETURN QUERY SELECT false, 'Minimum loan amount is $' || v_min_loan::TEXT || '.'::TEXT, 0::NUMERIC; RETURN; END IF; IF p_principal > v_max_principal THEN RETURN QUERY SELECT false, 'Maximum for ' || v_tier || ' tier ' || p_loan_type || ' loan is $' || v_max_principal::TEXT || '.'::TEXT, 0::NUMERIC; RETURN; END IF;
    v_total_repayable := p_principal * (1 + v_interest_rate); v_weekly_payment := v_total_repayable / p_term_weeks;
    INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, game_date_taken, status, loan_type, collateral_aircraft_id, credit_score_at_origination) VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, v_game_time, 'active', p_loan_type, p_collateral_aircraft_id, v_credit_score) RETURNING id INTO v_loan_id;
    UPDATE users SET cash = cash + p_principal WHERE id = p_user_id;
    INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, reference_type, reference_id, game_date) SELECT ba.id, p_user_id, 'disbursement', p_principal, ba.balance + p_principal, 'Loan disbursement', 'loan', v_loan_id, v_game_time FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'checking' LIMIT 1;
    SELECT cash INTO v_cash FROM users WHERE id = p_user_id; RETURN QUERY SELECT true, 'Loan disbursed at ' || ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT, v_cash;
END;
$function$;

CREATE OR REPLACE FUNCTION public.take_loan(p_principal numeric, p_term_weeks integer DEFAULT 52, p_loan_type character varying DEFAULT 'unsecured', p_collateral_aircraft_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(success boolean, message text, new_cash numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := require_current_user_id(); RETURN QUERY SELECT * FROM take_loan(v_user_id, p_principal, p_term_weeks, p_loan_type, p_collateral_aircraft_id); END;
$function$;

CREATE OR REPLACE FUNCTION public.repay_loan(p_loan_id uuid, p_amount numeric DEFAULT NULL::numeric)
RETURNS TABLE(success boolean, message text, new_cash numeric, paid_off boolean) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID; v_loan RECORD; v_payment NUMERIC; v_cash NUMERIC; v_is_paid_off BOOLEAN := false;
BEGIN v_user_id := require_current_user_id(); SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active'; IF NOT FOUND THEN RETURN QUERY SELECT false, 'Loan not found or already paid off.'::TEXT, 0::NUMERIC, false; RETURN; END IF; IF p_amount IS NULL THEN v_payment := v_loan.remaining_balance; ELSE v_payment := LEAST(p_amount, v_loan.remaining_balance); END IF; IF v_payment <= 0 THEN RETURN QUERY SELECT false, 'Payment amount must be positive.'::TEXT, 0::NUMERIC, false; RETURN; END IF; SELECT cash INTO v_cash FROM users WHERE id = v_user_id FOR UPDATE; IF v_cash < v_payment THEN RETURN QUERY SELECT false, 'Insufficient cash. Need $' || v_payment::TEXT || ', have $' || v_cash::TEXT || '.'::TEXT, v_cash, false; RETURN; END IF; UPDATE users SET cash = cash - v_payment WHERE id = v_user_id; UPDATE loans SET remaining_balance = remaining_balance - v_payment, status = CASE WHEN remaining_balance - v_payment <= 0 THEN 'paid_off'::VARCHAR ELSE status END, paid_off_at = CASE WHEN remaining_balance - v_payment <= 0 THEN NOW() ELSE paid_off_at END WHERE id = p_loan_id; v_is_paid_off := (SELECT remaining_balance <= 0 FROM loans WHERE id = p_loan_id); INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, reference_type, reference_id, game_date) SELECT ba.id, v_user_id, 'payment', -v_payment, ba.balance, CASE WHEN v_is_paid_off THEN 'Loan fully repaid' ELSE 'Loan partial repayment' END, 'loan', p_loan_id, NOW() FROM bank_accounts ba WHERE ba.user_id = v_user_id AND ba.account_type = 'checking' LIMIT 1; SELECT cash INTO v_cash FROM users WHERE id = v_user_id; RETURN QUERY SELECT true, CASE WHEN v_is_paid_off THEN 'Loan fully repaid!' ELSE 'Payment of $' || v_payment::TEXT || ' applied.' END::TEXT, v_cash, v_is_paid_off; END;
$function$;

CREATE OR REPLACE FUNCTION public.refinance_loan(p_loan_id uuid)
RETURNS TABLE(success boolean, message text, new_rate numeric, savings numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID; v_loan RECORD; v_new_rate NUMERIC; v_old_total NUMERIC; v_new_total NUMERIC; v_savings NUMERIC; v_tier VARCHAR;
BEGIN v_user_id := require_current_user_id(); SELECT * INTO v_loan FROM loans WHERE id = p_loan_id AND user_id = v_user_id AND status = 'active'; IF v_loan IS NULL THEN RETURN QUERY SELECT false, 'Loan not found or not active.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF; SELECT tier INTO v_tier FROM credit_scores WHERE user_id = v_user_id; v_new_rate := CASE COALESCE(v_tier, 'Standard') WHEN 'Platinum' THEN 0.03 WHEN 'Gold' THEN 0.04 WHEN 'Silver' THEN 0.05 WHEN 'Standard' THEN 0.07 ELSE 0.10 END; IF v_new_rate >= v_loan.interest_rate THEN RETURN QUERY SELECT false, 'Current rate is not better than existing rate.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF; v_old_total := v_loan.remaining_balance; v_new_total := v_loan.principal * (1 + v_new_rate); v_savings := GREATEST(0, v_old_total - v_new_total); UPDATE loans SET interest_rate = v_new_rate WHERE id = p_loan_id; RETURN QUERY SELECT true, 'Loan refinanced successfully.'::TEXT, v_new_rate, v_savings; END;
$function$;

CREATE OR REPLACE FUNCTION public.create_savings_account()
RETURNS TABLE(success boolean, message text) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID; v_rate NUMERIC; v_config JSONB;
BEGIN v_user_id := require_current_user_id(); IF EXISTS (SELECT 1 FROM bank_accounts WHERE user_id = v_user_id AND account_type = 'savings') THEN RETURN QUERY SELECT false, 'Savings account already exists.'::TEXT; RETURN; END IF; SELECT savings_tiers INTO v_config FROM global_game_settings WHERE id = 1; v_rate := COALESCE((v_config->'tiers'->0->>'rate')::NUMERIC, 0.01); INSERT INTO bank_accounts (user_id, account_type, balance, interest_rate) VALUES (v_user_id, 'savings', 0.00, v_rate); RETURN QUERY SELECT true, 'Savings account created.'::TEXT; END;
$function$;

CREATE OR REPLACE FUNCTION public.deposit_to_savings(p_amount numeric)
RETURNS TABLE(success boolean, message text, new_checking_balance numeric, new_savings_balance numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID; v_checking_id UUID; v_savings_id UUID; v_checking_balance NUMERIC; v_savings_balance NUMERIC;
BEGIN v_user_id := require_current_user_id(); IF p_amount <= 0 THEN RETURN QUERY SELECT false, 'Amount must be positive.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF; SELECT id, balance INTO v_checking_id, v_checking_balance FROM bank_accounts WHERE user_id = v_user_id AND account_type = 'checking'; SELECT id, balance INTO v_savings_id, v_savings_balance FROM bank_accounts WHERE user_id = v_user_id AND account_type = 'savings'; IF v_checking_id IS NULL THEN RETURN QUERY SELECT false, 'No checking account found.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF; IF v_savings_id IS NULL THEN RETURN QUERY SELECT false, 'No savings account found. Create one first.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF; IF v_checking_balance < p_amount THEN RETURN QUERY SELECT false, 'Insufficient checking balance.'::TEXT, v_checking_balance, v_savings_balance; RETURN; END IF; UPDATE bank_accounts SET balance = balance - p_amount, updated_at = NOW() WHERE id = v_checking_id; UPDATE bank_accounts SET balance = balance + p_amount, updated_at = NOW() WHERE id = v_savings_id; UPDATE users SET cash = cash - p_amount WHERE id = v_user_id; INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date) VALUES (v_checking_id, v_user_id, 'transfer', -p_amount, v_checking_balance - p_amount, 'Transfer to savings', NOW()), (v_savings_id, v_user_id, 'deposit', p_amount, v_savings_balance + p_amount, 'Deposit from checking', NOW()); SELECT balance INTO v_checking_balance FROM bank_accounts WHERE id = v_checking_id; SELECT balance INTO v_savings_balance FROM bank_accounts WHERE id = v_savings_id; RETURN QUERY SELECT true, 'Deposited $' || p_amount::TEXT || ' to savings.'::TEXT, v_checking_balance, v_savings_balance; END;
$function$;

CREATE OR REPLACE FUNCTION public.withdraw_from_savings(p_amount numeric)
RETURNS TABLE(success boolean, message text, new_checking_balance numeric, new_savings_balance numeric) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID; v_checking_id UUID; v_savings_id UUID; v_checking_balance NUMERIC; v_savings_balance NUMERIC;
BEGIN v_user_id := require_current_user_id(); IF p_amount <= 0 THEN RETURN QUERY SELECT false, 'Amount must be positive.'::TEXT, 0::NUMERIC, 0::NUMERIC; RETURN; END IF; SELECT id, balance INTO v_checking_id, v_checking_balance FROM bank_accounts WHERE user_id = v_user_id AND account_type = 'checking'; SELECT id, balance INTO v_savings_id, v_savings_balance FROM bank_accounts WHERE user_id = v_user_id AND account_type = 'savings'; IF v_savings_id IS NULL OR v_savings_balance < p_amount THEN RETURN QUERY SELECT false, 'Insufficient savings balance.'::TEXT, v_checking_balance, v_savings_balance; RETURN; END IF; UPDATE bank_accounts SET balance = balance + p_amount, updated_at = NOW() WHERE id = v_checking_id; UPDATE bank_accounts SET balance = balance - p_amount, updated_at = NOW() WHERE id = v_savings_id; UPDATE users SET cash = cash + p_amount WHERE id = v_user_id; INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after, description, game_date) VALUES (v_savings_id, v_user_id, 'withdrawal', -p_amount, v_savings_balance - p_amount, 'Withdrawal to checking', NOW()), (v_checking_id, v_user_id, 'deposit', p_amount, v_checking_balance + p_amount, 'Deposit from savings', NOW()); SELECT balance INTO v_checking_balance FROM bank_accounts WHERE id = v_checking_id; SELECT balance INTO v_savings_balance FROM bank_accounts WHERE id = v_savings_id; RETURN QUERY SELECT true, 'Withdrew $' || p_amount::TEXT || ' from savings.'::TEXT, v_checking_balance, v_savings_balance; END;
$function$;

-- ── Group 8: Settings/Reset ──

CREATE OR REPLACE FUNCTION public.save_airline_settings(p_user_id uuid, p_company_name character varying, p_auto_grounding_threshold numeric, p_hq_airport_iata character varying)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
BEGIN PERFORM 1 FROM process_simulation_delta(p_user_id); IF p_auto_grounding_threshold < 30.00 OR p_auto_grounding_threshold > 100.00 THEN RETURN QUERY SELECT FALSE, 'Safety threshold must be between 30 and 100.'::VARCHAR; RETURN; END IF; IF p_hq_airport_iata IS NOT NULL AND NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_hq_airport_iata) THEN RETURN QUERY SELECT FALSE, 'HQ airport not found.'::VARCHAR; RETURN; END IF; UPDATE users SET company_name = TRIM(p_company_name), auto_grounding_threshold = p_auto_grounding_threshold, hq_airport_iata = p_hq_airport_iata WHERE id = p_user_id; IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR; RETURN; END IF; RETURN QUERY SELECT TRUE, 'Settings saved successfully.'::VARCHAR; END;
$function$;

CREATE OR REPLACE FUNCTION public.save_airline_settings(p_company_name character varying, p_auto_grounding_threshold numeric, p_hq_airport_iata character varying)
RETURNS TABLE(success boolean, message character varying) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM save_airline_settings(v_user_id, p_company_name, p_auto_grounding_threshold, p_hq_airport_iata); END;
$function$;

CREATE OR REPLACE FUNCTION public.reset_user_airline(p_user_id uuid)
RETURNS TABLE(success boolean, message text) LANGUAGE plpgsql VOLATILE AS $function$
BEGIN IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN RETURN QUERY SELECT FALSE, 'User not found'; RETURN; END IF; DELETE FROM loans WHERE user_id = p_user_id; DELETE FROM credit_scores WHERE user_id = p_user_id; DELETE FROM credit_score_history WHERE user_id = p_user_id; DELETE FROM route_assignments WHERE user_id = p_user_id; DELETE FROM fleet_aircraft WHERE user_id = p_user_id; DELETE FROM financial_ledger WHERE user_id = p_user_id; UPDATE users SET cash = 15000000.00, game_current_time = TIMESTAMP WITH TIME ZONE '2020-01-01 00:00:00+00', hq_airport_iata = 'SIN', auto_grounding_threshold = 40.00, buffered_revenue = 0.00, buffered_ops_cost = 0.00, buffered_lease_cost = 0.00, operational_status = 'Active', consecutive_negative_days = 0, recovery_streak_days = 0, last_active_at = NOW() WHERE id = p_user_id; RETURN QUERY SELECT TRUE, 'Airline reset successfully'; END;
$function$;

CREATE OR REPLACE FUNCTION public.reset_user_airline()
RETURNS TABLE(success boolean, message text) LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM reset_user_airline(v_user_id); END;
$function$;

-- ── Group 9: Leaderboard/Reporting ──

CREATE OR REPLACE FUNCTION public.get_global_leaderboard()
RETURNS TABLE(id uuid, company_name character varying, ceo_name character varying, is_bot boolean, archetype character varying, cash numeric, net_worth numeric, fleet_size integer, monthly_revenue numeric, status character varying)
LANGUAGE plpgsql VOLATILE AS $function$
BEGIN RETURN QUERY SELECT u.id, u.company_name::VARCHAR, u.ceo_name::VARCHAR, (u.actor_type = 'AI')::BOOLEAN, COALESCE(u.archetype, 'Player')::VARCHAR, u.cash, u.net_worth, (SELECT COUNT(*)::INT FROM fleet_aircraft f WHERE f.user_id = u.id AND f.status = 'active'), COALESCE((SELECT SUM(fl.amount) FROM financial_ledger fl WHERE fl.user_id = u.id AND fl.transaction_type = 'revenue' AND fl.game_date >= u.game_current_time - INTERVAL '30 days'), 0.00)::NUMERIC, COALESCE(u.operational_status, 'Active')::VARCHAR FROM users u; END;
$function$;

CREATE OR REPLACE FUNCTION public.get_competitor_insights(p_id uuid, p_is_bot boolean)
RETURNS TABLE(company_name character varying, ceo_name character varying, cash numeric, net_worth numeric, status character varying, fleet_breakdown jsonb, network_routes jsonb)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_company VARCHAR; v_ceo VARCHAR; v_cash NUMERIC; v_net_worth NUMERIC; v_status VARCHAR; v_fleet JSONB; v_routes JSONB;
BEGIN SELECT u.company_name, u.ceo_name, u.cash, u.net_worth, COALESCE(u.operational_status, 'Active') INTO v_company, v_ceo, v_cash, v_net_worth, v_status FROM users u WHERE u.id = p_id; SELECT COALESCE(jsonb_object_agg(model_label, count_val), '{}'::jsonb) INTO v_fleet FROM (SELECT (m.manufacturer || ' ' || m.model_name || ' (' || f.acquisition_type || ')') AS model_label, COUNT(*)::INT AS count_val FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = p_id AND f.status = 'active' GROUP BY m.manufacturer, m.model_name, f.acquisition_type) d; SELECT COALESCE(jsonb_agg(route_label), '[]'::jsonb) INTO v_routes FROM (SELECT (origin_iata || '-' || destination_iata) AS route_label FROM route_assignments WHERE user_id = p_id) r; RETURN QUERY SELECT v_company::VARCHAR, v_ceo::VARCHAR, v_cash, v_net_worth, v_status::VARCHAR, v_fleet, v_routes; END;
$function$;

CREATE OR REPLACE FUNCTION public.get_finance_snapshot(p_id uuid, p_is_bot boolean DEFAULT false)
RETURNS TABLE(actor_id uuid, is_bot boolean, company_name character varying, cash numeric, net_worth numeric, owned_aircraft_asset_value numeric, leased_aircraft_monthly_exposure numeric, fleet_count integer, owned_fleet_count integer, leased_fleet_count integer, active_route_count integer, rolling_revenue_30d numeric, rolling_expense_30d numeric, rolling_net_30d numeric, ledger_window_days integer)
LANGUAGE plpgsql STABLE AS $function$
DECLARE v_company_name VARCHAR; v_cash NUMERIC := 0.00; v_net_worth NUMERIC := 0.00; v_owned_asset_value NUMERIC := 0.00; v_leased_monthly_exposure NUMERIC := 0.00; v_fleet_count INT := 0; v_owned_fleet_count INT := 0; v_leased_fleet_count INT := 0; v_active_route_count INT := 0; v_revenue_30d NUMERIC := 0.00; v_expense_30d NUMERIC := 0.00; v_ledger_window_days INT := 30; v_game_current_time TIMESTAMP WITH TIME ZONE;
BEGIN SELECT u.company_name, u.cash, u.net_worth, u.game_current_time INTO v_company_name, v_cash, v_net_worth, v_game_current_time FROM users u WHERE u.id = p_id; IF NOT FOUND THEN RETURN; END IF;
SELECT COUNT(*)::INT, COUNT(*) FILTER (WHERE f.acquisition_type = 'purchase')::INT, COUNT(*) FILTER (WHERE f.acquisition_type = 'lease')::INT, COALESCE(SUM(CASE WHEN f.acquisition_type = 'purchase' THEN m.purchase_price ELSE 0 END), 0.00), COALESCE(SUM(CASE WHEN f.acquisition_type = 'lease' THEN m.lease_price_per_month ELSE 0 END), 0.00) INTO v_fleet_count, v_owned_fleet_count, v_leased_fleet_count, v_owned_asset_value, v_leased_monthly_exposure FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.user_id = p_id;
SELECT COUNT(*)::INT INTO v_active_route_count FROM route_assignments r WHERE r.user_id = p_id;
SELECT COALESCE(SUM(CASE WHEN fl.transaction_type = 'revenue' THEN fl.amount ELSE 0 END), 0.00), COALESCE(SUM(CASE WHEN fl.transaction_type = 'expense' THEN fl.amount ELSE 0 END), 0.00) INTO v_revenue_30d, v_expense_30d FROM financial_ledger fl WHERE fl.user_id = p_id AND fl.game_date >= v_game_current_time - INTERVAL '30 days';
RETURN QUERY SELECT p_id, p_is_bot, v_company_name::VARCHAR, v_cash, v_net_worth, v_owned_asset_value, v_leased_monthly_exposure, v_fleet_count, v_owned_fleet_count, v_leased_fleet_count, v_active_route_count, v_revenue_30d, v_expense_30d, v_revenue_30d - v_expense_30d, v_ledger_window_days; END;
$function$;

CREATE OR REPLACE FUNCTION public.get_finance_snapshot()
RETURNS TABLE(actor_id uuid, is_bot boolean, company_name character varying, cash numeric, net_worth numeric, owned_aircraft_asset_value numeric, leased_aircraft_monthly_exposure numeric, fleet_count integer, owned_fleet_count integer, leased_fleet_count integer, active_route_count integer, rolling_revenue_30d numeric, rolling_expense_30d numeric, rolling_net_30d numeric, ledger_window_days integer)
LANGUAGE plpgsql STABLE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM get_finance_snapshot(v_user_id, FALSE); END;
$function$;

CREATE OR REPLACE FUNCTION public.get_fleet_commonality_discount(p_user_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_max_same_mfr INT := 0; v_total_fleet INT := 0;
BEGIN SELECT COUNT(*) INTO v_total_fleet FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = p_user_id AND f.status = 'active'; IF v_total_fleet < 2 THEN RETURN 0.0; END IF; SELECT COALESCE(MAX(cnt), 0) INTO v_max_same_mfr FROM (SELECT COUNT(*) AS cnt FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = p_user_id AND f.status = 'active' GROUP BY m.manufacturer) sub; RETURN LEAST(0.20, (v_max_same_mfr - 1) * 0.05); END;
$function$;

CREATE OR REPLACE FUNCTION public.get_owner_route_optimizer(p_user_id uuid, p_origin_iata character varying DEFAULT NULL::character varying, p_destination_iata character varying DEFAULT NULL::character varying, p_limit integer DEFAULT 25, p_include_assigned boolean DEFAULT false, p_exclude_existing_routes boolean DEFAULT true)
RETURNS TABLE(aircraft_id uuid, tail_number character varying, aircraft_model character varying, acquisition_type character varying, currently_assigned boolean, route_origin_iata character varying, route_destination_iata character varying, route_already_exists boolean, distance_km numeric, ticket_price numeric, weekly_flights integer, recommended_economy_seats integer, recommended_business_seats integer, recommended_first_class_seats integer, effective_passenger_capacity integer, expected_passengers_per_flight integer, load_factor numeric, direct_cost_per_flight numeric, revenue_per_flight numeric, contribution_per_flight numeric, weekly_contribution numeric, maintenance_impact_per_week numeric)
LANGUAGE plpgsql STABLE AS $function$
DECLARE v_origin_iata VARCHAR(3);
BEGIN
    SELECT COALESCE(p_origin_iata, hq_airport_iata) INTO v_origin_iata FROM users WHERE id = p_user_id;
    IF v_origin_iata IS NULL THEN RETURN; END IF;
    RETURN QUERY
    WITH origin_airport AS (SELECT a.* FROM airports a WHERE a.iata = v_origin_iata LIMIT 1),
    settings AS (SELECT COALESCE(MAX(ggs.fuel_price_per_liter), 0.85) AS fuel_price_per_liter FROM global_game_settings ggs),
    aircraft_candidates AS (SELECT f.id AS candidate_aircraft_id, f.tail_number AS candidate_tail_number, f.acquisition_type AS candidate_acquisition_type, m.model_name AS candidate_model_name, m.capacity AS model_capacity, m.range_km AS model_range_km, m.speed_kmh AS model_speed_kmh, m.fuel_burn_per_km AS model_fuel_burn_per_km, m.maintenance_cost_per_hour AS model_maintenance_cost_per_hour, EXISTS (SELECT 1 FROM route_assignments r WHERE r.user_id = p_user_id AND r.assigned_aircraft_id = f.id) AS candidate_currently_assigned FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.user_id = p_user_id AND (p_include_assigned OR NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.user_id = p_user_id AND r.assigned_aircraft_id = f.id))),
    destination_candidates AS (SELECT dst.iata AS destination_iata, dst.demand_index AS destination_demand_index, dst.airport_tax AS destination_airport_tax, ROUND((6371.0 * 2.0 * ASIN(SQRT(POWER(SIN(RADIANS(dst.latitude - org.latitude) / 2.0), 2) + COS(RADIANS(org.latitude)) * COS(RADIANS(dst.latitude)) * POWER(SIN(RADIANS(dst.longitude - org.longitude) / 2.0), 2))))::NUMERIC, 2) AS route_distance_km FROM airports dst CROSS JOIN origin_airport org WHERE dst.iata <> org.iata AND (p_destination_iata IS NULL OR dst.iata = p_destination_iata)),
    candidate_pairs AS (SELECT ac.*, dc.destination_iata, dc.destination_demand_index, dc.destination_airport_tax, dc.route_distance_km, org.iata AS origin_iata, org.demand_index AS origin_demand_index, org.airport_tax AS origin_airport_tax FROM aircraft_candidates ac CROSS JOIN destination_candidates dc CROSS JOIN origin_airport org WHERE dc.route_distance_km <= ac.model_range_km),
    seat_presets AS (SELECT cp.*, seat_profile.preset_economy_seats, seat_profile.preset_business_seats, seat_profile.preset_first_class_seats, GREATEST(0, COALESCE(NULLIF(COALESCE(seat_profile.preset_economy_seats, 0) + COALESCE(seat_profile.preset_business_seats, 0) + COALESCE(seat_profile.preset_first_class_seats, 0), 0), COALESCE(cp.model_capacity, 0)))::INT AS passenger_capacity FROM candidate_pairs cp CROSS JOIN LATERAL (VALUES (cp.model_capacity, 0, 0), (GREATEST(1, cp.model_capacity - (2 * FLOOR(cp.model_capacity * 0.18 / 2.0)::INT) - (3 * FLOOR(cp.model_capacity * 0.06 / 3.0)::INT)), FLOOR(cp.model_capacity * 0.18 / 2.0)::INT, FLOOR(cp.model_capacity * 0.06 / 3.0)::INT), (GREATEST(1, cp.model_capacity - (2 * FLOOR(cp.model_capacity * 0.24 / 2.0)::INT) - (3 * FLOOR(cp.model_capacity * 0.12 / 3.0)::INT)), FLOOR(cp.model_capacity * 0.24 / 2.0)::INT, FLOOR(cp.model_capacity * 0.12 / 3.0)::INT)) AS seat_profile(preset_economy_seats, preset_business_seats, preset_first_class_seats)),
    fare_points AS (SELECT sp.*, ROUND((50.00 + (COALESCE(sp.route_distance_km, 0.0)::NUMERIC * 0.12)) * fare.multiplier, 2) AS evaluated_ticket_price FROM seat_presets sp CROSS JOIN LATERAL (VALUES (0.95::NUMERIC), (1.00::NUMERIC), (1.05::NUMERIC), (1.10::NUMERIC), (1.20::NUMERIC), (1.35::NUMERIC)) AS fare(multiplier)),
    scored AS (SELECT fp.candidate_aircraft_id, fp.candidate_tail_number, fp.candidate_model_name, fp.candidate_acquisition_type, fp.candidate_currently_assigned, fp.origin_iata, fp.destination_iata, EXISTS (SELECT 1 FROM route_assignments existing_route WHERE existing_route.user_id = p_user_id AND existing_route.origin_iata = fp.origin_iata AND existing_route.destination_iata = fp.destination_iata) AS candidate_route_already_exists, fp.route_distance_km, fp.evaluated_ticket_price, CASE WHEN COALESCE(fp.route_distance_km, 0.0) <= 0.0 OR COALESCE(fp.model_speed_kmh, 0) <= 0 THEN 0 ELSE FLOOR(168.0 / NULLIF((COALESCE(fp.route_distance_km, 0.0) / fp.model_speed_kmh::DOUBLE PRECISION) + 1.0, 0.0))::INT END AS computed_weekly_flights, fp.preset_economy_seats, fp.preset_business_seats, fp.preset_first_class_seats, fp.passenger_capacity, GREATEST(0, LEAST(COALESCE(fp.passenger_capacity, 0), FLOOR(COALESCE(fp.passenger_capacity, 0) * 0.95 * GREATEST(0.55, LEAST(1.00, 0.55 + (((((COALESCE(fp.origin_demand_index, 50) + COALESCE(fp.destination_demand_index, 50))::NUMERIC) / 2.0) / 100.0) * 0.45))) * GREATEST(0.00, LEAST(1.50, 1.5 - 0.8 * POWER(COALESCE(fp.evaluated_ticket_price, 0.00) / NULLIF(50.00 + (COALESCE(fp.route_distance_km, 0.0)::NUMERIC * 0.12), 0.00), 2))))::INT)) AS computed_expected_passengers_per_flight, ROUND((fp.route_distance_km * fp.model_fuel_burn_per_km * s.fuel_price_per_liter + (((fp.route_distance_km / NULLIF(fp.model_speed_kmh::DOUBLE PRECISION, 0.0)) + 1.0) * fp.model_maintenance_cost_per_hour) + fp.origin_airport_tax + fp.destination_airport_tax)::NUMERIC, 2) AS computed_direct_cost_per_flight FROM fare_points fp CROSS JOIN settings s),
    ranked AS (SELECT s.candidate_aircraft_id, s.candidate_tail_number, s.candidate_model_name, s.candidate_acquisition_type, s.candidate_currently_assigned, s.origin_iata, s.destination_iata, s.candidate_route_already_exists, s.route_distance_km, s.evaluated_ticket_price, s.computed_weekly_flights, s.preset_economy_seats, s.preset_business_seats, s.preset_first_class_seats, s.passenger_capacity, s.computed_expected_passengers_per_flight, ROUND(CASE WHEN s.passenger_capacity <= 0 THEN 0.00 ELSE (s.computed_expected_passengers_per_flight::NUMERIC / s.passenger_capacity::NUMERIC) * 100.00 END, 2) AS computed_load_factor, s.computed_direct_cost_per_flight, ROUND((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price)::NUMERIC, 2) AS computed_revenue_per_flight, ROUND(((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price) - s.computed_direct_cost_per_flight)::NUMERIC, 2) AS computed_contribution_per_flight, ROUND((((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price) - s.computed_direct_cost_per_flight) * s.computed_weekly_flights * CASE WHEN s.candidate_route_already_exists THEN 0.72 ELSE 1.00 END)::NUMERIC, 2) AS adjusted_weekly_contribution, ROUND(CASE WHEN s.candidate_acquisition_type = 'lease' THEN s.computed_weekly_flights * 0.70 ELSE s.computed_weekly_flights * 0.50 END::NUMERIC, 2) AS computed_maintenance_impact_per_week, ROW_NUMBER() OVER (PARTITION BY s.origin_iata, s.destination_iata, s.candidate_model_name, s.candidate_acquisition_type, s.preset_economy_seats, s.preset_business_seats, s.preset_first_class_seats, s.evaluated_ticket_price ORDER BY s.candidate_currently_assigned ASC, s.candidate_tail_number ASC, s.candidate_aircraft_id ASC) AS route_model_rank FROM scored s WHERE s.computed_weekly_flights > 0 AND (NOT p_exclude_existing_routes OR NOT s.candidate_route_already_exists))
    SELECT r.candidate_aircraft_id, r.candidate_tail_number, r.candidate_model_name, r.candidate_acquisition_type, r.candidate_currently_assigned, r.origin_iata, r.destination_iata, r.candidate_route_already_exists, r.route_distance_km, r.evaluated_ticket_price, r.computed_weekly_flights, r.preset_economy_seats, r.preset_business_seats, r.preset_first_class_seats, r.passenger_capacity, r.computed_expected_passengers_per_flight, r.computed_load_factor, r.computed_direct_cost_per_flight, r.computed_revenue_per_flight, r.computed_contribution_per_flight, r.adjusted_weekly_contribution, r.computed_maintenance_impact_per_week FROM ranked r WHERE r.route_model_rank = 1 ORDER BY r.adjusted_weekly_contribution DESC LIMIT p_limit;
END;
$function$;

-- ── Group 10: Compaction/Maintenance ──

CREATE OR REPLACE FUNCTION public.get_financial_ledger_compaction_report()
RETURNS TABLE(actor_id uuid, is_bot boolean, company_name character varying, summary_game_date date, summary_month date, transaction_type character varying, category character varying, source_row_count bigint, total_amount numeric, first_game_date timestamp with time zone, last_game_date timestamp with time zone, first_created_at timestamp with time zone, last_created_at timestamp with time zone, retention_game_days integer, actor_game_current_time timestamp with time zone, cutoff_game_time timestamp with time zone)
LANGUAGE plpgsql STABLE AS $function$
BEGIN RETURN QUERY WITH actor_cutoffs AS (SELECT u.id AS actor_id, FALSE AS is_bot, u.company_name, u.game_current_time AS actor_game_current_time, COALESCE(policy.value_int, 90) AS retention_game_days, u.game_current_time - make_interval(days => COALESCE(policy.value_int, 90)) AS cutoff_game_time FROM users u LEFT JOIN data_retention_policy policy ON policy.key = 'player_ledger_raw_game_days'), eligible AS (SELECT ac.actor_id, ac.is_bot, ac.company_name, ac.retention_game_days, ac.actor_game_current_time, ac.cutoff_game_time, fl.transaction_type, fl.category, fl.amount, fl.game_date, fl.created_at FROM financial_ledger fl JOIN actor_cutoffs ac ON fl.user_id = ac.actor_id WHERE fl.game_date < ac.cutoff_game_time) SELECT eligible.actor_id, eligible.is_bot, eligible.company_name, (eligible.game_date AT TIME ZONE 'UTC')::DATE, date_trunc('month', eligible.game_date AT TIME ZONE 'UTC')::DATE, eligible.transaction_type, eligible.category, COUNT(*)::BIGINT, COALESCE(SUM(eligible.amount), 0.00)::NUMERIC, MIN(eligible.game_date), MAX(eligible.game_date), MIN(eligible.created_at), MAX(eligible.created_at), eligible.retention_game_days, eligible.actor_game_current_time, eligible.cutoff_game_time FROM eligible GROUP BY eligible.actor_id, eligible.is_bot, eligible.company_name, eligible.retention_game_days, eligible.actor_game_current_time, eligible.cutoff_game_time, (eligible.game_date AT TIME ZONE 'UTC')::DATE, date_trunc('month', eligible.game_date AT TIME ZONE 'UTC')::DATE, eligible.transaction_type, eligible.category; END;
$function$;

CREATE OR REPLACE FUNCTION public.compact_financial_ledger(p_dry_run boolean DEFAULT true)
RETURNS TABLE(action text, actor_id uuid, is_bot boolean, company_name character varying, summary_game_date date, summary_month date, transaction_type character varying, category character varying, source_row_count bigint, total_amount numeric, first_game_date timestamp with time zone, last_game_date timestamp with time zone, first_created_at timestamp with time zone, last_created_at timestamp with time zone, retention_game_days integer, actor_game_current_time timestamp with time zone, cutoff_game_time timestamp with time zone, raw_rows_deleted bigint)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_deleted_rows BIGINT := 0;
BEGIN CREATE TEMP TABLE tmp_financial_ledger_compaction_report ON COMMIT DROP AS SELECT * FROM get_financial_ledger_compaction_report(); IF p_dry_run THEN RETURN QUERY SELECT 'dry_run'::TEXT, report.actor_id, report.is_bot, report.company_name, report.summary_game_date, report.summary_month, report.transaction_type, report.category, report.source_row_count, report.total_amount, report.first_game_date, report.last_game_date, report.first_created_at, report.last_created_at, report.retention_game_days, report.actor_game_current_time, report.cutoff_game_time, 0::BIGINT FROM tmp_financial_ledger_compaction_report report ORDER BY report.summary_game_date ASC, report.is_bot ASC, report.actor_id ASC, report.transaction_type ASC, report.category ASC; RETURN; END IF; INSERT INTO financial_ledger_summary (actor_id, is_bot, summary_game_date, summary_month, transaction_type, category, source_row_count, total_amount, first_game_date, last_game_date, first_created_at, last_created_at, compacted_at) SELECT report.actor_id, report.is_bot, report.summary_game_date, report.summary_month, report.transaction_type, report.category, report.source_row_count, report.total_amount, report.first_game_date, report.last_game_date, report.first_created_at, report.last_created_at, NOW() FROM tmp_financial_ledger_compaction_report report ON CONFLICT (actor_id, is_bot, summary_game_date, transaction_type, category) DO UPDATE SET source_row_count = financial_ledger_summary.source_row_count + EXCLUDED.source_row_count, total_amount = financial_ledger_summary.total_amount + EXCLUDED.total_amount, last_game_date = GREATEST(financial_ledger_summary.last_game_date, EXCLUDED.last_game_date), last_created_at = GREATEST(financial_ledger_summary.last_created_at, EXCLUDED.last_created_at), compacted_at = NOW(); WITH to_delete AS (SELECT fl.id FROM financial_ledger fl JOIN tmp_financial_ledger_compaction_report report ON fl.user_id = report.actor_id AND fl.transaction_type = report.transaction_type AND fl.category = report.category AND fl.game_date < report.cutoff_game_time) SELECT COUNT(*) INTO v_deleted_rows FROM to_delete; DELETE FROM financial_ledger WHERE id IN (SELECT fl.id FROM financial_ledger fl JOIN tmp_financial_ledger_compaction_report report ON fl.user_id = report.actor_id AND fl.transaction_type = report.transaction_type AND fl.category = report.category AND fl.game_date < report.cutoff_game_time); RETURN QUERY SELECT 'compacted'::TEXT, report.actor_id, report.is_bot, report.company_name, report.summary_game_date, report.summary_month, report.transaction_type, report.category, report.source_row_count, report.total_amount, report.first_game_date, report.last_game_date, report.first_created_at, report.last_created_at, report.retention_game_days, report.actor_game_current_time, report.cutoff_game_time, v_deleted_rows FROM tmp_financial_ledger_compaction_report report ORDER BY report.summary_game_date ASC, report.is_bot ASC, report.actor_id ASC, report.transaction_type ASC, report.category ASC; END;
$function$;

CREATE OR REPLACE FUNCTION public.get_world_tick_log_compaction_report()
RETURNS TABLE(season_id uuid, summary_date date, status character varying, source_row_count bigint, first_started_at timestamp with time zone, last_finished_at timestamp with time zone, first_game_time_before timestamp with time zone, last_game_time_after timestamp with time zone, total_ticks_processed bigint, total_real_seconds_processed numeric, total_game_seconds_processed numeric, total_players_processed bigint, total_bots_processed bigint, latest_message text, retention_real_days integer, cutoff_started_at timestamp with time zone)
LANGUAGE plpgsql STABLE AS $function$
DECLARE v_retention_days INT; v_cutoff TIMESTAMP WITH TIME ZONE;
BEGIN SELECT value_int INTO v_retention_days FROM data_retention_policy WHERE key = 'world_tick_log_raw_real_days'; v_retention_days := COALESCE(v_retention_days, 7); v_cutoff := NOW() - make_interval(days => v_retention_days); RETURN QUERY WITH eligible AS (SELECT * FROM world_tick_log WHERE started_at < v_cutoff) SELECT grouped.season_id, grouped.summary_date, grouped.status, grouped.source_row_count, grouped.first_started_at, grouped.last_finished_at, grouped.first_game_time_before, grouped.last_game_time_after, grouped.total_ticks_processed, grouped.total_real_seconds_processed, grouped.total_game_seconds_processed, grouped.total_players_processed, grouped.total_bots_processed, grouped.latest_message, v_retention_days, v_cutoff FROM (SELECT eligible.season_id, (eligible.started_at AT TIME ZONE 'UTC')::DATE AS summary_date, eligible.status, COUNT(*)::BIGINT AS source_row_count, MIN(eligible.started_at), MAX(eligible.finished_at), (ARRAY_AGG(eligible.game_time_before ORDER BY eligible.started_at ASC NULLS LAST))[1], (ARRAY_AGG(eligible.game_time_after ORDER BY COALESCE(eligible.finished_at, eligible.started_at) DESC NULLS LAST))[1], COALESCE(SUM(eligible.ticks_processed), 0)::BIGINT, COALESCE(SUM(eligible.real_seconds_processed), 0.0000)::NUMERIC, COALESCE(SUM(eligible.game_seconds_processed), 0.0000)::NUMERIC, COALESCE(SUM(eligible.players_processed), 0)::BIGINT, COALESCE(SUM(eligible.bots_processed), 0)::BIGINT, (ARRAY_AGG(eligible.message ORDER BY eligible.started_at DESC NULLS LAST))[1] FROM eligible GROUP BY eligible.season_id, (eligible.started_at AT TIME ZONE 'UTC')::DATE, eligible.status) grouped; END;
$function$;

CREATE OR REPLACE FUNCTION public.compact_world_tick_log(p_dry_run boolean DEFAULT true)
RETURNS TABLE(action text, season_id uuid, summary_date date, status character varying, source_row_count bigint, first_started_at timestamp with time zone, last_finished_at timestamp with time zone, first_game_time_before timestamp with time zone, last_game_time_after timestamp with time zone, total_ticks_processed bigint, total_real_seconds_processed numeric, total_game_seconds_processed numeric, total_players_processed bigint, total_bots_processed bigint, latest_message text, retention_real_days integer, cutoff_started_at timestamp with time zone, raw_rows_deleted bigint)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_deleted_rows BIGINT := 0;
BEGIN CREATE TEMP TABLE tmp_world_tick_compaction_report ON COMMIT DROP AS SELECT * FROM get_world_tick_log_compaction_report(); IF p_dry_run THEN RETURN QUERY SELECT 'dry_run'::TEXT, report.season_id, report.summary_date, report.status, report.source_row_count, report.first_started_at, report.last_finished_at, report.first_game_time_before, report.last_game_time_after, report.total_ticks_processed, report.total_real_seconds_processed, report.total_game_seconds_processed, report.total_players_processed, report.total_bots_processed, report.latest_message, report.retention_real_days, report.cutoff_started_at, 0::BIGINT FROM tmp_world_tick_compaction_report report ORDER BY report.summary_date ASC, report.season_id ASC, report.status ASC; RETURN; END IF; INSERT INTO world_tick_daily_summary (season_id, summary_date, status, source_row_count, first_started_at, last_finished_at, first_game_time_before, last_game_time_after, total_ticks_processed, total_real_seconds_processed, total_game_seconds_processed, total_players_processed, total_bots_processed, latest_message, compacted_at) SELECT report.season_id, report.summary_date, report.status, report.source_row_count, report.first_started_at, report.last_finished_at, report.first_game_time_before, report.last_game_time_after, report.total_ticks_processed, report.total_real_seconds_processed, report.total_game_seconds_processed, report.total_players_processed, report.total_bots_processed, report.latest_message, NOW() FROM tmp_world_tick_compaction_report report ON CONFLICT (season_id, summary_date, status) DO UPDATE SET source_row_count = world_tick_daily_summary.source_row_count + EXCLUDED.source_row_count, last_finished_at = GREATEST(world_tick_daily_summary.last_finished_at, EXCLUDED.last_finished_at), total_ticks_processed = world_tick_daily_summary.total_ticks_processed + EXCLUDED.total_ticks_processed, total_real_seconds_processed = world_tick_daily_summary.total_real_seconds_processed + EXCLUDED.total_real_seconds_processed, total_game_seconds_processed = world_tick_daily_summary.total_game_seconds_processed + EXCLUDED.total_game_seconds_processed, total_players_processed = world_tick_daily_summary.total_players_processed + EXCLUDED.total_players_processed, total_bots_processed = world_tick_daily_summary.total_bots_processed + EXCLUDED.total_bots_processed, latest_message = EXCLUDED.latest_message, compacted_at = NOW(); WITH to_delete AS (SELECT wtl.id FROM world_tick_log wtl JOIN tmp_world_tick_compaction_report report ON wtl.season_id = report.season_id AND (wtl.started_at AT TIME ZONE 'UTC')::DATE = report.summary_date AND wtl.status = report.status AND wtl.started_at < report.cutoff_started_at) SELECT COUNT(*) INTO v_deleted_rows FROM to_delete; DELETE FROM world_tick_log WHERE id IN (SELECT wtl.id FROM world_tick_log wtl JOIN tmp_world_tick_compaction_report report ON wtl.season_id = report.season_id AND (wtl.started_at AT TIME ZONE 'UTC')::DATE = report.summary_date AND wtl.status = report.status AND wtl.started_at < report.cutoff_started_at); RETURN QUERY SELECT 'compacted'::TEXT, report.season_id, report.summary_date, report.status, report.source_row_count, report.first_started_at, report.last_finished_at, report.first_game_time_before, report.last_game_time_after, report.total_ticks_processed, report.total_real_seconds_processed, report.total_game_seconds_processed, report.total_players_processed, report.total_bots_processed, report.latest_message, report.retention_real_days, report.cutoff_started_at, v_deleted_rows FROM tmp_world_tick_compaction_report report ORDER BY report.summary_date ASC, report.season_id ASC, report.status ASC; END;
$function$;

-- ── Group 11: Health/Diagnostics ──

CREATE OR REPLACE FUNCTION public.get_database_size_report()
RETURNS TABLE(database_name text, database_size_bytes bigint, database_size_pretty text, free_quota_mb integer, used_quota_percent numeric, status text)
LANGUAGE plpgsql STABLE AS $function$
DECLARE v_size BIGINT; v_quota_mb INT; v_warn_mb INT; v_critical_mb INT;
BEGIN v_size := pg_database_size(current_database()); SELECT value_int INTO v_quota_mb FROM data_retention_policy WHERE key = 'database_free_quota_mb'; SELECT value_int INTO v_warn_mb FROM data_retention_policy WHERE key = 'database_warn_mb'; SELECT value_int INTO v_critical_mb FROM data_retention_policy WHERE key = 'database_critical_mb'; v_quota_mb := COALESCE(v_quota_mb, 500); v_warn_mb := COALESCE(v_warn_mb, 350); v_critical_mb := COALESCE(v_critical_mb, 425); RETURN QUERY SELECT current_database()::TEXT, v_size, pg_size_pretty(v_size), v_quota_mb, ROUND(((v_size::NUMERIC / (v_quota_mb::NUMERIC * 1024 * 1024)) * 100), 2), CASE WHEN v_size >= (v_critical_mb::BIGINT * 1024 * 1024) THEN 'critical' WHEN v_size >= (v_warn_mb::BIGINT * 1024 * 1024) THEN 'warn' ELSE 'ok' END; END;
$function$;

CREATE OR REPLACE FUNCTION public.get_table_size_report()
RETURNS TABLE(schema_name text, table_name text, row_estimate bigint, total_size_bytes bigint, total_size_pretty text, table_size_pretty text, index_size_pretty text)
LANGUAGE plpgsql STABLE AS $function$
BEGIN RETURN QUERY SELECT stat.schemaname::TEXT, stat.relname::TEXT, stat.n_live_tup::BIGINT, pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)::BIGINT, pg_size_pretty(pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)), pg_size_pretty(pg_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)), pg_size_pretty(pg_indexes_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)) FROM pg_stat_user_tables stat WHERE stat.schemaname = 'public' ORDER BY pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS) DESC; END;
$function$;

CREATE OR REPLACE FUNCTION public.get_world_tick_guardrail_report()
RETURNS TABLE(check_name text, check_status text, details text)
LANGUAGE plpgsql STABLE AS $function$
DECLARE r_season RECORD; r_latest_success RECORD; v_lagging_actors INT := 0; v_ahead_actors INT := 0; v_backwards_logs INT := 0;
BEGIN SELECT * INTO r_season FROM season_clock WHERE status = 'active' ORDER BY created_at ASC LIMIT 1; IF NOT FOUND THEN RETURN QUERY SELECT 'active_season_exists', 'fail', 'No active season_clock row exists.'; RETURN; END IF; RETURN QUERY SELECT 'active_season_exists', 'pass', 'Active season ' || r_season.id || ' at ' || r_season.current_game_time || '.'; SELECT COUNT(*)::INT INTO v_lagging_actors FROM users u WHERE u.season_id = r_season.id AND u.game_current_time < r_season.current_game_time; RETURN QUERY SELECT 'actors_not_lagging', CASE WHEN v_lagging_actors = 0 THEN 'pass' ELSE 'fail' END, 'lagging_actors=' || v_lagging_actors || '.'; SELECT COUNT(*)::INT INTO v_ahead_actors FROM users u WHERE u.season_id = r_season.id AND u.game_current_time > r_season.current_game_time; RETURN QUERY SELECT 'actors_not_ahead', CASE WHEN v_ahead_actors = 0 THEN 'pass' ELSE 'fail' END, 'ahead_actors=' || v_ahead_actors || '.'; SELECT COUNT(*)::INT INTO v_backwards_logs FROM world_tick_log wtl WHERE wtl.status = 'success' AND wtl.game_time_after < wtl.game_time_before; RETURN QUERY SELECT 'no_backwards_world_ticks', CASE WHEN v_backwards_logs = 0 THEN 'pass' ELSE 'fail' END, 'backwards_success_logs=' || v_backwards_logs || '.'; SELECT * INTO r_latest_success FROM world_tick_log wtl WHERE wtl.season_id = r_season.id AND wtl.status = 'success' ORDER BY wtl.started_at DESC LIMIT 1; IF NOT FOUND THEN RETURN QUERY SELECT 'recent_successful_world_tick', 'fail', 'No successful world_tick_log rows exist for active season.'; ELSE RETURN QUERY SELECT 'recent_successful_world_tick', CASE WHEN r_latest_success.started_at > NOW() - INTERVAL '5 minutes' THEN 'pass' ELSE 'warn' END, 'Last success at ' || r_latest_success.started_at || '.'; END IF; END;
$function$;

CREATE OR REPLACE FUNCTION public.get_world_tick_scheduler_health()
RETURNS TABLE(season_id uuid, season_status character varying, current_game_time timestamp with time zone, season_last_tick_at timestamp with time zone, seconds_since_last_tick numeric, latest_log_started_at timestamp with time zone, latest_log_status character varying, latest_log_message text, latest_ticks_processed integer, scheduler_job_exists boolean, scheduler_job_active boolean)
LANGUAGE plpgsql STABLE AS $function$
DECLARE r_season RECORD; r_log RECORD; r_job RECORD;
BEGIN SELECT * INTO r_season FROM public.season_clock WHERE status = 'active' ORDER BY created_at ASC LIMIT 1; IF NOT FOUND THEN RETURN; END IF; SELECT * INTO r_log FROM public.world_tick_log WHERE world_tick_log.season_id = r_season.id ORDER BY started_at DESC LIMIT 1; SELECT * INTO r_job FROM cron.job WHERE jobname = 'skyward_world_tick' LIMIT 1; RETURN QUERY SELECT r_season.id, r_season.status::VARCHAR, r_season.current_game_time, r_season.last_tick_at, EXTRACT(EPOCH FROM (NOW() - r_season.last_tick_at))::NUMERIC, r_log.started_at, r_log.status::VARCHAR, r_log.message, COALESCE(r_log.ticks_processed, 0), (r_job.jobid IS NOT NULL), COALESCE(r_job.active, FALSE); END;
$function$;

-- ── Group 12: Auth trigger ──

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_username TEXT; v_expected_email TEXT; v_company_name TEXT; v_ceo_name TEXT; v_starting_cash NUMERIC;
BEGIN IF EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = NEW.id) THEN RETURN NEW; END IF; v_username := public.normalize_username(NEW.raw_user_meta_data ->> 'username'); v_company_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'company_name', '')), ''); v_ceo_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'ceo_name', '')), ''); IF v_username IS NULL THEN RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.username'; END IF; IF v_company_name IS NULL THEN RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.company_name'; END IF; IF v_ceo_name IS NULL THEN RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.ceo_name'; END IF; v_expected_email := public.build_synthetic_auth_email(v_username); IF lower(COALESCE(NEW.email, '')) <> v_expected_email THEN RAISE EXCEPTION 'Auth bootstrap email mismatch for username %', v_username; END IF; IF EXISTS (SELECT 1 FROM public.users u WHERE u.username = v_username) THEN RAISE EXCEPTION 'Username % is already registered.', v_username; END IF; IF EXISTS (SELECT 1 FROM public.users u WHERE u.company_name = v_company_name) THEN RAISE EXCEPTION 'Company name % is already registered.', v_company_name; END IF; SELECT COALESCE((SELECT g.starting_cash::NUMERIC FROM public.global_game_settings g LIMIT 1), 15000000.00) INTO v_starting_cash; INSERT INTO public.users (auth_user_id, username, company_name, ceo_name, cash, net_worth, game_current_time, last_active_at, operational_status, consecutive_negative_days, recovery_streak_days, auto_grounding_threshold, credit_score, credit_tier, actor_type) VALUES (NEW.id, v_username, v_company_name, v_ceo_name, v_starting_cash, v_starting_cash, '2020-01-01 00:00:00+00', NOW(), 'Active', 0, 0, 40.00, 500, 'Standard', 'REAL'); RETURN NEW; END;
$function$;

-- ── Group 13: Simulation delta ──

CREATE OR REPLACE FUNCTION public.process_simulation_delta(p_user_id uuid)
RETURNS TABLE(cash_before numeric, cash_after numeric, elapsed_real_sec double precision, elapsed_game_days double precision, flights_run integer)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_season_time TIMESTAMPTZ; v_result RECORD;
BEGIN SELECT current_game_time INTO v_season_time FROM season_clock WHERE status = 'active' LIMIT 1; IF v_season_time IS NULL THEN RAISE EXCEPTION 'No active season found'; END IF; SELECT * INTO v_result FROM process_player_simulation_to_time(p_user_id, v_season_time); cash_before := 0; cash_after := v_result.cash; elapsed_real_sec := 0; elapsed_game_days := v_result.elapsed_days; flights_run := v_result.flights_run; RETURN NEXT; END;
$function$;

CREATE OR REPLACE FUNCTION public.process_simulation_delta()
RETURNS TABLE(cash_before numeric, cash_after numeric, elapsed_real_sec double precision, elapsed_game_days double precision, flights_run integer)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE v_user_id UUID;
BEGIN v_user_id := public.require_current_user_id(); RETURN QUERY SELECT * FROM process_simulation_delta(v_user_id); END;
$function$;


-- ============================================================================
-- ── Triggers ──
-- ============================================================================

DROP TRIGGER IF EXISTS assign_active_season_id ON public.users;
CREATE TRIGGER assign_active_season_id
    BEFORE INSERT ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.trg_assign_active_season_id();

DROP TRIGGER IF EXISTS create_default_bank_account ON public.users;
CREATE TRIGGER create_default_bank_account
    AFTER INSERT ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.trg_create_default_bank_account();

DROP TRIGGER IF EXISTS sync_checking_balance ON public.users;
CREATE TRIGGER sync_checking_balance
    AFTER UPDATE OF cash ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.trg_sync_checking_balance();

DROP TRIGGER IF EXISTS sync_tail_numbers_on_hq_change ON public.users;
CREATE TRIGGER sync_tail_numbers_on_hq_change
    AFTER UPDATE OF hq_airport_iata ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.trg_sync_tail_numbers_on_hq_change();

DROP TRIGGER IF EXISTS update_user_net_worth ON public.users;
CREATE TRIGGER update_user_net_worth
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.trg_update_user_net_worth();

DROP TRIGGER IF EXISTS fleet_reconcile_net_worth ON public.fleet_aircraft;
CREATE TRIGGER fleet_reconcile_net_worth
    AFTER INSERT OR UPDATE OR DELETE ON public.fleet_aircraft
    FOR EACH ROW EXECUTE FUNCTION public.trg_fleet_reconcile_net_worth();

DROP TRIGGER IF EXISTS set_acquired_game_date ON public.fleet_aircraft;
CREATE TRIGGER set_acquired_game_date
    BEFORE INSERT ON public.fleet_aircraft
    FOR EACH ROW EXECUTE FUNCTION public.trg_set_acquired_game_date();

DROP TRIGGER IF EXISTS set_default_fare_buckets ON public.route_assignments;
CREATE TRIGGER set_default_fare_buckets
    BEFORE INSERT ON public.route_assignments
    FOR EACH ROW EXECUTE FUNCTION public.trg_set_default_fare_buckets();

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- ============================================================================
-- ── Grants ──
-- ============================================================================

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;
GRANT USAGE ON SCHEMA public TO anon;

GRANT SELECT, INSERT, UPDATE ON public.users TO authenticated;
GRANT SELECT ON public.fleet_aircraft TO authenticated;
GRANT SELECT ON public.route_assignments TO authenticated;
GRANT SELECT ON public.financial_ledger TO authenticated;
GRANT SELECT ON public.financial_ledger_summary TO authenticated;
GRANT SELECT ON public.loans TO authenticated;
GRANT SELECT ON public.credit_scores TO authenticated;
GRANT SELECT ON public.credit_score_history TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.bank_accounts TO authenticated;
GRANT SELECT, INSERT ON public.bank_transactions TO authenticated;
GRANT SELECT, INSERT ON public.achievements TO authenticated;
GRANT SELECT ON public.rank_history TO authenticated;
GRANT SELECT ON public.game_events TO authenticated;
GRANT SELECT ON public.world_tick_log TO authenticated;
GRANT SELECT ON public.world_tick_daily_summary TO authenticated;
GRANT SELECT ON public.airports TO authenticated;
GRANT SELECT ON public.aircraft_models TO authenticated;
GRANT SELECT ON public.season_clock TO authenticated;
GRANT SELECT ON public.global_game_settings TO authenticated;
GRANT SELECT ON public.data_retention_policy TO authenticated;
GRANT SELECT ON public.scheduler_config TO authenticated;

GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO service_role;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;

GRANT USAGE ON SCHEMA extensions TO authenticated;
GRANT USAGE ON SCHEMA extensions TO service_role;

-- ============================================================================
-- ── Seed Data ──
-- ============================================================================

-- global_game_settings: 1 row
INSERT INTO public.global_game_settings (id, starting_cash, fuel_price_per_liter, absolute_minimum_safety_limit, max_bot_count, base_lease_deposit_percentage, time_scale_multiplier, credit_tier_config, savings_tiers, crew_cost_per_hour)
VALUES (1, 15000000, 0.85, 30.00, 5, 0.10, 60.00,
    '{"tiers":{"Gold":{"min_score":750,"max_secured":75000000,"rate_secured":0.03,"max_financing":60000000,"max_unsecured":30000000,"rate_financing":0.04,"rate_unsecured":0.04},"Silver":{"min_score":600,"max_secured":50000000,"rate_secured":0.04,"max_financing":40000000,"max_unsecured":15000000,"rate_financing":0.05,"rate_unsecured":0.05},"Platinum":{"min_score":900,"max_secured":100000000,"rate_secured":0.02,"max_financing":80000000,"max_unsecured":50000000,"rate_financing":0.03,"rate_unsecured":0.03},"Standard":{"min_score":400,"max_secured":25000000,"rate_secured":0.06,"max_financing":20000000,"max_unsecured":5000000,"rate_financing":0.07,"rate_unsecured":0.07},"Subprime":{"min_score":0,"max_secured":10000000,"rate_secured":0.09,"max_financing":5000000,"max_unsecured":1000000,"rate_financing":0.10,"rate_unsecured":0.10}},"min_loan":100000,"max_active_loans":3}'::jsonb,
    '{"tiers":[{"rate":0.010,"max_balance":1000000,"min_balance":0},{"rate":0.015,"max_balance":5000000,"min_balance":1000000},{"rate":0.020,"max_balance":10000000,"min_balance":5000000},{"rate":0.025,"max_balance":25000000,"min_balance":10000000},{"rate":0.030,"max_balance":null,"min_balance":25000000}]}'::jsonb,
    350.0)
ON CONFLICT (id) DO NOTHING;

-- data_retention_policy: 7 rows
INSERT INTO public.data_retention_policy (key, value_int, unit, description) VALUES
    ('player_ledger_raw_game_days', 90, 'game_days', 'Retention window for raw financial_ledger rows before compaction eligibility'),
    ('world_tick_log_raw_real_days', 7, 'real_days', 'Retention window for raw world_tick_log rows before compaction eligibility'),
    ('database_free_quota_mb', 500, 'MB', 'Supabase Free plan database storage quota'),
    ('database_warn_mb', 350, 'MB', 'Database size warning threshold'),
    ('database_critical_mb', 425, 'MB', 'Database size critical threshold'),
    ('compaction_batch_size', 1000, 'rows', 'Maximum rows per compaction batch'),
    ('rank_history_retention_days', 365, 'game_days', 'Retention window for rank_history snapshots')
ON CONFLICT (key) DO NOTHING;

-- scheduler_config: 1 row
INSERT INTO public.scheduler_config (id, job_name, cron_expression, enabled, max_ticks_per_run)
VALUES (1, 'skyward_world_tick', '* * * * *', true, 100)
ON CONFLICT (id) DO NOTHING;

-- season_clock: 1 row (Season 1)
INSERT INTO public.season_clock (id, label, current_game_time, last_tick_at, time_scale_multiplier, tick_interval_seconds, status)
VALUES (gen_random_uuid(), 'Season 1', '2020-01-01 00:00:00+00', now(), 60.00, 60, 'active')
ON CONFLICT DO NOTHING;

-- ============================================================================
-- End of baseline schema
-- ============================================================================
