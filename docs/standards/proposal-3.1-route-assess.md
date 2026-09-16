Status: proposal, awaiting owner approval | Last verified against code: 2026-09-16

# Proposal 3.1 — Server-owned route assessment (`GET /routes/assess`)

Phase 3 item in [refactor-plan-2026-09.md](refactor-plan-2026-09.md). Phase 3 needs
a written proposal before any code: blast radius, migration path, test plan.

## Why now (evidence, not opinion)

- The planner's economics live in
  `apps/app/lib/features/routes/domain/route_models.dart`: about **269 LOC** of
  definitions, measured by brace span — `buildPlanningAssessment` 128,
  `buildMaintenancePreviewForSchedule` 58, `allocateCabins` 38,
  `calculateDailyDemandPool` 18, `calculateViabilityBand` 14,
  `calculateDirectOperatingCostPerFlight` 13 (the plan's "~300 LOC" holds).
- That code reads **12+ `GameConstants`**, each labelled "Deprecated fallback —
  game_config 'X' is authoritative": `fuelPricePerLiter` (0.85, line 124),
  `ticketBaseFare` (50), `ticketPerKmRate` (0.12), `routeBaseLoadFactor` (0.85),
  `minAirportDemandFactor` (0.55), `maxAirportDemandFactor`,
  `demandPoolShortHaulKm` / `demandPoolLongHaulKm` / `demandPoolMinDistanceFactor`
  / `demandPoolScale`, the cabin willing shares and fare multipliers,
  `aircraftTurnaroundHours`, `totalWeeklyHoursCap`, `absoluteMaxWeeklyFlights`,
  `maintenanceAutoRepairRatePerHour`.
- The client **already receives the live values** (`go_simulation_gateway.dart:41`
  GETs `/game-config`, `simulation_cubit.dart:62` flattens it, `:265-325` uses it
  for the fuel price). The planner ignores it and uses the compile-time constant,
  so after any operator tuning the HUD shows one fuel price while the planner
  projects with another. This is a live contradiction, not just a layering wart.
- The client also cannot apply the tick's event multipliers: the per-route
  `demandMult` / `capacityMult`, the global fuel and maintenance multipliers and
  the safety/`TickSnapshot` config all live server-side
  (`internal/engine/snapshot.go`, applied in `simulation.go`). A projection taken
  during a fuel shock overstates contribution, by construction.
- The server already owns this exact model: `routeDailyDemand`
  (`internal/engine/simulation.go:670`), `allocateCabins` (`:611`),
  `routeWeeklyProfit` with `routePerfParams` / `routePerfConfig`
  (`internal/engine/bots.go:695-750`), config through `TickSnapshot`, and a
  hermetic test to copy (`internal/engine/bot_economics_test.go:13`). GAME-25
  already unified bot pricing with the player tick; the planner is the last copy.

## Proposal

Add `GET /routes/assess` on the guarded read surface: it takes a **proposed**
route (which may not exist yet) and returns the assessment the planner renders
today, computed by the engine with live config and event multipliers.

Query params: `origin`, `destination`, `distance_km` (required while the route
does not exist; validated against the 10% tolerance `RouteCreate` uses),
`ticket_price`, `flights_per_week`, optional `aircraft_id` and `route_id`.

Response per candidate aircraft:

```json
{
  "origin": "CGK", "destination": "DPS", "distance_km": 983.0,
  "aircraft_id": "…", "ticket_price": 120.0, "flights_per_week": 7,
  "allocated_flights_per_week": 6, "max_weekly_flights": 9,
  "expected_passengers_per_flight": 141.3, "load_factor_percent": 78.5,
  "direct_operating_cost_per_flight": 21450.0, "revenue_per_flight": 30120.0,
  "contribution_per_flight": 8670.0, "weekly_contribution": 52020.0,
  "flight_duration_hours": 1.9, "maintenance_hours_per_week": 3.2,
  "viability": { "band": "workable", "reasons": ["contribution below 12000"] },
  "inputs_used": {
    "fuel_price": 0.85, "ticket_base_fare": 50.0, "ticket_per_km_rate": 0.12,
    "route_base_load_factor": 0.85,
    "multipliers": { "fuel": 1.2, "maintenance": 1.0, "demand": 1.0, "capacity": 1.0 }
  }
}
```

`inputs_used` exists so an operator can see which config produced the number and
so a support question ("why does the planner disagree with the HUD?") is
answerable without reading code.

Server work:

- `Engine.AssessRoute(ctx, inputs)` — pure over an injected config + multipliers,
  reusing `routeDailyDemand`, `allocateCabins`, `calcMaxWeeklyFlights` and the
  wear model the tick already applies (`owned_wear_per_flight_cycle`,
  `leased_wear_per_flight_cycle`, `maintenance_auto_repair_rate`).
- `ReadHandler.RouteAssess` — parse and validate, then `httperr.WriteJSON`;
  rejections mirror `RouteCreate`'s messages and use `httperr` (400 bad input,
  404 unknown airport/user).
- Register next to the other reads: `mux.Handle("GET /routes/assess",
  guard(read.RouteAssess))` (`cmd/server/main.go:164-168`).

Client work:

- `RoutesGateway.assessRoute(...)` GET, following `loadRoutes`
  (`go_routes_gateway.dart:24`), a `RouteAssessment` DTO in
  `features/routes/domain/`, and a `RoutesCubit` method with a state field,
  debounced because the planner is edited live.
- Delete the economics: `buildPlanningAssessment`, `calculateDailyDemandPool`,
  `allocateCabins`, `calculateViabilityBand`,
  `calculateDirectOperatingCostPerFlight`, `buildMaintenancePreviewForSchedule`
  and the private helpers they lean on (~269 LOC). The viability thresholds
  (40% / 65% load factor, 12,000 contribution) move server-side with them.
- Keep `loadFactor`, `weeklyASK` and `weeklyRPK` on the client: they are
  arithmetic over server-supplied fields (capacity, distance, frequency), so a
  round trip buys nothing.
- Rewire three call sites: `routes_view.dart:1230` (planner dialog),
  `routes_view.dart:1627` (route detail panel), `overview_snapshot.dart:182`
  (dashboard "top yield" KPI).

## Blast radius

| Area | Files | Notes |
|---|---|---|
| Go | `internal/handler/read.go`, `cmd/server/main.go`, `internal/engine/` (new assess function) | additive; no migration, no schema change, no mutation path touched |
| Flutter | `features/routes/domain/route_models.dart` (−~269), `data/{routes_gateway,go_routes_gateway}.dart`, `presentation/cubit/routes_{cubit,state}.dart`, `presentation/views/routes_view.dart`, `features/dashboard/domain/overview_snapshot.dart` | read-only feature |
| Docs | this file, `docs/README.md` tree, `architecture/backend.md` + `architecture/frontend.md` route/economics notes, plan 3.1 | |

Risks, named honestly:

1. The dashboard KPI is computed locally today, so moving it server-side adds a
   fetch and a loading state to a screen that currently needs no network call for
   it. If that KPI must render before the assessment arrives, derive it from
   cached data or keep the KPI on the client until step 3.
2. The planner stops working if the endpoint is unreachable. The app is
   online-only in practice (every tab loads from the API), but the planner's
   current projections work from already-loaded data. Decide: show an explicit
   "assessment unavailable" state, or keep a degraded client estimate.
3. Rounding and type differences could shift displayed numbers slightly. The
   parity step below is the guard, not a hope.

## Migration path (additive, no flag day)

1. Ship the endpoint + Go tests. Inert: nothing calls it.
2. Ship the DTO/gateway/cubit and render the **server** assessment alongside the
   local one behind a dev-only switch, logging both for a session of real use.
   This is where divergence is caught before anything is deleted.
3. Flatten the switch: delete the local economics and the tests that covered them,
   rewire the dashboard KPI.
4. Update the architecture docs and tick 3.1.

## Test plan

- Go, hermetic: unit tests for `AssessRoute` with fixtures in the style of
  `bot_economics_test.go:13`, covering each viability band, a fuel-shock
  multiplier, an out-of-range aircraft, and a route with no compatible aircraft.
  Also a pure test for the query parsing/validation helper.
- Go, HTTP layer: **the honest constraint** — `ReadHandler` holds a concrete
  `*store.Store` (`read.go:19`), not an interface, and the DB-backed handler tests
  were removed by owner decision, so the endpoint's HTTP layer has no automated
  test as things stand. Options: (a) accept manual `curl` verification against
  prod plus the pure-function coverage, or (b) introduce a narrow interface for
  just the store methods this handler needs so it can be tested with a fake — a
  small, contained refactor that also helps 3.2. Recommend (b), but it is a
  decision.
- Flutter: DTO `fromMap` test; cubit success/error test with a fake gateway; a
  widget test asserting the planner renders values that came from the fake
  gateway rather than computing them (which is precisely what proves the deletion
  worked).
- Parity, manual, before step 3: with the dev switch on, compare server and client
  numbers over the same inputs in one session and record the deltas.
- Manual end to end: assess a route in the planner, then compare against the
  player's actual tick result in the bank ledger.

## Open questions (owner input needed)

1. Per-aircraft or ranked list? v1 proposes `aircraft_id` optional: omitted, return
   one entry per compatible aircraft so the client keeps "recommended aircraft".
2. Include the maintenance/wear preview in v1 (58 of the LOC)? The server has the
   model, so it is nearly free in the same response. Recommend yes.
3. Return `multipliers` always, or only when at least one differs from 1.0?
4. Keep `weeklyASK` / `weeklyRPK` client-side (recommended) or move them too?
5. If the assessment is unavailable, is a degraded client estimate acceptable, or
   should the planner show an explicit unavailable state (risk 2)?
