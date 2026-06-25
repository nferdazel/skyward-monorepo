# Owner Operator Tools

> **Note:** Replace `<your_user_id>` and `<your_username>` with your actual account values.
> Find them with: `SELECT id, username FROM users WHERE company_name = '<your_company>';`

Last verified against code on 2026-06-26.

This document covers the private operator surfaces added for the game owner.

If migration `53` was applied before `54`, apply migration `61` too. It makes
the optimizer self-contained, deduplicated, and new-route focused by default.

## Access model

`get_owner_route_optimizer(...)` is intentionally not granted to normal app
roles.

Safe ways to use it:
- Supabase SQL Editor
- service-role scripts
- a future private Edge Function if you decide to wrap it

Do not expose it through the public Flutter client.

## 1. Find your player id

```sql
select id, username, company_name, hq_airport_iata
from users
order by created_at asc;
```

For your account, find your player id:

```sql
<your_user_id>
```

## 2. Run the optimizer from HQ

This ranks route, fare, and cabin-layout combinations for your fleet.

```sql
select *
from get_owner_route_optimizer(
  '<your_user_id>',
  null,
  null,
  25,
  false,
  true
);
```

Meaning:
- `p_user_id`: your player id
- `p_origin_iata = null`: use your HQ automatically
- `p_destination_iata = null`: scan all reachable destinations
- `p_limit = 25`: top 25 opportunities
- `p_include_assigned = false`: only idle aircraft
- `p_exclude_existing_routes = true`: focus on new routes by default

## 3. Force one origin

```sql
select *
from get_owner_route_optimizer(
  '<your_user_id>',
  'CGK',
  null,
  20,
  true,
  false
);
```

This uses `CGK` as origin, includes already-assigned aircraft, and also allows
already-operated routes back into the ranking.

## 4. Force one destination

```sql
select *
from get_owner_route_optimizer(
  '<your_user_id>',
  'CGK',
  'LAX',
  10,
  true,
  false
);
```

Use this when you want to inspect the best setup for one specific city pair.

## 5. How to read the result

Key columns:
- `aircraft_id`, `tail_number`, `aircraft_model`
- `currently_assigned`
- `route_origin_iata`, `route_destination_iata`
- `route_already_exists`
- `ticket_price`
- `weekly_flights`
- `recommended_economy_seats`
- `recommended_business_seats`
- `recommended_first_class_seats`
- `effective_passenger_capacity`
- `expected_passengers_per_flight`
- `load_factor`
- `direct_cost_per_flight`
- `revenue_per_flight`
- `contribution_per_flight`
- `weekly_contribution`
- `maintenance_impact_per_week`

Interpretation:
- `weekly_contribution` is the main ranking metric
- the result is deduplicated by route, model, acquisition type, seat plan, and
  suggested fare
- `route_already_exists = true` means the optimizer found a profitable
  configuration on a route you already operate; when those are included, they
  receive a simple ranking penalty so expansion options surface more naturally
- `maintenance_impact_per_week` is not a cash charge by itself; it is wear
  pressure under the current simulation model

## 6. Important realism note

Under the current simulation model, premium cabins reduce passenger throughput
but do not yet generate premium-class fare multipliers.

That means the optimizer will often prefer all-economy layouts for pure max
profit.

This is expected with the current rules, not a bug in the operator tool.

## 7. Disposal RPCs

These are normal gameplay RPCs used by Flutter:
- `sell_aircraft(p_fleet_id)`
- `terminate_aircraft_lease(p_fleet_id)`

Rules:
- the airframe must belong to the player
- it must not be assigned to a route
- owned aircraft sell for a condition-adjusted residual value
- leased aircraft terminate with an exit fee

Direct SQL examples:

```sql
select *
from sell_aircraft(
  '<fleet_id>'
);
```

```sql
select *
from terminate_aircraft_lease(
  '<fleet_id>'
);
```

These player-facing wrappers now resolve the actor from `auth.uid()`.
If you are operating through SQL Editor or service-role scripts and need the
legacy UUID-explicit form, use the older two-argument signatures instead.
