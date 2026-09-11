-- 17_game_config_seed.sql — seed game_config untuk environment fresh
--
-- LATAR (AUDIT-10): tidak ada migrasi yang men-seed game_config, padahal
-- engine & worker membaca puluhan key (fuel/crew/wear/ticket/bot knobs/
-- credit_tier_config) via getConfigNum()/get_config_numeric(). Fresh env yang
-- hanya menjalankan migrasi akan senyap memakai default hardcoded Go — ekonomi
-- berbeda dari prod. (00_baseline.sql hanya schema; 09 & 11 men-seed 3 key.)
--
-- Nilai di bawah = SNAPSHOT LIVE PROD 2026-09-11 (`skyward` DB, 39 key),
-- diambil via pg_dump --data-only. updated_at diisi default now().
-- ON CONFLICT DO NOTHING: environment yang sudah punya baris (mis. prod)
-- tidak diubah.
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

INSERT INTO game_config (key, value, category, unit, description) VALUES ('absolute_minimum_safety_limit', '30.00', 'simulation', NULL, 'Minimum aircraft condition to fly')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bank_txn_raw_retention_game_days', '180', 'ops', 'game_days', 'Retention for raw bank transactions before prune')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bankruptcy_cash_threshold', '-5000000.0', 'simulation', NULL, 'Cash level that triggers bankruptcy')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bankruptcy_negative_days_threshold', '30', 'simulation', 'days', 'Consecutive negative-balance days before automatic bankruptcy')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('base_lease_deposit_percentage', '0.10', 'simulation', NULL, 'Lease deposit as fraction of monthly rent')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bot_consecutive_loss_days_threshold', '7', 'simulation', 'game_days', 'Days of consecutive route loss before bot deletes the route')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bot_distress_cash_threshold', '3000000', 'simulation', 'currency', 'Cash level below which a bot enters distress-mode route trimming')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bot_fleet_diversity_chance', '0.30', 'simulation', 'ratio', 'Chance of bot using alternative aircraft model')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bot_loan_repayment_ratio', '0.20', 'simulation', 'ratio', 'Max ratio of loan balance to repay per action')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bot_purchase_cash_multiplier', '1.5', 'simulation', 'multiplier', 'Bot cash must be > starting_cash * this to purchase aircraft')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bot_recovery_loan_amount', '2000000', 'simulation', 'currency', 'Loan amount for desperate bot recovery')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bot_repair_cash_reserve', '500000', 'simulation', 'currency', 'Minimum cash reserve a bot keeps after repairing an aircraft')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bot_route_optimization_cooldown_hours', '24', 'simulation', 'hours', 'Hours between bot route optimization attempts')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bot_secondary_hub_chance', '0.20', 'simulation', 'ratio', 'Chance of bot using secondary hub for new route')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('cargo_revenue_percentage', '0.05', 'simulation', 'ratio', 'Fraction of ticket revenue attributed to ancillary cargo income')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('credit_tier_config', '{"Gold": {"max": 819, "min": 660, "rate": 0.05, "max_secured": 75000000, "rate_secured": 0.04, "max_unsecured": 10000000, "rate_unsecured": 0.05}, "Silver": {"max": 659, "min": 520, "rate": 0.08, "max_secured": 45000000, "rate_secured": 0.06, "max_unsecured": 7000000, "rate_unsecured": 0.08}, "Platinum": {"max": 1000, "min": 820, "rate": 0.03, "max_secured": 120000000, "rate_secured": 0.02, "max_unsecured": 15000000, "rate_unsecured": 0.03}, "Standard": {"max": 519, "min": 0, "rate": 0.12, "max_secured": 25000000, "rate_secured": 0.10, "max_unsecured": 5000000, "rate_unsecured": 0.12}, "min_loan": 100000, "max_active_loans": 3}', 'finance', NULL, 'Credit tier thresholds and rates')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('crew_cost_per_hour', '350.0', 'simulation', NULL, 'Crew cost per flight hour')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('database_critical_mb', '425', 'ops', 'megabytes', 'Database size critical threshold')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('database_free_quota_mb', '500', 'ops', 'megabytes', 'Database free quota')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('database_warn_mb', '350', 'ops', 'megabytes', 'Database size warning threshold')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('fuel_price_per_liter', '0.85', 'simulation', NULL, 'Base fuel price')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('leased_wear_per_flight_cycle', '0.70', 'simulation', NULL, 'Base wear per flight cycle for leased aircraft')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('maintenance_auto_repair_rate', '0.85', 'simulation', NULL, 'Auto-repair recovery rate per hour')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('max_airport_demand_factor', '1.0', 'simulation', NULL, 'Maximum airport demand multiplier')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('max_bot_count', '5', 'simulation', NULL, 'Maximum AI competitors')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('max_weekly_flights', '168', 'simulation', NULL, 'Maximum flights per week (24h * 7d)')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('min_airport_demand_factor', '0.55', 'simulation', NULL, 'Minimum airport demand multiplier')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('owned_wear_per_flight_cycle', '0.50', 'simulation', NULL, 'Base wear per flight cycle for owned aircraft')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('ticket_base_fare', '50.0', 'simulation', NULL, 'Base fare formula: base + per_km * distance')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('ticket_per_km_rate', '0.12', 'simulation', NULL, 'Per-km rate in fare formula')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('world_tick_log_raw_real_days', '7', 'ops', 'real_days', 'Retention for raw world tick logs')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('demand_pool_scale', '290.0', 'simulation', 'passengers', 'GAME-02: scale factor for a route''s fixed daily passenger demand pool. The pool is split across the player''s flights on that route.')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('starting_cash', '25000000', 'simulation', NULL, 'Initial cash for new players')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('bot_competitive_price_threshold', '0.08', 'simulation', 'ratio', 'Price deviation ratio before bot responds to competitor pricing')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('business_fare_multiplier', '1.5', 'simulation', 'multiplier', 'GAME-03: business-class fare as a multiple of the route economy ticket price.')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('first_fare_multiplier', '2.5', 'simulation', 'multiplier', 'GAME-03: first-class fare as a multiple of the route economy ticket price.')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('economy_willing_share', '0.80', 'simulation', 'ratio', 'GAME-03: share of the demand pool willing to travel economy.')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('business_willing_share', '0.15', 'simulation', 'ratio', 'GAME-03: share of the demand pool willing to pay for business class.')
  ON CONFLICT (key) DO NOTHING;
INSERT INTO game_config (key, value, category, unit, description) VALUES ('first_willing_share', '0.05', 'simulation', 'ratio', 'GAME-03: share of the demand pool willing to pay for first class.')
  ON CONFLICT (key) DO NOTHING;

COMMIT;
