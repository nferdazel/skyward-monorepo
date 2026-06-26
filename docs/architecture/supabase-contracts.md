# Skyward Supabase Contract Map

Last verified against code on 2026-06-26.

This is the live Flutter-to-Supabase contract surface.

## Runtime rules

- Supabase remains the authoritative source of game state.
- Flutter does not calculate authoritative simulation or economy outcomes.
- `DevModeManager.isDevMode` bypasses these contracts with local mock data.
- Realtime subscriptions are a reflection layer for UI freshness, not a replacement for SQL/RPC authority.

## RPC surface

### Auth

`register-with-username` Edge Function
- caller: `AuthCubit.register()` through `SupabaseAuthGateway`
- input body:
  - `username`
  - `password`
  - `companyName`
  - `ceoName`
- current behavior:
  - normalizes the username
  - derives the synthetic `@skyward.sachiel.id` auth email
  - creates an auto-confirmed Supabase Auth user through admin auth APIs
  - expects the authenticated bootstrap flow to create the matching
    `public.users` actor row
  - live DB verification confirms `handle_new_auth_user()` is attached to
    `auth.users`, but that trigger attachment is not declared by the public
    migrations in this repo
- phase note:
  - Security Phase 6 removed the legacy `register_company`, `login_company`,
    and `validate_session` RPCs entirely

### Simulation

`process_simulation_delta`
- caller: `SimulationCubit.syncWithDatabase()`
- params:
  - none from Flutter after Security Phase 4
- expected:
  - first row may include:
    - `elapsed_game_days`
    - `flights_run`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()` and forwards to the legacy UUID-based implementation
  - compatibility sync surface for Flutter
  - ensures the active season clock is current
  - processes the player from `users.game_current_time` to
    `season_clock.current_game_time`
  - no longer drives bot simulation from the player sync path

`process_world_tick`
- caller: scheduler / manual backend audit
- params:
  - `p_season_id`
  - `p_max_ticks`
- current behavior:
  - advances `season_clock.current_game_time` under advisory and row locks
  - records each attempt in `world_tick_log`
  - synchronizes player and bot actor state to the new season game time
  - after Phase 5.1, uses qualified season references and assumes the active
    season has been bootstrapped to the existing actor frontier
  - calls `generate_game_events()` and `deactivate_expired_events()` after
    advancing the clock (event system)

`process_player_simulation_to_time`
- caller: `process_world_tick`, `process_simulation_delta`
- params:
  - `p_user_id`
  - `p_target_game_time`
- current behavior:
  - processes one player from `users.game_current_time` to the target season
    game time through deterministic game-day boundaries
  - applies active game event multipliers (fuel price, demand)
  - applies hub bonus, airport congestion, and competition factors
  - applies seasonal demand modifiers (peak/normal/off-season)
  - applies fare-class demand elasticity (business/first 30% fewer pax)
  - includes crew cost model ($350/flight-hour)
  - tracks A-check (500 flights) and C-check (3000 flights) milestones
  - computes cargo revenue (10% of ticket revenue, distance-scaled)
  - uses non-linear degradation (accelerating wear below 60% condition)
  - computes catch-up subsidy for players < 30% of leader net worth
  - no live public `financial_snapshots` read surface is currently exposed to
    Flutter; finance history falls back to a single current net-worth point

`process_all_bots_simulation_to_time`
- caller: `process_world_tick`
- params:
  - `p_target_game_time`
  - `p_season_id`
- current behavior:
  - processes active backend-owned bot actors to the target season game time
    through deterministic game-day boundaries
  - applies active game event multipliers (fuel price, demand)
  - applies seasonal demand modifiers, fare-class elasticity, crew costs
  - tracks A-check and C-check maintenance milestones
  - computes cargo revenue and non-linear degradation

`ensure_world_current`
- caller: command RPCs and snapshot reads
- params:
  - `p_season_id`
- current behavior:
  - wrapper around `process_world_tick`
  - brings the season clock current up to the configured tick cap

`get_world_tick_scheduler_health`
- caller: backend audit / operations checks
- params: none
- current behavior:
  - reports active season clock state
  - reports latest `world_tick_log` row using real-time `started_at`
    alongside season real-time `last_tick_at`
  - reports whether the `skyward_world_tick` pg_cron job exists and is active
  - runs as a narrow security-definer audit surface so client roles do not need
    direct `cron.job` access

`get_world_tick_guardrail_report`
- caller: backend audit / operations checks
- params: none
- current behavior:
  - reports active season presence
  - reports player/bot lag or ahead counts against `season_clock`
  - reports backwards successful world-tick logs
  - reports recent successful world-tick activity
  - compares actors on the in-game clock (`users.game_current_time` against
    `season_clock.current_game_time`), not against wall-clock time

`get_database_size_report`
- caller: backend audit / operations checks
- params: none
- current behavior:
  - reports current database size
  - reports configured Supabase Free quota reference
  - returns `ok`, `warn`, or `critical`

`get_table_size_report`
- caller: backend audit / operations checks
- params: none
- current behavior:
  - reports approximate row counts
  - reports table, index, and total relation sizes for public user tables
  - runs as a narrow security-definer audit surface so client roles do not need
    extension schema access

`get_finance_snapshot`
- caller: `FinanceCubit.loadLedger()`
- params:
  - none from Flutter after Security Phase 4
- current behavior:
  - Flutter now calls an auth-bound wrapper for the current human player
  - returns current balance-sheet values (`cash`, `net_worth`)
  - returns owned-aircraft asset value and leased monthly exposure
  - returns fleet count and deployed-route footprint
  - returns rolling 30-day revenue, expense, and net values
  - supports both human players and AI competitors through one shared contract

`assign_active_season_id`
- caller: database insert trigger path on `users`
- current behavior:
  - assigns the active season when `season_id` is missing
  - starts newly inserted actors at the active season game time

`normalize_username`
- caller: planned auth bootstrap / future username-only auth flow
- params:
  - `p_username`
- current behavior:
  - converts a user-facing username into a deterministic lowercase slug-safe
    identifier for future auth ownership workflows

`build_synthetic_auth_email`
- caller: planned auth bootstrap / future username-only auth flow
- params:
  - `p_username`
- current behavior:
  - derives the synthetic `@skyward.sachiel.id` auth email for username-based
    sign-in UX

`get_user_id_for_auth_uid`
- caller: planned authenticated gameplay RPCs
- params:
  - `p_auth_user_id` optional, defaults to `auth.uid()`
- current behavior:
  - resolves the future Supabase Auth identity anchor to `public.users.id`

`handle_new_auth_user`
- caller: live `auth.users` bootstrap trigger; attachment is live-verified but
  not declared by the public migrations in this repo
- current behavior:
  - validates synthetic-email/metadata bootstrap assumptions
  - creates the matching `public.users` row with future auth ownership linkage
  - leaves season bootstrap and actor-start-time enforcement to existing
    `users` insert triggers

### Table-read surfaces

`achievements`
- caller: `AchievementCubit.loadAchievements()` through `SupabaseAchievementGateway`
- selected fields:
  - `id`, `user_id`, `achievement_type`, `achievement_name`, `description`
  - `unlocked_at`
  - `game_date`
- current behavior:
  - sorts first by `game_date desc nulls last` to preserve in-game chronology
  - breaks ties with `unlocked_at desc` as a real-time fallback
  - still exposes both timestamps because they belong to different clock domains

`credit_score_history`
- caller: `BankCubit.loadCreditHistory()` through `SupabaseBankGateway`
- selected fields:
  - `score`, factor-score columns
  - `game_date`
- current behavior:
  - sorts by `game_date desc`
  - treats `game_date` as the in-game chronology used by the client
  - leaves real-time `computed_at` as backend audit metadata rather than a
    client ordering field

### Simulation helpers

`haversine_distance`
- caller: `create_route` server-side distance validation
- params:
  - `lat1`, `lon1`, `lat2`, `lon2`
- current behavior:
  - computes great-circle distance in km between two coordinates
  - immutable, used for route distance validation with 10% tolerance

`calculate_route_max_weekly_flights` (2-param overload)
- caller: owner-optimizer, route assignment checks
- params:
  - `p_distance_km`
  - `p_speed_kmh`
- current behavior:
  - returns max weekly flights using hardcoded 1.0-hour turnaround

`calculate_route_max_weekly_flights` (3-param overload)
- caller: player and bot simulation engine
- params:
  - `p_distance_km`
  - `p_speed_kmh`
  - `p_turnaround_hours`
- current behavior:
  - returns max weekly flights using per-aircraft turnaround time

`calculate_route_expected_passengers` (8-param overload)
- caller: player and bot simulation engine
- params:
  - `p_capacity`, `p_distance_km`, `p_ticket_price`
  - `p_origin_demand`, `p_destination_demand`
  - `p_origin_iata`, `p_destination_iata`, `p_user_id`
- current behavior:
  - base passenger count from capacity, demand, and pricing elasticity
  - competition factor: splits demand when multiple actors serve same O-D pair
  - congestion factor: penalises overloaded origin airports (> 50 weekly departures)
  - hub bonus: 2% per additional route sharing the same origin, capped at 20%

`calculate_airport_congestion_factor`
- caller: 8-param `calculate_route_expected_passengers`
- params:
  - `p_origin_iata`
- current behavior:
  - returns a multiplier (0.50–1.0) based on total weekly departures from the airport
  - penalty starts at > 50 weekly flights

`calculate_hub_bonus`
- caller: 8-param `calculate_route_expected_passengers`
- params:
  - `p_origin_iata`, `p_user_id`
- current behavior:
  - returns a demand multiplier (1.0–1.20) based on hub-and-spoke effect
  - 2% bonus per additional active route sharing the same origin, capped at 20%

`get_hub_bonus_percentage`
- caller: Flutter UI for hub bonus display
- params:
  - `p_origin_iata`, `p_user_id`
- current behavior:
  - returns the hub bonus as a percentage (0–20) for UI display labels

### Event system

`generate_game_events`
- caller: `process_world_tick` after advancing the season clock
- params:
  - `p_game_time`
- current behavior:
  - 5% chance per tick to generate one of four event types
  - `fuel_shock`: global fuel price multiplier (0.7×–1.3×) for 72 hours
  - `demand_surge`: airport-specific demand multiplier (1.2×–1.5×) for 48 hours
  - `weather`: airport-specific demand penalty (0.5×) for 24 hours
  - `regulatory`: global airport tax increase (5–20%) for 168 hours

`deactivate_expired_events`
- caller: `process_world_tick` after advancing the season clock
- params:
  - `p_game_time`
- current behavior:
  - marks `game_events` rows as `is_active = false` when `end_game_time` has passed

### Fleet

`purchase_aircraft`
- caller: `FleetCubit.purchaseAircraft()`
- params:
  - `p_model_id`
  - `p_nickname`
  - `p_economy_seats`
  - `p_business_seats`
  - `p_first_class_seats`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - catches up simulation before purchase
  - validates seat-slot capacity inside the purchase transaction

`lease_aircraft`
- caller: `FleetCubit.leaseAircraft()`
- params:
  - `p_model_id`
  - `p_nickname`
  - `p_economy_seats`
  - `p_business_seats`
  - `p_first_class_seats`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - catches up simulation before lease
  - validates seat-slot capacity inside the lease transaction

`repair_aircraft`
- caller: `FleetCubit.repairAircraft()`
- params:
  - `p_fleet_id`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - authoritative repair mechanics now flow through the same internal helper
    that bot paid-recovery uses
  - restores the airframe to 100%
  - repair pricing now matches the client display model
  - leased and owned aircraft use different cost bases

`sell_aircraft`
- caller: `FleetCubit.sellAircraft()`
- params:
  - `p_fleet_id`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - catches up simulation before sale
  - requires an owned aircraft
  - blocks disposal while the aircraft is still assigned
  - credits condition-adjusted residual value
  - writes a `bank_transactions` sale row
  - removes the fleet row

`terminate_aircraft_lease`
- caller: `FleetCubit.terminateLease()`
- params:
  - `p_fleet_id`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - catches up simulation before termination
  - requires a leased aircraft
  - blocks disposal while the aircraft is still assigned
  - charges a lease exit fee
  - writes a `bank_transactions` lease-exit row
  - removes the fleet row

`configure_aircraft_seats`
- caller: `FleetCubit.configureSeats()`
- params:
  - `p_fleet_id`
  - `p_economy_seats`
  - `p_business_seats`
  - `p_first_class_seats`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - catches up simulation before seat changes
  - validates seat-slot capacity server-side

### Routes

`create_route`
- caller: `RoutesCubit.createRoute()`
- params:
  - `p_origin_iata`
  - `p_destination_iata`
  - `p_distance_km`
  - `p_ticket_price`
  - `p_flights_per_week`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - catches up simulation before creating the route
  - stores blueprint economics before any aircraft is assigned

`assign_aircraft_to_route`
- caller: `RoutesCubit.assignAircraft()`
- params:
  - `p_route_id`
  - `p_aircraft_id`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - catches up simulation before changing assignment
  - validates ownership, safety threshold, route range fit, weekly schedule fit,
    and single-route assignment server-side

`update_route_frequency_and_price`
- caller: `RoutesCubit.updateRouteFrequencyAndPrice()`
- params:
  - `p_route_id`
  - `p_ticket_price`
  - `p_flights_per_week`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - catches up simulation before changing fare or schedule
  - enforces assigned-aircraft weekly schedule limits server-side

### Owner-only tools

`get_owner_route_optimizer`
- caller: operator only, not Flutter
- params:
  - `p_user_id`
  - `p_origin_iata`
  - `p_destination_iata`
  - `p_limit`
  - `p_include_assigned`
  - `p_exclude_existing_routes`
- current behavior:
  - scans reachable destinations for one player fleet
  - scores fare and seat-layout candidates
  - returns top route opportunities by estimated weekly contribution
  - is intentionally granted only to `service_role`

`delete_route`
- caller: `RoutesCubit.deleteRoute()`
- params:
  - `p_route_id`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - catches up simulation before closing the route
  - grounds the assigned aircraft before deleting the route

### Bank

`take_loan`
- caller: `BankCubit.takeLoan()`
- params:
  - `p_principal`
  - `p_term_weeks`
  - `p_loan_type`
  - `p_collateral_aircraft_id` (optional)
- current behavior:
  - auth-bound wrapper resolves player from `auth.uid()`
  - validates credit tier, active-loan limits, and policy eligibility
  - creates loan record and disburses funds into `bank_accounts`
  - stores the loan row's `taken_at` in real time, while the matching
    `loan_disbursement` ledger row is stamped with the player's in-game
    `users.game_current_time`

`get_credit_report`
- caller: `BankCubit.loadCreditReport()`
- params: none from Flutter
- current behavior:
  - auth-bound wrapper resolves player from `auth.uid()`
  - returns the current score surface plus tier-specific borrowing limits and rates

`repay_loan`
- caller: `BankCubit.repayLoan()`
- params:
  - `p_loan_id`
  - `p_amount` optional
- current behavior:
  - auth-bound wrapper resolves player from `auth.uid()`
  - debits the player's operating bank account
  - reduces `loans.remaining_balance`
  - writes a `bank_transactions` repayment row

`refinance_loan`
- caller: `BankCubit.refinanceLoan()`
- params:
  - `p_loan_id`
- current behavior:
  - auth-bound wrapper resolves player from `auth.uid()`
  - validates eligibility for refinancing
  - updates loan terms

`finance_aircraft`
- caller: `BankCubit.financeAircraft()`
- params:
  - `p_aircraft_model_id`
  - `p_down_payment_pct`
  - `p_term_months`
- current behavior:
  - auth-bound wrapper resolves player from `auth.uid()`
  - validates credit eligibility
  - creates aircraft financing loan and purchase-side bank activity

### Leaderboard

`get_global_leaderboard`
- caller: `LeaderboardCubit.loadRankings()`
- params: none
- current client behavior:
  - executes through a security-definer read surface after Security Phase 5
  - rankings are always presented by net worth
  - client-side sort controls were removed
  - overview consumes this feed for competitor-gap and leading-bot signals
  - `monthly_revenue` now means realized revenue over the last 30 in-game days for both players and bots
  - `status` is sourced from the backend leaderboard payload for both human and bot entries

`get_competitor_insights`
- caller: `LeaderboardCubit.getInsights()`
- params:
  - `p_id`
  - `p_is_bot`
- current client behavior:
  - executes through a security-definer read surface after Security Phase 5
  - bot intelligence is loaded from the live RPC, not synthetic client fallback
  - competitor dialogs reflect the live backend status surface (`Active`, `Distress`, `Maintenance`, `Recovery`, `Bankrupt`)

### Settings

`reset_user_airline`
- caller: `SettingsCubit.resetAirline()`
- params: none from Flutter after Security Phase 4

`save_airline_settings`
- caller: `SettingsCubit.saveSettings()`
- params:
  - `p_company_name`
  - `p_auto_grounding_threshold`
  - `p_hq_airport_iata`
- current behavior:
  - Flutter now calls an auth-bound wrapper that resolves the player row from
    `auth.uid()`
  - catches up simulation before saving settings
  - validates safety threshold and HQ airport server-side

`delete-account` Edge Function
- caller: `SettingsGateway.deleteAccount()`
- runtime path:
  - validates caller JWT
  - calls auth-bound `delete_account()` RPC as the user
  - deletes the auth identity through admin auth APIs
- current verification status:
  - proven live by `test/layer4_database/native_audit/delete_account_e2e_audit.sh`

### Direct table writes

The Flutter client should not directly write simulation-sensitive tables. Player
commands that mutate fleet, routes, settings, cash, ledger, or simulation state
must go through RPCs.

## Direct table reads

The client also reads some tables directly through Supabase queries:
- `fleet_aircraft`
- `aircraft_models`
- `route_assignments`
- `bank_transactions`
- `users`
- `airports`
- `game_config`
- `game_events`
- `loans` (active and historical loan records)
- `credit_score_history` (credit score tracking)
- `achievements` (achievement tracking and unlock state)

These are still part of the effective contract because UI parsing depends on their returned fields.

## Realtime subscription surface

The Flutter client now subscribes to Postgres Changes on:
- `users`
- `bank_transactions`
- `fleet_aircraft`
- `route_assignments`
- `achievements`
- `loans`

Operational rule:
- the pg_cron world tick is the authoritative catch-up trigger
- periodic/app-resume `process_simulation_delta` calls remain compatibility
  reconciliation for the current player
- Realtime is used to reflect committed row changes into Cubit state sooner between syncs
- production Flutter does not locally advance game time; mock/dev mode may still
  use a local display ticker

## Backend-only behavior surfaces

The app also depends indirectly on backend jobs that are not called as standalone RPCs from Flutter:
- `season_clock`
  - shared-world clock foundation, with scheduler-driven world ticks
  - links users into an active season through `season_id`
  - remains the shared time authority even while player cursors still exist
- `skyward_world_tick`
  - Phase 4 pg_cron job
  - calls `ensure_world_current(NULL)` once per minute
  - advances `season_clock` only until actor simulation migrates into world ticks
- `execute_bot_decisions()`
  - archetype-specific fleet growth
  - archetype-specific route doctrine retuning on existing active routes
  - idle-aircraft route deployment
  - distance-stage and demand-aware route selection by archetype
  - contribution-based distress route cutbacks
  - paid bot repair recovery for grounded airframes now shares the same
    authoritative repair helper used by player repairs
  - reserve-aware expansion gates tied to active lease burden
  - premium cabin seat distributions per archetype
  - competitive response pricing on shared O-D routes
  - bot aircraft purchasing when cash > 3× starting capital
  - soft-delete bankruptcy (status = 'Bankrupt', fleet grounded, data preserved)
