-- ============================================================================
-- Skyward Supabase Production Baseline Migration
-- Generated: 2026-06-25
-- Source: Live database uikxnfcthytodkaupnmm (Tokyo region)
--
-- This file represents the complete public schema as of Phase 2 Schema Reset.
-- It is self-contained and idempotent (uses IF NOT EXISTS / ON CONFLICT).
-- ============================================================================

-- ============================================================================
-- SECTION 1: Extensions
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;
-- ============================================================================
-- SECTION 2: Tables (in dependency order)
-- ============================================================================

-- ---------- season_clock (no FK dependencies) ----------
CREATE TABLE IF NOT EXISTS public.season_clock (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    label                  varchar(80) NOT NULL,
    current_game_time      timestamptz NOT NULL DEFAULT '2020-01-01 00:00:00+00',
    last_tick_at           timestamptz NOT NULL DEFAULT now(),
    time_scale_multiplier  numeric(10,2) NOT NULL DEFAULT 60.00,
    tick_interval_seconds  integer NOT NULL DEFAULT 60,
    status                 varchar(20) NOT NULL DEFAULT 'active',
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT season_clock_status_check CHECK (status IN ('draft','active','paused','completed')),
    CONSTRAINT season_clock_tick_interval_seconds_check CHECK (tick_interval_seconds > 0)
);

-- ---------- airports (no FK dependencies) ----------
CREATE TABLE IF NOT EXISTS public.airports (
    iata          varchar(3) PRIMARY KEY,
    name          varchar(150) NOT NULL,
    city          varchar(100) NOT NULL,
    country       varchar(100) NOT NULL,
    latitude      double precision NOT NULL,
    longitude     double precision NOT NULL,
    demand_index  integer NOT NULL DEFAULT 50,
    CONSTRAINT airports_demand_index_check CHECK (demand_index >= 1 AND demand_index <= 100)
);

-- ---------- aircraft_models (no FK dependencies) ----------
CREATE TABLE IF NOT EXISTS public.aircraft_models (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    manufacturer              varchar(50) NOT NULL,
    model_name                varchar(50) NOT NULL UNIQUE,
    type                      varchar(30) NOT NULL,
    range_km                  integer NOT NULL,
    capacity                  integer NOT NULL,
    speed_kmh                 integer NOT NULL DEFAULT 850,
    fuel_burn_per_km          numeric(8,3) NOT NULL,
    maintenance_cost_per_hour numeric(10,2) NOT NULL,
    purchase_price            numeric(15,2) NOT NULL,
    lease_price_per_month     numeric(15,2) NOT NULL,
    turnaround_hours          numeric DEFAULT 1.0,
    CONSTRAINT aircraft_models_type_check CHECK (type IN ('regional_turboprop','regional_jet','narrow_body_jet','wide_body_jet'))
);

-- ---------- game_config (no FK dependencies) ----------
CREATE TABLE IF NOT EXISTS public.game_config (
    key          text PRIMARY KEY,
    value        jsonb NOT NULL,
    category     text NOT NULL DEFAULT 'general',
    unit         text,
    description  text,
    updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------- data_retention_policy (no FK dependencies) ----------
-- NOTE: This table does not exist in the live schema. Included as placeholder.
-- CREATE TABLE IF NOT EXISTS public.data_retention_policy (...);

-- ---------- users (depends on airports, season_clock) ----------
CREATE TABLE IF NOT EXISTS public.users (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username                  varchar(50) UNIQUE,
    company_name              varchar(100) NOT NULL UNIQUE,
    ceo_name                  varchar(100) NOT NULL,
    game_current_time         timestamptz NOT NULL DEFAULT '2020-01-01 00:00:00+00',
    last_active_at            timestamptz NOT NULL DEFAULT now(),
    net_worth                 numeric(20,2) DEFAULT 15000000.00,
    hq_airport_iata           varchar(3),
    auto_grounding_threshold  numeric(5,2) DEFAULT 40.00,
    operational_status        varchar(20) NOT NULL DEFAULT 'Active',
    consecutive_negative_days integer NOT NULL DEFAULT 0,
    recovery_streak_days      integer NOT NULL DEFAULT 0,
    season_id                 uuid,
    auth_user_id              uuid,
    onboarding_completed      boolean DEFAULT false,
    actor_type                varchar(10) NOT NULL DEFAULT 'REAL',
    CONSTRAINT users_actor_type_check CHECK (actor_type IN ('REAL','AI')),
    CONSTRAINT users_operational_status_check CHECK (operational_status IN ('Active','Bankrupt')),
    CONSTRAINT users_hq_airport_iata_fkey FOREIGN KEY (hq_airport_iata) REFERENCES public.airports(iata),
    CONSTRAINT users_season_id_fkey FOREIGN KEY (season_id) REFERENCES public.season_clock(id),
    CONSTRAINT users_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE SET NULL
);

-- ---------- fleet_aircraft (depends on users, aircraft_models) ----------
CREATE TABLE IF NOT EXISTS public.fleet_aircraft (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid,
    aircraft_model_id uuid NOT NULL,
    acquisition_type  varchar(10) NOT NULL,
    condition         numeric(5,2) NOT NULL DEFAULT 100.00,
    status            varchar(20) NOT NULL DEFAULT 'grounded',
    tail_number       varchar(20) NOT NULL,
    economy_seats     integer DEFAULT 0,
    business_seats    integer DEFAULT 0,
    first_class_seats integer DEFAULT 0,
    nickname          varchar(100),
    acquired_game_date timestamptz,
    CONSTRAINT fleet_aircraft_aircraft_model_id_fkey FOREIGN KEY (aircraft_model_id) REFERENCES public.aircraft_models(id),
    CONSTRAINT fleet_aircraft_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT fleet_aircraft_acquisition_type_check CHECK (acquisition_type IN ('purchase','lease','finance')),
    CONSTRAINT user_fleet_condition_check CHECK (condition >= 0.00 AND condition <= 100.00),
    CONSTRAINT user_fleet_status_check CHECK (status IN ('grounded','active','maintenance'))
);

-- ---------- route_assignments (depends on users, airports, fleet_aircraft) ----------
CREATE TABLE IF NOT EXISTS public.route_assignments (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             uuid,
    origin_iata         varchar(3) NOT NULL,
    destination_iata    varchar(3) NOT NULL,
    distance_km         double precision NOT NULL,
    ticket_price        numeric(10,2) NOT NULL,
    assigned_aircraft_id uuid,
    flights_per_week    integer NOT NULL DEFAULT 7,
    status              varchar(20) DEFAULT 'active',
    CONSTRAINT route_assignments_origin_iata_fkey FOREIGN KEY (origin_iata) REFERENCES public.airports(iata),
    CONSTRAINT route_assignments_destination_iata_fkey FOREIGN KEY (destination_iata) REFERENCES public.airports(iata),
    CONSTRAINT route_assignments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT route_assignments_assigned_aircraft_id_fkey FOREIGN KEY (assigned_aircraft_id) REFERENCES public.fleet_aircraft(id) ON DELETE SET NULL,
    CONSTRAINT user_routes_flights_per_week_check CHECK (flights_per_week >= 1 AND flights_per_week <= 168),
    CONSTRAINT user_routes_ticket_price_check CHECK (ticket_price > 0)
);

-- ---------- bank_accounts (depends on users) ----------
CREATE TABLE IF NOT EXISTS public.bank_accounts (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid NOT NULL,
    account_type varchar(20) NOT NULL DEFAULT 'checking',
    balance      numeric(20,2) NOT NULL DEFAULT 0.00,
    created_at   timestamptz DEFAULT now(),
    updated_at   timestamptz DEFAULT now(),
    CONSTRAINT bank_accounts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT bank_accounts_account_type_check CHECK (account_type = 'operating'),
    CONSTRAINT bank_accounts_user_id_account_type_key UNIQUE (user_id, account_type)
);

-- ---------- bank_transactions (depends on bank_accounts, users) ----------
CREATE TABLE IF NOT EXISTS public.bank_transactions (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id        uuid NOT NULL,
    user_id           uuid NOT NULL,
    transaction_type  varchar(20) NOT NULL,
    amount            numeric(20,2) NOT NULL,
    balance_after     numeric(20,2) NOT NULL,
    description       text,
    game_date         timestamptz,
    ifrs_category     varchar(30),
    ifrs_subcategory  varchar(50),
    CONSTRAINT bank_transactions_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.bank_accounts(id) ON DELETE CASCADE,
    CONSTRAINT bank_transactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT bank_transactions_transaction_type_check CHECK (transaction_type IN ('debit','credit','payment','deposit','disbursement','refinance','late_fee'))
);

-- ---------- loans (depends on users, fleet_aircraft) ----------
CREATE TABLE IF NOT EXISTS public.loans (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                uuid NOT NULL,
    principal              numeric NOT NULL,
    interest_rate          numeric NOT NULL DEFAULT 0.05,
    remaining_balance      numeric NOT NULL,
    weekly_payment         numeric NOT NULL,
    status                 varchar(20) DEFAULT 'active',
    taken_at               timestamptz DEFAULT now(),
    loan_type              varchar(20) DEFAULT 'unsecured',
    collateral_aircraft_id uuid,
    missed_payments        integer DEFAULT 0,
    term_months            integer,
    monthly_payment        numeric,
    CONSTRAINT loans_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT loans_collateral_aircraft_id_fkey FOREIGN KEY (collateral_aircraft_id) REFERENCES public.fleet_aircraft(id) ON DELETE SET NULL,
    CONSTRAINT loans_loan_type_check CHECK (loan_type IN ('unsecured','secured','credit_line','aircraft_financing')),
    CONSTRAINT loans_status_check CHECK (status IN ('active','paid_off','defaulted','repossessed'))
);

-- ---------- credit_scores (depends on users) ----------
CREATE TABLE IF NOT EXISTS public.credit_scores (
    user_id                uuid PRIMARY KEY,
    score                  integer NOT NULL DEFAULT 500,
    tier                   varchar(10) NOT NULL DEFAULT 'Standard',
    fleet_health_score     integer DEFAULT 0,
    revenue_stability_score integer DEFAULT 0,
    debt_ratio_score       integer DEFAULT 0,
    cash_reserves_score    integer DEFAULT 0,
    profit_history_score   integer DEFAULT 0,
    computed_at            timestamptz DEFAULT now(),
    CONSTRAINT credit_scores_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT credit_scores_score_check CHECK (score >= 0 AND score <= 1000)
);

-- ---------- credit_score_history (depends on users) ----------
CREATE TABLE IF NOT EXISTS public.credit_score_history (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                uuid NOT NULL,
    score                  integer NOT NULL,
    tier                   varchar(10) NOT NULL,
    fleet_health_score     integer DEFAULT 0,
    revenue_stability_score integer DEFAULT 0,
    debt_ratio_score       integer DEFAULT 0,
    cash_reserves_score    integer DEFAULT 0,
    profit_history_score   integer DEFAULT 0,
    game_date              timestamptz NOT NULL,
    computed_at            timestamptz DEFAULT now(),
    CONSTRAINT credit_score_history_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT credit_score_history_user_date_unique UNIQUE (user_id, game_date)
);

-- ---------- achievements (depends on users) ----------
CREATE TABLE IF NOT EXISTS public.achievements (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid NOT NULL,
    achievement_type varchar(50) NOT NULL,
    achievement_name varchar(100) NOT NULL,
    description      text,
    unlocked_at      timestamptz DEFAULT now(),
    game_date        timestamptz,
    CONSTRAINT achievements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
    CONSTRAINT achievements_user_id_achievement_type_key UNIQUE (user_id, achievement_type)
);

-- ---------- game_events (no user FK) ----------
CREATE TABLE IF NOT EXISTS public.game_events (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type      varchar(50) NOT NULL,
    title           varchar(200) NOT NULL,
    description     text,
    effect_type     varchar(50) NOT NULL,
    effect_target   text,
    effect_value    numeric NOT NULL,
    start_game_time timestamptz NOT NULL,
    end_game_time   timestamptz NOT NULL,
    is_active       boolean DEFAULT true,
    created_at      timestamptz DEFAULT now()
);

-- ---------- world_tick_log (depends on season_clock) ----------
CREATE TABLE IF NOT EXISTS public.world_tick_log (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    season_id              uuid,
    started_at             timestamptz NOT NULL DEFAULT now(),
    finished_at            timestamptz,
    game_time_before       timestamptz,
    game_time_after        timestamptz,
    ticks_processed        integer NOT NULL DEFAULT 0,
    real_seconds_processed numeric(20,4) NOT NULL DEFAULT 0.0000,
    game_seconds_processed numeric(20,4) NOT NULL DEFAULT 0.0000,
    players_processed      integer NOT NULL DEFAULT 0,
    bots_processed         integer NOT NULL DEFAULT 0,
    status                 varchar(20) NOT NULL DEFAULT 'started',
    message                text,
    CONSTRAINT world_tick_log_season_id_fkey FOREIGN KEY (season_id) REFERENCES public.season_clock(id) ON DELETE CASCADE,
    CONSTRAINT world_tick_log_status_check CHECK (status IN ('started','skipped','success','error','player_error'))
);

-- ---------- bot_profiles (depends on users) ----------
CREATE TABLE IF NOT EXISTS public.bot_profiles (
    user_id    uuid PRIMARY KEY,
    archetype  varchar(30) NOT NULL DEFAULT 'Balanced',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT bot_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
);

-- ---------- bank_transaction_daily_summary (depends on users) ----------
CREATE TABLE IF NOT EXISTS public.bank_transaction_daily_summary (
    user_id           uuid NOT NULL,
    game_date         date NOT NULL,
    ifrs_category     varchar(30) NOT NULL,
    ifrs_subcategory  varchar(50) NOT NULL,
    transaction_type  varchar(20) NOT NULL,
    transaction_count bigint NOT NULL DEFAULT 0,
    total_amount      numeric(20,2) NOT NULL DEFAULT 0.00,
    total_debits      numeric(20,2) NOT NULL DEFAULT 0.00,
    total_credits     numeric(20,2) NOT NULL DEFAULT 0.00,
    first_balance     numeric(20,2),
    last_balance      numeric(20,2),
    first_game_date   timestamptz,
    last_game_date    timestamptz,
    compacted_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, game_date, ifrs_category, ifrs_subcategory, transaction_type)
);

-- ---------- bank_transactions_archive (depends on users) ----------
CREATE TABLE IF NOT EXISTS public.bank_transactions_archive (
    id                uuid NOT NULL,
    account_id        uuid,
    user_id           uuid NOT NULL,
    transaction_type  varchar(20) NOT NULL,
    amount            numeric(20,2) NOT NULL,
    balance_after     numeric(20,2) NOT NULL,
    description       text,
    game_date         timestamptz,
    created_at        timestamptz,
    ifrs_category     varchar(30),
    ifrs_subcategory  varchar(50),
    archived_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id)
);
-- ============================================================================
-- SECTION 3: Indexes
-- ============================================================================
CREATE UNIQUE INDEX IF NOT EXISTS achievements_user_id_achievement_type_key ON public.achievements USING btree (user_id, achievement_type);
CREATE UNIQUE INDEX IF NOT EXISTS aircraft_models_model_name_key ON public.aircraft_models USING btree (model_name);
CREATE UNIQUE INDEX IF NOT EXISTS bank_accounts_user_id_account_type_key ON public.bank_accounts USING btree (user_id, account_type);
CREATE INDEX IF NOT EXISTS idx_bt_daily_summary_date ON public.bank_transaction_daily_summary USING btree (game_date);
CREATE INDEX IF NOT EXISTS idx_bt_daily_summary_user ON public.bank_transaction_daily_summary USING btree (user_id, game_date);
CREATE INDEX IF NOT EXISTS bank_transactions_user_date_idx ON public.bank_transactions USING btree (user_id, game_date DESC);
CREATE INDEX IF NOT EXISTS idx_bank_txn_ifrs ON public.bank_transactions USING btree (user_id, ifrs_category, game_date);
CREATE INDEX IF NOT EXISTS idx_bt_archive_ifrs ON public.bank_transactions_archive USING btree (user_id, ifrs_category, game_date);
CREATE INDEX IF NOT EXISTS idx_bt_archive_user_date ON public.bank_transactions_archive USING btree (user_id, game_date);
CREATE INDEX IF NOT EXISTS credit_score_history_user_date_idx ON public.credit_score_history USING btree (user_id, game_date DESC);
CREATE UNIQUE INDEX IF NOT EXISTS credit_score_history_user_date_unique ON public.credit_score_history USING btree (user_id, game_date);
CREATE INDEX IF NOT EXISTS credit_scores_tier_idx ON public.credit_scores USING btree (tier);
CREATE INDEX IF NOT EXISTS user_fleet_user_id_idx ON public.fleet_aircraft USING btree (user_id);
CREATE INDEX IF NOT EXISTS idx_game_config_category ON public.game_config USING btree (category);
CREATE INDEX IF NOT EXISTS game_events_active_lookup_idx ON public.game_events USING btree (effect_type, effect_target, is_active, start_game_time, end_game_time) WHERE (is_active = true);
CREATE INDEX IF NOT EXISTS loans_collateral_idx ON public.loans USING btree (collateral_aircraft_id) WHERE (collateral_aircraft_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS loans_user_status_idx ON public.loans USING btree (user_id, status);
CREATE UNIQUE INDEX IF NOT EXISTS unique_human_route ON public.route_assignments USING btree (user_id, origin_iata, destination_iata) WHERE (user_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS user_routes_assigned_aircraft_id_idx ON public.route_assignments USING btree (assigned_aircraft_id) WHERE (assigned_aircraft_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS user_routes_user_id_iata_idx ON public.route_assignments USING btree (user_id, origin_iata, destination_iata);
CREATE UNIQUE INDEX IF NOT EXISTS season_clock_one_active_idx ON public.season_clock USING btree (status) WHERE (status = 'active');
CREATE UNIQUE INDEX IF NOT EXISTS users_auth_user_id_unique_idx ON public.users USING btree (auth_user_id) WHERE (auth_user_id IS NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS users_company_name_key ON public.users USING btree (company_name);
CREATE UNIQUE INDEX IF NOT EXISTS users_username_key ON public.users USING btree (username);
CREATE UNIQUE INDEX IF NOT EXISTS fleet_aircraft_tail_number_key ON public.fleet_aircraft (tail_number);
CREATE INDEX IF NOT EXISTS users_season_id_idx ON public.users USING btree (season_id);
CREATE INDEX IF NOT EXISTS world_tick_log_season_started_idx ON public.world_tick_log USING btree (season_id, started_at DESC);
-- ============================================================================
-- SECTION 4: Row Level Security
-- ============================================================================
ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aircraft_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.airports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_transaction_daily_summary ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_transactions_archive ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bot_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_score_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fleet_aircraft ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.loans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.route_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.season_clock ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.world_tick_log ENABLE ROW LEVEL SECURITY;
-- ============================================================================
-- SECTION 5: RLS Policies
-- ============================================================================
CREATE POLICY achievements_select_own ON public.achievements
    FOR SELECT TO authenticated
    USING (user_id = (SELECT users.id FROM users WHERE users.auth_user_id = auth.uid()));

CREATE POLICY aircraft_models_select_authenticated ON public.aircraft_models
    FOR SELECT TO authenticated
    USING (true);

CREATE POLICY airports_select_authenticated ON public.airports
    FOR SELECT TO authenticated
    USING (true);

CREATE POLICY bank_accounts_select_own ON public.bank_accounts
    FOR SELECT TO authenticated
    USING (user_id = get_current_user_id());

CREATE POLICY "Bank txn daily summary viewable by owner" ON public.bank_transaction_daily_summary
    FOR SELECT TO authenticated
    USING (user_id = get_current_user_id());

CREATE POLICY bank_transactions_select_own ON public.bank_transactions
    FOR SELECT TO authenticated
    USING (user_id = get_current_user_id());

CREATE POLICY "Bank txn archive viewable by owner" ON public.bank_transactions_archive
    FOR SELECT TO authenticated
    USING (user_id = get_current_user_id());

CREATE POLICY "Bot profiles viewable by everyone" ON public.bot_profiles
    FOR SELECT TO authenticated
    USING (true);

CREATE POLICY credit_score_history_select_own ON public.credit_score_history
    FOR SELECT TO authenticated
    USING (user_id = (SELECT users.id FROM users WHERE users.auth_user_id = auth.uid()));

CREATE POLICY credit_scores_select_own ON public.credit_scores
    FOR SELECT TO authenticated
    USING (user_id = (SELECT users.id FROM users WHERE users.auth_user_id = auth.uid()));

CREATE POLICY fleet_aircraft_select_own ON public.fleet_aircraft
    FOR SELECT TO authenticated
    USING (user_id = get_current_user_id());

CREATE POLICY "Game config viewable by everyone" ON public.game_config
    FOR SELECT TO authenticated
    USING (true);

CREATE POLICY game_events_select_authenticated ON public.game_events
    FOR SELECT TO authenticated
    USING (true);

CREATE POLICY loans_select_own ON public.loans
    FOR SELECT TO authenticated
    USING (user_id = (SELECT users.id FROM users WHERE users.auth_user_id = auth.uid()));

CREATE POLICY route_assignments_select_own ON public.route_assignments
    FOR SELECT TO authenticated
    USING (user_id = get_current_user_id());

CREATE POLICY season_clock_select_authenticated ON public.season_clock
    FOR SELECT TO authenticated
    USING (true);

CREATE POLICY users_select_own ON public.users
    FOR SELECT TO authenticated
    USING ((auth.uid() IS NOT NULL) AND (auth.uid() = auth_user_id));

CREATE POLICY users_update_own ON public.users
    FOR UPDATE TO authenticated
    USING ((auth.uid() IS NOT NULL) AND (auth.uid() = auth_user_id))
    WITH CHECK ((auth.uid() IS NOT NULL) AND (auth.uid() = auth_user_id));
-- ============================================================================
-- SECTION 6: Grants
-- ============================================================================
-- Read-only tables (SELECT only)
GRANT SELECT ON public.achievements TO authenticated;
GRANT SELECT ON public.aircraft_models TO authenticated;
GRANT SELECT ON public.airports TO authenticated;
GRANT SELECT ON public.bank_accounts TO authenticated;
GRANT SELECT ON public.bank_transactions TO authenticated;
GRANT SELECT ON public.credit_score_history TO authenticated;
GRANT SELECT ON public.credit_scores TO authenticated;
GRANT SELECT ON public.fleet_aircraft TO authenticated;
GRANT SELECT ON public.game_events TO authenticated;
GRANT SELECT ON public.loans TO authenticated;
GRANT SELECT ON public.route_assignments TO authenticated;
GRANT SELECT ON public.season_clock TO authenticated;
GRANT SELECT ON public.world_tick_log TO authenticated;

-- Full CRUD tables
GRANT SELECT, INSERT, UPDATE, DELETE ON public.bank_transaction_daily_summary TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.bank_transactions_archive TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.bot_profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.game_config TO authenticated;

-- Users table (INSERT, SELECT, UPDATE — no DELETE)
GRANT INSERT, SELECT, UPDATE ON public.users TO authenticated;
-- ============================================================================
-- SECTION 7: Functions
-- ============================================================================
CREATE OR REPLACE FUNCTION public.assign_aircraft_to_route(p_route_id uuid, p_aircraft_id uuid)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM assign_aircraft_to_route(v_user_id, p_route_id, p_aircraft_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.assign_aircraft_to_route(p_user_id uuid, p_route_id uuid, p_aircraft_id uuid)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_current_aircraft_id UUID; v_effective_threshold NUMERIC(5,2); v_route_distance_km DOUBLE PRECISION; v_route_flights_per_week INT; v_aircraft_range_km INT; v_aircraft_speed_kmh INT; v_max_weekly_flights INT;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
SELECT assigned_aircraft_id, distance_km, flights_per_week INTO v_current_aircraft_id, v_route_distance_km, v_route_flights_per_week FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR; RETURN; END IF;
IF p_aircraft_id IS NOT NULL THEN
SELECT GREATEST(COALESCE(u.auto_grounding_threshold, 40.00), COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00)) INTO v_effective_threshold FROM users u WHERE u.id = p_user_id LIMIT 1;
SELECT m.range_km, m.speed_kmh INTO v_aircraft_range_km, v_aircraft_speed_kmh FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = p_aircraft_id AND f.user_id = p_user_id AND f.condition >= COALESCE(v_effective_threshold, 40.00);
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft is unavailable or below the safety threshold.'::VARCHAR; RETURN; END IF;
IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN RETURN QUERY SELECT FALSE, 'Aircraft range is insufficient for this route.'::VARCHAR; RETURN; END IF;
v_max_weekly_flights := calculate_route_max_weekly_flights(v_route_distance_km, v_aircraft_speed_kmh);
IF v_max_weekly_flights > 0 AND COALESCE(v_route_flights_per_week, 0) > v_max_weekly_flights THEN RETURN QUERY SELECT FALSE, 'Route frequency exceeds this aircraft''s weekly operating capacity.'::VARCHAR; RETURN; END IF;
IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_aircraft_id AND id <> p_route_id) THEN RETURN QUERY SELECT FALSE, 'Aircraft is already assigned to another route.'::VARCHAR; RETURN; END IF;
END IF;
UPDATE route_assignments SET assigned_aircraft_id = p_aircraft_id WHERE id = p_route_id AND user_id = p_user_id;
IF p_aircraft_id IS NOT NULL THEN UPDATE fleet_aircraft SET status = 'active' WHERE id = p_aircraft_id AND user_id = p_user_id; END IF;
RETURN QUERY SELECT TRUE, 'Aircraft assignment updated successfully!'::VARCHAR;
END;
$function$;

CREATE OR REPLACE FUNCTION public.bot_finance_aircraft(p_bot_id uuid, p_aircraft_model_id uuid, p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 60)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_model RECORD;
v_purchase_price NUMERIC;
v_down_payment NUMERIC;
v_principal NUMERIC;
v_interest_rate NUMERIC := 0.05;
v_monthly_payment NUMERIC;
v_cash NUMERIC;
v_game_time TIMESTAMPTZ;
v_fleet_id UUID;
BEGIN
SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
IF NOT FOUND THEN RETURN false; END IF;
v_purchase_price := v_model.purchase_price;
v_down_payment := v_purchase_price * p_down_payment_pct;
v_principal := v_purchase_price - v_down_payment;
v_monthly_payment := (v_principal * (1 + v_interest_rate)) / p_term_months;
v_cash := get_user_balance(p_bot_id);
SELECT game_current_time INTO v_game_time FROM users WHERE id = p_bot_id;
IF v_cash < v_down_payment THEN RETURN false; END IF;
PERFORM debit_bank_account(p_bot_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
'Aircraft financing down payment — ' || v_model.model_name, v_game_time);
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
VALUES (p_bot_id, p_aircraft_model_id, v_model.model_name, 'finance', 100.00, 'active', 'BOT-' || left(p_bot_id::text, 4), FLOOR(v_model.capacity * 0.70)::INT, FLOOR(v_model.capacity * 0.20)::INT, FLOOR(v_model.capacity * 0.10)::INT)
RETURNING id INTO v_fleet_id;
INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id, term_months, monthly_payment)
VALUES (p_bot_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', 'aircraft_financing', v_fleet_id, p_term_months, v_monthly_payment);
RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.bot_take_loan(p_bot_id uuid, p_principal numeric, p_term_weeks integer DEFAULT 52)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_existing_loans INT;
v_interest_rate NUMERIC := 0.05;
v_total_repayable NUMERIC;
v_weekly_payment NUMERIC;
v_game_time TIMESTAMPTZ;
BEGIN
SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_bot_id AND status = 'active';
IF v_existing_loans >= 3 THEN RETURN false; END IF;
IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN false; END IF;
SELECT game_current_time INTO v_game_time FROM users WHERE id = p_bot_id;
v_total_repayable := p_principal * (1 + v_interest_rate);
v_weekly_payment := v_total_repayable / p_term_weeks;
INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type)
VALUES (p_bot_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', 'unsecured');
PERFORM credit_bank_account(p_bot_id, p_principal, 'financing', 'loan_disbursement',
'Bot loan disbursement', v_game_time);
RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.build_synthetic_auth_email(p_username text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
SELECT public.normalize_username(p_username) || '@skyward.sachiel.id';
$function$;

CREATE OR REPLACE FUNCTION public.calculate_airport_congestion_factor(p_origin_iata character varying)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_total_flights INT;
BEGIN
SELECT COALESCE(SUM(flights_per_week), 0) INTO v_total_flights FROM route_assignments WHERE origin_iata = p_origin_iata AND status = 'active';
IF v_total_flights > 50 THEN RETURN GREATEST(0.50, 1.0 - ((v_total_flights - 50) * 0.005)); END IF;
RETURN 1.0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_airport_demand_factor(p_origin_demand integer, p_destination_demand integer)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
SELECT GREATEST(
COALESCE(get_config_numeric('min_airport_demand_factor'), 0.55),
LEAST(
COALESCE(get_config_numeric('max_airport_demand_factor'), 1.00),
COALESCE(get_config_numeric('min_airport_demand_factor'), 0.55) + (
((((COALESCE(p_origin_demand, 50) + COALESCE(p_destination_demand, 50))::NUMERIC) / 2.0) / 100.0)
* (COALESCE(get_config_numeric('max_airport_demand_factor'), 1.00) - COALESCE(get_config_numeric('min_airport_demand_factor'), 0.55))
)
)
);
$function$;

CREATE OR REPLACE FUNCTION public.calculate_credit_score(p_user_id uuid)
RETURNS TABLE(
    total_score       integer,
    tier              character varying,
    fleet_health      integer,
    revenue_stability integer,
    debt_ratio        integer,
    cash_reserve      integer,
    profit_history    integer
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user              RECORD;
    v_actor_type        VARCHAR(10);
    v_fleet_count       INT     := 0;
    v_avg_condition     NUMERIC := 100.0;
    v_grounded_ratio    NUMERIC := 0.0;
    v_fleet_health      NUMERIC := 200.0;
    v_revenue_days      INT     := 0;
    v_positive_days     INT     := 0;
    v_revenue_stability NUMERIC := 200.0;
    v_total_debt        NUMERIC := 0.0;
    v_net_worth         NUMERIC := 0.0;
    v_debt_ratio        NUMERIC := 200.0;
    v_cash              NUMERIC := 0.0;
    v_starting_cash     NUMERIC := 15000000.0;
    v_cash_reserve      NUMERIC := 200.0;
    v_total_revenue_30d NUMERIC := 0.0;
    v_total_expense_30d NUMERIC := 0.0;
    v_profit_margin     NUMERIC := 0.0;
    v_profit_history    NUMERIC := 200.0;
    v_total_score       INT;
BEGIN
    SELECT u.net_worth, u.game_current_time, u.actor_type
      INTO v_user FROM users u WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        total_score := 500; tier := 'Standard';
        fleet_health := 100; revenue_stability := 100;
        debt_ratio := 100; cash_reserve := 100;
        profit_history := 100;
        RETURN NEXT; RETURN;
    END IF;

    v_actor_type := COALESCE(v_user.actor_type, 'REAL');
    v_cash       := get_user_balance(p_user_id);
    v_net_worth  := COALESCE(v_user.net_worth, 0.0);
    v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.0);

    -- Fleet health
    SELECT COUNT(*)::INT, COALESCE(AVG(condition), 100.0),
           COALESCE(COUNT(*) FILTER (WHERE status = 'grounded')::NUMERIC
                    / NULLIF(COUNT(*), 0), 0.0)
      INTO v_fleet_count, v_avg_condition, v_grounded_ratio
      FROM fleet_aircraft WHERE user_id = p_user_id;

    IF v_fleet_count > 0 THEN
        v_fleet_health := (v_avg_condition / 100.0) * 150.0
                        + 50.0 * (1.0 - v_grounded_ratio);
    ELSE
        v_fleet_health := 100.0;
    END IF;

    -- Revenue stability (counts days with revenue-category credits)
    SELECT COUNT(*)::INT, COUNT(*) FILTER (WHERE amount > 0)::INT
      INTO v_revenue_days, v_positive_days
      FROM bank_transactions
     WHERE user_id = p_user_id
       AND ifrs_category = 'revenue'
       AND game_date >= v_user.game_current_time - INTERVAL '30 days';

    IF v_revenue_days > 0 THEN
        v_revenue_stability := (v_positive_days::NUMERIC / v_revenue_days::NUMERIC) * 200.0;
    ELSE
        v_revenue_stability := 100.0;
    END IF;

    -- Debt ratio
    SELECT COALESCE(SUM(remaining_balance), 0)
      INTO v_total_debt FROM loans
     WHERE user_id = p_user_id AND status = 'active';

    IF v_net_worth > 0 THEN
        v_debt_ratio := GREATEST(0, 200.0 - ((v_total_debt / v_net_worth) * 200.0));
    ELSE
        v_debt_ratio := 0.0;
    END IF;

    -- Cash reserve
    IF v_starting_cash > 0 THEN
        v_cash_reserve := LEAST(200.0, (v_cash / v_starting_cash) * 200.0);
    ELSE
        v_cash_reserve := 100.0;
    END IF;

    -- Filter profit calculation to operating categories only.
    -- Excludes financing (loans, disbursements, late fees) and investing
    -- (aircraft purchases/sales) from revenue and expense totals.
    SELECT COALESCE(SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN transaction_type = 'debit'  THEN amount ELSE 0 END), 0)
      INTO v_total_revenue_30d, v_total_expense_30d
      FROM bank_transactions
     WHERE user_id = p_user_id
       AND game_date >= v_user.game_current_time - INTERVAL '30 days'
       AND ifrs_category IN ('revenue', 'cogs', 'opex');

    IF v_total_revenue_30d > 0 THEN
        v_profit_margin  := (v_total_revenue_30d - v_total_expense_30d)
                          / v_total_revenue_30d;
        v_profit_history := LEAST(200.0, 100.0 + (v_profit_margin * 100.0));
    ELSE
        v_profit_history := 100.0;
    END IF;

    v_total_score := GREATEST(0, LEAST(1000,
        ROUND(v_fleet_health) + ROUND(v_revenue_stability)
      + ROUND(v_debt_ratio) + ROUND(v_cash_reserve)
      + ROUND(v_profit_history)));

    total_score       := v_total_score;
    tier              := resolve_credit_tier(v_total_score);
    fleet_health      := ROUND(v_fleet_health)::INT;
    revenue_stability := ROUND(v_revenue_stability)::INT;
    debt_ratio        := ROUND(v_debt_ratio)::INT;
    cash_reserve      := ROUND(v_cash_reserve)::INT;
    profit_history    := ROUND(v_profit_history)::INT;
    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_effective_passenger_capacity(p_model_capacity integer, p_economy_seats integer, p_business_seats integer, p_first_class_seats integer)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $function$
SELECT GREATEST(
0,
COALESCE(
NULLIF(
COALESCE(p_economy_seats, 0) +
COALESCE(p_business_seats, 0) +
COALESCE(p_first_class_seats, 0),
0
),
COALESCE(p_model_capacity, 0)
)
);
$function$;

CREATE OR REPLACE FUNCTION public.calculate_hub_bonus(p_origin_iata character varying, p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
v_hub_routes_count INT;
BEGIN
SELECT COUNT(*) INTO v_hub_routes_count
FROM route_assignments
WHERE origin_iata = p_origin_iata
AND user_id = p_user_id
AND status = 'active';
IF v_hub_routes_count > 1 THEN
RETURN 1.0 + LEAST((v_hub_routes_count - 1) * 0.02, 0.20);
END IF;
RETURN 1.0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_lease_termination_fee(p_lease_price_per_month numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
SELECT ROUND(COALESCE(p_lease_price_per_month, 0.00) * 0.25, 2);
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_base_fare(p_distance_km double precision)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
SELECT COALESCE(get_config_numeric('ticket_base_fare'), 50.0)
+ (COALESCE(p_distance_km, 0.0)::NUMERIC * COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12));
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_demand_multiplier(p_distance_km double precision, p_ticket_price numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
SELECT GREATEST(
0.00,
LEAST(
1.50,
1.5 - 0.8 * POWER(
COALESCE(p_ticket_price, 0.00) /
NULLIF(calculate_route_base_fare(p_distance_km), 0.00),
2
)
)
);
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_expected_passengers(p_capacity integer, p_distance_km double precision, p_ticket_price numeric, p_origin_demand integer, p_destination_demand integer)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $function$
SELECT GREATEST(
0,
LEAST(
COALESCE(p_capacity, 0),
FLOOR(
COALESCE(p_capacity, 0) *
0.95 *
calculate_airport_demand_factor(p_origin_demand, p_destination_demand) *
calculate_route_demand_multiplier(p_distance_km, p_ticket_price)
)::INT
)
);
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_expected_passengers(p_capacity integer, p_distance_km double precision, p_ticket_price numeric, p_origin_demand integer, p_destination_demand integer, p_origin_iata character varying, p_destination_iata character varying, p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
v_base_passengers INT;
v_competitor_count INT;
v_my_frequency INT;
v_total_frequency INT;
v_competition_factor NUMERIC := 1.0;
v_congestion_factor NUMERIC := 1.0;
v_hub_bonus NUMERIC := 1.0;
BEGIN
v_base_passengers := GREATEST(0, LEAST(
COALESCE(p_capacity, 0),
FLOOR(COALESCE(p_capacity, 0) * 0.95 *
calculate_airport_demand_factor(p_origin_demand, p_destination_demand) *
calculate_route_demand_multiplier(p_distance_km, p_ticket_price)
)::INT
));
SELECT COUNT(*) INTO v_competitor_count
FROM route_assignments
WHERE origin_iata = p_origin_iata
AND destination_iata = p_destination_iata
AND status = 'active';
IF v_competitor_count > 1 THEN
SELECT COALESCE(flights_per_week, 0) INTO v_my_frequency
FROM route_assignments
WHERE origin_iata = p_origin_iata
AND destination_iata = p_destination_iata
AND user_id = p_user_id
AND status = 'active'
LIMIT 1;
SELECT COALESCE(SUM(flights_per_week), 1) INTO v_total_frequency
FROM route_assignments
WHERE origin_iata = p_origin_iata
AND destination_iata = p_destination_iata
AND status = 'active';
IF v_total_frequency > 0 THEN
v_competition_factor := v_my_frequency::NUMERIC / v_total_frequency;
END IF;
END IF;
v_congestion_factor := calculate_airport_congestion_factor(p_origin_iata);
v_hub_bonus := calculate_hub_bonus(p_origin_iata, p_user_id);
RETURN GREATEST(0, FLOOR(v_base_passengers * v_competition_factor * v_congestion_factor * v_hub_bonus)::INT);
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_max_weekly_flights(p_distance_km double precision, p_speed_kmh integer)
RETURNS integer
LANGUAGE sql
STABLE
AS $function$
SELECT CASE WHEN COALESCE(p_distance_km, 0.0) <= 0.0 OR COALESCE(p_speed_kmh, 0) <= 0 THEN 0
ELSE FLOOR(COALESCE(get_config_numeric('max_weekly_flights'), 168.0) / ((p_distance_km / p_speed_kmh) + 1.0))::INT END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_route_max_weekly_flights(p_distance_km double precision, p_speed_kmh integer, p_turnaround_hours numeric)
RETURNS integer
LANGUAGE sql
STABLE
AS $function$
SELECT CASE WHEN COALESCE(p_distance_km, 0.0) <= 0.0 OR COALESCE(p_speed_kmh, 0) <= 0 THEN 0
ELSE FLOOR(COALESCE(get_config_numeric('max_weekly_flights'), 168.0) / NULLIF((COALESCE(p_distance_km, 0.0) / p_speed_kmh::DOUBLE PRECISION) + COALESCE(p_turnaround_hours, 1.0), 0.0))::INT END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_user_net_worth(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_cash NUMERIC;
v_fleet_value NUMERIC;
BEGIN
v_cash := get_user_balance(p_user_id);
SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
INTO v_fleet_value
FROM fleet_aircraft f
JOIN aircraft_models m ON f.aircraft_model_id = m.id
WHERE f.user_id = p_user_id AND f.acquisition_type = 'purchase';
RETURN COALESCE(v_cash, 0) + v_fleet_value;
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_achievements(p_user_id uuid, p_game_time timestamp with time zone)
RETURNS TABLE(achievement_name character varying, achievement_type character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_cash NUMERIC; v_net_worth NUMERIC; v_fleet_count INT; v_route_count INT;
v_hub_routes INT; v_has_first_class BOOLEAN; v_distress_recovered BOOLEAN;
v_achievement_count_before INT; v_achievement_count_after INT;
BEGIN
SELECT COUNT(*) INTO v_achievement_count_before FROM achievements WHERE user_id = p_user_id;
v_cash := get_user_balance(p_user_id);
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

CREATE OR REPLACE FUNCTION public.compact_bank_transactions(p_dry_run boolean DEFAULT true)
RETURNS TABLE(action text, detail text, row_count bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_retention_days INT;
v_cutoff_date DATE;
v_archived BIGINT := 0;
v_summarized BIGINT := 0;
v_deleted BIGINT := 0;
BEGIN
v_retention_days := COALESCE(get_config_int('bank_txn_raw_retention_days'), 30);
v_cutoff_date := (NOW() - (v_retention_days || ' days')::INTERVAL)::DATE;
-- Step 1: Archive old raw transactions
IF NOT p_dry_run THEN
INSERT INTO bank_transactions_archive (
id, account_id, user_id, transaction_type, amount, balance_after,
description, game_date, archived_at,
ifrs_category, ifrs_subcategory
)
SELECT id, account_id, user_id, transaction_type, amount, balance_after,
description, game_date, NOW(),
ifrs_category, ifrs_subcategory
FROM bank_transactions
WHERE game_date < v_cutoff_date;
GET DIAGNOSTICS v_archived = ROW_COUNT;
ELSE
SELECT COUNT(*) INTO v_archived FROM bank_transactions WHERE game_date < v_cutoff_date;
END IF;
action := 'archive'; detail := 'Rows moved to archive'; row_count := v_archived;
RETURN NEXT;
-- Step 2: Generate/update daily summaries
IF NOT p_dry_run THEN
INSERT INTO bank_transaction_daily_summary (
user_id, game_date, ifrs_category, ifrs_subcategory, transaction_type,
transaction_count, total_amount, total_debits, total_credits,
first_balance, last_balance, first_game_date, last_game_date
)
SELECT
user_id,
(game_date AT TIME ZONE 'UTC')::DATE,
COALESCE(ifrs_category, 'uncategorized'),
COALESCE(ifrs_subcategory, 'uncategorized'),
transaction_type,
COUNT(*),
SUM(amount),
COALESCE(SUM(amount) FILTER (WHERE amount < 0), 0),
COALESCE(SUM(amount) FILTER (WHERE amount > 0), 0),
(ARRAY_AGG(balance_after ORDER BY game_date ASC))[1],
(ARRAY_AGG(balance_after ORDER BY game_date DESC))[1],
MIN(game_date),
MAX(game_date)
FROM bank_transactions
WHERE game_date < v_cutoff_date
GROUP BY user_id, (game_date AT TIME ZONE 'UTC')::DATE,
COALESCE(ifrs_category, 'uncategorized'),
COALESCE(ifrs_subcategory, 'uncategorized'),
transaction_type
ON CONFLICT (user_id, game_date, ifrs_category, ifrs_subcategory, transaction_type)
DO UPDATE SET
transaction_count = bank_transaction_daily_summary.transaction_count + EXCLUDED.transaction_count,
total_amount = bank_transaction_daily_summary.total_amount + EXCLUDED.total_amount,
total_debits = bank_transaction_daily_summary.total_debits + EXCLUDED.total_debits,
total_credits = bank_transaction_daily_summary.total_credits + EXCLUDED.total_credits,
last_balance = EXCLUDED.last_balance,
last_game_date = GREATEST(bank_transaction_daily_summary.last_game_date, EXCLUDED.last_game_date),
compacted_at = NOW();
GET DIAGNOSTICS v_summarized = ROW_COUNT;
ELSE
SELECT COUNT(DISTINCT (user_id, (game_date AT TIME ZONE 'UTC')::DATE,
COALESCE(ifrs_category, 'uncategorized'),
COALESCE(ifrs_subcategory, 'uncategorized'),
transaction_type))
INTO v_summarized
FROM bank_transactions WHERE game_date < v_cutoff_date;
END IF;
action := 'summarize'; detail := 'Daily summary rows upserted'; row_count := v_summarized;
RETURN NEXT;
-- Step 3: Delete archived rows from main table
IF NOT p_dry_run THEN
DELETE FROM bank_transactions WHERE game_date < v_cutoff_date;
GET DIAGNOSTICS v_deleted = ROW_COUNT;
END IF;
action := 'delete'; detail := 'Raw rows deleted from main table'; row_count := v_deleted;
RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.compact_world_tick_log(p_dry_run boolean DEFAULT true)
RETURNS TABLE(action text, detail text, row_count bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_retention_days INT;
v_cutoff TIMESTAMPTZ;
v_count BIGINT := 0;
BEGIN
v_retention_days := COALESCE(get_config_int('world_tick_log_raw_real_days'), 7);
v_cutoff := NOW() - (v_retention_days || ' days')::INTERVAL;
SELECT COUNT(*) INTO v_count FROM world_tick_log WHERE started_at < v_cutoff;
IF NOT p_dry_run AND v_count > 0 THEN
DELETE FROM world_tick_log WHERE started_at < v_cutoff;
END IF;
action := 'delete';
detail := CASE WHEN p_dry_run THEN 'Rows that would be deleted' ELSE 'Rows deleted' END;
row_count := v_count;
RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.configure_aircraft_seats(p_fleet_id uuid, p_economy_seats integer, p_business_seats integer, p_first_class_seats integer)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM configure_aircraft_seats(v_user_id, p_fleet_id, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;

CREATE OR REPLACE FUNCTION public.configure_aircraft_seats(p_user_id uuid, p_fleet_id uuid, p_economy_seats integer, p_business_seats integer, p_first_class_seats integer)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_capacity INT; v_slots_used INT;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
SELECT m.capacity INTO v_capacity FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = p_fleet_id AND f.user_id = p_user_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR; RETURN; END IF;
v_slots_used := p_economy_seats + (p_business_seats * 2) + (p_first_class_seats * 3);
IF p_economy_seats < 0 OR p_business_seats < 0 OR p_first_class_seats < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR; RETURN; END IF;
UPDATE fleet_aircraft SET economy_seats = p_economy_seats, business_seats = p_business_seats, first_class_seats = p_first_class_seats WHERE id = p_fleet_id AND user_id = p_user_id;
RETURN QUERY SELECT TRUE, 'Successfully updated seat configuration!'::VARCHAR;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_route(p_origin_iata character varying, p_destination_iata character varying, p_distance_km numeric, p_ticket_price numeric, p_flights_per_week integer)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM create_route(v_user_id, p_origin_iata, p_destination_iata, p_distance_km, p_ticket_price, p_flights_per_week);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_route(p_user_id uuid, p_origin_iata character varying, p_destination_iata character varying, p_distance_km numeric, p_ticket_price numeric, p_flights_per_week integer)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_actual_distance NUMERIC;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
IF p_origin_iata = p_destination_iata THEN RETURN QUERY SELECT FALSE, 'Origin and destination must be different.'::VARCHAR; RETURN; END IF;
IF p_distance_km <= 0 OR p_ticket_price <= 0 OR p_flights_per_week < 1 OR p_flights_per_week > 168 THEN RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR; RETURN; END IF;
IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR; RETURN; END IF;
IF NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_origin_iata) OR NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_destination_iata) THEN RETURN QUERY SELECT FALSE, 'Route airport not found.'::VARCHAR; RETURN; END IF;
SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude) INTO v_actual_distance FROM airports o, airports d WHERE o.iata = p_origin_iata AND d.iata = p_destination_iata;
IF v_actual_distance > 0 AND ABS(p_distance_km - v_actual_distance) / v_actual_distance > 0.10 THEN RETURN QUERY SELECT FALSE, ('Distance validation failed. Expected ~' || ROUND(v_actual_distance, 1)::TEXT || ' km.')::VARCHAR; RETURN; END IF;
IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND origin_iata = p_origin_iata AND destination_iata = p_destination_iata) THEN RETURN QUERY SELECT FALSE, 'Route already exists.'::VARCHAR; RETURN; END IF;
INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, flights_per_week) VALUES (p_user_id, p_origin_iata, p_destination_iata, p_distance_km, p_ticket_price, p_flights_per_week);
RETURN QUERY SELECT TRUE, 'Route established successfully!'::VARCHAR;
END;
$function$;

CREATE OR REPLACE FUNCTION public.credit_bank_account(p_user_id uuid, p_amount numeric, p_ifrs_category character varying, p_ifrs_subcategory character varying, p_description text, p_game_date timestamp with time zone)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_account_id UUID;
v_new_balance NUMERIC;
BEGIN
SELECT id INTO v_account_id
FROM bank_accounts
WHERE user_id = p_user_id AND account_type = 'operating'
LIMIT 1;
IF v_account_id IS NULL THEN
RAISE EXCEPTION 'No operating bank account for user %', p_user_id;
END IF;
UPDATE bank_accounts
SET balance = balance + p_amount
WHERE id = v_account_id
RETURNING balance INTO v_new_balance;
INSERT INTO bank_transactions (
account_id, user_id, transaction_type, amount, balance_after,
description, game_date, ifrs_category, ifrs_subcategory
) VALUES (
v_account_id, p_user_id, 'credit', p_amount, v_new_balance,
p_description, p_game_date, p_ifrs_category, p_ifrs_subcategory
);
RETURN v_new_balance;
END;
$function$;

CREATE OR REPLACE FUNCTION public.deactivate_expired_events(p_game_time timestamp with time zone)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
UPDATE game_events
SET is_active = false
WHERE is_active = true
AND end_game_time <= p_game_time;
END;
$function$;

CREATE OR REPLACE FUNCTION public.debit_bank_account(p_user_id uuid, p_amount numeric, p_ifrs_category character varying, p_ifrs_subcategory character varying, p_description text, p_game_date timestamp with time zone)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_account_id UUID;
v_new_balance NUMERIC;
BEGIN
SELECT id INTO v_account_id
FROM bank_accounts
WHERE user_id = p_user_id AND account_type = 'operating'
LIMIT 1;
IF v_account_id IS NULL THEN
RAISE EXCEPTION 'No operating bank account for user %', p_user_id;
END IF;
UPDATE bank_accounts
SET balance = balance - p_amount
WHERE id = v_account_id
RETURNING balance INTO v_new_balance;
INSERT INTO bank_transactions (
account_id, user_id, transaction_type, amount, balance_after,
description, game_date, ifrs_category, ifrs_subcategory
) VALUES (
v_account_id, p_user_id, 'debit', -p_amount, v_new_balance,
p_description, p_game_date, p_ifrs_category, p_ifrs_subcategory
);
RETURN v_new_balance;
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_account()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_user_id UUID;
BEGIN
v_user_id := require_current_user_id();
-- Delete in dependency order (children before parents)
-- bank_transactions_archive (has user_id)
DELETE FROM bank_transactions_archive WHERE user_id = v_user_id;
-- bank_transaction_daily_summary (has user_id)
DELETE FROM bank_transaction_daily_summary WHERE user_id = v_user_id;
-- bank_transactions (FK: account_id → bank_accounts, user_id → users)
DELETE FROM bank_transactions WHERE user_id = v_user_id;
-- bank_accounts (FK: user_id → users)
DELETE FROM bank_accounts WHERE user_id = v_user_id;
-- achievements (FK: user_id → users)
DELETE FROM achievements WHERE user_id = v_user_id;
-- credit_score_history (FK: user_id → users)
DELETE FROM credit_score_history WHERE user_id = v_user_id;
-- credit_scores (FK: user_id → users, PK is user_id)
DELETE FROM credit_scores WHERE user_id = v_user_id;
-- route_assignments (FK: user_id → users, assigned_aircraft_id → fleet_aircraft)
DELETE FROM route_assignments WHERE user_id = v_user_id;
-- loans (FK: user_id → users, collateral_aircraft_id/fleet_aircraft_id → fleet_aircraft)
DELETE FROM loans WHERE user_id = v_user_id;
-- fleet_aircraft (FK: user_id → users)
DELETE FROM fleet_aircraft WHERE user_id = v_user_id;
-- bot_profiles (FK: user_id → users ON DELETE CASCADE, but explicit is cleaner)
DELETE FROM bot_profiles WHERE user_id = v_user_id;
-- Finally, the user row itself
DELETE FROM users WHERE id = v_user_id;
RETURN TRUE;
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_route(p_route_id uuid)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM delete_route(v_user_id, p_route_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_route(p_user_id uuid, p_route_id uuid)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_assigned_aircraft_id UUID;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
SELECT assigned_aircraft_id INTO v_assigned_aircraft_id FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR; RETURN; END IF;
IF v_assigned_aircraft_id IS NOT NULL THEN UPDATE fleet_aircraft SET status = 'grounded' WHERE id = v_assigned_aircraft_id AND user_id = p_user_id; END IF;
DELETE FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id;
RETURN QUERY SELECT TRUE, 'Route closed and aircraft grounded successfully!'::VARCHAR;
END;
$function$;

CREATE OR REPLACE FUNCTION public.ensure_world_current(p_season_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(season_id uuid, ticks_processed integer, game_time_after timestamp with time zone, players_processed integer, bots_processed integer)
LANGUAGE plpgsql
AS $function$
DECLARE
v_season_id UUID;
v_ticks INT := 0;
r_result RECORD;
v_current_game_time TIMESTAMPTZ;
BEGIN
IF p_season_id IS NOT NULL THEN v_season_id := p_season_id;
ELSE SELECT id INTO v_season_id FROM season_clock WHERE status = 'active' ORDER BY created_at ASC LIMIT 1;
END IF;
IF v_season_id IS NULL THEN RETURN; END IF;
LOOP
SELECT * INTO r_result FROM process_world_tick(v_season_id, 1) LIMIT 1;
v_ticks := v_ticks + 1;
IF v_ticks >= 100 THEN EXIT; END IF;
SELECT current_game_time INTO v_current_game_time FROM season_clock WHERE id = v_season_id;
EXIT WHEN v_current_game_time >= now();
END LOOP;
IF r_result IS NOT NULL THEN
season_id := r_result.season_id;
ticks_processed := r_result.ticks_processed;
game_time_after := r_result.game_time_after;
players_processed := r_result.players_processed;
bots_processed := r_result.bots_processed;
RETURN NEXT;
END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.execute_bot_decisions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
r_bot RECORD; v_model_id UUID; v_model_name VARCHAR; v_lease_price NUMERIC; v_purchase_price NUMERIC; v_capacity INT; v_speed_kmh NUMERIC; v_range_km NUMERIC; v_deposit_pct NUMERIC; v_deposit_amount NUMERIC; v_tail VARCHAR(20); v_origin_iata VARCHAR(3); v_dest_iata VARCHAR(3); v_distance DOUBLE PRECISION; v_fleet_count INT; v_route_count INT; v_idle_aircraft_count INT; v_idle_aircraft_id UUID; v_idle_tail VARCHAR(20); v_idle_condition NUMERIC; v_idle_model_name VARCHAR; v_idle_capacity INT; v_idle_speed NUMERIC; v_idle_range NUMERIC; v_grounded_aircraft_id UUID; v_grounded_condition NUMERIC; v_grounded_acquisition_type VARCHAR; v_grounded_model_name VARCHAR; v_grounded_lease_price NUMERIC; v_grounded_purchase_price NUMERIC; v_repair_cost NUMERIC; v_target_fleet_cap INT; v_min_cash_reserve NUMERIC; v_growth_chance NUMERIC; v_target_distance DOUBLE PRECISION; v_target_price_multiplier NUMERIC; v_target_schedule_ratio NUMERIC; v_effective_threshold NUMERIC(5,2); v_absolute_minimum_safety_limit NUMERIC(5,2) := 30.00; v_selected_route_id UUID; v_selected_flights INT; v_selected_base_fare NUMERIC; v_max_weekly_flights INT; v_target_flights INT; v_target_price NUMERIC; v_bot_cash NUMERIC; v_starting_cash NUMERIC; v_attempts INT; v_inserted BOOLEAN; v_economy INT; v_business INT; v_first INT; r_route RECORD; v_human_competitors INT; v_new_price NUMERIC; v_base_fare NUMERIC; v_purchase_capacity INT; v_purchase_model_name VARCHAR; v_active_loans INT; v_game_time TIMESTAMPTZ;
v_archetype VARCHAR(30);
v_ticket_base_fare NUMERIC;
v_ticket_per_km_rate NUMERIC;
v_bankruptcy_threshold NUMERIC;
v_spawned_id UUID;
BEGIN
-- Read constants from game_config
v_ticket_base_fare := COALESCE(get_config_numeric('ticket_base_fare'), 50.0);
v_ticket_per_km_rate := COALESCE(get_config_numeric('ticket_per_km_rate'), 0.12);
v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);
SELECT value::numeric INTO v_deposit_pct FROM game_config WHERE key = 'base_lease_deposit_percentage';
v_deposit_pct := COALESCE(v_deposit_pct, 0.10);
FOR r_bot IN
SELECT u.*, COALESCE(bp.archetype, 'Balanced') as archetype
FROM users u
LEFT JOIN bot_profiles bp ON bp.user_id = u.id
WHERE u.actor_type = 'AI' AND u.operational_status != 'Bankrupt'
LOOP
v_archetype := r_bot.archetype;
v_bot_cash := get_user_balance(r_bot.id);
v_game_time := r_bot.game_current_time;
v_origin_iata := r_bot.hq_airport_iata;
v_effective_threshold := GREATEST(v_absolute_minimum_safety_limit, COALESCE(r_bot.auto_grounding_threshold, 40.00));
IF COALESCE(r_bot.operational_status, 'Active') = 'Bankrupt' OR v_bot_cash < v_bankruptcy_threshold THEN UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id; UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id; UPDATE loans SET status = 'defaulted', remaining_balance = 0 WHERE user_id = r_bot.id AND status = 'active'; DELETE FROM route_assignments WHERE user_id = r_bot.id; CONTINUE; END IF;
CASE v_archetype WHEN 'Regional' THEN v_target_fleet_cap := 8; v_min_cash_reserve := 3500000.00; v_growth_chance := 0.20; v_target_distance := 900.0; v_target_price_multiplier := 0.95; v_target_schedule_ratio := 0.72; WHEN 'Aggressive' THEN v_target_fleet_cap := 14; v_min_cash_reserve := 4500000.00; v_growth_chance := 0.26; v_target_distance := 1800.0; v_target_price_multiplier := 1.02; v_target_schedule_ratio := 0.82; ELSE v_target_fleet_cap := 10; v_min_cash_reserve := 7000000.00; v_growth_chance := 0.16; v_target_distance := 4200.0; v_target_price_multiplier := 1.18; v_target_schedule_ratio := 0.58; END CASE;
SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
SELECT COUNT(*)::INT INTO v_idle_aircraft_count FROM fleet_aircraft f WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id);
SELECT f.id, f.condition, f.acquisition_type, m.model_name, m.lease_price_per_month, m.purchase_price INTO v_grounded_aircraft_id, v_grounded_condition, v_grounded_acquisition_type, v_grounded_model_name, v_grounded_lease_price, v_grounded_purchase_price FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND (f.status = 'grounded' OR f.condition < v_effective_threshold) ORDER BY f.condition DESC LIMIT 1;
IF v_grounded_aircraft_id IS NOT NULL THEN v_repair_cost := CASE WHEN v_grounded_acquisition_type = 'lease' THEN (100.00 - v_grounded_condition) * (COALESCE(v_grounded_lease_price, 0.00) * 0.50) ELSE (100.00 - v_grounded_condition) * (COALESCE(v_grounded_purchase_price, 0.00) * 0.0005) END; IF v_repair_cost > 0 AND v_bot_cash >= (v_repair_cost + 500000.00) THEN PERFORM debit_bank_account(r_bot.id, v_repair_cost, 'cogs', 'maintenance', 'Bot maintenance recovery: ' || v_grounded_model_name, v_game_time); UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = v_grounded_aircraft_id; v_bot_cash := v_bot_cash - v_repair_cost; END IF; END IF;
-- Use config values for base fare calculation
IF v_bot_cash < 3000000.00 OR COALESCE(r_bot.consecutive_negative_days, 0) >= 2 THEN SELECT r.id, r.flights_per_week, (v_ticket_base_fare + (r.distance_km * v_ticket_per_km_rate))::NUMERIC INTO v_selected_route_id, v_selected_flights, v_selected_base_fare FROM route_assignments r WHERE r.user_id = r_bot.id ORDER BY (r.ticket_price / NULLIF((v_ticket_base_fare + (r.distance_km * v_ticket_per_km_rate)), 0)) DESC, r.flights_per_week DESC LIMIT 1; IF v_selected_route_id IS NOT NULL THEN IF v_selected_flights > 8 THEN UPDATE route_assignments SET flights_per_week = GREATEST(6, flights_per_week - CASE v_archetype WHEN 'Regional' THEN 6 WHEN 'Aggressive' THEN 4 ELSE 2 END), ticket_price = GREATEST(ROUND((v_selected_base_fare * v_target_price_multiplier)::numeric, 2), ROUND((ticket_price * 0.90)::numeric, 2)) WHERE id = v_selected_route_id; ELSE DELETE FROM route_assignments WHERE id = v_selected_route_id; END IF; END IF; END IF;
IF v_fleet_count < v_target_fleet_cap AND v_bot_cash > v_min_cash_reserve AND COALESCE(r_bot.consecutive_negative_days, 0) = 0 AND v_idle_aircraft_count = 0 AND v_route_count >= v_fleet_count AND random() < v_growth_chance THEN
v_model_id := NULL; v_model_name := NULL; v_lease_price := NULL; v_purchase_price := NULL; v_capacity := NULL;
IF v_archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' AND model_name = 'ATR 72-600' LIMIT 1; ELSIF v_archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' AND model_name = 'A320neo' LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' AND model_name = '787-9' LIMIT 1; END IF;
IF v_model_id IS NULL THEN IF v_archetype = 'Regional' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'ATR' ORDER BY capacity DESC LIMIT 1; ELSIF v_archetype = 'Aggressive' THEN SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Airbus' ORDER BY capacity DESC LIMIT 1; ELSE SELECT id, model_name, lease_price_per_month, purchase_price, capacity, speed_kmh, range_km INTO v_model_id, v_model_name, v_lease_price, v_purchase_price, v_capacity, v_speed_kmh, v_range_km FROM aircraft_models WHERE manufacturer = 'Boeing' ORDER BY capacity DESC LIMIT 1; END IF; END IF;
v_deposit_amount := COALESCE(v_lease_price, 0.00) * v_deposit_pct;
IF v_model_id IS NOT NULL AND v_bot_cash >= v_deposit_amount THEN IF v_archetype = 'Regional' THEN v_economy := FLOOR(v_capacity * 0.80); v_business := FLOOR(v_capacity * 0.15); v_first := v_capacity - v_economy - v_business; ELSIF v_archetype = 'Aggressive' THEN v_economy := FLOOR(v_capacity * 0.70); v_business := FLOOR(v_capacity * 0.20); v_first := v_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_capacity * 0.50); v_business := FLOOR(v_capacity * 0.30); v_first := v_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (id, user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats) VALUES (gen_random_uuid(), r_bot.id, v_model_id, v_model_name, 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN PERFORM debit_bank_account(r_bot.id, v_deposit_amount, 'investing', 'aircraft_lease_deposit', 'Leased aircraft ' || v_model_name || ' [' || v_tail || '] - deposit', v_game_time); v_bot_cash := v_bot_cash - v_deposit_amount; END IF; END IF;
END IF;
IF v_bot_cash > (v_starting_cash * 3) AND v_fleet_count < v_target_fleet_cap THEN SELECT id, purchase_price, capacity, model_name INTO v_model_id, v_purchase_price, v_purchase_capacity, v_purchase_model_name FROM aircraft_models WHERE range_km >= v_target_distance ORDER BY purchase_price ASC LIMIT 1; IF v_bot_cash >= v_purchase_price AND v_purchase_price IS NOT NULL THEN IF v_archetype = 'Regional' THEN v_economy := FLOOR(v_purchase_capacity * 0.80); v_business := FLOOR(v_purchase_capacity * 0.15); v_first := v_purchase_capacity - v_economy - v_business; ELSIF v_archetype = 'Aggressive' THEN v_economy := FLOOR(v_purchase_capacity * 0.70); v_business := FLOOR(v_purchase_capacity * 0.20); v_first := v_purchase_capacity - v_economy - v_business; ELSE v_economy := FLOOR(v_purchase_capacity * 0.50); v_business := FLOOR(v_purchase_capacity * 0.30); v_first := v_purchase_capacity - v_economy - v_business; END IF; v_attempts := 0; v_inserted := false; WHILE v_attempts < 10 AND NOT v_inserted LOOP v_tail := generate_tail_number(r_bot.hq_airport_iata); BEGIN INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats) VALUES (r_bot.id, v_model_id, v_purchase_model_name, v_tail, 'purchase', 100.00, 'active', v_economy, v_business, v_first); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; END LOOP; IF v_inserted THEN PERFORM debit_bank_account(r_bot.id, v_purchase_price, 'investing', 'aircraft_purchase', 'Aircraft purchase: ' || v_tail, v_game_time); v_bot_cash := v_bot_cash - v_purchase_price; END IF; END IF; END IF;
SELECT COUNT(*)::INT INTO v_fleet_count FROM fleet_aircraft WHERE user_id = r_bot.id; SELECT COUNT(*)::INT INTO v_route_count FROM route_assignments WHERE user_id = r_bot.id;
SELECT f.id, f.tail_number, f.condition, m.model_name, m.capacity, m.speed_kmh, m.range_km INTO v_idle_aircraft_id, v_idle_tail, v_idle_condition, v_idle_model_name, v_idle_capacity, v_idle_speed, v_idle_range FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = r_bot.id AND f.status = 'active' AND f.condition >= v_effective_threshold AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id) ORDER BY f.condition DESC LIMIT 1;
IF v_idle_aircraft_id IS NOT NULL AND v_route_count < v_target_fleet_cap THEN v_attempts := 0; v_inserted := false; WHILE v_attempts < 20 AND NOT v_inserted LOOP SELECT iata INTO v_dest_iata FROM airports WHERE iata != v_origin_iata ORDER BY demand_index DESC, random() LIMIT 1; IF v_dest_iata IS NULL THEN EXIT; END IF; SELECT haversine_distance(o.latitude, o.longitude, d.latitude, d.longitude) INTO v_distance FROM airports o, airports d WHERE o.iata = v_origin_iata AND d.iata = v_dest_iata; IF v_distance > 0 AND v_distance <= v_idle_range THEN v_base_fare := v_ticket_base_fare + (v_distance * v_ticket_per_km_rate); v_target_price := ROUND(v_base_fare * v_target_price_multiplier, 2); v_max_weekly_flights := calculate_route_max_weekly_flights(v_distance, v_idle_speed::INT); v_target_flights := GREATEST(1, FLOOR(v_max_weekly_flights * v_target_schedule_ratio)); BEGIN INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, assigned_aircraft_id, flights_per_week) VALUES (r_bot.id, v_origin_iata, v_dest_iata, v_distance, v_target_price, v_idle_aircraft_id, v_target_flights); v_inserted := true; EXCEPTION WHEN unique_violation THEN v_attempts := v_attempts + 1; END; ELSE v_attempts := v_attempts + 1; END IF; END LOOP; END IF;
FOR r_route IN SELECT ra.*, m.speed_kmh, m.range_km, m.turnaround_hours FROM route_assignments ra JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id JOIN aircraft_models m ON m.id = fa.aircraft_model_id WHERE ra.user_id = r_bot.id AND ra.status = 'active' LOOP SELECT COUNT(*) INTO v_human_competitors FROM route_assignments WHERE origin_iata = r_route.origin_iata AND destination_iata = r_route.destination_iata AND status = 'active' AND user_id != r_bot.id AND user_id IN (SELECT id FROM users WHERE actor_type = 'REAL'); IF v_human_competitors > 0 THEN v_base_fare := v_ticket_base_fare + (r_route.distance_km * v_ticket_per_km_rate); v_new_price := ROUND(v_base_fare * v_target_price_multiplier * CASE WHEN r_route.ticket_price > v_base_fare * 1.3 THEN 0.95 ELSE 1.0 END, 2); IF v_new_price != r_route.ticket_price THEN UPDATE route_assignments SET ticket_price = v_new_price WHERE id = r_route.id; END IF; END IF; END LOOP;
SELECT COUNT(*) INTO v_active_loans FROM loans WHERE user_id = r_bot.id AND status = 'active'; IF v_active_loans = 0 AND v_bot_cash < v_starting_cash * 0.5 AND v_bot_cash > 1000000 THEN PERFORM bot_take_loan(r_bot.id, LEAST(5000000, v_starting_cash - v_bot_cash)); END IF;
UPDATE users SET last_active_at = NOW() WHERE id = r_bot.id;
END LOOP;
-- Spawn replacement bot if below max (runs once per day boundary)
IF (SELECT COUNT(*) FROM users WHERE actor_type = 'AI' AND COALESCE(operational_status, 'Active') != 'Bankrupt') <
COALESCE(get_config_int('max_bot_count'), 5) THEN
v_spawned_id := spawn_bot();
END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.finance_aircraft(p_aircraft_model_id uuid, p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 36)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := require_current_user_id();
RETURN QUERY SELECT * FROM finance_aircraft(v_user_id, p_aircraft_model_id, p_down_payment_pct, p_term_months);
END;
$function$;

CREATE OR REPLACE FUNCTION public.finance_aircraft(p_user_id uuid, p_aircraft_model_id uuid, p_down_payment_pct numeric DEFAULT 0.20, p_term_months integer DEFAULT 36)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_actor_type VARCHAR(10); v_model RECORD; v_credit_score INT; v_tier VARCHAR(10);
v_purchase_price NUMERIC; v_down_payment NUMERIC; v_principal NUMERIC;
v_interest_rate NUMERIC; v_monthly_payment NUMERIC; v_total_repayable NUMERIC;
v_cash NUMERIC; v_game_time TIMESTAMPTZ; v_fleet_id UUID; v_hq_iata VARCHAR(3);
v_max_financing NUMERIC; v_economy_seats INT; v_business_seats INT; v_first_seats INT;
v_archetype VARCHAR(30);
BEGIN
SELECT * INTO v_model FROM aircraft_models WHERE id = p_aircraft_model_id;
IF NOT FOUND THEN RETURN QUERY SELECT false, 'Aircraft model not found.'::TEXT, 0::NUMERIC; RETURN; END IF;
v_purchase_price := v_model.purchase_price;
SELECT u.actor_type, u.game_current_time, u.hq_airport_iata
INTO v_actor_type, v_game_time, v_hq_iata
FROM users u WHERE u.id = p_user_id;
IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;
-- Read archetype from bot_profiles for AI users
IF v_actor_type = 'AI' THEN
SELECT COALESCE(bp.archetype, 'Balanced') INTO v_archetype
FROM bot_profiles bp WHERE bp.user_id = p_user_id;
IF NOT FOUND THEN v_archetype := 'Balanced'; END IF;
END IF;
IF v_actor_type = 'AI' THEN
v_cash := get_user_balance(p_user_id);
v_down_payment := v_purchase_price * p_down_payment_pct;
v_principal := v_purchase_price - v_down_payment;
v_interest_rate := 0.05;
v_total_repayable := v_principal * (1 + v_interest_rate);
v_monthly_payment := v_total_repayable / p_term_months;
IF v_cash < v_down_payment THEN
RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
END IF;
PERFORM debit_bank_account(p_user_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
'Aircraft financing down payment — ' || v_model.model_name, v_game_time);
v_economy_seats := CASE WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.80)::INT
WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.70)::INT
ELSE FLOOR(v_model.capacity * 0.50)::INT END;
v_business_seats := CASE WHEN v_archetype = 'Regional' THEN FLOOR(v_model.capacity * 0.15)::INT
WHEN v_archetype = 'Aggressive' THEN FLOOR(v_model.capacity * 0.20)::INT
ELSE FLOOR(v_model.capacity * 0.30)::INT END;
v_first_seats := v_model.capacity - v_economy_seats - v_business_seats;
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
VALUES (p_user_id, p_aircraft_model_id, v_model.model_name, 'BOT-' || left(p_user_id::text, 4), 'finance', 100.00, 'active', v_economy_seats, v_business_seats, v_first_seats)
RETURNING id INTO v_fleet_id;
INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id, term_months, monthly_payment)
VALUES (p_user_id, v_principal, v_interest_rate, v_principal * (1 + v_interest_rate), 0, 'active', 'aircraft_financing', v_fleet_id, p_term_months, v_monthly_payment);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT true, 'Aircraft financed (bot).'::TEXT, v_cash;
RETURN;
END IF;
-- Human path
v_cash := get_user_balance(p_user_id);
SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
v_credit_score := COALESCE(v_credit_score, 500);
SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = p_user_id;
v_tier := COALESCE(v_tier, 'Standard');
v_max_financing := CASE
WHEN v_tier = 'Platinum' THEN 80000000 WHEN v_tier = 'Gold' THEN 60000000
WHEN v_tier = 'Silver' THEN 40000000 WHEN v_tier = 'Standard' THEN 20000000
ELSE 5000000
END;
IF v_purchase_price > v_max_financing THEN
RETURN QUERY SELECT false, 'Aircraft price ($' || v_purchase_price::TEXT || ') exceeds your financing limit ($' || v_max_financing::TEXT || ') for tier ' || v_tier || '.'::TEXT, 0::NUMERIC; RETURN;
END IF;
IF p_term_months NOT IN (12, 24, 36, 48, 60) THEN
RETURN QUERY SELECT false, 'Financing term must be 12, 24, 36, 48, or 60 months.'::TEXT, 0::NUMERIC; RETURN;
END IF;
IF p_down_payment_pct < 0.10 OR p_down_payment_pct > 0.50 THEN
RETURN QUERY SELECT false, 'Down payment must be between 10% and 50%.'::TEXT, 0::NUMERIC; RETURN;
END IF;
v_down_payment := v_purchase_price * p_down_payment_pct;
v_principal := v_purchase_price - v_down_payment;
v_interest_rate := CASE
WHEN v_tier = 'Platinum' THEN 0.03 WHEN v_tier = 'Gold' THEN 0.04
WHEN v_tier = 'Silver' THEN 0.05 WHEN v_tier = 'Standard' THEN 0.07
ELSE 0.10
END;
v_total_repayable := v_principal * (1 + v_interest_rate);
v_monthly_payment := v_total_repayable / p_term_months;
IF v_cash < v_down_payment THEN
RETURN QUERY SELECT false, 'Insufficient cash for down payment of $' || ROUND(v_down_payment)::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
END IF;
PERFORM debit_bank_account(p_user_id, v_down_payment, 'investing', 'aircraft_purchase_deposit',
'Aircraft financing down payment — ' || v_model.model_name, v_game_time);
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, tail_number, acquisition_type, condition, status, economy_seats, business_seats, first_class_seats)
VALUES (p_user_id, p_aircraft_model_id, v_model.model_name, generate_tail_number(COALESCE(v_hq_iata, 'CGK')), 'finance', 100.00, 'active', v_model.capacity, 0, 0)
RETURNING id INTO v_fleet_id;
INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id, term_months, monthly_payment)
VALUES (p_user_id, v_principal, v_interest_rate, v_total_repayable, 0, 'active', 'aircraft_financing', v_fleet_id, p_term_months, v_monthly_payment);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT true, 'Aircraft financed successfully.'::TEXT, v_cash;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_ceo_name()
RETURNS character varying
LANGUAGE plpgsql
AS $function$
DECLARE
v_first_names TEXT[] := ARRAY[
'James', 'Maria', 'Chen', 'Ahmed', 'Yuki', 'Carlos', 'Priya', 'David',
'Sophie', 'Kim', 'Rafael', 'Aisha', 'Hans', 'Mei', 'Diego', 'Fatima',
'Erik', 'Sakura', 'Omar', 'Isabella', 'Ravi', 'Anna', 'Wei', 'Hassan',
'Elena', 'Takeshi', 'Marco', 'Lina', 'Viktor', 'Nadia'
];
v_last_names TEXT[] := ARRAY[
'Anderson', 'Tanaka', 'Müller', 'Santos', 'Park', 'Singh', 'Chen', 'Ali',
'Sato', 'Garcia', 'Kim', 'Patel', 'Fischer', 'Nakamura', 'Silva', 'Hassan',
'Bergström', 'Yamamoto', 'Fernandez', 'Lee', 'Sharma', 'Petrov', 'Wang',
'Ibrahim', 'Johansson', 'Kobayashi', 'Rossi', 'Zhang', 'Nguyen', 'Cohen'
];
BEGIN
RETURN v_first_names[1 + floor(random() * array_length(v_first_names, 1))] || ' ' ||
v_last_names[1 + floor(random() * array_length(v_last_names, 1))];
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_company_name(p_archetype character varying)
RETURNS character varying
LANGUAGE plpgsql
AS $function$
DECLARE
v_prefixes TEXT[] := ARRAY[
'Pacific', 'Atlas', 'Eagle', 'Nova', 'Apex', 'Summit', 'Horizon', 'Zenith',
'Sterling', 'Phoenix', 'Titan', 'Vanguard', 'Sovereign', 'Pinnacle', 'Crest',
'Falcon', 'Meridian', 'Aurora', 'Comet', 'Star', 'Sky', 'Air', 'Jet', 'Swift'
];
v_suffixes TEXT[] := ARRAY[
'Airways', 'Air', 'Airlines', 'Aviation', 'Air Lines', 'Express', 'Air Services'
];
v_regional_suffixes TEXT[] := ARRAY[
'Regional', 'Air Express', 'Commuter', 'Air Link', 'Connect'
];
v_premium_suffixes TEXT[] := ARRAY[
'International', 'World', 'Global', 'Airways International', 'Premium'
];
v_name VARCHAR;
BEGIN
v_name := v_prefixes[1 + floor(random() * array_length(v_prefixes, 1))];
CASE p_archetype
WHEN 'Regional' THEN
v_name := v_name || ' ' || v_regional_suffixes[1 + floor(random() * array_length(v_regional_suffixes, 1))];
WHEN 'Aggressive' THEN
v_name := v_name || ' ' || v_suffixes[1 + floor(random() * array_length(v_suffixes, 1))];
WHEN 'Balanced' THEN
v_name := v_name || ' ' || v_premium_suffixes[1 + floor(random() * array_length(v_premium_suffixes, 1))];
ELSE
v_name := v_name || ' ' || v_suffixes[1 + floor(random() * array_length(v_suffixes, 1))];
END CASE;
RETURN v_name;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_game_events(p_game_time timestamp with time zone)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
v_roll NUMERIC;
v_airport_iata VARCHAR(3);
v_effect_value NUMERIC;
v_title TEXT;
v_description TEXT;
BEGIN
-- 5% chance per tick to generate an event
v_roll := random();
IF v_roll > 0.05 THEN RETURN; END IF;
-- Pick random event type
CASE floor(random() * 4)
WHEN 0 THEN -- Fuel price shock (global)
v_effect_value := 0.7 + (random() * 0.6); -- 0.7x to 1.3x multiplier
IF v_effect_value > 1.0 THEN
v_title := 'Fuel Price Surge';
v_description := 'Global fuel prices have increased by ' || ROUND((v_effect_value - 1) * 100) || '%';
ELSE
v_title := 'Fuel Price Drop';
v_description := 'Global fuel prices have decreased by ' || ROUND((1 - v_effect_value) * 100) || '%';
END IF;
INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time)
VALUES ('fuel_shock', v_title, v_description, 'fuel_price', 'global', v_effect_value, p_game_time, p_game_time + INTERVAL '72 hours');
WHEN 1 THEN -- Demand surge at random airport
SELECT iata INTO v_airport_iata FROM airports ORDER BY random() LIMIT 1;
IF v_airport_iata IS NULL THEN RETURN; END IF;
v_effect_value := 1.2 + (random() * 0.3); -- 1.2x to 1.5x demand
v_title := 'Demand Surge at ' || v_airport_iata;
v_description := 'Increased passenger demand at ' || v_airport_iata || ' airport';
INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time)
VALUES ('demand_surge', v_title, v_description, 'demand_index', v_airport_iata, v_effect_value, p_game_time, p_game_time + INTERVAL '48 hours');
WHEN 2 THEN -- Weather disruption at high-demand airport
SELECT iata INTO v_airport_iata FROM airports WHERE demand_index > 70 ORDER BY random() LIMIT 1;
IF v_airport_iata IS NULL THEN
-- Fallback: pick any airport
SELECT iata INTO v_airport_iata FROM airports ORDER BY random() LIMIT 1;
END IF;
IF v_airport_iata IS NULL THEN RETURN; END IF;
v_title := 'Weather Disruption at ' || v_airport_iata;
v_description := 'Severe weather affecting operations at ' || v_airport_iata;
INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time)
VALUES ('weather', v_title, v_description, 'demand_index', v_airport_iata, 0.5, p_game_time, p_game_time + INTERVAL '24 hours');
WHEN 3 THEN -- Regulatory change (global tax increase)
v_effect_value := 1.05 + (random() * 0.15); -- 5-20% tax increase
v_title := 'Airport Tax Increase';
v_description := 'Airport taxes increased by ' || ROUND((v_effect_value - 1) * 100) || '% globally';
INSERT INTO game_events (event_type, title, description, effect_type, effect_target, effect_value, start_game_time, end_game_time)
VALUES ('regulatory', v_title, v_description, 'airport_tax', 'global', v_effect_value, p_game_time, p_game_time + INTERVAL '168 hours');
END CASE;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_tail_number(p_airport_iata character varying)
RETURNS character varying
LANGUAGE plpgsql
AS $function$
DECLARE
v_prefix VARCHAR;
v_rand VARCHAR := '';
v_chars VARCHAR := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
BEGIN
v_prefix := get_hq_prefix(p_airport_iata);
FOR i IN 1..3 LOOP
v_rand := v_rand || substr(v_chars, floor(random() * 26 + 1)::int, 1);
END LOOP;
RETURN v_prefix || v_rand;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_bot_health()
RETURNS TABLE(bot_id uuid, username character varying, archetype character varying, bot_status character varying, cash numeric, fleet_count bigint, route_count bigint)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
RETURN QUERY
SELECT
u.id,
u.username,
COALESCE(bp.archetype, 'Unknown')::VARCHAR,
COALESCE(u.operational_status, 'Active')::VARCHAR,
COALESCE(get_user_balance(u.id), 0),
(SELECT COUNT(*) FROM fleet_aircraft fa WHERE fa.user_id = u.id),
(SELECT COUNT(*) FROM route_assignments ra WHERE ra.user_id = u.id AND ra.status = 'active')
FROM users u
LEFT JOIN bot_profiles bp ON bp.user_id = u.id
WHERE u.actor_type = 'AI'
ORDER BY COALESCE(u.operational_status, 'Active'), u.username;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_competitor_insights(p_id uuid, p_is_bot boolean)
RETURNS TABLE(company_name character varying, ceo_name character varying, cash numeric, net_worth numeric, status character varying, fleet_breakdown jsonb, network_routes jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_company VARCHAR; v_ceo VARCHAR; v_cash NUMERIC; v_net_worth NUMERIC;
v_status VARCHAR; v_fleet JSONB; v_routes JSONB;
BEGIN
SELECT u.company_name, u.ceo_name, u.net_worth, COALESCE(u.operational_status, 'Active')
INTO v_company, v_ceo, v_net_worth, v_status
FROM users u WHERE u.id = p_id;
v_cash := get_user_balance(p_id);
SELECT COALESCE(jsonb_object_agg(model_label, count_val), '{}'::jsonb) INTO v_fleet
FROM (SELECT (m.manufacturer || ' ' || m.model_name || ' (' || f.acquisition_type || ')') AS model_label,
COUNT(*)::INT AS count_val
FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id
WHERE f.user_id = p_id AND f.status = 'active'
GROUP BY m.manufacturer, m.model_name, f.acquisition_type) d;
SELECT COALESCE(jsonb_agg(route_label), '[]'::jsonb) INTO v_routes
FROM (SELECT (origin_iata || '-' || destination_iata) AS route_label
FROM route_assignments WHERE user_id = p_id) r;
RETURN QUERY SELECT v_company::VARCHAR, v_ceo::VARCHAR, v_cash, v_net_worth,
v_status::VARCHAR, v_fleet, v_routes;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_config_int(p_key text)
RETURNS integer
LANGUAGE sql
STABLE
AS $function$
SELECT (value #>> '{}')::int FROM game_config WHERE key = p_key;
$function$;

CREATE OR REPLACE FUNCTION public.get_config_jsonb(p_key text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
SELECT value FROM game_config WHERE key = p_key;
$function$;

CREATE OR REPLACE FUNCTION public.get_config_numeric(p_key text)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
SELECT (value #>> '{}')::numeric FROM game_config WHERE key = p_key;
$function$;

CREATE OR REPLACE FUNCTION public.get_config_text(p_key text)
RETURNS text
LANGUAGE sql
STABLE
AS $function$
SELECT value #>> '{}' FROM game_config WHERE key = p_key;
$function$;

CREATE OR REPLACE FUNCTION public.get_credit_report()
RETURNS TABLE(
    current_score        integer,
    fleet_health         integer,
    revenue_stability    integer,
    debt_ratio           integer,
    cash_reserve         integer,
    profit_history       integer,
    credit_tier          character varying,
    max_unsecured_loan   numeric,
    max_secured_loan     numeric,
    max_financing_amount numeric,
    base_interest_rate   numeric,
    suggestions          text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id  UUID;
    v_score    RECORD;
    v_tier     VARCHAR(20);
    v_config   JSONB;
    v_tier_cfg JSONB;
    v_sugg     TEXT[] := '{}';
    v_existing RECORD;
BEGIN
    v_user_id := require_current_user_id();
    SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';

    -- Check for existing credit_scores entry (written by update_credit_score)
    SELECT cs.tier INTO v_existing
    FROM credit_scores cs
    WHERE cs.user_id = v_user_id;

    -- Always compute fresh component scores
    SELECT * INTO v_score FROM calculate_credit_score(v_user_id) LIMIT 1;
    IF NOT FOUND THEN
        current_score := 500; fleet_health := 100; revenue_stability := 100;
        debt_ratio := 100; cash_reserve := 100; profit_history := 100;
        credit_tier := 'Standard'; max_unsecured_loan := 5000000;
        max_secured_loan := 25000000; max_financing_amount := 20000000;
        base_interest_rate := 0.07;
        suggestions := ARRAY['Build your fleet and routes to establish credit history.'];
        RETURN NEXT; RETURN;
    END IF;

    -- Use existing tier from credit_scores if available (set correctly by
    -- update_credit_score). Only fall back to resolve_credit_tier when no
    -- credit_scores entry exists yet.
    IF v_existing IS NOT NULL THEN
        v_tier := v_existing.tier;
    ELSE
        v_tier := resolve_credit_tier(v_score.total_score);
    END IF;

    -- Upsert the computed scores (preserving the authoritative tier)
    INSERT INTO credit_scores (
        user_id, score, tier, fleet_health_score, revenue_stability_score,
        debt_ratio_score, cash_reserves_score, profit_history_score, computed_at
    ) VALUES (
        v_user_id, v_score.total_score, v_tier,
        v_score.fleet_health, v_score.revenue_stability, v_score.debt_ratio,
        v_score.cash_reserve, v_score.profit_history, NOW()
    )
    ON CONFLICT (user_id) DO UPDATE SET
        score                = EXCLUDED.score,
        -- Only update tier if we are NOT preserving an existing one
        tier                 = CASE
                                 WHEN credit_scores.tier IS NOT NULL THEN credit_scores.tier
                                 ELSE EXCLUDED.tier
                               END,
        fleet_health_score   = EXCLUDED.fleet_health_score,
        revenue_stability_score = EXCLUDED.revenue_stability_score,
        debt_ratio_score     = EXCLUDED.debt_ratio_score,
        cash_reserves_score  = EXCLUDED.cash_reserves_score,
        profit_history_score = EXCLUDED.profit_history_score,
        computed_at          = EXCLUDED.computed_at;

    -- Read back the (possibly preserved) tier
    SELECT cs.tier INTO v_tier FROM credit_scores cs WHERE cs.user_id = v_user_id;

    -- Lookup tier config: tiers are at root level in seed data
    v_tier_cfg := COALESCE(v_config->v_tier, '{}'::JSONB);

    current_score        := v_score.total_score;
    fleet_health         := v_score.fleet_health;
    revenue_stability    := v_score.revenue_stability;
    debt_ratio           := v_score.debt_ratio;
    cash_reserve         := v_score.cash_reserve;
    profit_history       := v_score.profit_history;
    credit_tier          := v_tier;
    max_unsecured_loan   := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
    max_secured_loan     := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
    max_financing_amount := COALESCE((v_tier_cfg->>'max_financing')::NUMERIC, 20000000);
    base_interest_rate   := COALESCE((v_tier_cfg->>'rate')::NUMERIC,
                            COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07));

    v_sugg := '{}';
    IF v_score.fleet_health < 100 THEN
        v_sugg := array_append(v_sugg, 'Repair grounded aircraft to improve fleet health.');
    END IF;
    IF v_score.debt_ratio < 100 THEN
        v_sugg := array_append(v_sugg, 'Reduce outstanding debt to improve your debt ratio.');
    END IF;
    IF v_score.cash_reserve < 100 THEN
        v_sugg := array_append(v_sugg, 'Build cash reserves for financial stability.');
    END IF;
    IF v_score.revenue_stability < 100 THEN
        v_sugg := array_append(v_sugg, 'Establish consistent revenue from routes.');
    END IF;
    IF array_length(v_sugg, 1) IS NULL THEN
        v_sugg := ARRAY['Your credit profile is healthy. Keep it up!'];
    END IF;
    suggestions := v_sugg;
    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
SELECT public.get_user_id_for_auth_uid(auth.uid());
$function$;

CREATE OR REPLACE FUNCTION public.get_database_size_report()
RETURNS TABLE(metric text, value text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_db_size_mb NUMERIC;
v_warn_mb NUMERIC;
v_critical_mb NUMERIC;
v_free_quota_mb NUMERIC;
BEGIN
v_warn_mb := COALESCE(get_config_numeric('database_warn_mb'), 350);
v_critical_mb := COALESCE(get_config_numeric('database_critical_mb'), 425);
v_free_quota_mb := COALESCE(get_config_numeric('database_free_quota_mb'), 500);
SELECT ROUND((pg_database_size(current_database()) / 1024.0 / 1024.0)::NUMERIC, 2) INTO v_db_size_mb;
metric := 'database_size_mb'; value := v_db_size_mb::TEXT; RETURN NEXT;
metric := 'free_quota_mb'; value := v_free_quota_mb::TEXT; RETURN NEXT;
metric := 'usage_pct'; value := ROUND((v_db_size_mb / v_free_quota_mb * 100)::NUMERIC, 1)::TEXT || '%'; RETURN NEXT;
metric := 'warn_threshold_mb'; value := v_warn_mb::TEXT; RETURN NEXT;
metric := 'critical_threshold_mb'; value := v_critical_mb::TEXT; RETURN NEXT;
metric := 'status'; value := CASE
WHEN v_db_size_mb >= v_critical_mb THEN 'CRITICAL'
WHEN v_db_size_mb >= v_warn_mb THEN 'WARNING'
ELSE 'OK'
END; RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_finance_snapshot()
RETURNS TABLE(actor_id uuid, is_bot boolean, company_name character varying, cash numeric, net_worth numeric, owned_aircraft_asset_value numeric, leased_aircraft_monthly_exposure numeric, fleet_count integer, owned_fleet_count integer, leased_fleet_count integer, active_route_count integer, rolling_revenue_30d numeric, rolling_expense_30d numeric, rolling_net_30d numeric, ledger_window_days integer)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM get_finance_snapshot(v_user_id, FALSE);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_finance_snapshot(p_id uuid, p_is_bot boolean DEFAULT false)
RETURNS TABLE(actor_id uuid, is_bot boolean, company_name character varying, cash numeric, net_worth numeric, owned_aircraft_asset_value numeric, leased_aircraft_monthly_exposure numeric, fleet_count integer, owned_fleet_count integer, leased_fleet_count integer, active_route_count integer, rolling_revenue_30d numeric, rolling_expense_30d numeric, rolling_net_30d numeric, ledger_window_days integer)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_company_name VARCHAR; v_cash NUMERIC := 0.00; v_net_worth NUMERIC := 0.00;
v_owned_asset_value NUMERIC := 0.00; v_leased_monthly_exposure NUMERIC := 0.00;
v_fleet_count INT := 0; v_owned_fleet_count INT := 0; v_leased_fleet_count INT := 0;
v_active_route_count INT := 0; v_revenue_30d NUMERIC := 0.00; v_expense_30d NUMERIC := 0.00;
v_ledger_window_days INT := 30; v_game_current_time TIMESTAMP WITH TIME ZONE;
BEGIN
SELECT u.company_name, u.net_worth, u.game_current_time
INTO v_company_name, v_net_worth, v_game_current_time
FROM users u WHERE u.id = p_id;
IF NOT FOUND THEN RETURN; END IF;
v_cash := get_user_balance(p_id);
SELECT COUNT(*)::INT, COUNT(*) FILTER (WHERE f.acquisition_type = 'purchase')::INT,
COUNT(*) FILTER (WHERE f.acquisition_type = 'lease')::INT,
COALESCE(SUM(CASE WHEN f.acquisition_type = 'purchase' THEN m.purchase_price ELSE 0 END), 0.00),
COALESCE(SUM(CASE WHEN f.acquisition_type = 'lease' THEN m.lease_price_per_month ELSE 0 END), 0.00)
INTO v_fleet_count, v_owned_fleet_count, v_leased_fleet_count, v_owned_asset_value, v_leased_monthly_exposure
FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.user_id = p_id;
SELECT COUNT(*)::INT INTO v_active_route_count FROM route_assignments r WHERE r.user_id = p_id;
SELECT COALESCE(SUM(CASE WHEN transaction_type = 'credit' THEN amount ELSE 0 END), 0.00),
COALESCE(SUM(CASE WHEN transaction_type = 'debit' THEN amount ELSE 0 END), 0.00)
INTO v_revenue_30d, v_expense_30d
FROM bank_transactions
WHERE user_id = p_id AND game_date >= v_game_current_time - INTERVAL '30 days';
RETURN QUERY SELECT p_id, p_is_bot, v_company_name::VARCHAR, v_cash, v_net_worth,
v_owned_asset_value, v_leased_monthly_exposure, v_fleet_count, v_owned_fleet_count,
v_leased_fleet_count, v_active_route_count, v_revenue_30d, v_expense_30d,
v_revenue_30d - v_expense_30d, v_ledger_window_days;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_fleet_commonality_discount(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE v_max_same_mfr INT := 0; v_total_fleet INT := 0;
BEGIN
SELECT COUNT(*) INTO v_total_fleet FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = p_user_id AND f.status = 'active';
IF v_total_fleet < 2 THEN RETURN 0.0; END IF;
SELECT COALESCE(MAX(cnt), 0) INTO v_max_same_mfr FROM (SELECT COUNT(*) AS cnt FROM fleet_aircraft f JOIN aircraft_models m ON f.aircraft_model_id = m.id WHERE f.user_id = p_user_id AND f.status = 'active' GROUP BY m.manufacturer) sub;
RETURN LEAST(0.20, (v_max_same_mfr - 1) * 0.05);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_global_leaderboard()
RETURNS TABLE(id uuid, company_name character varying, ceo_name character varying, is_bot boolean, archetype character varying, cash numeric, net_worth numeric, fleet_size integer, monthly_revenue numeric, status character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
RETURN QUERY SELECT u.id, u.company_name::VARCHAR, u.ceo_name::VARCHAR,
(u.actor_type = 'AI')::BOOLEAN, COALESCE(bp.archetype, 'Player')::VARCHAR,
get_user_balance(u.id), u.net_worth,
(SELECT COUNT(*)::INT FROM fleet_aircraft f WHERE f.user_id = u.id AND f.status = 'active'),
COALESCE((SELECT SUM(bt.amount) FROM bank_transactions bt
WHERE bt.user_id = u.id AND bt.transaction_type = 'credit'
AND bt.game_date >= u.game_current_time - INTERVAL '30 days'), 0.00)::NUMERIC,
COALESCE(u.operational_status, 'Active')::VARCHAR
FROM users u
LEFT JOIN bot_profiles bp ON bp.user_id = u.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_hq_prefix(p_airport_iata character varying)
RETURNS character varying
LANGUAGE plpgsql
AS $function$
DECLARE
v_country VARCHAR;
BEGIN
SELECT country INTO v_country FROM airports WHERE iata = p_airport_iata;

RETURN CASE
    WHEN v_country = 'Indonesia' THEN 'PK-'
    WHEN v_country = 'Singapore' THEN '9V-'
    WHEN v_country = 'United Kingdom' OR v_country = 'UK' THEN 'G-'
    WHEN v_country = 'Malaysia' THEN '9M-'
    WHEN v_country = 'Thailand' THEN 'HS-'
    WHEN v_country = 'Philippines' THEN 'RP-'
    WHEN v_country = 'Vietnam' THEN 'VN-'
    WHEN v_country = 'Japan' THEN 'JA-'
    WHEN v_country = 'Germany' THEN 'D-'
    WHEN v_country = 'France' THEN 'F-'
    WHEN v_country = 'United States' OR v_country = 'USA' THEN 'N-'
    ELSE '9V-'
END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_hub_bonus_percentage(p_origin_iata character varying, p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
v_hub_routes_count INT;
BEGIN
SELECT COUNT(*) INTO v_hub_routes_count
FROM route_assignments
WHERE origin_iata = p_origin_iata
AND user_id = p_user_id
AND status = 'active';
IF v_hub_routes_count > 1 THEN
RETURN LEAST((v_hub_routes_count - 1) * 2.0, 20.0);
END IF;
RETURN 0.0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_owner_route_optimizer(p_user_id uuid, p_origin_iata character varying DEFAULT NULL::character varying, p_destination_iata character varying DEFAULT NULL::character varying, p_limit integer DEFAULT 25, p_include_assigned boolean DEFAULT false, p_exclude_existing_routes boolean DEFAULT true)
RETURNS TABLE(aircraft_id uuid, tail_number character varying, aircraft_model character varying, acquisition_type character varying, currently_assigned boolean, route_origin_iata character varying, route_destination_iata character varying, route_already_exists boolean, distance_km numeric, ticket_price numeric, weekly_flights integer, recommended_economy_seats integer, recommended_business_seats integer, recommended_first_class_seats integer, effective_passenger_capacity integer, expected_passengers_per_flight integer, load_factor numeric, direct_cost_per_flight numeric, revenue_per_flight numeric, contribution_per_flight numeric, weekly_contribution numeric, maintenance_impact_per_week numeric)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE v_origin_iata VARCHAR(3); v_player_schema TEXT; v_player_relation TEXT;
BEGIN
SELECT ns.nspname, cls.relname INTO v_player_schema, v_player_relation
FROM pg_catalog.pg_class cls JOIN pg_catalog.pg_namespace ns ON ns.oid = cls.relnamespace
JOIN pg_catalog.pg_attribute att_id ON att_id.attrelid = cls.oid AND att_id.attname = 'id' AND att_id.attnum > 0 AND NOT att_id.attisdropped
JOIN pg_catalog.pg_attribute att_hq ON att_hq.attrelid = cls.oid AND att_hq.attname = 'hq_airport_iata' AND att_hq.attnum > 0 AND NOT att_hq.attisdropped
WHERE cls.relkind IN ('r', 'p', 'v', 'm') AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY CASE WHEN ns.nspname = 'public' AND cls.relname = 'users' THEN 0 WHEN cls.relname = 'users' THEN 1 ELSE 2 END, ns.nspname, cls.relname LIMIT 1;
IF v_player_schema IS NULL OR v_player_relation IS NULL THEN RETURN; END IF;
EXECUTE format('select coalesce($1, hq_airport_iata) from %I.%I where id = $2', v_player_schema, v_player_relation) INTO v_origin_iata USING p_origin_iata, p_user_id;
IF v_origin_iata IS NULL THEN RETURN; END IF;
RETURN QUERY
WITH origin_airport AS (SELECT a.* FROM public.airports a WHERE a.iata = v_origin_iata LIMIT 1),
settings AS (SELECT COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85) AS fuel_price_per_liter),
aircraft_candidates AS (
SELECT f.id AS candidate_aircraft_id, f.tail_number AS candidate_tail_number, f.acquisition_type AS candidate_acquisition_type,
m.model_name AS candidate_model_name, m.capacity AS model_capacity, m.range_km AS model_range_km, m.speed_kmh AS model_speed_kmh,
m.fuel_burn_per_km AS model_fuel_burn_per_km, m.maintenance_cost_per_hour AS model_maintenance_cost_per_hour,
EXISTS (SELECT 1 FROM public.route_assignments r WHERE r.user_id = p_user_id AND r.assigned_aircraft_id = f.id) AS candidate_currently_assigned
FROM public.fleet_aircraft f JOIN public.aircraft_models m ON m.id = f.aircraft_model_id
WHERE f.user_id = p_user_id AND (p_include_assigned OR NOT EXISTS (SELECT 1 FROM public.route_assignments r WHERE r.user_id = p_user_id AND r.assigned_aircraft_id = f.id))),
destination_candidates AS (
SELECT dst.iata AS destination_iata, dst.demand_index AS destination_demand_index,
ROUND((6371.0 * 2.0 * ASIN(SQRT(POWER(SIN(RADIANS(dst.latitude - org.latitude) / 2.0), 2) + COS(RADIANS(org.latitude)) * COS(RADIANS(dst.latitude)) * POWER(SIN(RADIANS(dst.longitude - org.longitude) / 2.0), 2))))::NUMERIC, 2) AS route_distance_km
FROM public.airports dst CROSS JOIN origin_airport org WHERE dst.iata <> org.iata AND (p_destination_iata IS NULL OR dst.iata = p_destination_iata)),
candidate_pairs AS (
SELECT ac.*, dc.destination_iata, dc.destination_demand_index, dc.route_distance_km, org.iata AS origin_iata, org.demand_index AS origin_demand_index
FROM aircraft_candidates ac CROSS JOIN destination_candidates dc CROSS JOIN origin_airport org WHERE dc.route_distance_km <= ac.model_range_km),
seat_presets AS (
SELECT cp.*, seat_profile.preset_economy_seats, seat_profile.preset_business_seats, seat_profile.preset_first_class_seats,
GREATEST(0, COALESCE(NULLIF(COALESCE(seat_profile.preset_economy_seats, 0) + COALESCE(seat_profile.preset_business_seats, 0) + COALESCE(seat_profile.preset_first_class_seats, 0), 0), COALESCE(cp.model_capacity, 0)))::INT AS passenger_capacity
FROM candidate_pairs cp CROSS JOIN LATERAL (VALUES (cp.model_capacity, 0, 0), (GREATEST(1, cp.model_capacity - (2 * FLOOR(cp.model_capacity * 0.18 / 2.0)::INT) - (3 * FLOOR(cp.model_capacity * 0.06 / 3.0)::INT)), FLOOR(cp.model_capacity * 0.18 / 2.0)::INT, FLOOR(cp.model_capacity * 0.06 / 3.0)::INT), (GREATEST(1, cp.model_capacity - (2 * FLOOR(cp.model_capacity * 0.24 / 2.0)::INT) - (3 * FLOOR(cp.model_capacity * 0.12 / 3.0)::INT)), FLOOR(cp.model_capacity * 0.24 / 2.0)::INT, FLOOR(cp.model_capacity * 0.12 / 3.0)::INT)) AS seat_profile(preset_economy_seats, preset_business_seats, preset_first_class_seats)),
fare_points AS (
SELECT sp.*, ROUND((50.00 + (COALESCE(sp.route_distance_km, 0.0)::NUMERIC * 0.12)) * fare.multiplier, 2) AS evaluated_ticket_price
FROM seat_presets sp CROSS JOIN LATERAL (VALUES (0.95::NUMERIC), (1.00::NUMERIC), (1.05::NUMERIC), (1.10::NUMERIC), (1.20::NUMERIC), (1.35::NUMERIC)) AS fare(multiplier)),
scored AS (
SELECT fp.candidate_aircraft_id, fp.candidate_tail_number, fp.candidate_model_name, fp.candidate_acquisition_type, fp.candidate_currently_assigned,
fp.origin_iata, fp.destination_iata,
EXISTS (SELECT 1 FROM public.route_assignments existing_route WHERE existing_route.user_id = p_user_id AND existing_route.origin_iata = fp.origin_iata AND existing_route.destination_iata = fp.destination_iata) AS candidate_route_already_exists,
fp.route_distance_km, fp.evaluated_ticket_price,
CASE WHEN COALESCE(fp.route_distance_km, 0.0) <= 0.0 OR COALESCE(fp.model_speed_kmh, 0) <= 0 THEN 0 ELSE FLOOR(168.0 / NULLIF((COALESCE(fp.route_distance_km, 0.0) / fp.model_speed_kmh::DOUBLE PRECISION) + 1.0, 0.0))::INT END AS computed_weekly_flights,
fp.preset_economy_seats, fp.preset_business_seats, fp.preset_first_class_seats, fp.passenger_capacity,
GREATEST(0, LEAST(COALESCE(fp.passenger_capacity, 0), FLOOR(COALESCE(fp.passenger_capacity, 0) * 0.95 * GREATEST(0.55, LEAST(1.00, 0.55 + (((((COALESCE(fp.origin_demand_index, 50) + COALESCE(fp.destination_demand_index, 50))::NUMERIC) / 2.0) / 100.0) * 0.45))) * GREATEST(0.00, LEAST(1.50, 1.5 - 0.8 * POWER(COALESCE(fp.evaluated_ticket_price, 0.00) / NULLIF(50.00 + (COALESCE(fp.route_distance_km, 0.0)::NUMERIC * 0.12), 0.00), 2))))::INT)) AS computed_expected_passengers_per_flight,
ROUND((fp.route_distance_km * fp.model_fuel_burn_per_km * s.fuel_price_per_liter + (((fp.route_distance_km / NULLIF(fp.model_speed_kmh::DOUBLE PRECISION, 0.0)) + 1.0) * fp.model_maintenance_cost_per_hour))::NUMERIC, 2) AS computed_direct_cost_per_flight
FROM fare_points fp CROSS JOIN settings s),
ranked AS (
SELECT s.candidate_aircraft_id, s.candidate_tail_number, s.candidate_model_name, s.candidate_acquisition_type, s.candidate_currently_assigned,
s.origin_iata, s.destination_iata, s.candidate_route_already_exists, s.route_distance_km, s.evaluated_ticket_price, s.computed_weekly_flights,
s.preset_economy_seats, s.preset_business_seats, s.preset_first_class_seats, s.passenger_capacity, s.computed_expected_passengers_per_flight,
ROUND(CASE WHEN s.passenger_capacity <= 0 THEN 0.00 ELSE (s.computed_expected_passengers_per_flight::NUMERIC / s.passenger_capacity::NUMERIC) * 100.00 END, 2) AS computed_load_factor,
s.computed_direct_cost_per_flight,
ROUND((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price)::NUMERIC, 2) AS computed_revenue_per_flight,
ROUND(((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price) - s.computed_direct_cost_per_flight)::NUMERIC, 2) AS computed_contribution_per_flight,
ROUND((((s.computed_expected_passengers_per_flight * s.evaluated_ticket_price) - s.computed_direct_cost_per_flight) * s.computed_weekly_flights * CASE WHEN s.candidate_route_already_exists THEN 0.72 ELSE 1.00 END)::NUMERIC, 2) AS adjusted_weekly_contribution,
ROUND(CASE WHEN s.candidate_acquisition_type = 'lease' THEN s.computed_weekly_flights * 0.70 ELSE s.computed_weekly_flights * 0.50 END::NUMERIC, 2) AS computed_maintenance_impact_per_week,
ROW_NUMBER() OVER (PARTITION BY s.origin_iata, s.destination_iata, s.candidate_model_name, s.candidate_acquisition_type, s.preset_economy_seats, s.preset_business_seats, s.preset_first_class_seats, s.evaluated_ticket_price ORDER BY s.candidate_currently_assigned ASC, s.candidate_tail_number ASC, s.candidate_aircraft_id ASC) AS route_model_rank
FROM scored s WHERE s.computed_weekly_flights > 0 AND (NOT p_exclude_existing_routes OR NOT s.candidate_route_already_exists))
SELECT r.candidate_aircraft_id, r.candidate_tail_number, r.candidate_model_name, r.candidate_acquisition_type, r.candidate_currently_assigned,
r.origin_iata, r.destination_iata, r.candidate_route_already_exists, r.route_distance_km, r.evaluated_ticket_price, r.computed_weekly_flights,
r.preset_economy_seats, r.preset_business_seats, r.preset_first_class_seats, r.passenger_capacity, r.computed_expected_passengers_per_flight,
r.computed_load_factor, r.computed_direct_cost_per_flight, r.computed_revenue_per_flight, r.computed_contribution_per_flight,
r.adjusted_weekly_contribution, r.computed_maintenance_impact_per_week
FROM ranked r WHERE r.route_model_rank = 1 ORDER BY r.adjusted_weekly_contribution DESC, r.computed_contribution_per_flight DESC, r.computed_load_factor DESC, r.route_distance_km ASC LIMIT LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_table_size_report()
RETURNS TABLE(schema_name text, table_name text, row_estimate bigint, total_size_bytes bigint, total_size_pretty text, table_size_pretty text, index_size_pretty text)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
RETURN QUERY
SELECT
stat.schemaname::TEXT,
stat.relname::TEXT,
stat.n_live_tup::BIGINT,
pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)::BIGINT,
pg_size_pretty(pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)),
pg_size_pretty(pg_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS)),
pg_size_pretty(pg_indexes_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS))
FROM pg_stat_user_tables stat
WHERE stat.schemaname = 'public'
ORDER BY pg_total_relation_size(format('%I.%I', stat.schemaname, stat.relname)::REGCLASS) DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_tail_suffix(p_tail character varying)
RETURNS character varying
LANGUAGE plpgsql
AS $function$
BEGIN
IF position('-' in p_tail) > 0 THEN
RETURN split_part(p_tail, '-', 2);
ELSE
-- Fallback to last 3 characters
RETURN right(p_tail, 3);
END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_user_balance(p_user_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
SELECT COALESCE(balance, 0)
FROM bank_accounts
WHERE user_id = p_user_id AND account_type = 'operating'
LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.get_user_id_for_auth_uid(p_auth_user_id uuid DEFAULT auth.uid())
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
SELECT u.id
FROM public.users u
WHERE u.auth_user_id = p_auth_user_id
LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.get_world_tick_guardrail_report()
RETURNS TABLE(check_name text, check_status text, details text)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
r_season RECORD;
r_latest_success RECORD;
v_lagging_actors INT := 0;
v_ahead_actors INT := 0;
v_backwards_logs INT := 0;
BEGIN
SELECT * INTO r_season
FROM season_clock
WHERE status = 'active'
ORDER BY created_at ASC
LIMIT 1;
IF NOT FOUND THEN
RETURN QUERY SELECT 'active_season_exists', 'fail', 'No active season_clock row exists.';
RETURN;
END IF;
RETURN QUERY SELECT
'active_season_exists', 'pass',
'Active season ' || r_season.id || ' at ' || r_season.current_game_time || '.';
SELECT COUNT(*)::INT INTO v_lagging_actors
FROM users u
WHERE u.season_id = r_season.id
AND u.game_current_time < r_season.current_game_time;
RETURN QUERY SELECT
'actors_not_lagging',
CASE WHEN v_lagging_actors = 0 THEN 'pass' ELSE 'fail' END,
'lagging_actors=' || v_lagging_actors || '.';
SELECT COUNT(*)::INT INTO v_ahead_actors
FROM users u
WHERE u.season_id = r_season.id
AND u.game_current_time > r_season.current_game_time;
RETURN QUERY SELECT
'actors_not_ahead',
CASE WHEN v_ahead_actors = 0 THEN 'pass' ELSE 'fail' END,
'ahead_actors=' || v_ahead_actors || '.';
SELECT COUNT(*)::INT INTO v_backwards_logs
FROM world_tick_log wtl
WHERE wtl.status = 'success'
AND wtl.game_time_after < wtl.game_time_before;
RETURN QUERY SELECT
'no_backwards_world_ticks',
CASE WHEN v_backwards_logs = 0 THEN 'pass' ELSE 'fail' END,
'backwards_success_logs=' || v_backwards_logs || '.';
SELECT * INTO r_latest_success
FROM world_tick_log wtl
WHERE wtl.season_id = r_season.id AND wtl.status = 'success'
ORDER BY wtl.started_at DESC
LIMIT 1;
IF NOT FOUND THEN
RETURN QUERY SELECT 'recent_successful_world_tick', 'fail',
'No successful world_tick_log rows exist for active season.';
RETURN;
END IF;
RETURN QUERY SELECT
'recent_successful_world_tick',
CASE WHEN r_latest_success.started_at >= NOW() - INTERVAL '10 minutes' THEN 'pass' ELSE 'warn' END,
'latest_success=' || r_latest_success.started_at
|| ', ticks=' || r_latest_success.ticks_processed
|| ', players=' || r_latest_success.players_processed
|| ', bots=' || r_latest_success.bots_processed || '.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_world_tick_log_compaction_report()
RETURNS TABLE(metric text, value text)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_raw_count BIGINT;
v_retention_days INT;
v_cutoff TIMESTAMPTZ;
v_would_delete BIGINT;
BEGIN
SELECT COUNT(*) INTO v_raw_count FROM world_tick_log;
v_retention_days := COALESCE(get_config_int('world_tick_log_raw_real_days'), 7);
v_cutoff := NOW() - (v_retention_days || ' days')::INTERVAL;
SELECT COUNT(*) INTO v_would_delete FROM world_tick_log WHERE started_at < v_cutoff;
metric := 'raw_log_count';        value := v_raw_count::TEXT;           RETURN NEXT;
metric := 'retention_days';        value := v_retention_days::TEXT;      RETURN NEXT;
metric := 'cutoff_date';           value := v_cutoff::TEXT;             RETURN NEXT;
metric := 'rows_pending_delete';   value := v_would_delete::TEXT;       RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_world_tick_scheduler_health()
RETURNS TABLE(season_id uuid, season_status character varying, current_game_time timestamp with time zone, season_last_tick_at timestamp with time zone, seconds_since_last_tick numeric, latest_log_started_at timestamp with time zone, latest_log_status character varying, latest_log_message text, latest_ticks_processed integer, scheduler_job_exists boolean, scheduler_job_active boolean)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'cron', 'extensions'
AS $function$
DECLARE
r_season RECORD;
r_log RECORD;
r_job RECORD;
BEGIN
SELECT *
INTO r_season
FROM public.season_clock
WHERE status = 'active'
ORDER BY created_at ASC
LIMIT 1;
IF NOT FOUND THEN
RETURN;
END IF;
SELECT *
INTO r_log
FROM public.world_tick_log
WHERE world_tick_log.season_id = r_season.id
ORDER BY started_at DESC
LIMIT 1;
SELECT *
INTO r_job
FROM cron.job
WHERE jobname = 'skyward_world_tick'
LIMIT 1;
RETURN QUERY SELECT
r_season.id,
r_season.status::VARCHAR,
r_season.current_game_time,
r_season.last_tick_at,
EXTRACT(EPOCH FROM (NOW() - r_season.last_tick_at))::NUMERIC,
r_log.started_at,
r_log.status::VARCHAR,
r_log.message,
COALESCE(r_log.ticks_processed, 0),
(r_job.jobid IS NOT NULL),
COALESCE(r_job.active, FALSE);
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_username TEXT;
v_expected_email TEXT;
v_company_name TEXT;
v_ceo_name TEXT;
v_starting_cash NUMERIC;
BEGIN
IF EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = NEW.id) THEN
RETURN NEW;
END IF;
v_username := public.normalize_username(NEW.raw_user_meta_data ->> 'username');
v_company_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'company_name', '')), '');
v_ceo_name := NULLIF(trim(COALESCE(NEW.raw_user_meta_data ->> 'ceo_name', '')), '');
IF v_username IS NULL THEN
RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.username';
END IF;
IF v_company_name IS NULL THEN
RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.company_name';
END IF;
IF v_ceo_name IS NULL THEN
RAISE EXCEPTION 'Auth bootstrap requires raw_user_meta_data.ceo_name';
END IF;
v_expected_email := public.build_synthetic_auth_email(v_username);
IF lower(COALESCE(NEW.email, '')) <> v_expected_email THEN
RAISE EXCEPTION 'Auth bootstrap email mismatch for username %', v_username;
END IF;
IF EXISTS (SELECT 1 FROM public.users u WHERE u.username = v_username) THEN
RAISE EXCEPTION 'Username % is already registered.', v_username;
END IF;
IF EXISTS (SELECT 1 FROM public.users u WHERE u.company_name = v_company_name) THEN
RAISE EXCEPTION 'Company name % is already registered.', v_company_name;
END IF;
SELECT COALESCE(get_config_numeric('starting_cash'), 15000000.00)
INTO v_starting_cash;
INSERT INTO public.users (
auth_user_id, username, company_name, ceo_name, net_worth,
game_current_time, last_active_at, operational_status,
consecutive_negative_days, recovery_streak_days, auto_grounding_threshold,
actor_type, hq_airport_iata
) VALUES (
NEW.id, v_username, v_company_name, v_ceo_name, v_starting_cash,
'2020-01-01 00:00:00+00', NOW(), 'Active',
0, 0, 40.00,
'REAL', 'CGK'
);
-- trg_create_default_bank_account trigger handles creating the operating account
-- credit_scores entry is created by update_credit_score on day boundary
RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.haversine_distance(lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision)
RETURNS double precision
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
R DOUBLE PRECISION := 6371.0;
dlat DOUBLE PRECISION;
dlon DOUBLE PRECISION;
a DOUBLE PRECISION;
c DOUBLE PRECISION;
BEGIN
dlat := radians(lat2 - lat1);
dlon := radians(lon2 - lon1);
a := sin(dlat / 2) ^ 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ^ 2;
c := 2 * atan2(sqrt(a), sqrt(1 - a));
RETURN R * c;
END;
$function$;

CREATE OR REPLACE FUNCTION public.haversine_distance(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
R NUMERIC := 6371; -- Earth radius in km
dlat NUMERIC;
dlon NUMERIC;
a NUMERIC;
c NUMERIC;
BEGIN
dlat := radians(lat2 - lat1);
dlon := radians(lon2 - lon1);
a := sin(dlat/2)^2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon/2)^2;
c := 2 * atan2(sqrt(a), sqrt(1-a));
RETURN R * c;
END;
$function$;

CREATE OR REPLACE FUNCTION public.lease_aircraft(p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM lease_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;

CREATE OR REPLACE FUNCTION public.lease_aircraft(p_user_id uuid, p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_cash NUMERIC; v_lease_price NUMERIC; v_model_name VARCHAR; v_capacity INT;
v_hq_iata VARCHAR(3); v_tail VARCHAR(20); v_deposit_pct NUMERIC; v_lease_deposit NUMERIC;
v_economy INT; v_business INT; v_first INT; v_slots_used INT; v_game_time TIMESTAMPTZ;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
v_cash := get_user_balance(p_user_id);
SELECT hq_airport_iata, game_current_time INTO v_hq_iata, v_game_time
FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC; RETURN; END IF;
SELECT lease_price_per_month, model_name, capacity INTO v_lease_price, v_model_name, v_capacity
FROM aircraft_models WHERE id = p_model_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash; RETURN; END IF;
v_deposit_pct := COALESCE(get_config_numeric('base_lease_deposit_percentage'), 0.10);
v_lease_deposit := v_lease_price * v_deposit_pct;
v_economy := COALESCE(p_economy_seats, v_capacity);
v_business := COALESCE(p_business_seats, 0);
v_first := COALESCE(p_first_class_seats, 0);
v_slots_used := v_economy + (v_business * 2) + (v_first * 3);
IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash; RETURN;
END IF;
IF v_cash < v_lease_deposit THEN
RETURN QUERY SELECT FALSE, ('Insufficient funds for lease down payment of ' || v_model_name || '. Required: $' || ROUND(v_lease_deposit, 2))::VARCHAR, v_cash; RETURN;
END IF;
LOOP v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
EXIT WHEN NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_tail);
END LOOP;
PERFORM debit_bank_account(p_user_id, v_lease_deposit, 'investing', 'aircraft_lease_deposit',
'Leased aircraft ' || v_model_name || ' deposit [' || v_tail || ']', v_game_time);
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'lease', 100.00, 'active', v_tail, v_economy, v_business, v_first);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, ('Successfully leased ' || v_model_name || ' [' || v_tail || ']')::VARCHAR, v_cash;
END;
$function$;

CREATE OR REPLACE FUNCTION public.normalize_username(p_username text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
SELECT NULLIF(
trim(both '-' from regexp_replace(
lower(trim(COALESCE(p_username, ''))),
'[^a-z0-9._-]+', '-', 'g'
)),
''
);
$function$;

CREATE OR REPLACE FUNCTION public.process_aircraft_financing_payments(p_user_id uuid, p_game_date timestamp with time zone)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_loan RECORD;
v_cash NUMERIC;
v_payment NUMERIC;
v_late_fee NUMERIC;
BEGIN
v_cash := get_user_balance(p_user_id);
FOR v_loan IN
SELECT * FROM loans
WHERE user_id = p_user_id AND loan_type = 'aircraft_financing' AND status = 'active'
LOOP
v_payment := v_loan.monthly_payment;
IF v_cash >= v_payment THEN
PERFORM debit_bank_account(p_user_id, v_payment, 'financing', 'financing_payment',
'Aircraft financing payment', p_game_date);
v_cash := v_cash - v_payment;
UPDATE loans SET remaining_balance = remaining_balance - v_payment WHERE id = v_loan.id;
IF (SELECT remaining_balance FROM loans WHERE id = v_loan.id) <= 0 THEN
UPDATE loans SET status = 'paid_off', remaining_balance = 0 WHERE id = v_loan.id;
END IF;
ELSE
v_late_fee := v_payment * 0.05;
UPDATE loans SET remaining_balance = remaining_balance + v_late_fee,
missed_payments = missed_payments + 1 WHERE id = v_loan.id;
INSERT INTO bank_transactions (account_id, user_id, transaction_type, amount, balance_after,
description, game_date, ifrs_category, ifrs_subcategory)
SELECT ba.id, p_user_id, 'late_fee', v_late_fee, ba.balance,
'Aircraft financing late fee', p_game_date, 'financing', 'financing_late_fee'
FROM bank_accounts ba WHERE ba.user_id = p_user_id AND ba.account_type = 'operating' LIMIT 1;
IF (SELECT missed_payments FROM loans WHERE id = v_loan.id) >= 3 THEN
UPDATE loans SET status = 'repossessed' WHERE id = v_loan.id;
IF v_loan.collateral_aircraft_id IS NOT NULL THEN
UPDATE fleet_aircraft SET status = 'grounded' WHERE id = v_loan.collateral_aircraft_id;
END IF;
END IF;
END IF;
END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_all_bots_simulation_to_time(
    p_target_game_time timestamp with time zone,
    p_season_id        uuid DEFAULT NULL::uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    r_bot                          RECORD;
    v_game_sec                     DOUBLE PRECISION;
    v_game_days                    DOUBLE PRECISION;
    v_route                        RECORD;
    v_flights                      DOUBLE PRECISION;
    v_revenue                      NUMERIC(20,2) := 0;
    v_fuel_cost                    NUMERIC(20,2) := 0;
    v_maint_cost                   NUMERIC(20,2) := 0;
    v_crew_cost                    NUMERIC(20,2) := 0;
    v_total_cost                   NUMERIC(20,2) := 0;
    v_net                          NUMERIC(20,2) := 0;
    v_passengers                   INT;
    v_flight_duration              DOUBLE PRECISION;
    v_turnaround_hours             NUMERIC;
    v_lease_cost                   NUMERIC(20,2) := 0;
    v_fuel_price                   NUMERIC;
    v_fuel_price_multiplier        NUMERIC;
    v_crew_cost_per_hour           NUMERIC;
    v_absolute_minimum_safety_limit NUMERIC(5,2);
    v_effective_grounding_threshold NUMERIC(5,2);
    v_max_weekly_flights           INT;
    v_wear_per_cycle               NUMERIC(8,4);
    v_gross_damage                 NUMERIC(20,4);
    v_self_healing_credit          NUMERIC(20,4);
    v_net_damage                   NUMERIC(20,4);
    v_cargo_rev                    NUMERIC(20,2);
    v_processed                    INT := 0;
    v_demand_multiplier            NUMERIC;
    v_seasonal_multiplier          NUMERIC;
    v_owned_wear                   NUMERIC;
    v_leased_wear                  NUMERIC;
    v_auto_repair_rate             NUMERIC;
BEGIN
    v_fuel_price       := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_absolute_minimum_safety_limit := COALESCE(get_config_numeric('absolute_minimum_safety_limit'), 30.00);
    v_crew_cost_per_hour := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear       := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear      := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
    v_fuel_price_multiplier := 1.0;
    v_seasonal_multiplier  := 1.0;

    FOR r_bot IN
        SELECT * FROM users
         WHERE actor_type = 'AI'
           AND COALESCE(operational_status, 'Active') != 'Bankrupt'
    LOOP
        v_effective_grounding_threshold := GREATEST(
            COALESCE(r_bot.auto_grounding_threshold, 40.00),
            v_absolute_minimum_safety_limit
        );

        v_game_sec  := EXTRACT(EPOCH FROM (p_target_game_time - r_bot.game_current_time));
        v_game_days := v_game_sec / 86400.0;
        IF v_game_days <= 0 THEN CONTINUE; END IF;

        FOR v_route IN
            SELECT ra.*, am.fuel_burn_per_km, am.speed_kmh, am.capacity,
                   am.turnaround_hours, am.maintenance_cost_per_hour,
                   am.lease_price_per_month, fa.acquisition_type,
                   a1.demand_index AS origin_demand,
                   a2.demand_index AS dest_demand
              FROM route_assignments ra
              JOIN fleet_aircraft fa ON fa.id = ra.assigned_aircraft_id
              JOIN aircraft_models am ON am.id = fa.aircraft_model_id
              JOIN airports a1 ON a1.iata = ra.origin_iata
              JOIN airports a2 ON a2.iata = ra.destination_iata
             WHERE ra.user_id = r_bot.id AND ra.status = 'active'
               AND fa.status = 'active'
               AND fa.condition >= v_effective_grounding_threshold
        LOOP
            v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
            v_flight_duration := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0))
                               + v_turnaround_hours;
            IF v_flight_duration <= 0 THEN CONTINUE; END IF;

            v_max_weekly_flights := FLOOR(168.0 / v_flight_duration)::INT;
            v_flights := LEAST(v_route.flights_per_week, v_max_weekly_flights);

            v_demand_multiplier := calculate_route_demand_multiplier(
                v_route.distance_km, v_route.ticket_price);
            v_passengers := LEAST(v_route.capacity,
                FLOOR(v_route.capacity * 0.95 * v_demand_multiplier * v_seasonal_multiplier));

            v_revenue   := v_flights * v_route.ticket_price * v_passengers;
            v_fuel_cost := v_flights * v_route.distance_km
                         * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
            v_crew_cost := v_flights * v_flight_duration * v_crew_cost_per_hour;
            v_maint_cost := v_flights * v_route.distance_km
                          * v_route.maintenance_cost_per_hour
                          / NULLIF(v_route.speed_kmh, 0);
            v_cargo_rev := v_revenue * 0.05;
            v_lease_cost := CASE
                WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                              WHERE fa2.id = v_route.assigned_aircraft_id
                                AND fa2.acquisition_type = 'lease')
                THEN COALESCE(v_route.lease_price_per_month, 0) / 4.0
                ELSE 0
            END;

            PERFORM credit_bank_account(r_bot.id, v_revenue + v_cargo_rev,
                'revenue', 'ticket_revenue',
                'Bot route ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
            PERFORM debit_bank_account(r_bot.id, v_fuel_cost,
                'cogs', 'fuel',
                'Bot fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
            PERFORM debit_bank_account(r_bot.id, v_crew_cost,
                'cogs', 'crew',
                'Bot crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
            PERFORM debit_bank_account(r_bot.id, v_maint_cost,
                'cogs', 'maintenance',
                'Bot maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
            IF v_lease_cost > 0 THEN
                PERFORM debit_bank_account(r_bot.id, v_lease_cost,
                    'opex', 'aircraft_lease',
                    'Bot lease: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                    p_target_game_time);
            END IF;

            v_wear_per_cycle := CASE
                WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
                ELSE v_owned_wear
            END + (v_route.distance_km * 0.0001);
            v_gross_damage := v_wear_per_cycle * v_flights * v_game_days / 7.0;

            -- FIX: Use auto_repair_rate directly as the recovery fraction.
            v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
            v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

            UPDATE fleet_aircraft
               SET condition = GREATEST(0, condition - v_net_damage)
             WHERE id = v_route.assigned_aircraft_id;
        END LOOP;

        -- Check achievements at day boundary
        IF date_trunc('day', r_bot.game_current_time)::DATE <>
           date_trunc('day', p_target_game_time)::DATE THEN
            PERFORM check_achievements(r_bot.id, p_target_game_time);
        END IF;

        UPDATE users
           SET game_current_time = p_target_game_time,
               last_active_at = NOW()
         WHERE id = r_bot.id;

        IF v_game_days >= 1.0 THEN
            PERFORM process_loan_payments(r_bot.id, p_target_game_time);
            PERFORM process_aircraft_financing_payments(r_bot.id, p_target_game_time);
            PERFORM process_credit_at_day_boundary(r_bot.id, p_target_game_time);

            IF get_user_balance(r_bot.id) < 0 THEN
                UPDATE users
                   SET consecutive_negative_days = consecutive_negative_days + 1
                 WHERE id = r_bot.id;
            ELSE
                UPDATE users
                   SET consecutive_negative_days = 0
                 WHERE id = r_bot.id;
            END IF;

            IF (SELECT consecutive_negative_days FROM users WHERE id = r_bot.id) >= 30 THEN
                UPDATE users SET operational_status = 'Bankrupt' WHERE id = r_bot.id;
                UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = r_bot.id;
            END IF;
        END IF;

        v_processed := v_processed + 1;
    END LOOP;

    RETURN v_processed;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_bot_loan_payments(p_bot_id uuid, p_game_date timestamp with time zone)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
PERFORM process_loan_payments(p_bot_id, p_game_date);
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_credit_at_day_boundary(p_user_id uuid, p_game_date timestamp with time zone)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
PERFORM update_credit_score(p_user_id, p_game_date);
INSERT INTO credit_score_history (
user_id, game_date, score, tier,
fleet_health_score, revenue_stability_score,
debt_ratio_score, cash_reserves_score, profit_history_score
)
SELECT
p_user_id,
p_game_date,
cs.score,
cs.tier,
cs.fleet_health_score,
cs.revenue_stability_score,
cs.debt_ratio_score,
cs.cash_reserves_score,
cs.profit_history_score
FROM credit_scores cs
WHERE cs.user_id = p_user_id
ON CONFLICT (user_id, game_date) DO NOTHING;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_loan_payments(
    p_user_id  uuid,
    p_game_date timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_actor_type       VARCHAR(10);
    r_loan             RECORD;
    v_cash             NUMERIC;
    v_payment          NUMERIC;
    v_late_fee         NUMERIC;
    v_effective_weekly NUMERIC;
BEGIN
    SELECT actor_type INTO v_actor_type FROM users WHERE id = p_user_id;
    IF NOT FOUND THEN RETURN; END IF;

    v_cash := get_user_balance(p_user_id);

    FOR r_loan IN
        SELECT * FROM loans
         WHERE user_id = p_user_id
           AND status = 'active'
           AND loan_type != 'aircraft_financing'
         ORDER BY taken_at ASC
    LOOP
        IF COALESCE(r_loan.weekly_payment, 0) > 0 THEN
            v_effective_weekly := r_loan.weekly_payment;
        ELSIF COALESCE(r_loan.monthly_payment, 0) > 0 THEN
            v_effective_weekly := r_loan.monthly_payment / 4.33;
        ELSE
            CONTINUE;
        END IF;

        IF v_actor_type = 'AI' THEN
            IF v_cash >= v_effective_weekly THEN
                PERFORM debit_bank_account(p_user_id, v_effective_weekly,
                    'financing', 'loan_payment',
                    'Weekly loan payment', p_game_date);
                v_cash := v_cash - v_effective_weekly;
                UPDATE loans
                   SET remaining_balance = remaining_balance - v_effective_weekly
                 WHERE id = r_loan.id;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', remaining_balance = 0
                     WHERE id = r_loan.id;
                END IF;
            ELSE
                -- FIX 7: Align bot late fee to human formula.
                -- Late fee = 10% of the weekly payment (not 10% of total balance).
                v_late_fee := v_effective_weekly * 0.10;
                UPDATE loans
                   SET remaining_balance = remaining_balance + v_late_fee,
                       missed_payments = missed_payments + 1
                 WHERE id = r_loan.id;
                -- Record the late fee in the ledger for transparency
                INSERT INTO bank_transactions (
                    account_id, user_id, transaction_type, amount, balance_after,
                    description, game_date, ifrs_category, ifrs_subcategory
                )
                SELECT ba.id, p_user_id, 'late_fee', v_late_fee, ba.balance,
                       'Loan payment late fee', p_game_date, 'financing', 'loan_late_fee'
                  FROM bank_accounts ba
                 WHERE ba.user_id = p_user_id AND ba.account_type = 'operating'
                 LIMIT 1;
                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
                END IF;
            END IF;
        ELSE
            v_payment := v_effective_weekly;
            IF v_cash >= v_payment THEN
                PERFORM debit_bank_account(p_user_id, v_payment,
                    'financing', 'loan_payment',
                    'Weekly loan payment', p_game_date);
                v_cash := v_cash - v_payment;
                UPDATE loans
                   SET remaining_balance = remaining_balance - v_payment
                 WHERE id = r_loan.id;
                IF (SELECT remaining_balance FROM loans WHERE id = r_loan.id) <= 0 THEN
                    UPDATE loans SET status = 'paid_off', remaining_balance = 0
                     WHERE id = r_loan.id;
                END IF;
            ELSE
                v_late_fee := v_payment * 0.10;
                UPDATE loans
                   SET remaining_balance = remaining_balance + v_late_fee,
                       missed_payments = missed_payments + 1
                 WHERE id = r_loan.id;
                INSERT INTO bank_transactions (
                    account_id, user_id, transaction_type, amount, balance_after,
                    description, game_date, ifrs_category, ifrs_subcategory
                )
                SELECT ba.id, p_user_id, 'late_fee', v_late_fee, ba.balance,
                       'Loan payment late fee', p_game_date, 'financing', 'loan_late_fee'
                  FROM bank_accounts ba
                 WHERE ba.user_id = p_user_id AND ba.account_type = 'operating'
                 LIMIT 1;
                IF (SELECT missed_payments FROM loans WHERE id = r_loan.id) >= 4 THEN
                    UPDATE loans SET status = 'defaulted' WHERE id = r_loan.id;
                    IF r_loan.collateral_aircraft_id IS NOT NULL THEN
                        UPDATE fleet_aircraft
                           SET status = 'grounded'
                         WHERE id = r_loan.collateral_aircraft_id;
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_player_simulation_to_time(
    p_user_id        uuid,
    p_target_game_time timestamp with time zone
)
RETURNS TABLE(
    game_time    timestamp with time zone,
    cash         numeric,
    flights_run  integer,
    elapsed_days numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    r_user                RECORD;
    v_route               RECORD;
    v_flight_hours        NUMERIC;
    v_revenue             NUMERIC;
    v_ops_cost            NUMERIC;
    v_lease_cost          NUMERIC;
    v_net                 NUMERIC := 0;
    v_flights_run         INT := 0;
    v_cash_after          NUMERIC;
    v_elapsed_days        NUMERIC;
    v_wear_per_cycle      NUMERIC(8,4);
    v_gross_damage        NUMERIC(20,4);
    v_self_healing_credit NUMERIC(20,4);
    v_net_damage          NUMERIC(20,4);
    v_cargo_rev           NUMERIC(20,2);
    v_turnaround_hours    NUMERIC;
    v_demand_multiplier   NUMERIC;
    v_crew_cost           NUMERIC;
    v_fuel_price          NUMERIC;
    v_seasonal_factor     NUMERIC;
    v_fuel_price_multiplier   NUMERIC := 1.0;
    v_maintenance_multiplier  NUMERIC := 1.0;
    v_route_demand_event      NUMERIC;
    v_route_capacity_event    NUMERIC;
    v_effective_capacity      NUMERIC;
    v_time_fraction           NUMERIC;
    v_payment_periods         INT;
    v_i                       INT;
    v_fuel_cost               NUMERIC;
    v_crew_cost_total         NUMERIC;
    v_maint_cost              NUMERIC;
    v_owned_wear              NUMERIC;
    v_leased_wear             NUMERIC;
    v_auto_repair_rate        NUMERIC;
    v_bankruptcy_threshold    NUMERIC;
BEGIN
    SELECT * INTO r_user FROM users WHERE id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;

    v_fuel_price        := COALESCE(get_config_numeric('fuel_price_per_liter'), 0.85);
    v_crew_cost         := COALESCE(get_config_numeric('crew_cost_per_hour'), 350.0);
    v_owned_wear        := COALESCE(get_config_numeric('owned_wear_per_flight_cycle'), 0.50);
    v_leased_wear       := COALESCE(get_config_numeric('leased_wear_per_flight_cycle'), 0.70);
    v_auto_repair_rate  := COALESCE(get_config_numeric('maintenance_auto_repair_rate'), 0.85);
    v_bankruptcy_threshold := COALESCE(get_config_numeric('bankruptcy_cash_threshold'), -5000000.0);

    SELECT COALESCE(effect_value, 1.0) INTO v_fuel_price_multiplier
      FROM game_events
     WHERE event_type = 'fuel_shock' AND is_active = true
       AND effect_type = 'fuel_price'
       AND start_game_time <= p_target_game_time
       AND end_game_time > p_target_game_time
     ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_fuel_price_multiplier := 1.0; END IF;

    SELECT COALESCE(effect_value, 1.0) INTO v_maintenance_multiplier
      FROM game_events
     WHERE event_type = 'maintenance_shock' AND is_active = true
       AND effect_type = 'maintenance_cost'
       AND start_game_time <= p_target_game_time
       AND end_game_time > p_target_game_time
     ORDER BY start_game_time DESC LIMIT 1;
    IF NOT FOUND THEN v_maintenance_multiplier := 1.0; END IF;

    v_elapsed_days := EXTRACT(EPOCH FROM (p_target_game_time - r_user.game_current_time)) / 86400.0;
    v_time_fraction := LEAST(v_elapsed_days / 7.0, 1.0);

    FOR v_route IN
        SELECT ur.*, am.fuel_burn_per_km, am.speed_kmh, am.turnaround_hours,
               am.capacity, am.lease_price_per_month, am.maintenance_cost_per_hour,
               fa.acquisition_type,
               a1.demand_index AS origin_demand, a2.demand_index AS dest_demand
          FROM route_assignments ur
          JOIN fleet_aircraft fa ON fa.id = ur.assigned_aircraft_id
          JOIN aircraft_models am ON am.id = fa.aircraft_model_id
          JOIN airports a1 ON a1.iata = ur.origin_iata
          JOIN airports a2 ON a2.iata = ur.destination_iata
         WHERE ur.user_id = p_user_id AND ur.status = 'active'
           AND fa.status = 'active'
           AND fa.condition >= COALESCE(r_user.auto_grounding_threshold, 40.00)
    LOOP
        v_route_demand_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_demand_event
          FROM game_events
         WHERE event_type = 'demand_surge' AND is_active = true
           AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
           AND start_game_time <= p_target_game_time
           AND end_game_time > p_target_game_time
         ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_demand_event := 1.0; END IF;

        v_route_capacity_event := 1.0;
        SELECT COALESCE(effect_value, 1.0) INTO v_route_capacity_event
          FROM game_events
         WHERE event_type = 'weather_disruption' AND is_active = true
           AND effect_target IN (v_route.origin_iata, v_route.destination_iata)
           AND start_game_time <= p_target_game_time
           AND end_game_time > p_target_game_time
         ORDER BY start_game_time DESC LIMIT 1;
        IF NOT FOUND THEN v_route_capacity_event := 1.0; END IF;

        v_turnaround_hours := COALESCE(v_route.turnaround_hours, 1.0);
        v_flight_hours := (v_route.distance_km / NULLIF(v_route.speed_kmh, 0)) + v_turnaround_hours;
        IF v_flight_hours <= 0 THEN CONTINUE; END IF;

        v_demand_multiplier := calculate_route_demand_multiplier(v_route.distance_km, v_route.ticket_price)
                             * v_route_demand_event;
        v_seasonal_factor := 1.0;
        v_effective_capacity := FLOOR(v_route.capacity * v_route_capacity_event);
        v_revenue := v_route.flights_per_week * v_route.ticket_price
                   * LEAST(v_effective_capacity,
                           FLOOR(v_effective_capacity * 0.95 * v_demand_multiplier * v_seasonal_factor));
        v_fuel_cost := v_route.flights_per_week * v_route.distance_km
                     * v_route.fuel_burn_per_km * v_fuel_price * v_fuel_price_multiplier;
        v_crew_cost_total := v_route.flights_per_week * v_flight_hours * v_crew_cost;
        v_maint_cost := v_route.flights_per_week * v_route.distance_km
                      * COALESCE(v_route.maintenance_cost_per_hour, 0)
                      * COALESCE(v_maintenance_multiplier, 1.0)
                      / NULLIF(v_route.speed_kmh, 0);
        v_ops_cost := v_fuel_cost + v_crew_cost_total + v_maint_cost;
        v_lease_cost := CASE
            WHEN EXISTS (SELECT 1 FROM fleet_aircraft fa2
                          WHERE fa2.id = v_route.assigned_aircraft_id
                            AND fa2.acquisition_type = 'lease')
            THEN COALESCE(v_route.lease_price_per_month, 0) * (v_elapsed_days / 30.0)
            ELSE 0
        END;

        v_revenue  := v_revenue * v_time_fraction;
        v_ops_cost := v_ops_cost * v_time_fraction;
        v_cargo_rev := v_revenue * 0.05;

        PERFORM credit_bank_account(p_user_id, v_revenue + v_cargo_rev,
            'revenue', 'ticket_revenue',
            'Route ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        PERFORM debit_bank_account(p_user_id, v_fuel_cost * v_time_fraction,
            'cogs', 'fuel',
            'Fuel: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        PERFORM debit_bank_account(p_user_id, v_crew_cost_total * v_time_fraction,
            'cogs', 'crew',
            'Crew: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        PERFORM debit_bank_account(p_user_id, v_maint_cost * v_time_fraction,
            'cogs', 'maintenance',
            'Maintenance: ' || v_route.origin_iata || '-' || v_route.destination_iata,
            p_target_game_time);
        IF v_lease_cost > 0 THEN
            PERFORM debit_bank_account(p_user_id, v_lease_cost,
                'opex', 'aircraft_lease',
                'Lease: ' || v_route.origin_iata || '-' || v_route.destination_iata,
                p_target_game_time);
        END IF;

        -- Wear formula
        v_wear_per_cycle := CASE
            WHEN v_route.acquisition_type = 'lease' THEN v_leased_wear
            ELSE v_owned_wear
        END + (v_route.distance_km * 0.0001);
        v_gross_damage := v_wear_per_cycle * v_route.flights_per_week
                        * v_elapsed_days / 7.0;

        -- FIX: Use auto_repair_rate directly as the recovery fraction.
        -- v_auto_repair_rate = 0.85 means 85% of gross damage is self-healed.
        v_self_healing_credit := v_gross_damage * v_auto_repair_rate;
        v_net_damage := GREATEST(0, v_gross_damage - v_self_healing_credit);

        UPDATE fleet_aircraft
           SET condition = GREATEST(0, condition - v_net_damage)
         WHERE id = v_route.assigned_aircraft_id;

        v_flights_run := v_flights_run
                       + (v_route.flights_per_week * v_elapsed_days / 7.0)::INT;
    END LOOP;

    v_cash_after := get_user_balance(p_user_id);

    UPDATE users u
       SET game_current_time = p_target_game_time,
           last_active_at = NOW()
     WHERE u.id = p_user_id;

    -- Bankruptcy check
    IF v_cash_after < v_bankruptcy_threshold THEN
        UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
        UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
    END IF;

    IF v_elapsed_days >= 1.0 THEN
        v_payment_periods := GREATEST(1, FLOOR(v_elapsed_days / 7.0)::INT);
        FOR v_i IN 1..v_payment_periods LOOP
            PERFORM process_loan_payments(p_user_id, p_target_game_time);
            PERFORM process_aircraft_financing_payments(p_user_id, p_target_game_time);
        END LOOP;
        PERFORM process_credit_at_day_boundary(p_user_id, p_target_game_time);
        PERFORM check_achievements(p_user_id, p_target_game_time);

        v_cash_after := get_user_balance(p_user_id);
        IF v_cash_after < 0 THEN
            UPDATE users
               SET consecutive_negative_days = consecutive_negative_days + 1
             WHERE id = p_user_id;
            IF (SELECT consecutive_negative_days FROM users WHERE id = p_user_id) >= 30 THEN
                UPDATE users SET operational_status = 'Bankrupt' WHERE id = p_user_id;
                UPDATE fleet_aircraft SET status = 'grounded' WHERE user_id = p_user_id;
            END IF;
        ELSE
            UPDATE users
               SET consecutive_negative_days = 0,
                   recovery_streak_days = recovery_streak_days + 1
             WHERE id = p_user_id;
        END IF;
    END IF;

    v_cash_after := get_user_balance(p_user_id);
    game_time    := p_target_game_time;
    cash         := v_cash_after;
    flights_run  := v_flights_run;
    elapsed_days := v_elapsed_days;
    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_simulation_delta()
RETURNS TABLE(cash_before numeric, cash_after numeric, elapsed_real_sec double precision, elapsed_game_days double precision, flights_run integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_catalog'
AS $function$
DECLARE
v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY
SELECT *
FROM process_simulation_delta(v_user_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_simulation_delta(p_user_id uuid)
RETURNS TABLE(cash_before numeric, cash_after numeric, elapsed_real_sec double precision, elapsed_game_days double precision, flights_run integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
v_season_time TIMESTAMPTZ;
v_result RECORD;
BEGIN
SELECT current_game_time INTO v_season_time
FROM season_clock WHERE status = 'active' LIMIT 1;
IF v_season_time IS NULL THEN
RAISE EXCEPTION 'No active season found';
END IF;
SELECT * INTO v_result
FROM process_player_simulation_to_time(p_user_id, v_season_time);
cash_before := 0;
cash_after := v_result.cash;
elapsed_real_sec := 0;
elapsed_game_days := v_result.elapsed_days;
flights_run := v_result.flights_run;
RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_world_tick(p_season_id uuid DEFAULT NULL::uuid, p_max_ticks integer DEFAULT 10)
RETURNS TABLE(season_id uuid, ticks_processed integer, game_time_after timestamp with time zone, players_processed integer, bots_processed integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
r_season RECORD;
v_game_time_before TIMESTAMPTZ;
v_game_time_after TIMESTAMPTZ;
v_ticks_processed INT := 0;
v_players_processed INT := 0;
v_bots_processed INT := 0;
r_user RECORD;
r_player_result RECORD;
v_lock_key BIGINT;
v_error_msg TEXT;
v_start_time TIMESTAMPTZ;
BEGIN
v_start_time := NOW();
IF p_season_id IS NOT NULL THEN
SELECT * INTO r_season FROM season_clock WHERE id = p_season_id;
ELSE
SELECT * INTO r_season FROM season_clock WHERE status = 'active' LIMIT 1;
END IF;
IF NOT FOUND THEN RAISE EXCEPTION 'No active season found'; END IF;
v_lock_key := hashtext(r_season.id::text);
IF NOT pg_try_advisory_xact_lock(v_lock_key) THEN
RAISE EXCEPTION 'World tick already in progress for season %', r_season.id;
END IF;
v_game_time_before := r_season.current_game_time;
v_game_time_after := r_season.current_game_time
+ (r_season.tick_interval_seconds * r_season.time_scale_multiplier * INTERVAL '1 second');
PERFORM generate_game_events(v_game_time_after);
PERFORM deactivate_expired_events(v_game_time_after);
FOR r_user IN
SELECT u.id, u.game_current_time
FROM users u
WHERE u.season_id = r_season.id
AND u.actor_type = 'REAL'
AND COALESCE(u.operational_status, 'Active') != 'Bankrupt'
LOOP
BEGIN
SELECT * INTO r_player_result
FROM process_player_simulation_to_time(r_user.id, v_game_time_after) LIMIT 1;
IF COALESCE(r_player_result.elapsed_days, 0.0) > 0.0 THEN
v_players_processed := v_players_processed + 1;
END IF;
EXCEPTION WHEN OTHERS THEN
GET STACKED DIAGNOSTICS v_error_msg = MESSAGE_TEXT;
INSERT INTO world_tick_log (season_id, status, message, started_at, finished_at)
VALUES (r_season.id, 'player_error',
'Player ' || r_user.id || ': ' || v_error_msg, NOW(), NOW());
END;
END LOOP;
v_bots_processed := process_all_bots_simulation_to_time(v_game_time_after, r_season.id);
IF date_trunc('day', r_season.current_game_time)::DATE <>
date_trunc('day', v_game_time_after)::DATE THEN
PERFORM execute_bot_decisions();
END IF;
UPDATE season_clock
SET current_game_time = v_game_time_after, last_tick_at = NOW(), updated_at = NOW()
WHERE id = r_season.id;
v_ticks_processed := 1;
-- Restore success logging with all columns populated
INSERT INTO world_tick_log (
season_id, started_at, finished_at,
game_time_before, game_time_after,
ticks_processed, players_processed, bots_processed,
status, message
) VALUES (
r_season.id, v_start_time, NOW(),
v_game_time_before, v_game_time_after,
1, v_players_processed, v_bots_processed,
'success', 'Tick completed successfully'
);
season_id := r_season.id;
ticks_processed := v_ticks_processed;
game_time_after := v_game_time_after;
players_processed := v_players_processed;
bots_processed := v_bots_processed;
RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.purchase_aircraft(p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM purchase_aircraft(v_user_id, p_model_id, p_nickname, p_economy_seats, p_business_seats, p_first_class_seats);
END;
$function$;

CREATE OR REPLACE FUNCTION public.purchase_aircraft(p_user_id uuid, p_model_id uuid, p_nickname character varying, p_economy_seats integer DEFAULT NULL::integer, p_business_seats integer DEFAULT 0, p_first_class_seats integer DEFAULT 0)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_cash NUMERIC; v_price NUMERIC; v_model_name VARCHAR; v_capacity INT;
v_hq_iata VARCHAR(3); v_tail VARCHAR(20); v_economy INT; v_business INT; v_first INT; v_slots_used INT;
v_game_time TIMESTAMPTZ;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
v_cash := get_user_balance(p_user_id);
SELECT hq_airport_iata, game_current_time INTO v_hq_iata, v_game_time
FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, 0.00::NUMERIC; RETURN; END IF;
SELECT purchase_price, model_name, capacity INTO v_price, v_model_name, v_capacity
FROM aircraft_models WHERE id = p_model_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft model not found.'::VARCHAR, v_cash; RETURN; END IF;
v_economy := COALESCE(p_economy_seats, v_capacity);
v_business := COALESCE(p_business_seats, 0);
v_first := COALESCE(p_first_class_seats, 0);
v_slots_used := v_economy + (v_business * 2) + (v_first * 3);
IF v_economy < 0 OR v_business < 0 OR v_first < 0 OR v_slots_used <= 0 OR v_slots_used > v_capacity THEN
RETURN QUERY SELECT FALSE, 'Invalid seat configuration for aircraft capacity.'::VARCHAR, v_cash; RETURN;
END IF;
IF v_cash < v_price THEN
RETURN QUERY SELECT FALSE, ('Insufficient funds to purchase ' || v_model_name || '.')::VARCHAR, v_cash; RETURN;
END IF;
LOOP v_tail := generate_tail_number(COALESCE(v_hq_iata, 'CGK'));
EXIT WHEN NOT EXISTS (SELECT 1 FROM fleet_aircraft WHERE tail_number = v_tail);
END LOOP;
PERFORM debit_bank_account(p_user_id, v_price, 'investing', 'aircraft_purchase',
'Purchased aircraft ' || v_model_name || ' [' || v_tail || ']', v_game_time);
INSERT INTO fleet_aircraft (user_id, aircraft_model_id, nickname, acquisition_type, condition, status, tail_number, economy_seats, business_seats, first_class_seats)
VALUES (p_user_id, p_model_id, TRIM(p_nickname), 'purchase', 100.00, 'active', v_tail, v_economy, v_business, v_first);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, ('Successfully purchased ' || v_model_name || ' [' || v_tail || ']')::VARCHAR, v_cash;
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.repair_aircraft(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM repair_aircraft(v_user_id, p_fleet_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.repair_aircraft(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_cash NUMERIC; v_condition NUMERIC; v_purchase_price NUMERIC; v_lease_price NUMERIC;
v_model_name VARCHAR; v_repair_cost NUMERIC; v_acquisition_type VARCHAR; v_game_time TIMESTAMPTZ;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
SELECT f.condition, f.acquisition_type, m.purchase_price, m.lease_price_per_month, m.model_name
INTO v_condition, v_acquisition_type, v_purchase_price, v_lease_price, v_model_name
FROM fleet_aircraft f
JOIN aircraft_models m ON f.aircraft_model_id = m.id
WHERE f.id = p_fleet_id AND f.user_id = p_user_id;
v_cash := get_user_balance(p_user_id);
SELECT game_current_time INTO v_game_time FROM users WHERE id = p_user_id FOR UPDATE;
IF v_model_name IS NULL THEN
RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, v_cash; RETURN;
END IF;
IF v_condition >= 100.00 THEN
RETURN QUERY SELECT FALSE, ('Aircraft ' || v_model_name || ' is already in pristine condition.')::VARCHAR, v_cash; RETURN;
END IF;
v_repair_cost := CASE
WHEN v_acquisition_type = 'lease' THEN (100.00 - v_condition) * (COALESCE(v_lease_price, 0.00) * 0.50)
ELSE (100.00 - v_condition) * (COALESCE(v_purchase_price, 0.00) * 0.0005)
END;
IF v_cash < v_repair_cost THEN
RETURN QUERY SELECT FALSE, ('Insufficient funds for repair. Required: $' || ROUND(v_repair_cost, 2))::VARCHAR, v_cash; RETURN;
END IF;
PERFORM debit_bank_account(p_user_id, v_repair_cost, 'cogs', 'maintenance',
'Maintenance completed for ' || v_model_name || ' - restored from ' || ROUND(v_condition::numeric, 2) || '% to 100%',
v_game_time);
UPDATE fleet_aircraft SET condition = 100.00, status = 'active' WHERE id = p_fleet_id;
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, 'Aircraft maintenance complete. Health restored to 100%!'::VARCHAR, v_cash;
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

CREATE OR REPLACE FUNCTION public.require_current_user_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_catalog'
AS $function$
DECLARE
v_user_id UUID;
BEGIN
v_user_id := public.get_current_user_id();
IF v_user_id IS NULL THEN
RAISE EXCEPTION 'Authenticated Skyward user profile not found.'
USING ERRCODE = 'P0001';
END IF;
RETURN v_user_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.reset_user_airline()
RETURNS TABLE(success boolean, message text)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM reset_user_airline(v_user_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reset_user_airline(p_user_id uuid)
RETURNS TABLE(success boolean, message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
RETURN QUERY SELECT FALSE, 'User not found'; RETURN;
END IF;
DELETE FROM bank_transactions WHERE user_id = p_user_id;
DELETE FROM bank_accounts WHERE user_id = p_user_id;
DELETE FROM loans WHERE user_id = p_user_id;
DELETE FROM credit_scores WHERE user_id = p_user_id;
DELETE FROM credit_score_history WHERE user_id = p_user_id;
DELETE FROM route_assignments WHERE user_id = p_user_id;
DELETE FROM fleet_aircraft WHERE user_id = p_user_id;
DELETE FROM achievements WHERE user_id = p_user_id;
UPDATE users SET
net_worth = 15000000.00,
game_current_time = TIMESTAMP WITH TIME ZONE '2020-01-01 00:00:00+00',
hq_airport_iata = 'SIN',
auto_grounding_threshold = 40.00,
operational_status = 'Active',
consecutive_negative_days = 0,
recovery_streak_days = 0,
last_active_at = NOW(),
onboarding_completed = false
WHERE id = p_user_id;
INSERT INTO bank_accounts (user_id, account_type, balance)
VALUES (p_user_id, 'operating', 15000000.00);
RETURN QUERY SELECT TRUE, 'Airline reset successfully';
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_active_season_id(p_season_id uuid DEFAULT NULL::uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
v_season_id UUID;
BEGIN
IF p_season_id IS NOT NULL THEN
RETURN p_season_id;
END IF;
SELECT id
INTO v_season_id
FROM season_clock
WHERE status = 'active'
ORDER BY created_at ASC
LIMIT 1;
RETURN v_season_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_credit_tier(p_score integer)
RETURNS character varying
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
    v_config     JSONB;
    v_tier_name  TEXT;
    v_tier_data  JSONB;
    v_best_tier  TEXT := 'Subprime';
    v_best_min   INT  := 0;
BEGIN
    SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';

    -- If no config found, use hardcoded defaults
    IF v_config IS NULL THEN
        RETURN CASE
            WHEN p_score >= 900 THEN 'Platinum'
            WHEN p_score >= 750 THEN 'Gold'
            WHEN p_score >= 600 THEN 'Silver'
            WHEN p_score >= 400 THEN 'Standard'
            ELSE 'Subprime'
        END;
    END IF;

    -- Iterate tier definitions at root level of the config JSONB.
    -- Seed data shape: {"Platinum":{"min":800,"max":1000,"rate":0.03}, ...}
    FOR v_tier_name, v_tier_data IN SELECT key, value FROM jsonb_each(v_config)
    LOOP
        -- Skip non-object entries (safety)
        IF jsonb_typeof(v_tier_data) != 'object' THEN
            CONTINUE;
        END IF;

        -- Use 'min' key (matches seed data); fall back to 'min_score' for
        -- backwards-compatibility with any future config changes.
        IF p_score >= COALESCE((v_tier_data->>'min')::INT, (v_tier_data->>'min_score')::INT, 0) THEN
            IF COALESCE((v_tier_data->>'min')::INT, (v_tier_data->>'min_score')::INT, 0) >= v_best_min THEN
                v_best_tier := v_tier_name;
                v_best_min  := COALESCE((v_tier_data->>'min')::INT, (v_tier_data->>'min_score')::INT, 0);
            END IF;
        END IF;
    END LOOP;

    RETURN v_best_tier;
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_airline_settings(p_company_name character varying, p_auto_grounding_threshold numeric, p_hq_airport_iata character varying)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM save_airline_settings(v_user_id, p_company_name, p_auto_grounding_threshold, p_hq_airport_iata);
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_airline_settings(p_user_id uuid, p_company_name character varying, p_auto_grounding_threshold numeric, p_hq_airport_iata character varying)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
IF p_auto_grounding_threshold < 30.00 OR p_auto_grounding_threshold > 100.00 THEN
RETURN QUERY SELECT FALSE, 'Safety threshold must be between 30 and 100.'::VARCHAR;
RETURN;
END IF;
IF p_hq_airport_iata IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM airports WHERE iata = p_hq_airport_iata) THEN
RETURN QUERY SELECT FALSE, 'HQ airport not found.'::VARCHAR;
RETURN;
END IF;
UPDATE users
SET company_name = TRIM(p_company_name),
auto_grounding_threshold = p_auto_grounding_threshold,
hq_airport_iata = p_hq_airport_iata
WHERE id = p_user_id;
IF NOT FOUND THEN
RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR;
RETURN;
END IF;
RETURN QUERY SELECT TRUE, 'Settings saved successfully.'::VARCHAR;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sell_aircraft(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM sell_aircraft(v_user_id, p_fleet_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.sell_aircraft(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_user RECORD; v_fleet RECORD;
v_base_value NUMERIC(20,2); v_age_years NUMERIC; v_depreciation_factor NUMERIC;
v_sale_value NUMERIC(20,2);
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
SELECT f.*, m.model_name, m.purchase_price
INTO v_fleet FROM fleet_aircraft f
JOIN aircraft_models m ON m.id = f.aircraft_model_id
WHERE f.id = p_fleet_id AND f.user_id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'purchase' THEN
RETURN QUERY SELECT FALSE, 'Only owned aircraft can be sold.'::VARCHAR, NULL::NUMERIC; RETURN;
END IF;
IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC; RETURN;
END IF;
v_base_value := v_fleet.purchase_price * (v_fleet.condition / 100.00);
IF v_fleet.acquired_game_date IS NOT NULL AND v_user.game_current_time IS NOT NULL THEN
v_age_years := EXTRACT(EPOCH FROM (v_user.game_current_time - v_fleet.acquired_game_date)) / (365.25 * 86400.0);
v_depreciation_factor := GREATEST(0.10, 1.0 - (0.05 * COALESCE(v_age_years, 0)));
v_sale_value := ROUND(v_base_value * v_depreciation_factor, 2);
ELSE
v_sale_value := v_base_value;
END IF;
PERFORM credit_bank_account(p_user_id, v_sale_value, 'investing', 'aircraft_sale',
'Sold aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
v_user.game_current_time);
DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;
new_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, ('Aircraft sold for $' || ROUND(v_sale_value, 2)::TEXT || '.')::VARCHAR, new_cash;
END;
$function$;

CREATE OR REPLACE FUNCTION public.spawn_bot()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_bot_id        UUID;
    v_archetype     VARCHAR(30);
    v_hq            VARCHAR(3);
    v_bot_count     INT;
    v_max_bots      INT;
    v_username      VARCHAR(50);
    v_ceo_name      VARCHAR(100);
    v_company_name  VARCHAR(100);
    v_game_time     TIMESTAMPTZ;
    v_attempts      INT;
    v_inserted      BOOLEAN;
BEGIN
    -- Check active bot count vs configured max
    SELECT COUNT(*) INTO v_bot_count
      FROM users
     WHERE actor_type = 'AI'
       AND COALESCE(operational_status, 'Active') != 'Bankrupt';
    v_max_bots := COALESCE(get_config_int('max_bot_count'), 5);
    IF v_bot_count >= v_max_bots THEN
        RETURN NULL;
    END IF;

    -- Pick random archetype (weighted equally)
    v_archetype := (ARRAY['Regional', 'Aggressive', 'Balanced'])[1 + floor(random() * 3)];

    -- Pick random HQ from top-demand airports
    SELECT iata INTO v_hq
      FROM airports
     ORDER BY demand_index DESC, random()
     LIMIT 1;

    -- Get current game time from active season
    SELECT current_game_time INTO v_game_time
      FROM season_clock
     WHERE status = 'active'
     LIMIT 1;
    v_game_time := COALESCE(v_game_time, '2020-01-01 00:00:00+00');

    -- Generate unique username (internal identifier, not shown to players)
    v_username := 'bot_' || left(gen_random_uuid()::text, 8);

    -- Generate human-like names
    v_ceo_name := generate_ceo_name();

    -- FIX 9: Retry loop for company_name INSERT to handle UNIQUE collisions.
    -- Generate a new company_name on each attempt.
    v_attempts := 0;
    v_inserted := false;
    WHILE v_attempts < 10 AND NOT v_inserted LOOP
        v_company_name := generate_company_name(v_archetype);
        BEGIN
            INSERT INTO users (
                username, company_name, ceo_name, actor_type,
                hq_airport_iata, game_current_time, operational_status,
                net_worth, consecutive_negative_days, recovery_streak_days,
                auto_grounding_threshold
            ) VALUES (
                v_username,
                v_company_name,
                v_ceo_name,
                'AI',
                v_hq,
                v_game_time,
                'Active',
                15000000.00,
                0,
                0,
                40.00
            ) RETURNING id INTO v_bot_id;
            v_inserted := true;
        EXCEPTION
            WHEN unique_violation THEN
                -- Company name collided; regenerate a new one and retry.
                -- Also regenerate username in case that was the collision.
                v_username := 'bot_' || left(gen_random_uuid()::text, 8);
                v_attempts := v_attempts + 1;
        END;
    END LOOP;

    IF NOT v_inserted THEN
        RAISE NOTICE 'Failed to spawn bot after % attempts (company name collisions)', v_attempts;
        RETURN NULL;
    END IF;

    -- Create bot profile with archetype
    INSERT INTO bot_profiles (user_id, archetype)
    VALUES (v_bot_id, v_archetype);

    RAISE NOTICE 'Spawned bot "%" (CEO: %, Archetype: %, HQ: %)',
        v_company_name, v_ceo_name, v_archetype, v_hq;
    RETURN v_bot_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.take_loan(p_principal numeric, p_term_weeks integer DEFAULT 52, p_loan_type character varying DEFAULT 'unsecured'::character varying, p_collateral_aircraft_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := require_current_user_id();
RETURN QUERY SELECT * FROM take_loan(v_user_id, p_principal, p_term_weeks, p_loan_type, p_collateral_aircraft_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.take_loan(p_user_id uuid, p_principal numeric, p_term_weeks integer DEFAULT 52, p_loan_type character varying DEFAULT 'unsecured'::character varying, p_collateral_aircraft_id uuid DEFAULT NULL::uuid)
RETURNS TABLE(success boolean, message text, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_actor_type VARCHAR(10); v_existing_loans INT; v_credit_score INT;
v_score_record RECORD; v_tier VARCHAR(10); v_config JSONB; v_tier_cfg JSONB;
v_min_loan NUMERIC; v_max_loans INT; v_interest_rate NUMERIC;
v_weekly_payment NUMERIC; v_total_repayable NUMERIC; v_cash NUMERIC;
v_game_time TIMESTAMPTZ; v_max_principal NUMERIC; v_loan_id UUID;
BEGIN
SELECT u.actor_type, u.game_current_time
INTO v_actor_type, v_game_time
FROM users u WHERE u.id = p_user_id;
IF NOT FOUND THEN RETURN QUERY SELECT false, 'User not found.'::TEXT, 0::NUMERIC; RETURN; END IF;
IF v_actor_type = 'AI' THEN
SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active';
IF v_existing_loans >= 3 THEN RETURN QUERY SELECT false, 'Maximum 3 active loans allowed.'::TEXT, 0::NUMERIC; RETURN; END IF;
IF p_principal < 100000 OR p_principal > 5000000 THEN RETURN QUERY SELECT false, 'Bot loan amount must be between $100K and $5M.'::TEXT, 0::NUMERIC; RETURN; END IF;
SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
IF NOT FOUND THEN v_credit_score := 500; END IF;
v_interest_rate := 0.05;
v_total_repayable := p_principal * (1 + v_interest_rate);
v_weekly_payment := v_total_repayable / p_term_weeks;
INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type)
VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', 'unsecured')
RETURNING id INTO v_loan_id;
PERFORM credit_bank_account(p_user_id, p_principal, 'financing', 'loan_disbursement',
'Loan disbursement', v_game_time);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT true, 'Loan disbursed.'::TEXT, v_cash;
RETURN;
END IF;
SELECT value INTO v_config FROM game_config WHERE key = 'credit_tier_config';
v_min_loan := COALESCE((v_config->>'min_loan')::NUMERIC, 100000);
v_max_loans := COALESCE((v_config->>'max_active_loans')::INT, 3);
SELECT COUNT(*) INTO v_existing_loans FROM loans WHERE user_id = p_user_id AND status = 'active';
IF v_existing_loans >= v_max_loans THEN
RETURN QUERY SELECT false, 'Maximum ' || v_max_loans || ' active loans allowed.'::TEXT, 0::NUMERIC; RETURN;
END IF;
SELECT score INTO v_credit_score FROM credit_scores WHERE user_id = p_user_id;
IF NOT FOUND THEN v_credit_score := 500; END IF;
SELECT * INTO v_score_record FROM calculate_credit_score(p_user_id) LIMIT 1;
IF FOUND THEN v_tier := resolve_credit_tier(v_score_record.total_score);
ELSE v_tier := resolve_credit_tier(v_credit_score); END IF;
v_tier_cfg := COALESCE(v_config->'tiers'->v_tier, '{}'::JSONB);
IF p_loan_type NOT IN ('unsecured', 'secured', 'credit_line') THEN
RETURN QUERY SELECT false, 'Invalid loan type.'::TEXT, 0::NUMERIC; RETURN;
END IF;
IF p_loan_type = 'unsecured' THEN
v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000);
v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07);
ELSIF p_loan_type = 'secured' THEN
IF p_collateral_aircraft_id IS NULL THEN
RETURN QUERY SELECT false, 'Secured loans require collateral aircraft.'::TEXT, 0::NUMERIC; RETURN;
END IF;
v_max_principal := COALESCE((v_tier_cfg->>'max_secured')::NUMERIC, 25000000);
v_interest_rate := COALESCE((v_tier_cfg->>'rate_secured')::NUMERIC, 0.06);
ELSE
v_max_principal := COALESCE((v_tier_cfg->>'max_unsecured')::NUMERIC, 5000000) * 0.5;
v_interest_rate := COALESCE((v_tier_cfg->>'rate_unsecured')::NUMERIC, 0.07) + 0.02;
END IF;
IF p_principal < v_min_loan THEN
RETURN QUERY SELECT false, 'Minimum loan amount is $' || v_min_loan::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
END IF;
IF p_principal > v_max_principal THEN
RETURN QUERY SELECT false, 'Maximum for ' || v_tier || ' tier ' || p_loan_type || ' loan is $' || v_max_principal::TEXT || '.'::TEXT, 0::NUMERIC; RETURN;
END IF;
v_total_repayable := p_principal * (1 + v_interest_rate);
v_weekly_payment := v_total_repayable / p_term_weeks;
INSERT INTO loans (user_id, principal, interest_rate, remaining_balance, weekly_payment, status, loan_type, collateral_aircraft_id)
VALUES (p_user_id, p_principal, v_interest_rate, v_total_repayable, v_weekly_payment, 'active', p_loan_type, p_collateral_aircraft_id)
RETURNING id INTO v_loan_id;
PERFORM credit_bank_account(p_user_id, p_principal, 'financing', 'loan_disbursement',
'Loan disbursement', v_game_time);
v_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT true, 'Loan disbursed at ' || ROUND(v_interest_rate * 100, 1)::TEXT || '% APR.'::TEXT, v_cash;
END;
$function$;

CREATE OR REPLACE FUNCTION public.terminate_aircraft_lease(p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM terminate_aircraft_lease(v_user_id, p_fleet_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.terminate_aircraft_lease(p_user_id uuid, p_fleet_id uuid)
RETURNS TABLE(success boolean, message character varying, new_cash numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_user RECORD; v_fleet RECORD; v_exit_fee NUMERIC(20,2);
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
SELECT * INTO v_user FROM users WHERE id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'User not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
SELECT f.*, m.model_name, m.lease_price_per_month
INTO v_fleet FROM fleet_aircraft f
JOIN aircraft_models m ON m.id = f.aircraft_model_id
WHERE f.id = p_fleet_id AND f.user_id = p_user_id FOR UPDATE;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Aircraft not found.'::VARCHAR, NULL::NUMERIC; RETURN; END IF;
IF COALESCE(v_fleet.acquisition_type, 'purchase') <> 'lease' THEN
RETURN QUERY SELECT FALSE, 'Only leased aircraft can be terminated through this action.'::VARCHAR, NULL::NUMERIC; RETURN;
END IF;
IF EXISTS (SELECT 1 FROM route_assignments WHERE user_id = p_user_id AND assigned_aircraft_id = p_fleet_id) THEN
RETURN QUERY SELECT FALSE, 'Aircraft is still assigned to a route.'::VARCHAR, NULL::NUMERIC; RETURN;
END IF;
v_exit_fee := calculate_lease_termination_fee(v_fleet.lease_price_per_month);
IF v_exit_fee > 0 THEN
PERFORM debit_bank_account(p_user_id, v_exit_fee, 'opex', 'lease_termination',
'Terminated leased aircraft ' || COALESCE(v_fleet.model_name, 'Unknown') || ' [' || COALESCE(v_fleet.tail_number, 'NO-TAIL') || ']',
date_trunc('day', v_user.game_current_time));
END IF;
DELETE FROM fleet_aircraft WHERE id = p_fleet_id AND user_id = p_user_id;
new_cash := get_user_balance(p_user_id);
RETURN QUERY SELECT TRUE, 'Lease terminated successfully!'::VARCHAR, new_cash;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_create_default_bank_account()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
v_starting_cash NUMERIC;
BEGIN
v_starting_cash := COALESCE(get_config_numeric('starting_cash'), 15000000.00);
INSERT INTO bank_accounts (user_id, account_type, balance)
VALUES (NEW.id, 'operating', v_starting_cash)
ON CONFLICT (user_id, account_type) DO NOTHING;
RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_fleet_reconcile_net_worth()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
v_user_id UUID;
v_fleet_value NUMERIC;
v_cash NUMERIC;
BEGIN
v_user_id := COALESCE(NEW.user_id, OLD.user_id);
SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
INTO v_fleet_value
FROM fleet_aircraft f
JOIN aircraft_models m ON f.aircraft_model_id = m.id
WHERE f.user_id = v_user_id AND f.acquisition_type = 'purchase';
SELECT COALESCE(balance, 0) INTO v_cash
FROM bank_accounts
WHERE user_id = v_user_id AND account_type = 'operating'
LIMIT 1;
UPDATE users SET net_worth = v_cash + v_fleet_value WHERE id = v_user_id;
RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_sync_tail_numbers_on_hq_change()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
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
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
v_fleet_value NUMERIC;
BEGIN
SELECT COALESCE(SUM(m.purchase_price * (f.condition / 100.00)), 0)
INTO v_fleet_value
FROM fleet_aircraft f
JOIN aircraft_models m ON f.aircraft_model_id = m.id
WHERE f.user_id = NEW.id AND f.acquisition_type = 'purchase';
NEW.net_worth := get_user_balance(NEW.id) + v_fleet_value;
RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_credit_score(p_user_id uuid, p_game_date timestamp with time zone)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE v_score RECORD; v_tier VARCHAR(10);
BEGIN
SELECT * INTO v_score FROM calculate_credit_score(p_user_id) LIMIT 1;
IF NOT FOUND THEN RETURN; END IF;
v_tier := CASE WHEN v_score.total_score >= 900 THEN 'Platinum' WHEN v_score.total_score >= 750 THEN 'Gold' WHEN v_score.total_score >= 600 THEN 'Silver' WHEN v_score.total_score >= 400 THEN 'Standard' ELSE 'Subprime' END;
INSERT INTO credit_scores (user_id, score, tier, fleet_health_score, revenue_stability_score, debt_ratio_score, cash_reserves_score, profit_history_score, computed_at)
VALUES (p_user_id, v_score.total_score, v_tier, v_score.fleet_health, v_score.revenue_stability, v_score.debt_ratio, v_score.cash_reserve, v_score.profit_history, NOW())
ON CONFLICT (user_id) DO UPDATE SET score = EXCLUDED.score, tier = EXCLUDED.tier, fleet_health_score = EXCLUDED.fleet_health_score, revenue_stability_score = EXCLUDED.revenue_stability_score, debt_ratio_score = EXCLUDED.debt_ratio_score, cash_reserves_score = EXCLUDED.cash_reserves_score, profit_history_score = EXCLUDED.profit_history_score, computed_at = EXCLUDED.computed_at;
-- No longer writing to users.credit_score / credit_tier (columns dropped)
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_route_frequency_and_price(p_route_id uuid, p_ticket_price numeric, p_flights_per_week integer)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
AS $function$
DECLARE v_user_id UUID;
BEGIN
v_user_id := public.require_current_user_id();
RETURN QUERY SELECT * FROM update_route_frequency_and_price(v_user_id, p_route_id, p_ticket_price, p_flights_per_week);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_route_frequency_and_price(p_user_id uuid, p_route_id uuid, p_ticket_price numeric, p_flights_per_week integer)
RETURNS TABLE(success boolean, message character varying)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_route_distance_km DOUBLE PRECISION; v_assigned_aircraft_id UUID; v_aircraft_range_km INT; v_aircraft_speed_kmh INT; v_max_weekly_flights INT;
BEGIN
PERFORM 1 FROM process_simulation_delta(p_user_id);
IF p_ticket_price <= 0 OR p_flights_per_week < 1 OR p_flights_per_week > 168 THEN RETURN QUERY SELECT FALSE, 'Invalid route economics or schedule.'::VARCHAR; RETURN; END IF;
SELECT distance_km, assigned_aircraft_id INTO v_route_distance_km, v_assigned_aircraft_id FROM route_assignments WHERE id = p_route_id AND user_id = p_user_id;
IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Route not found.'::VARCHAR; RETURN; END IF;
IF v_assigned_aircraft_id IS NOT NULL THEN
SELECT m.range_km, m.speed_kmh INTO v_aircraft_range_km, v_aircraft_speed_kmh FROM fleet_aircraft f JOIN aircraft_models m ON m.id = f.aircraft_model_id WHERE f.id = v_assigned_aircraft_id AND f.user_id = p_user_id;
IF COALESCE(v_aircraft_range_km, 0) < CEIL(COALESCE(v_route_distance_km, 0.0)) THEN RETURN QUERY SELECT FALSE, 'Assigned aircraft range is insufficient for this route.'::VARCHAR; RETURN; END IF;
v_max_weekly_flights := calculate_route_max_weekly_flights(v_route_distance_km, v_aircraft_speed_kmh);
IF v_max_weekly_flights > 0 AND p_flights_per_week > v_max_weekly_flights THEN RETURN QUERY SELECT FALSE, 'Route frequency exceeds the assigned aircraft''s weekly operating capacity.'::VARCHAR; RETURN; END IF;
END IF;
UPDATE route_assignments SET ticket_price = p_ticket_price, flights_per_week = p_flights_per_week WHERE id = p_route_id AND user_id = p_user_id;
RETURN QUERY SELECT TRUE, 'Route frequency and pricing adjusted!'::VARCHAR;
END;
$function$;

-- ============================================================================
-- SECTION 8: Triggers
-- ============================================================================
CREATE OR REPLACE TRIGGER fleet_reconcile_net_worth
    AFTER INSERT OR DELETE OR UPDATE ON public.fleet_aircraft
    FOR EACH ROW
    EXECUTE FUNCTION trg_fleet_reconcile_net_worth();

CREATE OR REPLACE TRIGGER create_default_bank_account
    AFTER INSERT ON public.users
    FOR EACH ROW
    EXECUTE FUNCTION trg_create_default_bank_account();

CREATE OR REPLACE TRIGGER trg_user_hq_change
    AFTER UPDATE ON public.users
    FOR EACH ROW
    EXECUTE FUNCTION trg_sync_tail_numbers_on_hq_change();
-- ============================================================================
-- SECTION 9: Seed Data
-- ============================================================================

-- ---------- airports (448 rows) ----------
INSERT INTO public.airports (iata, name, city, country, latitude, longitude, demand_index)
VALUES
('AAN', 'Al Ain International Airport', 'Al Ain', 'United Arab Emirates', 24.2617, 55.6092, 88),
('ADB', 'Izmir Adnan Menderes Airport', 'Izmir', 'Turkey', 38.2924, 27.157, 78),
('ADD', 'Bole International Airport', 'Addis Ababa', 'Ethiopia', 8.9778, 38.7994, 62),
('ADL', 'Adelaide Airport', 'Adelaide', 'Australia', -34.945, 138.5306, 52),
('AHB', 'Abha International Airport', 'Abha', 'Saudi Arabia', 18.2404, 42.656601, 81),
('AJF', 'Al-Jawf International Airport', 'Al-Jawf', 'Saudi Arabia', 29.783301, 40.100905, 81),
('AKL', 'Auckland Airport', 'Auckland', 'New Zealand', -37.0081, 174.7917, 70),
('AMD', 'Sardar Vallabhbhai Patel International Airport', 'Ahmedabad', 'India', 23.0772, 72.6347, 52),
('AMM', 'Queen Alia International Airport', 'Amman', 'Jordan', 31.7225, 35.9933, 50),
('AMQ', 'Pattimura International Airport', 'Ambon', 'Indonesia', -3.7103, 128.0892, 32),
('AMS', 'Amsterdam Airport Schiphol', 'Amsterdam', 'Netherlands', 52.3105, 4.7683, 92),
('AOJ', 'Aomori Airport', 'Aomori', 'Japan', 40.733777, 140.689477, 80),
('AOR', 'Sultan Abdul Halim Airport', 'Alor Setar', 'Malaysia', 6.1894, 100.3983, 30),
('AQI', 'Qaisumah–Hafar Al-Batin International Airport', 'Qaisumah', 'Saudi Arabia', 28.335726, 46.127108, 81),
('ARN', 'Stockholm Arlanda Airport', 'Stockholm', 'Sweden', 59.6519, 17.9186, 68),
('ATH', 'Athens International Airport', 'Athens', 'Greece', 37.9364, 23.9444, 70),
('ATL', 'Hartsfield-Jackson Atlanta International Airport', 'Atlanta', 'United States', 33.6408, -84.4272, 95),
('ATQ', 'Sri Guru Ram Das Ji International Airport', 'Amritsar', 'India', 31.7096, 74.797302, 78),
('AUH', 'Zayed International Airport', 'Abu Dhabi', 'UAE', 24.4331, 54.6511, 85),
('AVV', 'Melbourne Avalon International Airport', 'Geelong/Melbourne', 'Australia', -38.040269, 144.467196, 75),
('BAH', 'Bahrain International Airport', 'Manama', 'Bahrain', 26.2708, 50.6331, 52),
('BAQ', 'Ernesto Cortissoz International Airport', 'Barranquilla', 'Colombia', 10.8896, -74.7808, 62),
('BAV', 'Baotou Donghe International Airport', 'Baotou', 'China', 40.560001, 109.997002, 87),
('BBI', 'Biju Patnaik International Airport', 'Bhubaneswar', 'India', 20.251021, 85.814747, 78),
('BCD', 'Bacolod-Silay International Airport', 'Bacolod City', 'Philippines', 10.776237, 123.018879, 71),
('BCN', 'Josep Tarradellas Barcelona-El Prat Airport', 'Barcelona', 'Spain', 41.2969, 2.0783, 80),
('BDJ', 'Syamsudin Noor International Airport', 'Banjarbaru', 'Indonesia', -3.440112, 114.761209, 66),
('BDO', 'Husein Sastranegara International Airport', 'Bandung', 'Indonesia', -6.9006, 107.5764, 45),
('BDQ', 'Vadodara International Airport', 'Vadodara', 'India', 22.336201, 73.226303, 78),
('BEJ', 'Kalimarau Airport', 'Tanjung Redeb', 'Indonesia', 2.1558, 117.4308, 25),
('BER', 'Berlin Brandenburg Airport', 'Berlin', 'Germany', 52.3667, 13.5033, 85),
('BEY', 'Beirut-Rafic Hariri International Airport', 'Beirut', 'Lebanon', 33.8439, 35.4883, 44),
('BHO', 'Raja Bhoj International Airport', 'Bhopal', 'India', 23.2875, 77.337402, 78),
('BJN', 'Sultan Muhammad Kaharuddin III Airport', 'Sumbawa Besar', 'Indonesia', -8.4878, 117.4114, 18),
('BKI', 'Kota Kinabalu International Airport', 'Kota Kinabalu', 'Malaysia', 5.9372, 116.0511, 65),
('BKK', 'Suvarnabhumi Airport', 'Bangkok', 'Thailand', 13.69, 100.7501, 95),
('BLR', 'Kempegowda International Airport', 'Bengaluru', 'India', 13.1978, 77.7061, 78),
('BME', 'Broome International Airport', 'Broome', 'Australia', -17.949194, 122.2283, 75),
('BMU', 'Muhammad Salahuddin Airport', 'Bima', 'Indonesia', -8.5414, 118.6853, 20),
('BMV', 'Buon Ma Thuot Airport', 'Buon Ma Thuot', 'Vietnam', 12.6681, 108.1203, 26),
('BNE', 'Brisbane Airport', 'Brisbane', 'Australia', -27.3842, 153.1175, 68),
('BOG', 'El Dorado International Airport', 'Bogotá', 'Colombia', 4.7017, -74.1469, 72),
('BOM', 'Chhatrapati Shivaji Maharaj International Airport', 'Mumbai', 'India', 19.0886, 72.8681, 90),
('BOS', 'Logan International Airport', 'Boston', 'United States', 42.3642, -71.005, 82),
('BPN', 'Sultan Aji Muhammad Sulaiman Sepinggan Airport', 'Balikpapan', 'Indonesia', -1.2683, 116.8947, 58),
('BRU', 'Brussels Airport', 'Brussels', 'Belgium', 50.9014, 4.4844, 70),
('BSB', 'Brasília International Airport', 'Brasília', 'Brazil', -15.8711, -47.9186, 75),
('BTH', 'Hang Nadim International Airport', 'Batam', 'Indonesia', 1.1211, 104.1189, 58),
('BTJ', 'Sultan Iskandar Muda International Airport', 'Banda Aceh', 'Indonesia', 5.5222, 95.4206, 30),
('BUD', 'Budapest Ferenc Liszt International Airport', 'Budapest', 'Hungary', 47.4298, 19.2611, 72),
('BUW', 'Betoambari Airport', 'Bau-Bau', 'Indonesia', -5.4922, 122.5694, 20),
('BWA', 'Gautam Buddha International Airport', 'Siddharthanagar (Bhairahawa)', 'Nepal', 27.504636, 83.410381, 52),
('BWN', 'Brunei International Airport', 'Bandar Seri Begawan', 'Brunei', 4.9442, 114.9283, 50),
('CAI', 'Cairo International Airport', 'Cairo', 'Egypt', 30.1219, 31.4056, 75),
('CAN', 'Guangzhou Baiyun International Airport', 'Guangzhou', 'China', 23.3924, 113.2988, 92),
('CCJ', 'Calicut International Airport', 'Calicut', 'India', 11.135996, 75.955152, 78),
('CCS', 'Simón Bolívar International Airport', 'Caracas', 'Venezuela', 10.6012, -66.9913, 72),
('CCU', 'Netaji Subhash Chandra Bose International Airport', 'Kolkata', 'India', 22.6547, 88.4467, 65),
('CDG', 'Charles de Gaulle Airport', 'Paris', 'France', 49.0097, 2.5479, 92),
('CEB', 'Mactan-Cebu International Airport', 'Cebu', 'Philippines', 10.3075, 123.9794, 75),
('CEI', 'Mae Fah Luang - Chiang Rai International Airport', 'Chiang Rai', 'Thailand', 19.952299, 99.882896, 76),
('CGK', 'Soekarno-Hatta International Airport', 'Jakarta', 'Indonesia', -6.1256, 106.6558, 95),
('CGO', 'Zhengzhou Xinzheng International Airport', 'Zhengzhou', 'China', 34.526497, 113.849165, 87),
('CGP', 'Shah Amanat International Airport', 'Chattogram (Chittagong)', 'Bangladesh', 22.249599, 91.813301, 68),
('CGQ', 'Changchun Longjia International Airport', 'Changchun', 'China', 43.996201, 125.684998, 87),
('CGY', 'Laguindingan Airport', 'Cagayan de Oro', 'Philippines', 8.6122, 124.455, 42),
('CHC', 'Christchurch Airport', 'Christchurch', 'New Zealand', -43.4894, 172.5308, 50),
('CJB', 'Coimbatore International Airport', 'Coimbatore', 'India', 11.03, 77.043404, 78),
('CJJ', 'Cheongju International Airport/Cheongju Air Base (K-59/G-513)', 'Cheongju', 'South Korea', 36.71556, 127.500289, 77),
('CJU', 'Jeju International Airport', 'Jeju', 'South Korea', 33.5114, 126.4928, 75),
('CKG', 'Chongqing Jiangbei International Airport', 'Chongqing', 'China', 29.7189, 106.6417, 75),
('CLT', 'Charlotte Douglas International Airport', 'Charlotte', 'United States', 35.2139, -80.9431, 80),
('CMB', 'Bandaranaike International Colombo Airport', 'Colombo', 'Sri Lanka', 7.1807599067688, 79.8841018676758, 72),
('CMN', 'Mohammed V International Airport', 'Casablanca', 'Morocco', 33.3675, -7.5897, 60),
('CNF', 'Belo Horizonte International Airport', 'Belo Horizonte', 'Brazil', -19.6244, -43.9719, 72),
('CNN', 'Kannur International Airport', 'Kannur', 'India', 11.916343, 75.544979, 78),
('CNS', 'Cairns International Airport', 'Cairns', 'Australia', -16.878921, 145.74948, 75),
('CNX', 'Chiang Mai International Airport', 'Chiang Mai', 'Thailand', 18.7753, 98.9628, 70),
('COK', 'Cochin International Airport', 'Kochi', 'India', 10.1519, 76.4019, 54),
('CPH', 'Copenhagen Airport', 'Copenhagen', 'Denmark', 55.618, 12.6561, 80),
('CPT', 'Cape Town International Airport', 'Cape Town', 'South Africa', -33.9747, 18.6017, 68),
('CRK', 'Clark International Airport', 'Angeles City', 'Philippines', 15.1861, 120.56, 60),
('CSX', 'Changsha Huanghua International Airport', 'Changsha (Changsha)', 'China', 28.189199, 113.220001, 87),
('CTS', 'New Chitose Airport', 'Sapporo', 'Japan', 42.7753, 141.6928, 70),
('CTU', 'Chengdu Shuangliu International Airport', 'Chengdu', 'China', 30.5786, 103.9472, 80),
('CUM', 'Cumaná Airport', 'Cumaná', 'Venezuela', 10.4503, -64.1294, 15),
('CUN', 'Cancún International Airport', 'Cancun', 'Mexico', 21.0364, -86.8769, 78),
('CXR', 'Cam Ranh International Airport', 'Nha Trang', 'Vietnam', 11.9981, 109.2194, 55),
('DAC', 'Hazrat Shahjalal International Airport', 'Dhaka', 'Bangladesh', 23.843347, 90.397783, 68),
('DAD', 'Da Nang International Airport', 'Da Nang', 'Vietnam', 16.0439, 108.1994, 68),
('DAT', 'Datong Yungang International Airport', 'Datong', 'China', 40.06139, 113.480509, 87),
('DEL', 'Indira Gandhi International Airport', 'Delhi', 'India', 28.5686, 77.1008, 92),
('DEN', 'Denver International Airport', 'Denver', 'United States', 39.8561, -104.6739, 85),
('DFW', 'Dallas/Fort Worth International Airport', 'Dallas', 'United States', 32.8997, -97.0403, 90),
('DIA', 'Doha International Airport', 'Doha', 'Qatar', 25.259431, 51.565528, 92),
('DJJ', 'Dortheys Hiyo Eluay International Airport', 'Jayapura', 'Indonesia', -2.5761, 140.5169, 38),
('DLC', 'Dalian Zhoushuizi International Airport', 'Dalian (Ganjingzi)', 'China', 38.965719, 121.538477, 87),
('DMK', 'Don Mueang International Airport', 'Bangkok', 'Thailand', 13.9126, 100.6068, 80),
('DMM', 'King Fahd International Airport', 'Ad Dammam', 'Saudi Arabia', 26.4691, 49.798209, 81),
('DNH', 'Dunhuang Mogao International Airport', 'Dunhuang', 'China', 40.161953, 94.812827, 87),
('DOH', 'Hamad International Airport', 'Doha', 'Qatar', 25.2731, 51.6081, 92),
('DPS', 'I Gusti Ngurah Rai International Airport', 'Denpasar', 'Indonesia', -8.7482, 115.1672, 85),
('DQM', 'Duqm International Airport', 'Duqm', 'Oman', 19.501944, 57.634167, 54),
('DRP', 'Bicol International Airport', 'Legazpi', 'Philippines', 13.111915, 123.676829, 71),
('DRW', 'Darwin International Airport / RAAF Darwin', 'Darwin', 'Australia', -12.41497, 130.88185, 75),
('DSN', 'Ordos Ejin Horo International Airport', 'Ordos', 'China', 39.493514, 109.8599, 87),
('DSY', 'Dara Sakor International Airport', 'Ta Noun', 'Cambodia', 10.914244, 103.226652, 53),
('DTW', 'Detroit Metropolitan Airport', 'Detroit', 'United States', 42.2125, -83.3533, 72),
('DUB', 'Dublin Airport', 'Dublin', 'Ireland', 53.4214, -6.27, 68),
('DVO', 'Francisco Bangoy International Airport', 'Davao', 'Philippines', 7.1253, 125.6458, 58),
('DWC', 'Al Maktoum International Airport', 'Dubai(Jebel Ali)', 'United Arab Emirates', 24.896171, 55.16235, 88),
('DXB', 'Dubai International Airport', 'Dubai', 'UAE', 25.2532, 55.3657, 98),
('DYG', 'Zhangjiajie Hehua International Airport', 'Zhangjiajie (Yongding)', 'China', 29.104749, 110.442786, 87),
('EDI', 'Edinburgh Airport', 'Edinburgh', 'United Kingdom', 55.95, -3.3725, 72),
('EHU', 'Ezhou Huahu International Airport', 'Ezhou', 'China', 30.341178, 115.03926, 87),
('ELQ', 'Prince Naif bin Abdulaziz International Airport', 'Qassim', 'Saudi Arabia', 26.302799, 43.774399, 81),
('ENE', 'H. Hasan Aroeboesman Airport', 'Ende', 'Indonesia', -8.8475, 121.6622, 16),
('EWR', 'Newark Liberty International Airport', 'Newark', 'United States', 40.6925, -74.1686, 82),
('EZE', 'Ministro Pistarini International Airport', 'Buenos Aires', 'Argentina', -34.8222, -58.5358, 75),
('FCO', 'Leonardo da Vinci-Fiumicino Airport', 'Rome', 'Italy', 41.8003, 12.2389, 82),
('FJR', 'Fujairah International Airport', 'Fujairah', 'United Arab Emirates', 25.108411, 56.328061, 88),
('FKQ', 'Mopah International Airport', 'Merauke', 'Indonesia', -8.5203, 140.4178, 24),
('FOC', 'Fuzhou Changle International Airport', 'Fuzhou (Changle)', 'China', 25.929254, 119.672524, 87),
('FOR', 'Fortaleza Airport', 'Fortaleza', 'Brazil', -3.8178, -38.5433, 62),
('FRA', 'Frankfurt Airport', 'Frankfurt', 'Germany', 50.0333, 8.5706, 88),
('FSZ', 'Mount Fuji Shizuoka Airport', 'Makinohara / Shimada', 'Japan', 34.795022, 138.190976, 80),
('FUK', 'Fukuoka Airport', 'Fukuoka', 'Japan', 33.5858, 130.4506, 75),
('GAU', 'Lokpriya Gopinath Bordoloi International Airport', 'Guwahati', 'India', 26.106654, 91.585226, 78),
('GDL', 'Guadalajara International Airport', 'Guadalajara', 'Mexico', 20.5218, -103.3106, 78),
('GES', 'General Santos International Airport', 'General Santos', 'Philippines', 6.0578, 125.0958, 38),
('GIG', 'Galeão International Airport', 'Rio de Janeiro', 'Brazil', -22.81, -43.2506, 72),
('GMP', 'Gimpo International Airport', 'Seoul', 'South Korea', 37.5583, 126.7906, 76),
('GOI', 'Dabolim Airport', 'Goa', 'India', 15.3808, 73.8314, 55),
('GOT', 'Gothenburg Landvetter Airport', 'Gothenburg', 'Sweden', 57.6628, 12.2798, 72),
('GOX', 'Manohar International Airport', 'Mopa', 'India', 15.744257, 73.860625, 78),
('GRU', 'Sander International Airport', 'São Paulo', 'Brazil', -23.4356, -46.4731, 84),
('GTO', 'Jalaluddin Airport', 'Gorontalo', 'Indonesia', 0.6389, 122.8469, 25),
('GVA', 'Geneva Airport', 'Geneva', 'Switzerland', 46.2381, 6.109, 78),
('GWD', 'New Gwadar International Airport', 'Gurandani', 'Pakistan', 25.296733, 62.498822, 62),
('HAK', 'Haikou Meilan International Airport', 'Haikou (Meilan)', 'China', 19.9349, 110.459, 87),
('HAN', 'Noi Bai International Airport', 'Hanoi', 'Vietnam', 21.2211, 105.8072, 85),
('HAS', 'Hail International Airport', 'Hail', 'Saudi Arabia', 27.437901, 41.686298, 81),
('HBA', 'Hobart International Airport', 'Hobart (Cambridge)', 'Australia', -42.837032, 147.513022, 75),
('HDY', 'Hat Yai International Airport', 'Hat Yai', 'Thailand', 6.9328, 100.3928, 45),
('HEL', 'Helsinki-Vantaa Airport', 'Helsinki', 'Finland', 60.3172, 24.9633, 78),
('HET', 'Hohhot Baita International Airport', 'Hohhot', 'China', 40.849658, 111.824598, 87),
('HFE', 'Hefei Xinqiao International Airport', 'Hefei', 'China', 31.98779, 116.9769, 87),
('HGH', 'Hangzhou Xiaoshan International Airport', 'Hangzhou', 'China', 30.2294, 120.4344, 70),
('HIA', 'Huai''an Lianshui Airport', 'Huai''an', 'China', 33.792712, 119.126657, 87),
('HIJ', 'Hiroshima Airport', 'Hiroshima', 'Japan', 34.4361, 132.9194, 42),
('HKD', 'Hakodate Airport', 'Hakodate', 'Japan', 41.77, 140.822006, 80),
('HKG', 'Hong Kong International Airport', 'Hong Kong', 'Hong Kong', 22.308, 113.9185, 96),
('HKT', 'Phuket International Airport', 'Phuket', 'Thailand', 8.1133, 98.3167, 85),
('HLD', 'Hulunbuir Hailar Airport', 'Hailar', 'China', 49.208616, 119.822301, 87),
('HLP', 'Halim Perdanakusuma International Airport', 'Jakarta', 'Indonesia', -6.2653, 106.8903, 50),
('HND', 'Tokyo Haneda Airport', 'Tokyo', 'Japan', 35.5494, 139.7798, 98),
('HOF', 'Al-Ahsa International Airport', 'Hofuf', 'Saudi Arabia', 25.285299, 49.485199, 81),
('HPH', 'Cat Bi International Airport', 'Haiphong', 'Vietnam', 20.8189, 106.7247, 45),
('HRB', 'Harbin Taiping International Airport', 'Harbin', 'China', 45.623402, 126.25, 87),
('HRI', 'Mattala Rajapaksa International Airport', 'Mattala', 'Sri Lanka', 6.283878, 81.124163, 72),
('HSG', 'Kyushu Saga International Airport', 'Saga', 'Japan', 33.1497, 130.302002, 80),
('HSN', 'Zhoushan Putuoshan International Airport', 'Zhoushan', 'China', 29.933874, 122.362307, 87),
('HSR', 'Rajkot International Airport', 'Rajkot', 'India', 22.378824, 71.039391, 78),
('HSS', 'Maharaja Agrasen International Airport', 'Hisar', 'India', 29.186065, 75.74142, 78),
('HUI', 'Phu Bai International Airport', 'Hue', 'Vietnam', 16.4017, 107.7025, 38),
('HUN', 'Hualien Chiashan Airport', 'Hualien City', 'Taiwan', 24.023163, 121.617991, 85),
('HWR', 'Halwara International Airport', 'Halwara', 'India', 30.748501, 75.629799, 78),
('HYD', 'Rajiv Gandhi International Airport', 'Hyderabad', 'India', 17.2311, 78.4317, 72),
('IAH', 'George Bush Intercontinental Airport', 'Houston', 'United States', 29.9803, -95.3397, 84),
('IBR', 'Ibaraki Airport', 'Omitama', 'Japan', 36.181456, 140.414434, 80),
('ICN', 'Incheon International Airport', 'Seoul', 'South Korea', 37.4602, 126.4407, 95),
('IDR', 'Devi Ahilya Bai Holkar International Airport', 'Indore', 'India', 22.721404, 75.80051, 78),
('ILO', 'Iloilo International Airport', 'Iloilo City', 'Philippines', 10.8322, 122.4931, 44),
('IMF', 'Bir Tikendrajit International Airport', 'Imphal', 'India', 24.76, 93.896698, 78),
('INC', 'Yinchuan Hedong International Airport', 'Yinchuan', 'China', 38.322758, 106.393214, 87),
('INN', 'Innsbruck Airport', 'Innsbruck', 'Austria', 47.2602, 11.344, 65),
('IPH', 'Sultan Azlan Shah Airport', 'Ipoh', 'Malaysia', 4.5681, 101.0922, 34),
('ISB', 'Islamabad International Airport', 'Attock', 'Pakistan', 33.549, 72.82566, 62),
('ISK', 'Nashik International Airport', 'Nashik', 'India', 20.119101, 73.912903, 78),
('IST', 'Istanbul Airport', 'Istanbul', 'Turkey', 41.2753, 28.7519, 93),
('ITM', 'Osaka International Airport', 'Osaka', 'Japan', 34.7856, 135.4381, 70),
('IXB', 'Bagdogra Airport', 'Siliguri', 'India', 26.6812, 88.328598, 78),
('IXC', 'Shaheed Bhagat Singh International Airport', 'Chandigarh', 'India', 30.6735, 76.788498, 78),
('IXE', 'Mangaluru International Airport', 'Mangaluru', 'India', 12.95471, 74.886812, 78),
('IXZ', 'Veer Savarkar International Airport / INS Utkrosh', 'Port Blair', 'India', 11.640194, 92.72902, 78),
('JAF', 'Jaffna International Airport', 'Jaffna', 'Sri Lanka', 9.79233, 80.070099, 72),
('JAI', 'Jaipur International Airport', 'Jaipur', 'India', 26.8242, 75.8122, 42),
('JED', 'King Abdulaziz International Airport', 'Jeddah', 'Saudi Arabia', 21.6794, 39.1564, 82),
('JFK', 'John F. Kennedy International Airport', 'New York', 'United States', 40.6398, -73.7781, 96),
('JGN', 'Jiayuguan International Airport', 'Jiayuguan', 'China', 39.859052, 98.339344, 87),
('JHB', 'Senai International Airport', 'Johor Bahru', 'Malaysia', 1.6414, 103.6697, 56),
('JHG', 'Xishuangbanna Gasa International Airport', 'Jinghong (Gasa)', 'China', 21.974648, 100.762224, 87),
('JJN', 'Quanzhou Jinjiang International Airport', 'Quanzhou', 'China', 24.795855, 118.588599, 87),
('JNB', 'O.R. Tambo International Airport', 'Johannesburg', 'South Africa', -26.1392, 28.2461, 74),
('KBR', 'Sultan Ismail Petra Airport', 'Kota Bharu', 'Malaysia', 6.1664, 102.2925, 40),
('KBV', 'Krabi International Airport', 'Krabi', 'Thailand', 8.0994, 98.9856, 55),
('KCH', 'Kuching International Airport', 'Kuching', 'Malaysia', 1.4847, 110.3469, 62),
('KCZ', 'Kochi Ryoma Airport', 'Nankoku', 'Japan', 33.545217, 133.670166, 80),
('KDI', 'Haluoleo Airport', 'Kendari', 'Indonesia', -4.0811, 122.4175, 32),
('KDU', 'Skardu International Airport', 'Skardu', 'Pakistan', 35.33866, 75.538648, 62),
('KHG', 'Kashgar Laining International Airport', 'Kashgar', 'China', 39.542273, 76.02023, 87),
('KHH', 'Kaohsiung International Airport', 'Kaohsiung (Xiaogang)', 'Taiwan', 22.577101, 120.349998, 85),
('KHI', 'Jinnah International Airport', 'Karachi', 'Pakistan', 24.9065, 67.160797, 62),
('KHN', 'Nanchang Changbei International Airport', 'Nanchang', 'China', 28.864815, 115.90271, 87),
('KIJ', 'Niigata Airport', 'Niigata', 'Japan', 37.954166, 139.112189, 80),
('KIX', 'Kansai International Airport', 'Osaka', 'Japan', 34.4347, 135.2442, 88),
('KKC', 'Khon Kaen Airport', 'Khon Kaen', 'Thailand', 16.4839, 102.7831, 30),
('KKJ', 'Kitakyushu Airport', 'Kitakyushu', 'Japan', 33.845901, 131.035004, 80),
('KLO', 'Kalibo International Airport', 'Kalibo', 'Philippines', 11.6792, 122.3756, 42),
('KMG', 'Kunming Changshui International Airport', 'Kunming', 'China', 25.1017, 102.9292, 68),
('KMI', 'Miyazaki Airport', 'Miyazaki', 'Japan', 31.877199, 131.449005, 80),
('KMJ', 'Kumamoto Airport', 'Kumamoto', 'Japan', 32.8372, 130.855, 36),
('KMQ', 'Komatsu Airport', 'Komatsu', 'Japan', 36.3939, 136.4075, 34),
('KNO', 'Kualanamu International Airport', 'Medan', 'Indonesia', 3.6422, 98.8853, 65),
('KOE', 'El Tari International Airport', 'Kupang', 'Indonesia', -10.1717, 123.6706, 35),
('KOJ', 'Kagoshima Airport', 'Kagoshima', 'Japan', 31.8033, 130.7194, 38),
('KOS', 'Sihanouk International Airport', 'Sihanoukville', 'Cambodia', 10.58, 103.6369, 32),
('KTI', 'Techo International Airport', 'Phnom Penh (Boeng Khyang)', 'Cambodia', 11.359987, 104.921272, 53),
('KTM', 'Tribhuvan International Airport', 'Kathmandu', 'Nepal', 27.6966, 85.3591, 52),
('KUA', 'Sultan Haji Ahmad Shah Airport', 'Kuantan', 'Malaysia', 3.7753, 103.2094, 32),
('KUL', 'Kuala Lumpur International Airport', 'Kuala Lumpur', 'Malaysia', 2.7456, 101.7099, 90),
('KWE', 'Guiyang Longdongbao International Airport', 'Guiyang (Nanming)', 'China', 26.541805, 106.80402, 87),
('KWI', 'Kuwait International Airport', 'Kuwait City', 'Kuwait', 29.2264, 47.9689, 56),
('KWJ', 'Gwangju Airport', 'Gwangju', 'South Korea', 35.1264, 126.8089, 32),
('KWL', 'Guilin Liangjiang International Airport', 'Guilin (Lingui)', 'China', 25.219828, 110.039553, 87),
('LAO', 'Laoag International Airport', 'Laoag', 'Philippines', 18.1794, 120.5317, 30),
('LAS', 'Harry Reid International Airport', 'Las Vegas', 'United States', 36.08, -115.1522, 85),
('LAX', 'Los Angeles International Airport', 'Los Angeles', 'United States', 33.9416, -118.4085, 96),
('LGA', 'LaGuardia Airport', 'New York', 'United States', 40.7772, -73.8725, 78),
('LGK', 'Langkawi International Airport', 'Langkawi', 'Malaysia', 6.3297, 99.7286, 58),
('LGW', 'London Gatwick Airport', 'London', 'United Kingdom', 51.1481, -0.1903, 80),
('LHE', 'Allama Iqbal International Airport', 'Lahore', 'Pakistan', 31.521601, 74.403603, 62),
('LHR', 'London Heathrow Airport', 'London', 'United Kingdom', 51.47, -0.4543, 96),
('LHW', 'Lanzhou Zhongchuan International Airport', 'Lanzhou (Yongdeng)', 'China', 36.515202, 103.620003, 87),
('LIM', 'Jorge Chávez International Airport', 'Lima', 'Peru', -12.0219, -77.1144, 70),
('LIS', 'Humberto Delgado Airport', 'Lisbon', 'Portugal', 38.7742, -9.1342, 72),
('LJG', 'Lijiang Sanyi International Airport', 'Lijiang', 'China', 26.677483, 100.244944, 87),
('LKO', 'Chaudhary Charan Singh International Airport', 'Lucknow', 'India', 26.7606, 80.8819, 44),
('LOP', 'Lombok International Airport', 'Mataram', 'Indonesia', -8.7561, 116.275, 52),
('LPQ', 'Luang Prabang International Airport', 'Luang Prabang', 'Laos', 19.8975, 102.1625, 34),
('LSX', 'Leksula Airport', 'Buru', 'Indonesia', -3.7842, 126.5042, 10),
('LXA', 'Lhasa Gonggar International Airport', 'Shannan (Gonggar)', 'China', 29.298001, 90.911951, 87),
('LYA', 'Luoyang Beijiao Airport', 'Luoyang (Laocheng)', 'China', 34.7411, 112.388, 87),
('LYG', 'Lianyungang Huaguoshan International Airport', 'Lianyungang', 'China', 34.41406, 119.17899, 87),
('LYP', 'Faisalabad International Airport', 'Faisalabad', 'Pakistan', 31.364923, 72.995319, 62),
('LYS', 'Lyon-Saint Exupéry Airport', 'Lyon', 'France', 45.7256, 5.0811, 72),
('MAA', 'Chennai International Airport', 'Chennai', 'India', 12.99, 80.1692, 70),
('MAD', 'Adolfo Suarez Madrid-Barajas Airport', 'Madrid', 'Spain', 40.4719, -3.5608, 85),
('MAN', 'Manchester Airport', 'Manchester', 'United Kingdom', 53.4747, -2.2344, 82),
('MCO', 'Orlando International Airport', 'Orlando', 'United States', 28.4294, -81.3089, 82),
('MCT', 'Muscat International Airport', 'Muscat', 'Oman', 23.5933, 58.2814, 54),
('MCY', 'Sunshine Coast Airport', 'Maroochydore', 'Australia', -26.593324, 153.08319, 75),
('MDC', 'Sam Ratulangi International Airport', 'Manado', 'Indonesia', 1.5494, 124.9264, 45),
('MDE', 'José María Córdova International Airport', 'Medellín', 'Colombia', 6.1645, -75.4231, 68),
('MDL', 'Mandalay International Airport', 'Mandalay', 'Myanmar', 21.7014, 95.9758, 38),
('MDW', 'Chicago Midway International Airport', 'Chicago', 'United States', 41.7861, -87.7525, 60),
('MED', 'Prince Mohammad Bin Abdulaziz Airport', 'Medina', 'Saudi Arabia', 24.5534, 39.705101, 81),
('MEL', 'Melbourne Airport', 'Melbourne', 'Australia', -37.6733, 144.8433, 78),
('MEX', 'Mexico City International Airport', 'Mexico City', 'Mexico', 19.4363, -99.0721, 92),
('MFM', 'Macau International Airport', 'Macau', 'Macau', 22.1494, 113.5919, 54),
('MIA', 'Miami International Airport', 'Miami', 'United States', 25.7933, -80.2906, 84),
('MKW', 'Rendani Airport', 'Manokwari', 'Indonesia', -0.8906, 134.0506, 25),
('MNL', 'Ninoy Aquino International Airport', 'Manila', 'Philippines', 14.5086, 121.0194, 90),
('MOF', 'Frans Xavier Seda Airport', 'Maumere', 'Indonesia', -8.6414, 122.2403, 17),
('MSP', 'Minneapolis-Saint Paul International Airport', 'Minneapolis', 'United States', 44.8806, -93.2169, 70),
('MTY', 'Monterrey International Airport', 'Monterrey', 'Mexico', 25.7785, -100.1069, 75),
('MUC', 'Munich Airport', 'Munich', 'Germany', 48.3538, 11.7861, 85),
('MUX', 'Multan International Airport', 'Multan', 'Pakistan', 30.203199, 71.419098, 62),
('MWX', 'Muan International Airport', 'Muan (Piseo-ri)', 'South Korea', 34.991406, 126.382814, 77),
('MXP', 'Milan Malpensa Airport', 'Milan', 'Italy', 45.63, 8.7231, 68),
('MYJ', 'Matsuyama Airport', 'Matsuyama', 'Japan', 33.8272, 132.6997, 35),
('MYY', 'Miri Airport', 'Miri', 'Malaysia', 4.3225, 113.9872, 42),
('MZG', 'Penghu Magong Airport', 'Huxi', 'Taiwan', 23.568701, 119.627998, 85),
('NAG', 'Dr. Babasaheb Ambedkar International Airport', 'Nagpur', 'India', 21.092199, 79.047203, 78),
('NAN', 'Nadi International Airport', 'Nadi', 'Fiji', -17.7553, 177.4433, 45),
('NBO', 'Jomo Kenyatta International Airport', 'Nairobi', 'Kenya', -1.3192, 36.9275, 58),
('NCE', 'Nice Côte d''Azur Airport', 'Nice', 'France', 43.6584, 7.2159, 78),
('NDG', 'Qiqihar Sanjiazi Airport', 'Qiqihar', 'China', 47.229969, 123.914179, 87),
('NGB', 'Ningbo Lishe International Airport', 'Ningbo', 'China', 29.8267002105713, 121.46199798584, 87),
('NGO', 'Chubu Centrair International Airport', 'Nagoya', 'Japan', 34.8583, 136.8053, 72),
('NGS', 'Nagasaki Airport', 'Nagasaki', 'Japan', 32.916901, 129.914001, 80),
('NKG', 'Nanjing Lukou International Airport', 'Nanjing', 'China', 31.7419, 118.8619, 58),
('NMI', 'Navi Mumbai International Airport', 'Navi Mumbai', 'India', 18.984597, 73.065253, 78),
('NNG', 'Nanning Wuxu International Airport', 'Nanning (Jiangnan)', 'China', 22.598071, 108.181922, 87),
('NRT', 'Narita International Airport', 'Tokyo', 'Japan', 35.7767, 140.3864, 90),
('NST', 'Nakhon Si Thammarat Airport', 'Nakhon Si Thammarat', 'Thailand', 8.5417, 99.9458, 28),
('NTL', 'Newcastle Airport', 'Williamtown', 'Australia', -32.796114, 151.835025, 75),
('NUM', 'Neom Bay Airport', 'Sharma', 'Saudi Arabia', 27.924261, 35.29358, 81),
('NYT', 'Naypyidaw International Airport', 'Naypyidaw', 'Myanmar', 19.6231, 96.2008, 24),
('OHS', 'Suhar International Airport', 'Suhar', 'Oman', 24.38604, 56.62541, 54),
('OKA', 'Naha Airport', 'Okinawa', 'Japan', 26.1958, 127.6458, 72),
('OKJ', 'Okayama Momotaro Airport', 'Okayama', 'Japan', 34.756901, 133.854996, 80),
('OOL', 'Gold Coast Airport', 'Gold Coast', 'Australia', -28.165962, 153.506641, 75),
('ORD', 'OHare International Airport', 'Chicago', 'United States', 41.9742, -87.9073, 92),
('ORY', 'Orly Airport', 'Paris', 'France', 48.7253, 2.3594, 75),
('OSL', 'Oslo Gardermoen Airport', 'Oslo', 'Norway', 60.1976, 11.1004, 78),
('OTG', 'Leo Wattimena Airport', 'Morotai', 'Indonesia', 2.0792, 128.3242, 15),
('OTP', 'Henri Coandă International Airport', 'Bucharest', 'Romania', 44.5711, 26.085, 68),
('PBH', 'Paro International Airport', 'Paro', 'Bhutan', 27.4032, 89.424599, 45),
('PDG', 'Minangkabau International Airport', 'Padang', 'Indonesia', -0.785, 100.2817, 45),
('PEK', 'Beijing Capital International Airport', 'Beijing', 'China', 40.0799, 116.5975, 94),
('PEN', 'Penang International Airport', 'George Town', 'Malaysia', 5.2972, 100.2767, 72),
('PER', 'Perth Airport', 'Perth', 'Australia', -31.9403, 115.9669, 62),
('PEW', 'Bacha Khan International Airport', 'Peshawar', 'Pakistan', 33.9939, 71.514603, 62),
('PGK', 'Depati Amir Airport', 'Pangkal Pinang', 'Indonesia', -2.1622, 106.1389, 32),
('PHE', 'Port Hedland International Airport', 'Port Hedland', 'Australia', -20.382787, 118.629789, 75),
('PHH', 'Pokhara International Airport', 'Pokhara', 'Nepal', 28.1838, 84.0147, 52),
('PHX', 'Phoenix Sky Harbor International Airport', 'Phoenix', 'United States', 33.4342, -112.0081, 78),
('PKN', 'Iskandar Airport', 'Pangkalan Bun', 'Indonesia', -2.7042, 111.6742, 26),
('PKU', 'Sultan Syarif Kasim II International Airport', 'Pekanbaru', 'Indonesia', 0.4614, 101.4481, 46),
('PKX', 'Beijing Daxing International Airport', 'Beijing', 'China', 39.5092, 116.4106, 85),
('PKY', 'Tjilik Riwut Airport', 'Palangkaraya', 'Indonesia', -2.225, 113.9436, 28),
('PKZ', 'Pakse International Airport', 'Pakse', 'Laos', 15.1339, 105.7819, 20),
('PLM', 'Sultan Mahmud Badaruddin II Airport', 'Palembang', 'Indonesia', -2.8988, 104.7003, 48),
('PLW', 'Mutiara SIS Al-Jufri Airport', 'Palu', 'Indonesia', -0.9167, 119.9078, 30),
('PMI', 'Palma de Mallorca Airport', 'Palma de Mallorca', 'Spain', 39.5517, 2.7388, 78),
('PNH', 'Phnom Penh International Airport', 'Phnom Penh', 'Cambodia', 11.5467, 104.8442, 58),
('PNK', 'Supadio International Airport', 'Pontianak', 'Indonesia', -0.15, 109.4031, 44),
('PNQ', 'Pune Airport', 'Pune', 'India', 18.5822, 73.9197, 48),
('POA', 'Porto Alegre Airport', 'Porto Alegre', 'Brazil', -29.9944, -51.1714, 72),
('POM', 'Port Moresby Jacksons International Airport', 'Port Moresby', 'Papua New Guinea', -6.0653, 145.3942, 48),
('PPS', 'Puerto Princesa International Airport', 'Puerto Princesa', 'Philippines', 9.7422, 118.7589, 45),
('PPT', 'Fa''a''ā International Airport', 'Papeete', 'Tahiti', -17.5564, -149.6114, 40),
('PQC', 'Phu Quoc International Airport', 'Phu Quoc', 'Vietnam', 10.1694, 103.9928, 58),
('PRG', 'Vaclav Havel Airport Prague', 'Prague', 'Czech Republic', 50.1008, 14.26, 60),
('PTY', 'Tocumen International Airport', 'Panama City', 'Panama', 9.0714, -79.3835, 78),
('PUS', 'Gimhae International Airport', 'Busan', 'South Korea', 35.1794, 128.9383, 68),
('PVG', 'Shanghai Pudong International Airport', 'Shanghai', 'China', 31.1443, 121.8083, 95),
('PXA', 'Pagar Alam Airport', 'Pagar Alam', 'Indonesia', -4.0322, 103.2642, 12),
('REC', 'Recife Airport', 'Recife', 'Brazil', -8.1264, -34.9236, 65),
('REP', 'Siem Reap International Airport', 'Siem Reap', 'Cambodia', 13.4108, 103.9483, 55),
('RGN', 'Yangon International Airport', 'Yangon', 'Myanmar', 16.9072, 96.1331, 55),
('RKT', 'Ras Al Khaimah International Airport', 'Ras Al Khaimah', 'United Arab Emirates', 25.613501, 55.938801, 88),
('RKZ', 'Xigaze Peace Airport / Shigatse Air Base', 'Xigazê (Samzhubzê)', 'China', 29.350876, 89.299157, 87),
('RML', 'Colombo Ratmalana International Airport', 'Colombo', 'Sri Lanka', 6.821638, 79.885859, 72),
('RMQ', 'Taichung International Airport / Ching Chuang Kang Air Base', 'Taichung (Qingshui)', 'Taiwan', 24.2647, 120.621002, 85),
('RSI', 'Red Sea International Airport', 'Hanak', 'Saudi Arabia', 25.627975, 37.088914, 81),
('RUH', 'King Khalid International Airport', 'Riyadh', 'Saudi Arabia', 24.9578, 46.6986, 78),
('SAG', 'Shirdi International Airport', 'Kakadi', 'India', 19.689211, 74.373655, 78),
('SAI', 'Siem Reap-Angkor International Airport', 'Siem Reap', 'Cambodia', 13.36974, 104.223831, 53),
('SAW', 'Sabiha Gokcen International Airport', 'Istanbul', 'Turkey', 40.8986, 29.3092, 70),
('SCL', 'Arturo Merino Benítez International Airport', 'Santiago', 'Chile', -33.3931, -70.7856, 68),
('SDJ', 'Sendai Airport', 'Sendai', 'Japan', 38.1397, 140.9169, 44),
('SDK', 'Sandakan Airport', 'Sandakan', 'Malaysia', 5.9011, 118.0603, 34),
('SEA', 'Seattle-Tacoma International Airport', 'Seattle', 'United States', 47.4489, -122.3094, 80),
('SFO', 'San Francisco International Airport', 'San Francisco', 'United States', 37.619, -122.3749, 88),
('SFS', 'Subic Bay International Airport / Naval Air Station Cubi Point', 'Olongapo', 'Philippines', 14.794833, 120.271883, 71),
('SGN', 'Tan Son Nhat International Airport', 'Ho Chi Minh City', 'Vietnam', 10.8189, 106.6519, 88),
('SHA', 'Shanghai Hongqiao International Airport', 'Shanghai', 'China', 31.1978, 121.3364, 82),
('SHE', 'Shenyang Taoxian International Airport', 'Shenyang', 'China', 41.6398, 123.483668, 87),
('SHJ', 'Sharjah International Airport', 'Sharjah', 'United Arab Emirates', 25.3286, 55.5172, 88),
('SIN', 'Singapore Changi Airport', 'Singapore', 'Singapore', 1.3644, 103.9915, 98),
('SJO', 'Juan Santamaría International Airport', 'San José', 'Costa Rica', 9.9939, -84.2088, 72),
('SJW', 'Shijiazhuang Zhengding International Airport', 'Shijiazhuang', 'China', 38.280701, 114.696999, 87),
('SKT', 'Sialkot International Airport', 'Sialkot', 'Pakistan', 32.535941, 74.364623, 62),
('SLL', 'Salalah International Airport', 'Salalah', 'Oman', 17.0387, 54.091301, 54),
('SME', 'Santa Maria Airport', 'Santa Maria', 'Azores', 36.9742, -25.1706, 18),
('SMQ', 'H. Asan Airport', 'Sampit', 'Indonesia', -2.5008, 112.9669, 20),
('SNN', 'Shannon Airport', 'Shannon', 'Ireland', 52.702, -8.9286, 55),
('SOC', 'Adisoemarmo International Airport', 'Surakarta', 'Indonesia', -7.516044, 110.757492, 66),
('SOF', 'Sofia Airport', 'Sofia', 'Bulgaria', 42.6959, 23.4064, 62),
('SOQ', 'Domine Eduard Osok Airport', 'Sorong', 'Indonesia', -0.8903, 131.2908, 38),
('SRG', 'Jenderal Ahmad Yani International Airport', 'Semarang', 'Indonesia', -6.9722, 110.3753, 50),
('SSA', 'Salvador Airport', 'Salvador', 'Brazil', -12.9086, -38.3225, 68),
('STV', 'Surat International Airport', 'Surat', 'India', 21.115531, 72.743251, 78),
('SUB', 'Juanda International Airport', 'Surabaya', 'Indonesia', -7.3798, 112.7878, 70),
('SVQ', 'Seville Airport', 'Seville', 'Spain', 37.418, -5.8931, 68),
('SWA', 'Jieyang Chaoshan International Airport', 'Jieyang (Rongcheng)', 'China', 23.552, 116.5033, 87),
('SXR', 'Sheikh ul Alam International Airport', 'Srinagar', 'India', 33.987099, 74.7742, 78),
('SYD', 'Kingsford Smith Airport', 'Sydney', 'Australia', -33.9461, 151.1772, 82),
('SYX', 'Sanya Phoenix International Airport', 'Sanya (Tianya)', 'China', 18.3029, 109.412003, 87),
('SZB', 'Sultan Abdul Aziz Shah Airport', 'Subang', 'Malaysia', 3.1306, 101.5492, 50),
('SZG', 'Salzburg Airport', 'Salzburg', 'Austria', 47.7933, 13.0043, 65),
('SZX', 'Shenzhen Baoan International Airport', 'Shenzhen', 'China', 22.6393, 113.8107, 85),
('TAE', 'Daegu International Airport', 'Daegu', 'South Korea', 35.8939, 128.6528, 38),
('TAG', 'Bohol-Panglao International Airport', 'Panglao', 'Philippines', 9.5658, 123.7681, 48),
('TAK', 'Takamatsu Airport', 'Takamatsu', 'Japan', 34.214963, 134.015454, 80),
('TAO', 'Qingdao Jiaodong International Airport', 'Qingdao (Jiaozhou)', 'China', 36.361953, 120.088171, 87),
('TAX', 'Tana Toraja Airport', 'Makale', 'Indonesia', -3.0767, 119.8242, 22),
('TFU', 'Chengdu Tianfu International Airport', 'Chengdu (Jianyang)', 'China', 30.31252, 104.441284, 87),
('TGG', 'Sultan Mahmud Airport', 'Kuala Terengganu', 'Malaysia', 5.3828, 103.1028, 38),
('TIF', 'Taif International Airport', 'Taif', 'Saudi Arabia', 21.484739, 40.544074, 81),
('TIR', 'Tirupati International Airport', 'Tirupati', 'India', 13.631988, 79.539869, 78),
('TJQ', 'H.A.S. Hanandjoeddin International Airport', 'Tanjung Pandan', 'Indonesia', -2.7486, 107.7547, 34),
('TKS', 'Tokushima Awaodori Airport / JMSDF Tokushima Air Base', 'Tokushima', 'Japan', 34.132559, 134.607816, 80),
('TNA', 'Jinan Yaoqiang International Airport', 'Jinan (Licheng)', 'China', 36.857201, 117.216003, 87),
('TNN', 'Tainan International Airport / Tainan Air Base', 'Tainan (Rende)', 'Taiwan', 22.950399, 120.206001, 85),
('TPE', 'Taiwan Taoyuan International Airport', 'Taipei', 'Taiwan', 25.0797, 121.2342, 85),
('TRK', 'Juwata International Airport', 'Tarakan', 'Indonesia', 3.3242, 117.5683, 30),
('TRN', 'Turin Airport', 'Turin', 'Italy', 45.1886, 7.6494, 65),
('TRV', 'Thiruvananthapuram International Airport', 'Thiruvananthapuram', 'India', 8.481889, 76.920029, 78),
('TRZ', 'Tiruchirappalli International Airport', 'Tiruchirappalli', 'India', 10.762915, 78.717741, 78),
('TSA', 'Taipei Songshan International Airport', 'Taipei (Songshan)', 'Taiwan', 25.067244, 121.552822, 85),
('TSN', 'Tianjin Binhai International Airport', 'Tianjin', 'China', 39.1244010925, 117.346000671, 87),
('TTE', 'Sultan Babullah Airport', 'Ternate', 'Indonesia', 0.8322, 127.3792, 28),
('TUK', 'Turbat International Airport', 'Turbat', 'Pakistan', 25.984767, 63.028856, 62),
('TUU', 'Prince Sultan bin Abdulaziz International Airport', 'Tabuk', 'Saudi Arabia', 28.3711, 36.624865, 81),
('TWU', 'Tawau Airport', 'Tawau', 'Malaysia', 4.2678, 118.125, 36),
('TXN', 'Huangshan Tunxi International Airport', 'Huangshan', 'China', 29.733299, 118.255997, 87),
('TYN', 'Taiyuan Wusu International Airport', 'Taiyuan', 'China', 37.746899, 112.627998, 87),
('UET', 'Quetta International Airport', 'Quetta', 'Pakistan', 30.2514, 66.937798, 62),
('UKB', 'Kobe Airport', 'Kobe', 'Japan', 34.632801, 135.223999, 80),
('ULH', 'Al-Ula International Airport', 'Al-Ula', 'Saudi Arabia', 26.483634, 38.117048, 81),
('UPG', 'Sultan Hasanuddin International Airport', 'Makassar', 'Indonesia', -5.0616, 119.5539, 68),
('URC', 'Ürümqi Tianshan International Airport', 'Ürümqi', 'China', 43.913584, 87.479372, 87),
('URT', 'Surat Thani International Airport', 'Surat Thani', 'Thailand', 9.1325, 99.1356, 36),
('USM', 'Samui International Airport', 'Koh Samui', 'Thailand', 9.5494, 100.0631, 60),
('USN', 'Ulsan Airport', 'Ulsan', 'South Korea', 35.5933, 129.3517, 30),
('UTH', 'Udon Thani International Airport', 'Udon Thani', 'Thailand', 17.3864, 102.7881, 38),
('UTP', 'U-Tapao International Airport', 'Pattaya', 'Thailand', 12.6797, 101.005, 48),
('VCA', 'Can Tho International Airport', 'Can Tho', 'Vietnam', 10.0839, 105.7119, 40),
('VCE', 'Venice Marco Polo Airport', 'Venice', 'Italy', 45.5053, 12.3519, 72),
('VGA', 'Vijayawada International Airport', 'Vijayawada', 'India', 16.530011, 80.804888, 78),
('VIE', 'Vienna International Airport', 'Vienna', 'Austria', 48.1103, 16.5697, 70),
('VII', 'Vinh International Airport', 'Vinh', 'Vietnam', 18.7364, 105.6706, 30),
('VKO', 'Vnukovo International Airport', 'Moscow', 'Russia', 55.5961, 37.2614, 70),
('VLC', 'Valencia Airport', 'Valencia', 'Spain', 39.4893, -0.4816, 68),
('VNS', 'Lal Bahadur Shastri International Airport', 'Varanasi', 'India', 25.452171, 82.862549, 78),
('VTE', 'Wattay International Airport', 'Vientiane', 'Laos', 17.9883, 102.5633, 44),
('VTZ', 'Visakhapatnam International Airport', 'Visakhapatnam', 'India', 17.723506, 83.227729, 78),
('WAW', 'Warsaw Chopin Airport', 'Warsaw', 'Poland', 52.1658, 20.9672, 62),
('WGP', 'Umbu Mehang Kunda Airport', 'Waingapu', 'Indonesia', -9.6672, 120.3017, 18),
('WLG', 'Wellington Airport', 'Wellington', 'New Zealand', -41.3272, 174.8053, 48),
('WNZ', 'Wenzhou Longwan International Airport', 'Wenzhou (Longwan)', 'China', 27.910572, 120.853465, 87),
('WSI', '[Duplicate] Western Sydney International Airport', 'Sydney', 'Australia', -33.88806, 150.71472, 75),
('WTB', 'Toowoomba Wellcamp Airport', 'Toowoomba', 'Australia', -27.558332, 151.793335, 75),
('WUH', 'Wuhan Tianhe International Airport', 'Wuhan', 'China', 30.7839, 114.2081, 62),
('WUX', 'Sunan Shuofang International Airport', 'Wuxi', 'China', 31.496952, 120.43038, 87),
('XIY', 'Xi''an Xianyang International Airport', 'Xi''an', 'China', 34.4472, 108.7517, 72),
('XMN', 'Xiamen Gaoqi International Airport', 'Xiamen', 'China', 24.543889, 118.127454, 87),
('XNN', 'Xining Caojiabao International Airport', 'Haidong (Huzhu Tu Autonomous County)', 'China', 36.52775, 102.040215, 87),
('YCU', 'Yuncheng Yanhu International Airport', 'Yuncheng (Yanhu)', 'China', 35.117823, 111.034023, 87),
('YIA', 'Yogyakarta International Airport', 'Yogyakarta', 'Indonesia', -7.9044, 110.0572, 60),
('YIW', 'Yiwu Airport', 'Yiwu/Jinhua', 'China', 29.342095, 120.03116, 87),
('YNB', 'Prince Abdulmohsen Bin Abdulaziz International Airport', 'Yanbu', 'Saudi Arabia', 24.144199, 38.0634, 81),
('YNT', 'Yantai Penglai International Airport', 'Yantai', 'China', 37.659724, 120.978124, 87),
('YNY', 'Yangyang International Airport', 'Gonghang-ro', 'South Korea', 38.060481, 128.669822, 77),
('YNZ', 'Yancheng Nanyang International Airport', 'Yancheng (Tinghu)', 'China', 33.428317, 120.20545, 87),
('YUL', 'Montréal-Trudeau International Airport', 'Montreal', 'Canada', 45.4706, -73.7408, 68),
('YVR', 'Vancouver International Airport', 'Vancouver', 'Canada', 49.1961, -123.1839, 75),
('YYZ', 'Toronto Pearson International Airport', 'Toronto', 'Canada', 43.6778, -79.6247, 85),
('ZAG', 'Zagreb Airport', 'Zagreb', 'Croatia', 45.7429, 16.0688, 65),
('ZAM', 'Zamboanga International Airport', 'Zamboanga City', 'Philippines', 6.9222, 122.0594, 36),
('ZHA', 'Zhanjiang Wuchuan International Airport', 'Zhanjiang', 'China', 21.481667, 110.590278, 87),
('ZQN', 'Queenstown Airport', 'Queenstown', 'New Zealand', -45.019205, 168.746379, 63),
('ZRH', 'Zurich Airport', 'Zurich', 'Switzerland', 47.4581, 8.5481, 75),
('ZUH', 'Zhuhai Jinwan Airport', 'Zhuhai (Jinwan)', 'China', 22.006399, 113.375999, 87),
('ZYL', 'Osmany International Airport', 'Sylhet', 'Bangladesh', 24.963071, 91.866903, 68)
ON CONFLICT (iata) DO NOTHING;

-- ---------- aircraft_models (66 rows) ----------
INSERT INTO public.aircraft_models (id, manufacturer, model_name, type, range_km, capacity, speed_kmh, fuel_burn_per_km, maintenance_cost_per_hour, purchase_price, lease_price_per_month, turnaround_hours)
VALUES
('69bdeb97-da89-485d-9303-b09b2ec53e8b', 'Boeing', '717-200', 'narrow_body_jet', 3815, 134, 822, 3.900, 620.00, 55000000.00, 275000.00, 0.75),
('9d34d93f-52ad-4b1e-b4a4-88ca4a379460', 'Boeing', '737 MAX 10', 'narrow_body_jet', 6100, 230, 839, 4.800, 960.00, 134000000.00, 670000.00, 1.5),
('f3a962cc-f623-4c34-9032-3696ad1da208', 'Boeing', '737 MAX 200', 'narrow_body_jet', 6570, 197, 839, 4.350, 870.00, 123000000.00, 615000.00, 0.75),
('ea9f4708-1d91-44f2-bd5b-ce744f70bc38', 'Boeing', '737 MAX 7', 'narrow_body_jet', 7100, 153, 839, 4.000, 810.00, 100000000.00, 500000.00, 0.75),
('17af5936-2b43-469f-8e26-eaddd6e364ad', 'Boeing', '737 MAX 8', 'narrow_body_jet', 6500, 189, 839, 4.300, 860.00, 121000000.00, 605000.00, 0.75),
('e0fc6835-0693-4782-99d2-a9386b4bd7d4', 'Boeing', '737 MAX 9', 'narrow_body_jet', 6500, 220, 839, 4.600, 920.00, 128000000.00, 640000.00, 1.5),
('d20545c9-a590-41f1-b162-7c57f6a0525c', 'Boeing', '737-500', 'narrow_body_jet', 4400, 132, 838, 4.100, 700.00, 62000000.00, 310000.00, 0.75),
('3af8d69c-0749-431b-85a8-8cf53fbc886a', 'Boeing', '737-600', 'narrow_body_jet', 5600, 123, 838, 4.200, 760.00, 76000000.00, 380000.00, 0.75),
('3c41ea04-7af5-465c-8f57-ee0dc909e694', 'Boeing', '737-700', 'narrow_body_jet', 6000, 149, 838, 4.600, 820.00, 89000000.00, 445000.00, 0.75),
('c5aa3099-5cee-4f6c-8d70-fd6985cf28b3', 'Boeing', '737-800', 'narrow_body_jet', 5700, 189, 838, 5.100, 910.00, 106000000.00, 530000.00, 0.75),
('ceba991f-0734-47b8-8dfe-b58c02fa5c3a', 'Boeing', '737-900ER', 'narrow_body_jet', 5400, 215, 838, 5.500, 980.00, 112000000.00, 560000.00, 1.5),
('fc87eaf5-2b92-45f9-b278-5cc58d2c556b', 'Boeing', '747-8', 'wide_body_jet', 14815, 467, 988, 12.500, 3800.00, 418000000.00, 2090000.00, 2.0),
('dbe706de-a8ae-4d7d-998d-5e7c0a201912', 'Boeing', '757-200', 'narrow_body_jet', 7200, 239, 850, 6.800, 1100.00, 115000000.00, 575000.00, 1.5),
('5b9298b0-4086-4cda-8e8b-ec826fb88f26', 'Boeing', '757-300', 'narrow_body_jet', 6290, 280, 850, 7.300, 1250.00, 130000000.00, 650000.00, 1.5),
('7e9488e9-e20f-4ad7-b4f8-8178de434b9b', 'Boeing', '767-300ER', 'wide_body_jet', 11000, 269, 850, 9.200, 1600.00, 201000000.00, 1005000.00, 1.5),
('d667c21d-f842-4fa1-88a5-462eec5bfce5', 'Boeing', '767-400ER', 'wide_body_jet', 10418, 304, 851, 9.800, 1750.00, 230000000.00, 1150000.00, 1.5),
('5667839c-0c6b-4fcc-975d-fd64d46e83f1', 'Boeing', '777-200ER', 'wide_body_jet', 14305, 314, 905, 11.400, 2400.00, 306000000.00, 1530000.00, 1.5),
('934135b4-bd60-4c67-a36f-a4fee084d461', 'Boeing', '777-200LR', 'wide_body_jet', 15840, 317, 905, 11.200, 2300.00, 346000000.00, 1730000.00, 1.5),
('b9f3c715-369a-4d2e-a3d3-cd3fa253c409', 'Boeing', '777-300', 'wide_body_jet', 11390, 368, 905, 11.600, 2500.00, 330000000.00, 1650000.00, 2.0),
('5e618c66-b752-4600-835e-62c709aee009', 'Boeing', '777-300ER', 'wide_body_jet', 13650, 396, 905, 12.000, 2600.00, 375000000.00, 1875000.00, 2.0),
('44a636d8-a785-49db-9333-650a1bf466b1', 'Boeing', '777-8', 'wide_body_jet', 16170, 384, 905, 10.100, 2550.00, 410000000.00, 2050000.00, 2.0),
('a7526554-7591-4363-a747-8f39766296b1', 'Boeing', '777-9', 'wide_body_jet', 13500, 426, 905, 10.500, 2700.00, 442000000.00, 2210000.00, 2.0),
('4cf3e59a-df46-4838-85e1-472d0bff63b8', 'Boeing', '787-10', 'wide_body_jet', 11910, 330, 903, 8.400, 2000.00, 338000000.00, 1690000.00, 1.5),
('2325ddf7-eb8a-43d4-bc49-7e33652ec419', 'Boeing', '787-8', 'wide_body_jet', 13600, 242, 903, 7.200, 1700.00, 248000000.00, 1240000.00, 1.5),
('fd6d09ee-78ec-412b-b1d2-f269eb02b4bb', 'Boeing', '787-9', 'wide_body_jet', 14140, 290, 903, 7.800, 1850.00, 292000000.00, 1460000.00, 1.5),
('a2f435d0-bcc1-4bd0-8786-37fd88ec3c6b', 'Airbus', 'A220-100', 'narrow_body_jet', 6300, 120, 829, 3.200, 620.00, 81000000.00, 400000.00, 0.75),
('2f2f243e-757a-4558-a99c-68b8de231ae4', 'Airbus', 'A220-300', 'narrow_body_jet', 6200, 140, 829, 3.500, 680.00, 91000000.00, 450000.00, 0.75),
('5557aa74-6c13-408b-8446-fe8fe8c487f7', 'Airbus', 'A318-100', 'narrow_body_jet', 5700, 107, 840, 4.600, 700.00, 75000000.00, 350000.00, 0.75),
('020b080b-2088-42bc-b1df-798635b7a841', 'Airbus', 'A319ceo', 'narrow_body_jet', 6900, 134, 840, 4.800, 800.00, 92000000.00, 460000.00, 0.75),
('fdff06c8-5e6a-4411-8bc3-2bdc2a86a31b', 'Airbus', 'A319neo', 'narrow_body_jet', 7300, 140, 830, 4.000, 750.00, 102000000.00, 510000.00, 0.75),
('621f0c84-5b3c-4256-90d9-f968ce095bb8', 'Airbus', 'A320ceo', 'narrow_body_jet', 6100, 180, 840, 5.200, 900.00, 101000000.00, 500000.00, 0.75),
('3eb6f0d7-786f-4c58-969a-a4e88b3bbaf5', 'Airbus', 'A320neo', 'narrow_body_jet', 6500, 186, 833, 4.160, 820.00, 111000000.00, 550000.00, 0.75),
('ff815f3c-5d09-4721-b022-c24fd1bf193d', 'Airbus', 'A321ceo', 'narrow_body_jet', 5900, 220, 840, 5.800, 1000.00, 118000000.00, 590000.00, 1.5),
('87cab660-27fc-4d3c-a30f-405b20bd28f7', 'Airbus', 'A321LR', 'narrow_body_jet', 7400, 206, 833, 4.600, 950.00, 135000000.00, 675000.00, 1.5),
('c72cd29d-7ad5-478b-bff6-e40426bb9c8b', 'Airbus', 'A321neo', 'narrow_body_jet', 7400, 230, 833, 4.640, 920.00, 129000000.00, 645000.00, 1.5),
('f9e139ad-5c50-4189-b264-00e4b63a2bbc', 'Airbus', 'A321XLR', 'narrow_body_jet', 8700, 200, 833, 4.700, 980.00, 142000000.00, 710000.00, 0.75),
('0a396c51-df9e-4326-8388-562b64c9ca8a', 'Airbus', 'A330-200', 'wide_body_jet', 13400, 293, 871, 9.800, 1800.00, 238000000.00, 1190000.00, 1.5),
('07f69bf9-1acf-4e25-aefa-7d0d345eeee2', 'Airbus', 'A330-300', 'wide_body_jet', 11750, 335, 871, 10.400, 1900.00, 264000000.00, 1320000.00, 1.5),
('2808219d-aff6-4fa0-8138-f41ba631ff87', 'Airbus', 'A330-800neo', 'wide_body_jet', 15094, 257, 860, 7.600, 1550.00, 260000000.00, 1300000.00, 1.5),
('f5a8065b-7220-4219-ae1b-7a0b76b77b33', 'Airbus', 'A330-900neo', 'wide_body_jet', 13330, 310, 860, 8.200, 1650.00, 296000000.00, 1480000.00, 1.5),
('7707d3c9-46c6-46e1-ae8b-bdf17b2f1263', 'Airbus', 'A350-1000', 'wide_body_jet', 16100, 410, 903, 9.600, 2400.00, 366000000.00, 1830000.00, 2.0),
('9de9d24a-ae31-41a5-bfad-36c4cb65d422', 'Airbus', 'A350-900', 'wide_body_jet', 15000, 350, 903, 8.500, 2100.00, 317000000.00, 1585000.00, 1.5),
('9dd9a7d5-34fd-4df0-9785-99b57a805303', 'Airbus', 'A380-800', 'wide_body_jet', 15200, 525, 903, 17.500, 4200.00, 445000000.00, 2225000.00, 2.0),
('9d48d3c9-f9aa-4820-becb-44529fdb0dac', 'COMAC', 'ARJ21-700', 'regional_jet', 3700, 90, 820, 4.900, 620.00, 38000000.00, 190000.00, 0.75),
('50357494-e829-4faa-84ab-85e7764a905e', 'ATR', 'ATR 42-500', 'regional_turboprop', 1200, 48, 550, 2.200, 360.00, 14000000.00, 70000.00, 0.5),
('f0ef484a-8a57-43c6-8d4a-105c91013c58', 'ATR', 'ATR 42-600', 'regional_turboprop', 1300, 48, 550, 2.100, 350.00, 16000000.00, 80000.00, 0.5),
('17699039-6b61-4b1e-a53b-33817fc8ceae', 'ATR', 'ATR 72-500', 'regional_turboprop', 1520, 70, 510, 2.700, 380.00, 22000000.00, 110000.00, 0.5),
('b1a09fff-c89f-420b-ba9b-a7a88ee511b5', 'ATR', 'ATR 72-600', 'regional_turboprop', 1500, 72, 510, 2.500, 400.00, 26000000.00, 130000.00, 0.5),
('018b74c7-c338-43e1-ae3f-8abd5d31b5f0', 'CASA', 'C-212 Aviocar', 'regional_turboprop', 800, 26, 360, 1.600, 200.00, 8000000.00, 40000.00, 0.5),
('92d332df-8704-4ecc-bc43-428242895e3e', 'COMAC', 'C919', 'narrow_body_jet', 5550, 168, 830, 4.700, 840.00, 99000000.00, 495000.00, 0.75),
('d80e73be-7b9c-4806-a5fb-d4e9dbb5ec20', 'Bombardier', 'CRJ-1000', 'regional_jet', 3000, 104, 830, 5.000, 720.00, 51000000.00, 255000.00, 0.75),
('95db8bcd-8c3f-4c56-be30-1d53085288e6', 'Bombardier', 'CRJ-550', 'regional_jet', 3000, 50, 829, 3.900, 520.00, 34000000.00, 170000.00, 0.5),
('f410622e-823e-42bf-9eea-ee9403bae8d8', 'Bombardier', 'CRJ-700', 'regional_jet', 2500, 70, 830, 4.300, 580.00, 40000000.00, 200000.00, 0.5),
('5781a5a6-eba5-41ae-a5b6-b3c42d9db31b', 'Bombardier', 'CRJ-900', 'regional_jet', 2800, 90, 830, 4.700, 650.00, 48000000.00, 240000.00, 0.75),
('04ea6635-5dd1-4619-9599-43d886b294c2', 'Bombardier', 'Dash 8 Q300', 'regional_turboprop', 1500, 50, 530, 2.000, 320.00, 18000000.00, 90000.00, 0.5),
('a8cf2c1c-7b88-4f70-a2ad-2ad12728876b', 'De Havilland', 'Dash 8 Q400', 'regional_turboprop', 2000, 78, 667, 3.200, 450.00, 32000000.00, 160000.00, 0.5),
('64fb5d43-dcb7-424d-b8a9-4bcd4fae0df1', 'Embraer', 'E170', 'regional_jet', 3900, 70, 829, 4.000, 560.00, 41000000.00, 205000.00, 0.5),
('6f6cd414-d681-4ced-9ee2-968827ddc189', 'Embraer', 'E175', 'regional_jet', 3700, 76, 829, 4.200, 600.00, 45000000.00, 220000.00, 0.5),
('3339825c-6f3a-4b15-95ad-089bfafc6e02', 'Embraer', 'E175-E2', 'regional_jet', 5000, 90, 830, 3.800, 620.00, 57000000.00, 285000.00, 0.75),
('9eab6c2a-4143-44e0-b121-b8e4dd5cdcf0', 'Embraer', 'E190', 'regional_jet', 4500, 100, 829, 4.800, 700.00, 52000000.00, 260000.00, 0.75),
('af62ddae-a9f7-474e-99ba-217ad7b07f7d', 'Embraer', 'E190-E2', 'regional_jet', 5200, 106, 830, 4.000, 650.00, 60000000.00, 300000.00, 0.75),
('352b5a57-c65c-487f-bf7b-fc5a0f4e753b', 'Embraer', 'E195', 'regional_jet', 4200, 116, 829, 5.200, 750.00, 55000000.00, 275000.00, 0.75),
('e7f463bd-3787-45b1-99cb-fd4e8c0f764a', 'Embraer', 'E195-E1', 'regional_jet', 4200, 118, 829, 5.100, 740.00, 53000000.00, 265000.00, 0.75),
('52239b86-5fe3-4eb8-a3e3-c2851d9c105f', 'Embraer', 'E195-E2', 'regional_jet', 4800, 132, 830, 4.400, 700.00, 65000000.00, 325000.00, 0.75),
('990a73ae-1168-4cda-a855-f6a11ba03d63', 'Irkut', 'MC-21-300', 'narrow_body_jet', 6000, 211, 850, 4.900, 880.00, 95000000.00, 475000.00, 1.5),
('9bd7f800-d355-42c2-bbef-a0f27c89043a', 'Sukhoi', 'Superjet SSJ-100', 'regional_jet', 4400, 98, 830, 4.800, 640.00, 35000000.00, 175000.00, 0.75)
ON CONFLICT (model_name) DO NOTHING;

-- ---------- game_config (21 rows) ----------
INSERT INTO public.game_config (key, value, category, unit, description)
VALUES
('absolute_minimum_safety_limit', '30.00'::jsonb, 'simulation', NULL, 'Minimum aircraft condition to fly'),
('bank_txn_raw_retention_days', '180'::jsonb, 'ops', 'game_days', 'Retention for raw bank transactions before compaction'),
('bankruptcy_cash_threshold', '-5000000.0'::jsonb, 'simulation', NULL, 'Cash level that triggers bankruptcy'),
('base_lease_deposit_percentage', '0.10'::jsonb, 'simulation', NULL, 'Lease deposit as fraction of monthly rent'),
('credit_tier_config', '{"Gold": {"max": 799, "min": 650, "rate": 0.05}, "Silver": {"max": 649, "min": 500, "rate": 0.08}, "Platinum": {"max": 1000, "min": 800, "rate": 0.03}, "Standard": {"max": 499, "min": 0, "rate": 0.12}}'::jsonb, 'finance', NULL, 'Credit tier thresholds and rates'),
('crew_cost_per_hour', '350.0'::jsonb, 'simulation', NULL, 'Crew cost per flight hour'),
('database_critical_mb', '425'::jsonb, 'ops', 'megabytes', 'Database size critical threshold'),
('database_free_quota_mb', '500'::jsonb, 'ops', 'megabytes', 'Database free quota'),
('database_warn_mb', '350'::jsonb, 'ops', 'megabytes', 'Database size warning threshold'),
('fuel_price_per_liter', '0.85'::jsonb, 'simulation', NULL, 'Base fuel price'),
('leased_wear_per_flight_cycle', '0.70'::jsonb, 'simulation', NULL, 'Base wear per flight cycle for leased aircraft'),
('maintenance_auto_repair_rate', '0.85'::jsonb, 'simulation', NULL, 'Auto-repair recovery rate per hour'),
('max_airport_demand_factor', '1.0'::jsonb, 'simulation', NULL, 'Maximum airport demand multiplier'),
('max_bot_count', '5'::jsonb, 'simulation', NULL, 'Maximum AI competitors'),
('max_weekly_flights', '168'::jsonb, 'simulation', NULL, 'Maximum flights per week (24h * 7d)'),
('min_airport_demand_factor', '0.55'::jsonb, 'simulation', NULL, 'Minimum airport demand multiplier'),
('owned_wear_per_flight_cycle', '0.50'::jsonb, 'simulation', NULL, 'Base wear per flight cycle for owned aircraft'),
('starting_cash', '15000000.00'::jsonb, 'simulation', NULL, 'Initial cash for new players'),
('ticket_base_fare', '50.0'::jsonb, 'simulation', NULL, 'Base fare formula: base + per_km * distance'),
('ticket_per_km_rate', '0.12'::jsonb, 'simulation', NULL, 'Per-km rate in fare formula'),
('world_tick_log_raw_real_days', '7'::jsonb, 'ops', 'real_days', 'Retention for raw world tick logs')
ON CONFLICT (key) DO NOTHING;

-- ---------- season_clock (1 row) ----------
INSERT INTO public.season_clock (id, label, current_game_time, last_tick_at, time_scale_multiplier, tick_interval_seconds, status, created_at, updated_at)
VALUES
('00000000-0000-4000-8000-000000000001', 'Season 1', '2026-11-01 07:00:00+00', '2026-06-25 08:46:00.01577+00', 60.00, 60, 'active', '2026-06-02 06:47:48.385274+00', '2026-06-25 08:46:00.01577+00')
ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- SECTION 10: Cron Jobs
-- ============================================================================
SELECT cron.schedule('skyward_world_tick', '* * * * *', 'SELECT ensure_world_current()');
SELECT cron.schedule('skyward_compact_bank_transactions', '30 3 * * *', 'SELECT compact_bank_transactions(false)');
SELECT cron.schedule('skyward_compact_world_tick_log', '30 3 * * *', 'SELECT compact_world_tick_log(false)');
