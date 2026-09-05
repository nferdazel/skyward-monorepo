-- ============================================================================
-- SKYWARD SECURITY PHASE 5: ROW-LEVEL SECURITY (RLS) & TENANT ISOLATION
-- ============================================================================
-- 1. Enable RLS on all public user-facing tables.
-- 2. Create RLS policies for tenant data isolation based on auth.uid().
-- 3. Create public read-only RLS policies for global game definitions.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ENABLE ROW-LEVEL SECURITY ON PUBLIC TABLES
-- ----------------------------------------------------------------------------

ALTER TABLE IF EXISTS public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.bank_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.fleet_aircraft ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.route_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.loans ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.credit_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.credit_score_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.achievements ENABLE ROW LEVEL SECURITY;

ALTER TABLE IF EXISTS public.aircraft_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.airports ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.game_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.season_clock ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.bot_profiles ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 2. CREATE PUBLIC READ-ONLY POLICIES FOR GLOBAL GAME DEFINITIONS
-- ----------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'aircraft_models' AND policyname = 'Allow public read access on aircraft_models') THEN
    CREATE POLICY "Allow public read access on aircraft_models" ON public.aircraft_models FOR SELECT USING (true);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'airports' AND policyname = 'Allow public read access on airports') THEN
    CREATE POLICY "Allow public read access on airports" ON public.airports FOR SELECT USING (true);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'game_config' AND policyname = 'Allow public read access on game_config') THEN
    CREATE POLICY "Allow public read access on game_config" ON public.game_config FOR SELECT USING (true);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'season_clock' AND policyname = 'Allow public read access on season_clock') THEN
    CREATE POLICY "Allow public read access on season_clock" ON public.season_clock FOR SELECT USING (true);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'bot_profiles' AND policyname = 'Allow public read access on bot_profiles') THEN
    CREATE POLICY "Allow public read access on bot_profiles" ON public.bot_profiles FOR SELECT USING (true);
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 3. CREATE TENANT ISOLATION POLICIES FOR USER TABLES
-- ----------------------------------------------------------------------------

DO $$
BEGIN
  -- users table policy
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'Users can view their own profile or public leaderboard data') THEN
    CREATE POLICY "Users can view their own profile or public leaderboard data" ON public.users FOR SELECT USING (
      auth_user_id = auth.uid() OR auth.uid() IS NOT NULL
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'Users can update their own profile') THEN
    CREATE POLICY "Users can update their own profile" ON public.users FOR UPDATE USING (
      auth_user_id = auth.uid()
    );
  END IF;

  -- bank_accounts table policy
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'bank_accounts' AND policyname = 'Users can access their own bank accounts') THEN
    CREATE POLICY "Users can access their own bank accounts" ON public.bank_accounts FOR ALL USING (
      user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    );
  END IF;

  -- bank_transactions table policy
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'bank_transactions' AND policyname = 'Users can access their own transactions') THEN
    CREATE POLICY "Users can access their own transactions" ON public.bank_transactions FOR ALL USING (
      user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    );
  END IF;

  -- fleet_aircraft table policy
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'fleet_aircraft' AND policyname = 'Users can access their own fleet') THEN
    CREATE POLICY "Users can access their own fleet" ON public.fleet_aircraft FOR ALL USING (
      user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    );
  END IF;

  -- route_assignments table policy
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'route_assignments' AND policyname = 'Users can access their own route assignments') THEN
    CREATE POLICY "Users can access their own route assignments" ON public.route_assignments FOR ALL USING (
      user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    );
  END IF;

  -- loans table policy
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'loans' AND policyname = 'Users can access their own loans') THEN
    CREATE POLICY "Users can access their own loans" ON public.loans FOR ALL USING (
      user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    );
  END IF;

  -- credit_scores table policy
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'credit_scores' AND policyname = 'Users can view their own credit score') THEN
    CREATE POLICY "Users can view their own credit score" ON public.credit_scores FOR SELECT USING (
      user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    );
  END IF;

  -- credit_score_history table policy
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'credit_score_history' AND policyname = 'Users can view their own credit score history') THEN
    CREATE POLICY "Users can view their own credit score history" ON public.credit_score_history FOR SELECT USING (
      user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    );
  END IF;

  -- achievements table policy
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'achievements' AND policyname = 'Users can view their own achievements') THEN
    CREATE POLICY "Users can view their own achievements" ON public.achievements FOR SELECT USING (
      user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    );
  END IF;
END $$;
