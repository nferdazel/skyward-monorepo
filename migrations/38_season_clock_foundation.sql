-- ============================================================================
-- SKYWARD PHASE 2 SEASON CLOCK FOUNDATION
-- ============================================================================
-- Introduces a shared season clock without changing runtime authority yet.
-- Existing player/bot actor clocks remain active for compatibility until the
-- world-tick engine is introduced in the next phase.
-- ============================================================================

CREATE TABLE IF NOT EXISTS season_clock (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label VARCHAR(80) NOT NULL,
    current_game_time TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT TIMESTAMP WITH TIME ZONE '2020-01-01 00:00:00+00',
    last_tick_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    time_scale_multiplier NUMERIC(10,2) NOT NULL DEFAULT 60.00,
    tick_interval_seconds INT NOT NULL DEFAULT 60 CHECK (tick_interval_seconds > 0),
    status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('draft', 'active', 'paused', 'completed')),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS season_clock_one_active_idx
ON season_clock ((status))
WHERE status = 'active';

INSERT INTO season_clock (
    id,
    label,
    current_game_time,
    last_tick_at,
    time_scale_multiplier,
    tick_interval_seconds,
    status
)
SELECT
    '00000000-0000-4000-8000-000000000001'::UUID,
    'Season 1',
    TIMESTAMP WITH TIME ZONE '2020-01-01 00:00:00+00',
    NOW(),
    COALESCE((SELECT time_scale_multiplier FROM global_game_settings LIMIT 1), 60.00),
    60,
    'active'
WHERE NOT EXISTS (
    SELECT 1
    FROM season_clock
    WHERE status = 'active'
);

ALTER TABLE users
ADD COLUMN IF NOT EXISTS season_id UUID REFERENCES season_clock(id);

ALTER TABLE ai_competitors
ADD COLUMN IF NOT EXISTS season_id UUID REFERENCES season_clock(id);

UPDATE users
SET season_id = (
    SELECT id
    FROM season_clock
    WHERE status = 'active'
    ORDER BY created_at ASC
    LIMIT 1
)
WHERE season_id IS NULL;

UPDATE ai_competitors
SET season_id = (
    SELECT id
    FROM season_clock
    WHERE status = 'active'
    ORDER BY created_at ASC
    LIMIT 1
)
WHERE season_id IS NULL;

CREATE INDEX IF NOT EXISTS users_season_id_idx
ON users(season_id);

CREATE INDEX IF NOT EXISTS ai_competitors_season_id_idx
ON ai_competitors(season_id);

CREATE OR REPLACE FUNCTION assign_active_season_id()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.season_id IS NULL THEN
        SELECT id
        INTO NEW.season_id
        FROM season_clock
        WHERE status = 'active'
        ORDER BY created_at ASC
        LIMIT 1;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_users_assign_active_season_id ON users;
CREATE TRIGGER trg_users_assign_active_season_id
    BEFORE INSERT ON users
    FOR EACH ROW
    EXECUTE FUNCTION assign_active_season_id();

DROP TRIGGER IF EXISTS trg_ai_competitors_assign_active_season_id ON ai_competitors;
CREATE TRIGGER trg_ai_competitors_assign_active_season_id
    BEFORE INSERT ON ai_competitors
    FOR EACH ROW
    EXECUTE FUNCTION assign_active_season_id();

COMMENT ON TABLE season_clock IS
'Shared season clock foundation. Phase 2 only: actor game_current_time fields remain runtime authority until world ticking is introduced.';

COMMENT ON COLUMN season_clock.current_game_time IS
'Future authoritative season game time for world ticking. Not yet the source of runtime simulation truth in Phase 2.';

COMMENT ON COLUMN users.season_id IS
'Season membership for future shared-world simulation. users.game_current_time remains authoritative until later migration phases.';

COMMENT ON COLUMN ai_competitors.season_id IS
'Season membership for future shared-world simulation. ai_competitors.game_current_time remains authoritative until later migration phases.';
