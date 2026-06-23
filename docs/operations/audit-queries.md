# Skyward Live Backend Audit Queries

Last verified on 2026-06-22.

Use these against your real Supabase project when you want to inspect simulation behavior without changing code.

## 1. Current user buffers and actor cursor

```sql
select
  id,
  username,
  company_name,
  cash,
  net_worth,
  game_current_time,
  season_id,
  buffered_revenue,
  buffered_ops_cost,
  buffered_lease_cost,
  auto_grounding_threshold
from users
where id = '<your_user_id>';
```

## 2. Fleet condition, status, and acquisition mix

```sql
select
  f.id,
  f.nickname,
  f.tail_number,
  f.acquisition_type,
  f.condition,
  f.status,
  m.manufacturer,
  m.model_name,
  m.speed_kmh,
  m.lease_price_per_month,
  m.purchase_price
from user_fleet f
join aircraft_models m on m.id = f.aircraft_model_id
where f.user_id = '<your_user_id>'
order by f.acquired_at desc;
```

## 3. Routes with maintenance-slot math inputs

```sql
select
  r.id,
  r.origin_iata,
  r.destination_iata,
  r.distance_km,
  r.flights_per_week,
  f.nickname,
  f.status,
  f.condition,
  f.acquisition_type,
  m.model_name,
  round((r.distance_km / nullif(m.speed_kmh, 0)) + 1.0, 3) as flight_cycle_hours,
  floor(168.0 / nullif(((r.distance_km / nullif(m.speed_kmh, 0)) + 1.0), 0)) as max_weekly_flights,
  greatest(
    0,
    floor(168.0 / nullif(((r.distance_km / nullif(m.speed_kmh, 0)) + 1.0), 0)) - r.flights_per_week
  ) as unused_slots
from user_routes r
join user_fleet f on f.id = r.assigned_aircraft_id
join aircraft_models m on m.id = f.aircraft_model_id
where r.user_id = '<your_user_id>'
order by r.created_at desc;
```

## 4. Recent ledger rows

```sql
select
  game_date,
  transaction_type,
  category,
  amount,
  description
from financial_ledger
where user_id = '<your_user_id>'
order by game_date desc, created_at desc
limit 30;
```

## 5. Grounded-aircraft exploit check

This should return zero rows. If it does not, you have grounded aircraft still assigned to active routes.

```sql
select
  r.id as route_id,
  r.origin_iata,
  r.destination_iata,
  f.id as fleet_id,
  f.nickname,
  f.condition,
  f.status
from user_routes r
join user_fleet f on f.id = r.assigned_aircraft_id
where r.user_id = '<your_user_id>'
  and (f.status = 'grounded' or f.condition < 40.00);
```

## 6. Before/after condition snapshot around a sync

Run this first:

```sql
select
  f.id,
  f.nickname,
  f.condition,
  f.status
from user_fleet f
where f.user_id = '<your_user_id>'
order by f.acquired_at desc;
```

Then trigger a sync from the app, or if you are intentionally auditing from SQL:

```sql
select * from process_simulation_delta('<your_user_id>');
```

Then run the snapshot again and compare condition deltas.

## 7. Maintenance-slot behavior on one route

Replace `<route_id>` with a real route:

```sql
select
  r.id,
  r.flights_per_week,
  f.condition,
  f.status,
  f.acquisition_type,
  round((r.distance_km / nullif(m.speed_kmh, 0)) + 1.0, 3) as cycle_hours,
  floor(168.0 / nullif(((r.distance_km / nullif(m.speed_kmh, 0)) + 1.0), 0)) as max_weekly_flights,
  case
    when f.acquisition_type = 'lease' then 0.70
    else 0.50
  end as gross_wear_per_cycle
from user_routes r
join user_fleet f on f.id = r.assigned_aircraft_id
join aircraft_models m on m.id = f.aircraft_model_id
where r.id = '<route_id>';
```

## 8. Reset-buffer sanity check

After a reset, all three should be zero.

```sql
select
  buffered_revenue,
  buffered_ops_cost,
  buffered_lease_cost
from users
where id = '<your_user_id>';
```

## 9. Leaderboard 30-day revenue cross-check for one bot

Use this to compare the leaderboard contract with realized bot ledger revenue.
Replace `<bot_id>` with the competitor id from `ai_competitors`.

```sql
select
  ai.id,
  ai.company_name,
  ai.game_current_time,
  coalesce((
    select sum(fl.amount)
    from financial_ledger fl
    where fl.ai_competitor_id = ai.id
      and fl.transaction_type = 'revenue'
      and fl.game_date >= ai.game_current_time - interval '30 days'
  ), 0.00) as realized_30d_revenue
from ai_competitors ai
where ai.id = '<bot_id>';
```

Then compare with:

```sql
select *
from get_global_leaderboard()
where id = '<bot_id>';
```

## 10. World-clock actor lag check for one player

Use this when a player reports that resumed game time did not reflect the shared
world clock. Replace `<your_user_id>` with the player id.

Inspect the player cursor against the season clock:

```sql
select
  u.id,
  u.company_name,
  u.game_current_time,
  s.current_game_time as season_game_time,
  extract(epoch from (s.current_game_time - u.game_current_time)) as lag_seconds
from users u
join season_clock s on s.id = u.season_id
where u.id = '<your_user_id>';
```

Force world-clock reconciliation for that player:

```sql
select *
from process_simulation_delta('<your_user_id>');
```

## 11. World-tick compaction audit

```sql
select *
from get_world_tick_log_compaction_report();
```

## 12. Ledger compaction audit

```sql
select *
from get_financial_ledger_compaction_report();
```

## 13. Owner optimizer check

```sql
select *
from get_owner_route_optimizer(
  '<your_user_id>',
  null,
  null,
  25,
  true,
  true
);
```

Then confirm the lag is zero or near-zero:

```sql
select
  u.id,
  u.game_current_time,
  s.current_game_time as season_game_time,
  extract(epoch from (s.current_game_time - u.game_current_time)) as lag_seconds
from users u
join season_clock s on s.id = u.season_id
where u.id = '<your_user_id>';
```

## 14. Season-clock foundation check

Use this after applying Phase 2 to confirm there is one active season and that
players/bots are linked to it.

```sql
select
  id,
  label,
  current_game_time,
  last_tick_at,
  time_scale_multiplier,
  tick_interval_seconds,
  status
from season_clock
order by created_at asc;
```

```sql
select
  count(*) filter (where season_id is null) as users_without_season,
  count(*) as total_users
from users;
```

```sql
select
  count(*) filter (where season_id is null) as bots_without_season,
  count(*) as total_bots
from ai_competitors;
```

## 15. World tick RPC foundation check

Use this after applying Phase 3 to confirm the scheduler-safe clock RPCs work.
This advances only `season_clock`, not player/bot actor clocks.

```sql
select *
from process_world_tick(null, 1);
```

Then inspect the tick log:

```sql
select
  season_id,
  started_at,
  finished_at,
  game_time_before,
  game_time_after,
  ticks_processed,
  real_seconds_processed,
  game_seconds_processed,
  players_processed,
  bots_processed,
  status,
  message
from world_tick_log
order by started_at desc
limit 10;
```

## 16. World tick scheduler health check

Use this after applying Phase 4 to confirm the pg_cron job exists and the season
clock is being ticked automatically. If this fails with `permission denied for
schema cron`, apply migration `41_fix_scheduler_health_permissions.sql`.

```sql
select *
from get_world_tick_scheduler_health();
```

Direct pg_cron check:

```sql
select
  jobid,
  jobname,
  schedule,
  active,
  command
from cron.job
where jobname = 'skyward_world_tick';
```

After waiting one or two minutes, inspect recent logs:

```sql
select
  started_at,
  game_time_before,
  game_time_after,
  ticks_processed,
  players_processed,
  bots_processed,
  status,
  message
from world_tick_log
order by started_at desc
limit 10;
```

## 17. World actor tick audit

Use this after applying Phase 5 to confirm actors are no longer lagging behind
the shared season clock.

If `process_world_tick` returns `column reference "season_id" is ambiguous`,
apply migration `43_fix_world_actor_tick_bootstrap.sql`.

```sql
select
  u.id,
  u.company_name,
  u.game_current_time,
  s.current_game_time as season_game_time,
  extract(epoch from (s.current_game_time - u.game_current_time)) as lag_seconds
from users u
join season_clock s on s.id = u.season_id
order by u.created_at asc;
```

```sql
select
  ai.company_name,
  ai.game_current_time,
  s.current_game_time as season_game_time,
  extract(epoch from (s.current_game_time - ai.game_current_time)) as lag_seconds
from ai_competitors ai
join season_clock s on s.id = ai.season_id
where ai.status != 'Bankrupt'
order by ai.company_name asc;
```

## 18. World-clock guardrail report

Use this after Phase 7/8/11-lite to catch common world-time regressions quickly.

```sql
select *
from get_world_tick_guardrail_report();
```

## 19. Phase 9 daily segmentation audit

Use this after applying Phase 9 to inspect whether recent multi-day catch-up
created ledger rows across game-day boundaries instead of only on the final day.

```sql
select
  user_id,
  ai_competitor_id,
  transaction_type,
  category,
  amount,
  game_date
from financial_ledger
where game_date >= current_date - interval '45 days'
order by game_date desc, created_at desc
limit 50;
```

```sql
select
  proname,
  obj_description(oid, 'pg_proc') as description
from pg_proc
where proname in (
  'process_player_simulation_to_time',
  'process_player_simulation_segment',
  'process_all_bots_simulation_to_time',
  'process_all_bots_simulation_segment'
)
order by proname;
```

## 20. Free-tier database size audit

Use this after applying Phase 12/13 to inspect Supabase Free database-size risk.
If `get_table_size_report()` fails with extension-schema permission errors,
apply migration `47_fix_table_size_report_permissions.sql`.

```sql
select *
from get_database_size_report();
```

```sql
select *
from get_table_size_report()
limit 20;
```

```sql
select *
from data_retention_policy
order by key;
```

## 21. Active game events check

Use this to inspect currently active world events that may be affecting
simulation economics.

```sql
select
  event_type,
  title,
  effect_type,
  effect_target,
  effect_value,
  start_game_time,
  end_game_time
from game_events
where is_active = true
order by start_game_time desc;
```

## 22. Financial snapshots trend check

Use this to inspect daily financial trends for a player.

```sql
select
  game_date,
  cash,
  net_worth,
  daily_revenue,
  daily_expense,
  fleet_count,
  route_count
from financial_snapshots
where user_id = '<your_user_id>'
order by game_date desc
limit 30;
```

## 23. Hub bonus and congestion check

Inspect the hub bonus and congestion factor for a specific airport:

```sql
select
  get_hub_bonus_percentage('CGK', '<your_user_id>') as hub_bonus_pct,
  calculate_airport_congestion_factor('CGK') as congestion_factor;
```

## 24. Maintenance milestone audit

Check which aircraft are overdue for A-check or C-check:

```sql
select
  f.id,
  f.nickname,
  f.tail_number,
  f.condition,
  f.total_flights,
  f.last_a_check_at,
  f.last_c_check_at,
  CASE WHEN f.total_flights >= f.last_a_check_at + 500 THEN 'OVERDUE' ELSE 'ok' END as a_check_status,
  CASE WHEN f.total_flights >= f.last_c_check_at + 3000 THEN 'OVERDUE' ELSE 'ok' END as c_check_status
from user_fleet f
where f.user_id = '<your_user_id>'
  AND f.status = 'active'
  AND (f.total_flights >= f.last_a_check_at + 500
    OR f.total_flights >= f.last_c_check_at + 3000);
```

## 25. Cargo revenue audit

Check recent cargo revenue entries in the ledger:

```sql
select
  game_date,
  amount,
  description
from financial_ledger
where user_id = '<your_user_id>'
  and category = 'cargo'
order by game_date desc
limit 20;
```

## 26. Achievements audit

Check a player's unlocked achievements and progress:

```sql
select
  achievement_key,
  unlocked_at,
  progress
from achievements
where user_id = '<your_user_id>'
order by unlocked_at desc;
```

## 27. Bank loans audit

Check active and historical loans for a player:

```sql
select
  id,
  loan_type,
  principal,
  remaining_balance,
  interest_rate,
  monthly_payment,
  status,
  created_at
from loans
where user_id = '<your_user_id>'
order by created_at desc;
```

## 28. Credit scoring audit

Check credit score history for a player:

```sql
select
  score,
  factors,
  calculated_at
from credit_score_history
where user_id = '<your_user_id>'
order by calculated_at desc
limit 10;
```

## 29. Aircraft financing audit

Check aircraft financing records:

```sql
select
  af.id,
  af.financed_amount,
  af.down_payment,
  l.principal,
  l.remaining_balance,
  l.interest_rate,
  l.status,
  m.model_name,
  f.tail_number
from aircraft_financing af
join loans l on l.id = af.loan_id
join aircraft_models m on m.id = af.aircraft_model_id
join user_fleet f on f.id = af.fleet_id
where l.user_id = '<your_user_id>'
order by af.id desc;
```

## 30. Rank history audit

Check rank progression over time:

```sql
select
  game_date,
  rank,
  net_worth
from rank_history
where user_id = '<your_user_id>'
order by game_date desc
limit 30;
```
