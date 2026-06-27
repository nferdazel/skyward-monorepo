# Skyward Live Backend Audit Queries

Last verified on 2026-06-27.

Use these against the linked Supabase project when you want to inspect runtime
behavior without changing application code.

## 1. Player core state

```sql
select
  id,
  username,
  company_name,
  ceo_name,
  hq_airport_iata,
  net_worth,
  game_current_time,
  season_id,
  auto_grounding_threshold
from users
where id = '<your_user_id>';
```

## 2. Canonical cash balance

```sql
select
  id,
  user_id,
  account_type,
  balance,
  updated_at
from bank_accounts
where user_id = '<your_user_id>'
order by account_type;
```

## 3. Recent money trail

`bank_transactions.game_date` is in-game time. Do not compare it directly to
wall-clock fields such as `loans.taken_at` or `achievements.unlocked_at`
without calling out the clock-domain difference.

```sql
select
  game_date,
  transaction_type,
  ifrs_category,
  ifrs_subcategory,
  amount,
  balance_after,
  description
from bank_transactions
where user_id = '<your_user_id>'
order by game_date desc, created_at desc
limit 30;
```

Chronology note from the current audit pass:
- `loan_disbursement`, `loan_repayment`, `aircraft_purchase_deposit`, and
  `lease_termination` rows are now expected to preserve exact shared game time
- if one of those rows appears rounded to `00:00`, treat it as a regression

## 4. Fleet condition and status

```sql
select
  f.id,
  f.nickname,
  f.tail_number,
  f.acquisition_type,
  f.condition,
  f.status,
  f.total_flights,
  f.last_a_check_at,
  f.last_c_check_at,
  m.manufacturer,
  m.model_name,
  m.speed_kmh,
  m.purchase_price,
  m.lease_price_per_month
from fleet_aircraft f
join aircraft_models m on m.id = f.aircraft_model_id
where f.user_id = '<your_user_id>'
order by f.acquired_at desc;
```

## 5. Route network with assigned aircraft

```sql
select
  r.id,
  r.origin_iata,
  r.destination_iata,
  r.distance_km,
  r.ticket_price,
  r.flights_per_week,
  f.nickname,
  f.tail_number,
  f.status,
  f.condition,
  m.model_name
from route_assignments r
left join fleet_aircraft f on f.id = r.assigned_aircraft_id
left join aircraft_models m on m.id = f.aircraft_model_id
where r.user_id = '<your_user_id>'
order by r.created_at desc;
```

## 6. Grounded-aircraft assignment exploit check

This should return zero rows.

```sql
select
  r.id as route_id,
  r.origin_iata,
  r.destination_iata,
  f.id as fleet_id,
  f.nickname,
  f.status,
  f.condition
from route_assignments r
join fleet_aircraft f on f.id = r.assigned_aircraft_id
where r.user_id = '<your_user_id>'
  and (f.status = 'grounded' or f.condition < 40.00);
```

## 7. Loan book

`loans.taken_at` is a real-world origination timestamp. The matching
`loan_disbursement` ledger row lives in `bank_transactions.game_date`, which
uses the shared game calendar instead.

```sql
select
  id,
  loan_type,
  principal,
  remaining_balance,
  interest_rate,
  weekly_payment,
  monthly_payment,
  status,
  collateral_aircraft_id,
  originated_game_date,
  taken_at
from loans
where user_id = '<your_user_id>'
order by originated_game_date desc nulls last, taken_at desc;
```

Cross-check one loan against its cash movement without mixing clocks blindly:

```sql
select
  l.id as loan_id,
  l.principal,
  l.taken_at as loan_taken_at_real_time,
  bt.amount as ledger_amount,
  bt.game_date as ledger_game_time,
  bt.description
from loans l
left join bank_transactions bt
  on bt.user_id = l.user_id
 and bt.ifrs_subcategory = 'loan_disbursement'
 and bt.amount = l.principal
where l.user_id = '<your_user_id>'
order by l.taken_at desc, bt.game_date desc nulls last;
```

## 8. Current credit state

```sql
select
  *
from credit_scores
where user_id = '<your_user_id>';
```

## 9. Credit score history

`credit_score_history.game_date` is the in-game scoring date.
`credit_score_history.computed_at` is the real-world write timestamp.

```sql
select
  *
from credit_score_history
where user_id = '<your_user_id>'
order by game_date desc nulls last, computed_at desc nulls last
limit 20;
```

## 9b. Achievement history clock audit

`achievements.game_date` is the in-game award time when present.
`achievements.unlocked_at` is the real-world write time.

```sql
select
  achievement_type,
  achievement_name,
  game_date as achievement_game_time,
  unlocked_at as achievement_written_at_real_time
from achievements
where user_id = '<your_user_id>'
order by game_date desc nulls last, unlocked_at desc
limit 20;
```

Operational status:
- the backend chronology contract is intact
- the current Flutter dashboard runtime does not mount `AchievementCubit`, so
  this is mainly a backend/live-data audit surface today

## 10. Bank transaction retention dry-run

Use this to inspect the current prune horizon without deleting rows.

```sql
select
  key,
  value,
  unit
from game_config
where key = 'bank_txn_raw_retention_game_days';
```

```sql
select *
from prune_bank_transactions(true);
```

Operational note:
- this retention surface deletes old `bank_transactions` rows directly
- the cutoff is based on `season_clock.current_game_time`, not wall-clock time
- rows with `game_date is null` are preserved by the prune function

## 11. World-clock lag check for one player

`u.game_current_time` and `s.current_game_time` are in-game clocks.
This query does not measure wall-clock scheduler latency.

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

## 12. Force player reconciliation

Use this only when intentionally auditing simulation catch-up:

```sql
select *
from process_simulation_delta('<your_user_id>');
```

## 13. World-tick guardrail report

```sql
select *
from get_world_tick_guardrail_report();
```

## 14. Scheduler health report

`current_game_time` is the in-game season clock.
`season_last_tick_at` and `latest_log_started_at` are real-world scheduler timestamps.
This is the preferred repo-safe live proof for the world-tick cron job because
it runs through a security-definer audit surface instead of requiring direct
`cron.*` access from the caller role.

```sql
select *
from get_world_tick_scheduler_health();
```

## 15. Recent world-tick attempts

`started_at` / `finished_at` are wall-clock scheduler times.
`game_time_before` / `game_time_after` are in-game time boundaries.

```sql
select
  season_id,
  started_at,
  finished_at,
  game_time_before,
  game_time_after,
  extract(epoch from (finished_at - started_at)) as runtime_seconds,
  extract(epoch from (game_time_after - game_time_before)) / 3600
    as game_hours_advanced,
  ticks_processed,
  players_processed,
  bots_processed,
  status,
  message
from world_tick_log
order by started_at desc
limit 20;
```

## 16. Active world events

`start_game_time` and `end_game_time` are in-game activation windows.

```sql
select
  event_type,
  title,
  effect_type,
  effect_target,
  effect_value,
  start_game_time,
  end_game_time,
  is_active
from game_events
where is_active = true
order by start_game_time desc;
```

## 17. Database size report

```sql
select *
from get_database_size_report();
```

## 18. Table size report

```sql
select *
from get_table_size_report()
limit 20;
```

## 19. Owner optimizer

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

## 20. Native SQL audit pass

```bash
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked -f test/layer4_database/native_audit/supabase_audit_test.sql
```

What this currently proves:
- trigger behavior including:
  - `create_default_bank_account`
  - `fleet_reconcile_net_worth`
  - `trg_bank_balance_reconcile_net_worth`
  - `trg_loan_reconcile_net_worth`
  - `trg_user_hq_change`
- route CRUD RPCs
- `take_loan`
- `get_user_balance`
- auth-bound `get_credit_report`
- auth-bound `repay_loan`
- auth-bound `refinance_loan`
- loan repayment ledger rows using shared in-game clock stamps
- refinance staying out of `bank_transactions` when no cash moves
- auth-bound `get_finance_snapshot`
- `get_global_leaderboard`
- `get_competitor_insights`
- `get_owner_route_optimizer`
- auth-bound `save_airline_settings`
- auth-bound `reset_user_airline`
- auth-bound `configure_aircraft_seats`
- auth-bound `sell_aircraft`
- auth-bound `terminate_aircraft_lease`
- reset semantics for fleet, routes, loans, bank history, onboarding, and
  default operating balance restoration

## 21. Finance / credit regression audit

```bash
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked -f test/layer4_database/native_audit/finance_credit_regression_test.sql
```

What this currently proves:
- net worth reconciliation
- aircraft financing servicing values
- idle lease carrying-cost behavior

## 22. delete-account end-to-end audit

```bash
test/layer4_database/native_audit/delete_account_e2e_audit.sh
```

What this currently proves:
- `register-with-username` creates a disposable auth/player identity
- Auth password login returns a valid user JWT
- `delete-account` successfully calls the underlying `delete_account` RPC path
- the disposable identity is removed from both `public.users` and `auth.users`
