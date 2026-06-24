-- ============================================================================
-- Migration 138: Human-Like Bot Naming
-- ============================================================================
-- Problem:
--   Bot names are ugly and obviously robotic: "CEO bot_0f9670f4",
--   "Regional Airways a3f2". They break immersion.
--
-- Fix:
--   1. generate_ceo_name() — random realistic international CEO name
--   2. generate_company_name(archetype) — airline company name per archetype
--   3. Update spawn_bot() to use new naming functions
--   4. Retroactively fix all existing bots with ugly names
-- ============================================================================

BEGIN;


-- ============================================================================
-- Part 1: generate_ceo_name() — Realistic international CEO names
-- ============================================================================

CREATE OR REPLACE FUNCTION public.generate_ceo_name()
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
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
$$;


-- ============================================================================
-- Part 2: generate_company_name(archetype) — Airline company names
-- ============================================================================

CREATE OR REPLACE FUNCTION public.generate_company_name(p_archetype VARCHAR)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
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
$$;


-- ============================================================================
-- Part 3: Update spawn_bot() to use new naming functions
-- ============================================================================

CREATE OR REPLACE FUNCTION public.spawn_bot()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_bot_id UUID;
    v_archetype VARCHAR(30);
    v_hq VARCHAR(3);
    v_bot_count INT;
    v_max_bots INT;
    v_username VARCHAR(50);
    v_ceo_name VARCHAR(100);
    v_company_name VARCHAR(100);
    v_game_time TIMESTAMPTZ;
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
    v_company_name := generate_company_name(v_archetype);

    -- Create bot user
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

    -- Create bot profile with archetype
    INSERT INTO bot_profiles (user_id, archetype)
    VALUES (v_bot_id, v_archetype);

    RAISE NOTICE 'Spawned bot "%" (CEO: %, Archetype: %, HQ: %)', v_company_name, v_ceo_name, v_archetype, v_hq;
    RETURN v_bot_id;
END;
$$;


-- ============================================================================
-- Part 4: Fix existing bots with ugly names
-- ============================================================================
-- Match bots that have:
--   - NULL or empty company_name
--   - company_name containing 'bot_' pattern (from old "Regional Airways a3f2")
--   - ceo_name starting with 'CEO bot_' (the old pattern)
--   - ceo_name that is NULL or empty

UPDATE users u
SET
    company_name = generate_company_name(COALESCE(bp.archetype, 'Balanced')),
    ceo_name     = generate_ceo_name()
FROM bot_profiles bp
WHERE u.actor_type = 'AI'
  AND bp.user_id = u.id
  AND (
      -- NULL or empty names
      u.company_name IS NULL
      OR u.company_name = ''
      OR u.ceo_name IS NULL
      OR u.ceo_name = ''
      -- Old-style bot names containing "bot_"
      OR u.company_name LIKE '%bot_%'
      OR u.ceo_name LIKE '%bot_%'
      -- Old-style "CEO bot_xxxx" pattern
      OR u.ceo_name LIKE 'CEO %'
      -- Names with trailing numeric suffixes like "Atlas Airway 889"
      OR u.company_name ~ '\d{3,}$'
  );

-- Also fix any bots with NULL usernames
UPDATE users
SET username = 'bot_' || left(gen_random_uuid()::text, 8)
WHERE actor_type = 'AI'
  AND username IS NULL;


COMMIT;


-- ============================================================================
-- Verification
-- ============================================================================

-- SELECT username, company_name, ceo_name, actor_type
-- FROM users
-- WHERE actor_type = 'AI'
-- ORDER BY company_name;
