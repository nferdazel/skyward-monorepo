-- ==========================================================
-- SKYWARD SIMULATION - HQ TAIL NUMBER PRESERVATION MIGRATION
-- ==========================================================

-- 1. Create helper to extract the randomized suffix from tail number
CREATE OR REPLACE FUNCTION get_tail_suffix(p_tail VARCHAR)
RETURNS VARCHAR AS $$
BEGIN
    IF position('-' in p_tail) > 0 THEN
        RETURN split_part(p_tail, '-', 2);
    ELSE
        -- Fallback to last 3 characters
        RETURN right(p_tail, 3);
    END IF;
END;
$$ LANGUAGE plpgsql;

-- 2. Retroactively fix any NULL or empty tail codes and names in user_fleet
UPDATE user_fleet SET nickname = replace(nickname, 'Leasing ', '') WHERE nickname LIKE 'Leasing %';

DO $$
DECLARE
    r RECORD;
    v_hq VARCHAR;
    v_tail VARCHAR;
BEGIN
    FOR r IN SELECT id, user_id, ai_competitor_id, tail_number FROM user_fleet WHERE tail_number IS NULL OR trim(tail_number) = '' LOOP
        IF r.user_id IS NOT NULL THEN
            SELECT COALESCE(hq_airport_iata, 'CGK') INTO v_hq FROM users WHERE id = r.user_id;
        ELSIF r.ai_competitor_id IS NOT NULL THEN
            SELECT COALESCE(hq_airport_iata, 'CGK') INTO v_hq FROM ai_competitors WHERE id = r.ai_competitor_id;
        ELSE
            v_hq := 'CGK';
        END IF;
        
        -- Generate unique tail number
        LOOP
            v_tail := generate_tail_number(v_hq);
            EXIT WHEN NOT EXISTS (SELECT 1 FROM user_fleet WHERE tail_number = v_tail);
        END LOOP;
        
        UPDATE user_fleet SET tail_number = v_tail WHERE id = r.id;
    END LOOP;
END;
$$;

-- 3. Set NOT NULL constraint on tail_number column
ALTER TABLE user_fleet ALTER COLUMN tail_number SET NOT NULL;

-- 4. Re-engineer HQ update trigger to preserve suffix (e.g. 9V-AAA -> PK-AAA)
CREATE OR REPLACE FUNCTION trg_sync_tail_numbers_on_hq_change()
RETURNS TRIGGER AS $$
DECLARE
    r_aircraft RECORD;
    v_prefix VARCHAR;
    v_suffix VARCHAR;
    v_new_tail VARCHAR;
BEGIN
    IF OLD.hq_airport_iata IS DISTINCT FROM NEW.hq_airport_iata THEN
        v_prefix := get_hq_prefix(NEW.hq_airport_iata);
        FOR r_aircraft IN SELECT id, tail_number FROM user_fleet WHERE user_id = NEW.id LOOP
            v_suffix := get_tail_suffix(r_aircraft.tail_number);
            v_new_tail := v_prefix || v_suffix;
            
            -- Ensure uniqueness if there is a collision (rare fallback)
            IF EXISTS (SELECT 1 FROM user_fleet WHERE tail_number = v_new_tail AND id != r_aircraft.id) THEN
                v_new_tail := generate_tail_number(NEW.hq_airport_iata);
            END IF;
            
            UPDATE user_fleet SET tail_number = v_new_tail WHERE id = r_aircraft.id;
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 5. Re-create the trigger on users
DROP TRIGGER IF EXISTS trg_user_hq_change ON users;
CREATE TRIGGER trg_user_hq_change
    AFTER UPDATE OF hq_airport_iata ON users
    FOR EACH ROW
    EXECUTE FUNCTION trg_sync_tail_numbers_on_hq_change();
