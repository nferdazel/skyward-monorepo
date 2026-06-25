# Skyward Live Backend Audit Queries

Last verified on 2026-06-26.

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
  taken_at
from loans
where user_id = '<your_user_id>'
order by taken_at desc;
```

## 8. Current credit state

```sql
select
  *
from credit_scores
where user_id = '<your_user_id>';
```

## 9. Credit score history

```sql
select
  *
from credit_score_history
where user_id = '<your_user_id>'
order by game_date desc nulls last, calculated_at desc nulls last
limit 20;
```

## 10. World-clock lag check for one player

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

## 11. Force player reconciliation

Use this only when intentionally auditing simulation catch-up:

```sql
select *
from process_simulation_delta('<your_user_id>');
```

## 12. World-tick guardrail report

```sql
select *
from get_world_tick_guardrail_report();
```

## 13. Scheduler health report

```sql
select *
from get_world_tick_scheduler_health();
```

## 14. Recent world-tick attempts

```sql
select
  season_id,
  started_at,
  finished_at,
  game_time_before,
  game_time_after,
  ticks_processed,
  players_processed,
  bots_processed,
  status,
  message
from world_tick_log
order by started_at desc
limit 20;
```

## 15. Active world events

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

## 16. Database size report

```sql
select *
from get_database_size_report();
```

## 17. Table size report

```sql
select *
from get_table_size_report()
limit 20;
```

## 18. Owner optimizer

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

## 19. Native SQL audit pass

```bash
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked -f test/layer4_database/native_audit/supabase_audit_test.sql
```

What this currently proves:
- trigger behavior including `trg_user_hq_change`
- route CRUD RPCs
- `take_loan`
- auth-bound `get_credit_report`
- auth-bound `repay_loan`
- auth-bound `refinance_loan`

## 20. Finance / credit regression audit

```bash
SUPABASE_DISABLE_TELEMETRY=1 supabase db query --linked -f test/layer4_database/native_audit/finance_credit_regression_test.sql
```

What this currently proves:
- net worth reconciliation
- aircraft financing servicing values
- idle lease carrying-cost behavior

## 21. delete-account end-to-end audit

```bash
test/layer4_database/native_audit/delete_account_e2e_audit.sh
```

What this currently proves:
- `register-with-username` creates a disposable auth/player identity
- Auth password login returns a valid user JWT
- `delete-account` successfully calls the underlying `delete_account` RPC path
- the disposable identity is removed from both `public.users` and `auth.users`
