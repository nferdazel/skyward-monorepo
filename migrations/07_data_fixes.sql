-- ============================================================================
-- Migration 07: Data Fixes
-- ============================================================================
-- Fixes:
--   L3:  Achievement threshold calibration (TODO — no change, documented)
--   L13: Bot name collision risk — expand generate_company_name pools
--   L14: credit_score_history sub-score backfill
-- ============================================================================

-- ============================================================================
-- FIX 1 (L3): Achievement recalibration
-- ============================================================================
-- After the bot 168x inflation fix (migration 04), bot balances are much
-- lower. The current achievement thresholds in check_achievements are:
--
--   millionaire:        net_worth >= 1,000,000
--   multi_millionaire:  net_worth >= 10,000,000
--   hundred_million:    net_worth >= 100,000,000
--   billionaire:        net_worth >= 1,000,000,000
--
-- These thresholds appear reasonable for a game with $15M starting cash.
-- No change applied. Marked as TODO for future review after observing
-- post-inflation-fix player progression.
-- TODO: Revisit thresholds once real player data stabilises.
-- ============================================================================


-- ============================================================================
-- FIX 2 (L13): Bot name collision risk
-- ============================================================================
-- Expand the prefix/suffix pools in generate_company_name to reduce the
-- probability of duplicate company names when spawning bots.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.generate_company_name(p_archetype character varying)
RETURNS character varying
LANGUAGE plpgsql
AS $function$
DECLARE
    v_prefixes TEXT[] := ARRAY[
        'Pacific', 'Atlas', 'Eagle', 'Nova', 'Apex', 'Summit', 'Horizon', 'Zenith',
        'Sterling', 'Phoenix', 'Titan', 'Vanguard', 'Sovereign', 'Pinnacle', 'Crest',
        'Falcon', 'Meridian', 'Aurora', 'Comet', 'Star', 'Sky', 'Air', 'Jet', 'Swift',
        'Thunder', 'Lightning', 'Cyclone', 'Tornado', 'Tempest', 'Storm', 'Blaze',
        'Ember', 'Radiant', 'Golden', 'Silver', 'Diamond', 'Crystal', 'Sapphire',
        'Ruby', 'Emerald', 'Coral', 'Ocean', 'Mountain', 'River', 'Valley', 'Forest',
        'Canyon', 'Glacier', 'Island', 'Harbor', 'Coast', 'Ridge', 'Peak'
    ];
    v_suffixes TEXT[] := ARRAY[
        'Airways', 'Air', 'Airlines', 'Aviation', 'Air Lines', 'Express', 'Air Services',
        'Air Group', 'Air Corp', 'Air Transport', 'Air Link', 'Air Connect', 'Air Wing'
    ];
    v_regional_suffixes TEXT[] := ARRAY[
        'Regional', 'Air Express', 'Commuter', 'Air Link', 'Connect',
        'Air Shuttle', 'Air Taxi', 'Air Service', 'Air Bridge'
    ];
    v_premium_suffixes TEXT[] := ARRAY[
        'International', 'World', 'Global', 'Airways International', 'Premium',
        'Worldwide', 'Continental', 'Transcontinental', 'Intercontinental'
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


-- ============================================================================
-- FIX 3 (L14): credit_score_history sub-score backfill
-- ============================================================================
-- Historical rows in credit_score_history were recorded with all five
-- sub-scores defaulting to 0. Backfill them from the current credit_scores
-- table so the history view shows meaningful component breakdowns.
--
-- Idempotent: the WHERE clause only touches rows where ALL sub-scores are 0,
-- so re-running this migration is safe.
-- ============================================================================

UPDATE credit_score_history csh
SET
    fleet_health_score      = COALESCE(cs.fleet_health_score, 0),
    revenue_stability_score = COALESCE(cs.revenue_stability_score, 0),
    debt_ratio_score        = COALESCE(cs.debt_ratio_score, 0),
    cash_reserves_score     = COALESCE(cs.cash_reserves_score, 0),
    profit_history_score    = COALESCE(cs.profit_history_score, 0)
FROM credit_scores cs
WHERE csh.user_id = cs.user_id
  AND csh.fleet_health_score      = 0
  AND csh.revenue_stability_score = 0
  AND csh.debt_ratio_score        = 0
  AND csh.cash_reserves_score     = 0
  AND csh.profit_history_score    = 0;
