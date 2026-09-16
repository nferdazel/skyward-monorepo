# Refactor plan 2026-09

Tracked, audit-driven refactor backlog. Check items off in the implementing
commit (same convention as `docs/product/roadmap.md`).

- Origin: independent audit of `6b779f3` by three read-only reviewers
  (frontend, backend, infra/DB/docs). Raw reports live in `docs/reviews/`
  (gitignored, local-only): `refactor-audit-2026-09-{frontend,backend,infra-db-docs,synthesis}.md`.
- Owner-granted freedom: **structural + breaking changes allowed with
  justification**; behaviour-preserving by default.
- Non-negotiables that constrain every item: Cubit-owned app state; the Go API
  is authoritative for simulation/finance/credit/world; `bank_accounts` is
  canonical cash and `bank_transactions` canonical money movement;
  handler → engine → store layering; maintainer-standard §3/§4.
- Severity: P0 = correctness/security/data-loss/outage; P1 = high-value
  robustness/maintainability; P2 = worthwhile; P3 = nit.

## Phase 0 — Reproducibility & safety nets (no behaviour change)

- [x] **0.1** Restore the missing `migrations/18_retire_pgcron_scheduler_health.sql`
      (recovered from unreferenced object `153074e`) so the migration set matches prod.
- [x] **0.2** Make `00_baseline.sql` bootstrap-able. Removed the two raw
      dump-output lines, added a role preamble creating `anon`/`authenticated`/
      `service_role` as NOLOGIN groups when absent, added a minimal unused
      `auth.uid()` stub (one legacy helper keeps a DEFAULT on it), and removed the
      Supabase-only `users_auth_user_id_fkey` → `auth.users` plus the 16 baseline
      RLS enables + 16 policies (prod has none). Verified: `00–18` apply cleanly
      to a scratch DB. *Breaking for fresh-apply only; prod untouched.*
- [x] **0.2b** RLS converged (D5 = match prod). `migrations/21_disable_rls_to_match_prod.sql`
      disables RLS on the 14 tables enabled by `01` and drops its 15 `auth.uid()`
      policies, then raises if any RLS/policy remains. Verified: a scratch DB went
      14 tables/15 policies → 0/0, a fresh `00–21` apply ends at 0/0 with 22 ledger
      rows, and prod/`skyward_test` took it as a no-op with data unchanged.
- [x] **0.2c** Role provisioning. `migrations/22_role_provisioning.sql` creates
      role `postgres` (NOLOGIN) when the cluster lacks it — the baseline is full of
      `OWNER TO "postgres"` / `DEFAULT PRIVILEGES FOR ROLE "postgres"`, and the
      official image never creates that role once `POSTGRES_USER` is set to another
      name (this is what killed the CI migrate step). It also creates `skyward_app`
      as a LOGIN role and grants exactly prod's shape: 7 privileges x 17 tables =
      119 grants (verified equal on a fresh apply), `USAGE, SELECT` on sequences,
      plus default privileges so tables created by *future* migrations are covered —
      prod had **zero** default ACLs, which is why `schema_migrations` was the only
      table without grants. `schema_migrations` is deliberately excluded. The role
      password stays out of git: `scripts/set-app-role-password.sh` reads
      `APP_DB_PASSWORD` and sends it over stdin. Applied to prod (no-op except the
      4 new default ACLs; grants unchanged, `/readyz` 200).
      **Blocker found:** a fresh cluster still cannot log in — see 0.2d.
- [x] **0.2d** Schema reconciliation — approved and done 2026-09-16. All four
      divergences closed; drift check exits 0 on both comparisons:
      **(a)** `00_baseline.sql` gained `"password_hash" "text"` directly after
      `actor_type` — prod's position — so a fresh apply matches prod *and* column
      order stays identical (an `ADD COLUMN` migration would have appended it and
      left a permanent ordering diff). This was the real blocker: no migration
      created that column and the API reads it for login.
      **(b)** `23_reconcile_fk_constraints.sql` adds prod's three missing FKs
      (`users.hq_airport_iata → airports`, `users.season_id → season_clock`,
      `world_tick_log.season_id → season_clock`), idempotent via `pg_constraint`;
      applied to prod, re-run reports "tidak ada migrasi pending", `/readyz` 200.
      Prod data violated none of them (0 bad rows).
      **(c)** seven `starting_cash` / `net_worth` literals in `00_baseline.sql`
      moved 25,000,000 → 15,000,000 to match prod. Inert either way:
      `game_config.starting_cash` = 25,000,000 supplies the value, so the `COALESCE`
      never falls through.
      **(d)** `15_finance_snapshots_retention.sql` money columns became
      `numeric(20,2)`, matching prod (whose version came from the hosted DB).
      Snapshot regenerated (4,799 lines).
      *The in-place edits are deliberate:* `00_baseline.sql` and `15_*.sql` have
      **NULL** checksums in prod's ledger (the 19 backfill recorded filenames
      without verifying content) and prod never re-runs them — they define the
      fresh-apply path only. That is an exception to append-only, recorded here so
      a later reader does not mistake it for drift.

- [x] **0.3** Migration ledger + `make migrate`. `migrations/19_schema_migrations.sql`
      creates `schema_migrations` and backfills 00–18; `scripts/migrate.sh` applies
      pending files in order, records filename+checksum, verifies checksums of
      previously-recorded files, and refuses to run against a non-empty database
      that has no ledger. Runbook §5 updated (`-1` noted as legacy).
- [x] **0.3b** `scripts/drift-check.sh` (not a `make` target, and **not in CI** —
      CI does no database work). It rebuilds a scratch DB from every migration, then
      compares two ways: live DB vs migration output (catches hand-applied DDL) and
      migration output vs the committed snapshot
      `docs/operations/schema-snapshot.sql` (catches a stale snapshot). Owner/ACL are
      ignored (`postgres` vs `qouver` ownership is legitimate); role *grants* are
      also outside the comparison — this tool judges schema shape. Exit 1 = drift.
      First run found 10 hunks / 98 lines of real drift: 0.2d.
- [x] **0.4** DB-backed test harness — built, then **removed on request** (2026-09-16).
      It was `apps/api/internal/testsupport` (`NewTestPool`, `Reset` via
      `TRUNCATE users CASCADE`, seeders) plus 11 regression tests across
      engine/handler/store, all skipping unless `TEST_DATABASE_URL` was set. Two CI
      attempts to run it were dropped first: a `postgres:18` service plus
      `make migrate` failed with `role "postgres" does not exist` (the image makes
      `POSTGRES_USER` the superuser and never creates `postgres`, while the
      Supabase-dump baseline has hundreds of `OWNER TO "postgres"` /
      `DEFAULT PRIVILEGES FOR ROLE "postgres"` statements), and the user then asked
      for the DB tests themselves to go. Harness, tests and runbook §6 are deleted.
      `make migrate` stays an operator-run step against the real database; CI is
      hermetic (vet + `go test ./...` + Flutter). **Consequence to remember:** the
      Phase-1 regressions (loan rows silently skipped, phantom late fee, bot
      NULL-column skips, login brute force, insights HQ leak) no longer have
      automated coverage — each was verified fail-then-pass when it was fixed, and
      manual checks go through the runbook §2 audit queries.
- [x] **0.5** Deploy hardening in `deploy/deploy-vps.sh`: keep
      `bin/skyward-api.prev`, gate restart on `/readyz` with rollback, atomic web
      swap (build to `web.new/` then rename), skip the API restart when only
      `apps/app/` changed, retain full build logs. All five verified present in
      the script; exercised by the real deploy of `bdf0b7c`.
- [x] **0.6** CI: use `go-version-file: apps/api/go.mod` (was pinned 1.22 vs
      go.mod 1.26.5), add `go vet ./...`, add `permissions:` and `concurrency:`.
      Remaining: `golangci-lint` + migration smoke (after 0.2/0.4).
- [x] **0.7** Backup/restore automation. `scripts/backup-db.sh` dumps `pg_dump -Fc`,
      verifies the archive with `pg_restore -l`, prunes past `RETENTION_DAYS` and
      optionally `rsync`s to `BACKUP_REMOTE`. Installed on the VPS as the daily
      systemd user timer `skyward-backup.timer` (03:15, on-box
      `/srv/qouver/apps/skyward/backups`, 14 days ≈ 1 GB). Restore drill +
      single-replica constraint documented in runbook §0 and executed once with
      matching row counts. **Open:** no off-box `BACKUP_REMOTE` destination yet.
- [x] **0.8** Docs sweep: migration index now covers 16–18, `docs/README.md`
      range, `maintainer-standard.md` §5 range, root `README.md` (Go floor,
      deploy description, Makefile targets), runbook retired-function status.
- [x] **0.9** Seed reference data via `migrations/20_reference_data_seed.sql`
      (446 `airports` + 65 `aircraft_models`, `ON CONFLICT DO NOTHING`) so a fresh
      env is actually usable; `scripts/dump-reference-data.sh` regenerates it from
      a live database. Applied to prod/`skyward_test` as a no-op (446/65 unchanged).

## Phase 1 — Correctness & security (small diffs; each fix gets a regression test)

Every item below must fail-then-pass with a DB-backed test once 0.4 lands.

- [x] **1.1** Loan servicing in `ProcessLoanPayments` / `ProcessAircraftFinancingPayments`
      (`dayboundary.go`). The audit called the ignored `UPDATE loans` error a P0
      fund-loss bug; **that framing is wrong** — Postgres aborts the whole
      transaction when a statement fails, so `COMMIT` rolls back and no money
      moves. Two real defects were found while proving it with a test:
      (a) the ignored error also left the local `cash` counter decremented, so a
      later loan for the same user was wrongly treated as unaffordable and took a
      late fee; (b) **`rows.Scan` errors were ignored and `monthly_payment` is
      nullable** — one NULL row made the scan fail, pgx closed the rows, and every
      remaining loan for that user was silently skipped: never paid, never
      penalised, never defaulted. Fixed by scanning into `*float64`, checking the
      scan error, checking the `UPDATE` error (rollback + log) and logging
      `rows.Err()`. Verified with four DB tests that fail-then-pass; prod has 2
      active loans, 0 with NULL `monthly_payment`, so (b) was latent, not active.
- [x] **1.1b** Same class as 1.1, audited across `bots.go` and `simulation.go`. Two
      real defects fixed: (a) the bot-list query selected nullable columns
      (`users.hq_airport_iata`, `users.auto_grounding_threshold`) plus
      `bot_profiles.*` through a LEFT JOIN while ignoring the `rows.Scan` error —
      one NULL row closed the rows and every remaining bot was skipped, never
      simulated; (b) `simulation.go` scanned the nullable
      `auto_grounding_threshold` into a plain `float64`, so one NULL user had
      their entire simulation transaction rolled back every tick (no revenue, no
      costs, no clock advance). `botHandlePricing`'s discarded query error is now
      logged — observability only: the suspected nil-rows panic did **not**
      reproduce (pgxpool returns non-nil rows and reports the error via
      `Next`/`Err`). Other sites audited: `reapBankruptBots` and
      `routePerformance` scan only NOT NULL columns → safe. Prod has 0 NULLs in
      every affected column, so both defects were latent.
      **Lesson:** two audit "P0"s in this batch (1.1, 1.1b) did not hold up when
      reproduced; label findings P0 only after a failing test exists.
- [x] **1.2** Worker: `ticker.Reset` now happens on the success path too, via
      `tickInterval(base, errors)` (`worker.go`). Previously the reset only ran in
      the error branch, so the last backoff stuck permanently after recovery and
      the world tick ran far faster than `tick_interval_seconds`. Unit-tested
      (`tickInterval` is pure: base when healthy, exponential backoff capped at
      60s when failing).
- [x] **1.3** Single `*engine.Engine` in `main`, passed into `registerRoutes`
      (`main.go`). Two `engine.New` calls meant two `tickMu` mutexes, so
      `POST /admin/world/tick` could overlap the worker tick (AUDIT-09 guard was
      a no-op), and the mutation engine never received `Hub`.
- [x] **1.4** Lease (`fleet.go`) and aircraft financing (`bank.go`) now check
      `tx.Commit`: a failed commit returns "commit failed" with the
      pre-transaction balance instead of reporting success for an aircraft/loan
      that was never written while the deposit debit rolled back.
- [x] **1.5** `BankRepayLoan` returns 400 for a malformed body. An empty body still
      means "repay the whole loan" (`Amount` nil) — `io.EOF` is the only decode
      error treated that way. The handler test drives the real `AuthGuard` + JWT
      path with a nil engine, so it passes only because the body is rejected
      before the engine is touched.
- [x] **1.6** Both day-boundary servicing loops abort when `GetBalance` errors.
      Previously the discarded error left `cash = 0`, so every loan was treated as
      missed — 10% late fee, rising `missed_payments`, eventually default plus
      grounded collateral — because of a single transient read error.
- [x] **1.7** Owner-table writes scoped with `AND user_id = $n` (`routes.go`
      delete + update, `fleet.go` repair, `simulation.go` wear). Note: all four
      were already preceded by an ownership `SELECT` that returns early, so this
      is hardening against future edits rather than a live hole — which also means
      no discriminating test exists for it.
- [x] **1.8** 500s are logged again. All 97 `httperr.WriteError` call sites pass
      `nil` for the logger, and `WriteError` only logged when that was non-nil, so
      no handler-level 500 ever left a server-side trace. `WriteError` now falls
      back to `slog.Default()` and `main` calls `slog.SetDefault(logger)`, so
      those records land in the same sink as the rest of the app. Tests cover the
      logged case and assert client errors are not logged.
- [x] **1.8b** 500 responses now carry a generic `internal error` message; the cause
      stays in the log. Client errors (400/404/409) keep their curated messages,
      and there are tests for both. Decided with the user (client-visible change).
- [x] **1.9** `hq_airport_iata` no longer appears in the competitor-insights payload
      (struct field, SELECT and Scan all dropped) — `GET /leaderboard/competitors/{id}`
      only requires a bearer token, so any logged-in player could read any
      competitor's HQ airport, and that value is one of the three password-recovery
      factors. The FE needed **no** change: the leaderboard model never read the
      field (grep-verified). Regression test asserts the marshalled payload contains
      no `hq_airport_iata`; before the fix it leaked `"CGK"`.
- [x] **1.9b** `/auth/login` gained the same `WindowLimiter` guard as
      reset-password: 30 attempts/15 min per IP plus 10 per username, counted
      before the user lookup so attempts on unknown usernames still cost the
      attacker, and cleared on a successful login. Wired in `main`. DB-backed test
      drives ten 401s and asserts the eleventh is 429 with code
      `too_many_requests`, and that a different username is unaffected.
- [x] **1.10** Dead code deleted: `internal/domain` (7 model types, zero
      references anywhere including tests), `Store.Tx` (no callers; the engine
      opens its own transactions), and `LedgerService.DebitAccount` /
      `CreditAccount` (defined, never called). Removed the now-unused imports in
      `store.go`; `go build`/`vet`/tests green.
- [x] **1.11** `FleetError.props` now includes `message`. Without it, two errors
      that differed only in text compared equal, so `emit` skipped the state and
      the second message never reached the UI.
- [x] **1.12** Realtime is disconnected on logout and reconnected on login.
      `GoRealtimeClient.disconnect()` existed but had **no caller**, so after
      logout the socket kept running with the previous session's token.
      `GatewayFactory` gained `existingRealtimeClient` (no forced instantiation)
      and `AuthCubit` calls it after logout (even when the gateway logout throws)
      and after login/register/auto-login — the latter because already-mounted
      cubits never call `connect()` again.
- [x] **1.13** Auth errors are mapped from the structured `code`
      (`unauthorized`, `conflict`, `validation_error`, `too_many_requests`,
      `service_unavailable`) instead of substring-matching `toString()`.
      `AuthGatewayException` carries the `code` (populated from `ApiException`)
      and `AppError.isUnauthorizedError` uses it too. Unknown exceptions no longer
      reach the UI as `toString()` — they show a generic message. Curated gateway
      messages (from the API error envelope) are still shown verbatim, which is
      the pre-existing contract asserted by the layer-3 auth test.
- [x] **1.14** Removed `postgrest` (declared, never imported) and `cupertino_icons`
      (no `CupertinoIcons` usage) from `pubspec.yaml`; the description no longer
      mentions Supabase. `pubspec.lock` regenerated.

## Phase 2 — Consistency & robustness

- [x] **2.1** `BankService` returns wrapped errors for infra failures instead of
      `MutationResult{Success:false}` with a nil error, which the handler turned into
      a 400 whose message was "transaction error" / "ledger debit failed" — and
      which, after 1.8b, would have reached the player as nothing useful at all.
      22 sites in `bank.go` converted (take loan, repay, refinance, finance
      aircraft — Begin/Commit, ledger calls, inserts); genuine rejections
      (insufficient cash, active-loan cap, tier gates, bad amount/term) keep
      `Success:false` + 400. Single-row loads now split on `pgx.ErrNoRows`: no row =
      business rejection, anything else = infra, so a DB failure is no longer
      reported as "Loan not found". The four bank handlers pass the cause through
      `httperr.Wrap`, so even with 1.8b's generic 500 body the real error stays in
      the log (`TestWriteErrorWrapKeepsCauseOutOfBody`, verified fail-then-pass).
      Still on the old shape: `fleet`, `routes`, `settings`, `bankruptcy`.
- [x] **2.2** New `core/utils/coalesced_load.dart` holds the load-coalescing guard
      as a `CoalescedLoad<S>` mixin (one in-flight slot: a second call awaits the
      running load and drops its arguments). Fleet, routes, finance's ledger load
      and leaderboard each replaced their hand-rolled `Future<void>? _activeLoad`
      field with it. Left alone on purpose: `BankCubit`'s own coalescer (it also
      queues a trailing re-run instead of dropping it, AUDIT-19), finance's
      `_activeSnapshotRefresh` (a different refresh path), leaderboard's per-competitor
      insights in-flight flag, and the events/achievements cubits (no guard at all).
      **Data-preserving `BankActionLoading`:** the four money actions (take loan,
      finance aircraft, repay, refinance) used to `emit(const BankLoading())`, a
      state with no fields, so the panel collapsed to an empty spinner and back on
      every action. `BankActionLoading extends BankLoaded` carries the cached
      loans/accounts/transactions, so every existing `is BankLoaded` branch keeps
      rendering (the `bank_panel` switch, the dashboard notification refresh,
      `finance_view`, `ifrs_report_panel`) while `bank_panel`'s dialog button still
      shows its spinner through an extended `buildWhen` and
      `isLoading = state is BankLoading || state is BankActionLoading`.
      Tests: five action expectations updated to `const BankActionLoading(loans: [])`
      plus one new test proving the loaded data survives the action, verified
      fail-then-pass (reverting the `takeLoan` emit to `const BankLoading()` fails
      it). `flutter analyze` clean, all 405 app tests pass.
      No manual click-through was performed: this environment runs the test suite,
      not the desktop app.
- [x] **2.3** Config routing + the loan gates the port had dropped.
      **The notable find:** `TakeLoan` never ported `take_loan`'s gates. It had no
      loan-type whitelist, no `min_loan`, **no principal cap at all**, and read its
      rate from a hardcoded `Standard` tier — so any player could borrow any amount
      at the Standard rate regardless of credit. Ported faithfully from the SQL:
      type whitelist (`unsecured`/`secured`/`credit_line`), tier resolved from
      `credit_scores.tier` (the day-boundary result; new players default to score
      500 → Standard, as in SQL), per-type cap and rate from `credit_tier_config`
      (unsecured → `max_unsecured`/`rate_unsecured`; credit_line → half the cap and
      `rate_unsecured + 0.02`; secured → the SQL's "requires collateral" rejection,
      since AUDIT-12 still refuses collateral outright), `min_loan`, and the SQL's
      own rejection texts. Config JSON paths verified against prod
      (`{Standard,max_unsecured}`=5,000,000, `{Standard,rate_unsecured}`=0.12,
      `{Platinum,max_unsecured}`=15,000,000, `{min_loan}`=100,000).
      `calcMaxWeeklyFlights` and `calcLeaseDeposit` no longer hardcode 168 and 0.10 —
      callers pass `max_weekly_flights` / `base_lease_deposit_percentage`. Both were
      deviations: the SQL's `calculate_route_max_weekly_flights` reads the config and
      `calculate_required_lease_deposit` reads `base_lease_deposit_percentage` (the
      asset-percentage brackets stay hardcoded because the SQL hardcodes them too).
      **Config contract test** (`internal/engine/config_contract_test.go`, hermetic —
      reads files only): every key the Go code reads must be seeded in
      `17_game_config_seed.sql`, and every seeded key must be referenced by code or
      SQL. Verified fail-then-pass in both directions. It surfaced two **dead keys**
      nobody reads (not even the SQL): `bot_distress_cash_threshold` and
      `bot_route_optimization_cooldown_hours` — listed explicitly in the test so a
      *new* dead key still fails. Not wired here: the Go code deliberately computes
      bot reserves per archetype and uses its own 4-hour cooldown, so wiring them
      would change game balance and needs a product call.
- [x] **2.4** `TickSnapshot` (`internal/engine/snapshot.go`) reads the 17 tick
      `game_config` keys in **one** query and the active `game_events` rows in
      **one** query per `WorldTick`; `ProcessPlayer`/`ProcessBots` take it as a
      parameter and the single-player sync endpoint passes nil, loading its own.
      Per-player queries inside `ProcessPlayer` went from 18 (16 config + 2 events)
      to 3, and the two per-route event lookups (2NR) are now in-memory. Event
      selection reproduces the replaced queries exactly — newest matching
      `start_game_time`, `effect_type` filter only where the old query had one, and
      1.0 on no match (the old code ignored `ErrNoRows` with the variable already
      initialised to 1.0). Verified two ways: a hermetic unit test
      (`snapshot_test.go`) and an equivalence run in `skyward_test` with synthetic
      events, old query vs new query+filter for each event type (fuel 1.20/1.20,
      demand 1.40/1.40, capacity 0.80/0.80, no-match → 1.0/1.0).
      **Deliberate behaviour change:** a failed config/events read now fails the tick
      instead of each `getConfigNum` silently falling back to Go defaults — that
      silent divergence is what AUDIT-10 complained about, and the worker retries
      with backoff.
      Not covered here: the bots' decision-phase `getConfigNum` reads (~11, once per
      tick rather than per bot), `dayboundary.go`'s two keys (per player per day),
      and `GenerateGameEvents`' per-candidate `EXISTS` check.
- [x] **2.5** `GetAirports` no longer uses `SELECT *` — `pgx.RowToStructByPos` maps by
      position, so adding a column to `airports` would have broken the endpoint at
      runtime with no compile-time warning. Column order verified against the
      baseline and the live table (7 columns, matching the struct); it was the only
      `SELECT *` left in the API. `GetFinanceSnapshot` now checks its four ignored
      `Scan` errors (fleet stats, active routes, game time, rolling 30d): a failed
      scan used to leave zeros, and a failed `game_current_time` read left a zero
      timestamp, making the rolling window "since year 1" so the *entire* transaction
      history was reported as 30-day revenue/expense — a wrong number served as 200.
      Statements re-run read-only against prod: column counts match the scan
      destinations (5/1/1/2).
- [x] **2.8** Triaged the 2.5 survey backlog with an exact AST probe (a bare
      `.Scan` call as a statement, i.e. the error is structurally discarded) instead
      of the line-window heuristic: **64** such sites, **0** `_ =` discards, 69 more
      assign the error to a variable (previously audited). Split by consequence:
      *Fixed — an ignored read error opened a gate or corrupted state:* the
      `actor_type` read in `checkTierGate` (`fleet.go`) and `FinanceAircraft`
      (`bank.go`) returned `""` ≠ `"REAL"`, **skipping the GAME-06 tier gate
      entirely**; the `FinanceAircraft`/`Refinance` tier reads silently became
      `Standard`, which picks both the financing cap and the rate; `routes.go`
      `Assign` read `threshold` as 0, disabling the safety grounding gate, and
      `UpdateFreqPrice` read the assigned aircraft as speed 0, making
      `calcMaxWeeklyFlights` return 0 and silently skipping the frequency-capacity
      check; `ProcessLoanPayments` read `actor_type` as `""` and returned, skipping
      all loan servicing for that day without a trace; the `missed_payments`
      re-read after the late fee swallowed both the `UPDATE` and the read error, so
      a failed read (0) postponed default/repossess forever — now one
      `UPDATE … RETURNING missed_payments` with the error logged and the row
      skipped; `calculateCreditScore` computed from zeroed components and the
      zeroed `totalDebt` actually took the **best** branch (`totalDebt<=0 → 180`),
      i.e. a read error *raised* the score — all five component reads now share the
      function's existing 500-placeholder fallback; `routePerformance` appended a
      half-scanned row to the bot's worst-route ranking, and `TerminateLease`
      lacked the AUDIT-08 in-tx row lock + assignment re-check that `Sell` has,
      so a failed pre-read deleted an aircraft still assigned to a route (FK is
      `ON DELETE SET NULL` → ghost route) — now mirrors `Sell`.
      *Deliberate best-effort, left as is:* `fleet.go` pre-read assignment in
      `Sell` (authoritative re-check inside the tx), the `hq_airport_iata` reads
      feeding `deref(hq, "CGK")` tail-number prefixes, `reapBankruptBots`' id scan
      (`""` deletes nothing), the ~28 bot-heuristic reads (degrade conservatively;
      where they could over-borrow, `Bank.TakeLoan` re-validates
      `max_active_loans`), the duplicate-route `EXISTS` (covered by the
      `unique_human_route` unique index), `settings.Save`'s airport `EXISTS`
      (covered by the FK), `GenerateTailNumber`'s uniqueness probe (covered by the
      column constraint), `GenerateGameEvents`' duplicate probe, and the six
      achievement prerequisites (a failed read scores 0, i.e. the award is not
      granted — fails closed).
      **Not covered:** no automated test can reach these paths (the DB-backed
      tests were deleted at the owner's request), so verification was
      build + vet + the hermetic suite plus a manual check in `skyward_test` that
      `UPDATE … RETURNING` yields the post-increment value in one round trip and
      returns 0 rows for a missing id (→ `ErrNoRows` → log + skip).
      Related, still open: `fleet.go` `Sell`/`TerminateLease` discard the error
      from `Ledger.GetUserGameTime`, which stamps ledger rows with a zero
      game date — out of this item's scope, but now on the record.
- [x] **2.9** The IFRS statement and the badges read the same vocabulary through
      separate lists, and production data exposed holes in both.
      *Statement (wrong numbers).* `loan_repayment` (843 rows, 286.2M) and
      `aircraft_lease_deposit` (40 rows, 31.6M) matched no branch at all, so the
      financing outflow and the investing capex were understated and
      `netCashChange` claimed more cash arrived than really did. The
      `txnType == 'late_fee'` comparison was dead: it tested `transaction_type`,
      whose values are only `credit`/`debit`, and production holds no `late_fee`
      row. All three fixed, with a test that pins every key found in
      `bank_transactions` to its bucket plus the
      `netCashChange = operating + investing + financing` identity. Verified
      fail-then-pass first (capitalExpenditure 100 wanted 200, loanRepayments 0
      wanted 250), then re-ran the same rules over all 1.81M production rows:
      0 unmatched, down from 883, with financing in/out balancing at
      396,000,000 against 395,996,376.
      *Badges (labels only).* Five keys fell through to `IfrsGroup.other` and
      read CREDIT/DEBIT: `ticket_revenue` (320k revenue rows), `maintenance`,
      `loan_repayment`, `aircraft_lease_idle` and `aircraft_lease_deposit`.
      *One vocabulary.* `IfrsCategory` now owns every alias group (short forms
      `fuel`/`crew`/`maintenance`, ticket/cargo, lease including idle, capital
      expenditure including the lease deposit, financing in/out) and exposes the
      cash-flow predicates. `ifrs_report_builder`'s five loops and the ledger's
      fuel/ops chip call them instead of keeping local string lists. The builder
      test written for the fix passes unchanged, which is the evidence that this
      part moved no number.
      *Deliberate behaviour changes:* `aircraft_lease_idle` now counts as lease in
      the metrics too, since the income statement already put it in fleet leasing;
      buckets overlap by design and `totalExpense` is not summed from them, so
      nothing is double counted and `leaseExpenseShare` moves by about 0.015%.
      The ledger's fuel/ops filter now also matches the legacy short-form
      `maintenance` rows (95 rows, 123M).
- [ ] **2.6** FE consolidation: three parts, two done.
      *One IFRS category classifier — done.* `features/finance/domain/ifrs_category.dart`
      owns the subcategory sets, the metrics predicates and `groupFor(key)`, shared
      by the metrics cubit, the ledger filters and the two category badges (the
      filters' "kept in sync with FinanceCubit" comment is gone). The mapping is
      bit-compatible with the old switches, and a test pins it against the keys that
      actually exist in production (`bank_transactions`, 1.8M rows, 5 categories).
      That query also surfaced gaps that are left as they were, because closing them
      changes displayed copy or reported figures: `ticket_revenue` (320k rows of
      revenue), `maintenance` (cogs), `loan_repayment` (financing),
      `aircraft_lease_idle` (opex) and `aircraft_lease_deposit` (investing) have no
      display rule, so their badge falls back to CREDIT/DEBIT; and the metrics count
      `aircraft_lease_idle` as operations while the income statement puts the same
      row into fleet leasing. `ifrs_report_builder` keeps its own statement rules on
      purpose (short-form aliases, sign-based cash-flow buckets), with a comment
      saying why.
      *One notification-refresh helper — done.* The dashboard's five BlocListeners
      each rebuilt the same six-argument `refreshNotifications` call; each now hands
      only the state that changed to `_refreshNotifications`.
      *44 dp tap targets — icon-only controls done.* Raised the hit area without
      touching the visible size for `AppTableIconAction` (eleven call sites ask for a
      32 dp chip; it now centres that chip in a 44 dp box), the HUD notification bell
      (~28x24), the notification panel's mark-all-read and close, the sonner dismiss,
      the IFRS report close, and a routes dialog close that was pinned to 32.
      **Owner decision (2026-09-16): the rest stays as it is.** Raising the shared
      buttons and the text chips would grow ~30 call sites' row heights, so
      `AppButton` (height 40), `TactileButton` (36), the 20-26 dp text chips and the
      `dense: true` + `VisualDensity(horizontal: -4, vertical: -4)`
      `CheckboxListTile` in `app_multi_select_field` are a recorded exception rather
      than an open item.
      *Em dashes in user-facing copy — done.* The antislop filter's R-02 forbids
      them. Fixed all 26 outside code comments (24 in the app: `app_strings.dart`,
      the notification messages, the credit tier descriptions, the `'—'`
      empty-value placeholders in the bank, dashboard and route tables; plus the Go
      API's `Aircraft financing down payment` ledger description in `bank.go`, which
      is UI text because it lands in `bank_transactions.description`). Verified in
      prod that no existing row needs migrating: 0 of 1,810,024 descriptions
      contain an em dash (or any other non-ASCII character). The superseded SQL body
      in `00_baseline.sql` keeps its em dash on purpose: editing that function body
      would register as schema drift, since `pg_dump -s` includes function bodies
      and prod still runs the old one. Indonesian em dashes inside `//` comments are
      left alone; R-02 governs UI text, not comments.
- [x] **2.7** `applyBankruptcy` now runs in one transaction with every step checked.
      It was four bare `Exec` calls with the errors dropped, so a failure mid-way
      left the player half-bankrupt — status `Bankrupt` while loans stayed `active`
      and kept being serviced, or routes still operating. Failure now logs and rolls
      back instead of half-applying. The day-boundary negative-day block got the same
      treatment: increment, read-back and reset are checked; a failed read-back skips
      the decision instead of inventing 0 (which would postpone bankruptcy forever or
      trigger it without evidence); a failed reset is logged because stale negative
      days would bankrupt the player days later.
      `botHandlePricing` no longer ignores its two `Scan`s — a failed row scan leaves
      `price=0`, which reads as "cheapest by a wide margin" and would raise a fare
      from a phantom number, so the row is skipped; a failed competitor query also
      skips rather than comparing against zeros; `rows.Err()` ends the loop before
      stamping the review so a truncated iteration is retried. (The discarded query
      error at `bots.go:483` was already fixed in 1.1b.) Statements re-run inside a
      rolled-back transaction against prod to confirm they are valid as a set.

## Phase 3 — Structural refactors (breaking; one approved batch at a time)

Each needs a short written proposal (blast radius + migration path + test plan).

- [ ] **3.1** Server-owned route assessment (`GET /routes/assess`); delete the
      ~300 LOC of client-side economics in the planner.
      **Proposal written 2026-09-16:**
      [proposal-3.1-route-assess.md](proposal-3.1-route-assess.md). Verified
      against code: 269 LOC measured (not estimated), 12+ `GameConstants` in the
      planner are each labelled a fallback for an authoritative `game_config` key,
      the client already fetches `/game-config` (and uses it for the HUD fuel
      price) while the planner ignores it, and the server already owns the
      GAME-25 model (`routeDailyDemand`, `allocateCabins`, `routeWeeklyProfit`,
      `TickSnapshot`) with a hermetic test to copy.
      **Approved 2026-09-16** (owner answered all 5 questions: optional
      `aircraft_id` returns one entry per compatible aircraft; include the
      wear preview in v1; always send multipliers including 1.0; keep load
      factor/ASK/RPK client-side; show an explicit "assessment unavailable" +
      retry and label the last result as an estimate; add a narrow interface so
      the handler is testable with a fake).
      **Three further divergences confirmed while implementing Step 1** — the
      client's planner does not charge crew cost at all; its maintenance basis
      uses `distance/speed + turnaround` where the tick uses `distance/speed`;
      and its self-heal model is `idle hours x rate` where the tick is
      `gross damage x maintenance_auto_repair_rate`. Its flight cap differs too
      (`totalWeeklyHoursCap / cycleDuration` vs the tick's
      `max_weekly_flights / flightHours`). These are the concrete justification
      for the endpoint, not stylistic preferences.
      **Step 1 (Go, inert) landed in `6aa87a3`:** `Engine.AssessRoutes` (pure,
      reuses the tick helpers, reads config + event multipliers from
      `TickSnapshot`) and `Engine.AssessRoute` (haversine distance and
      `demand_index` from `airports`, player grounding threshold, candidates
      from `fleet_aircraft`, incompatible aircraft filtered), plus
      `RouteAssessHandler` on the narrow `routeAssessor` interface and
      `GET /routes/assess` behind AuthGuard. Parameters are query-string, not
      a body, because the client's `ApiClient.get` only sends `query`. Tests:
      8 hermetic engine + 4 handler (401 / malformed query / 400-404-500
      mapping / success); fail-then-pass checked for crew, self-heal, lease and
      error mapping; `ServeMux` precedence for `/routes` vs `/routes/assess`
      confirmed by an experiment, not assumed. Validated against prod data:
      CGK-DOH pools 160.34 passengers/day, 70.15 per flight on a 230-seat
      A321neo (30.5% load factor) — the arithmetic is faithful, so the band is
      `weak` for every long-haul route in the current world. Still to do:
      Steps 3-4 (switch over, delete the ~269 LOC + dashboard KPI, docs).
      **Step 2 (client, inert) landed in `7ca721a`:** `RouteAssessResultDto`
      (+ wear/viability/multipliers/inputs_used) parsing the server JSON,
      `RoutesGateway.assessRoute` + Go implementation, `RoutesCubit.assessRoute`
      with "last successful result is kept on failure" (owner answer 5), and a
      pure client-vs-server comparator logged only in debug. 20 new tests (461
      total, from 441). The DTO is tested against a **real** payload captured
      from `GET /routes/assess` against prod, including re-checkable invariants
      and the live event multipliers (fuel 0.795, maintenance 1.125). One more
      client/server mismatch surfaced here: the client model stores
      `expectedPassengersPerFlight` as an `int` (truncating 70.15), while the
      server returns a double. Deliberate: the view still shows the old
      numbers, so the switchover in Step 3 can be validated first.
- [ ] **3.2** Unified mutation pipeline (`MutationRunner`) + push DTO knowledge
      out of cubits into gateways.
- [ ] **3.3** Decompose the five god views; shrink backend god files.
- [ ] **3.4** Per-tick config injection replacing ~30 `getConfigNum` call sites.
- [ ] **3.5** Money boundary: round at the Ledger, then migrate float64 →
      int64 cents / decimal inside the engine.
- [x] **3.6** ~~Clean-room baseline v2~~ — **dropped.** D1 answered 2026-09-16:
      no rewrite; 0.2c/0.2d made the existing dump self-sufficient and the drift
      check now proves a fresh apply matches prod.
- [ ] **3.7** Real deploy pipeline: versioned artifacts, gated migration step,
      health-gated rollback, retained logs.

## Owner decisions

- [x] **D1** Answered 2026-09-16: **no clean-room rewrite.** The additive patch in
      0.2c makes the existing dump self-sufficient for a fresh cluster. The dump stays
      as the record of prod's lineage, so `3.6` (clean-room baseline v2) is not
      planned. (a) under 0.2d may still need a one-line change to the baseline.
- [x] **D2** Answered 2026-09-16: remove the field. Done in 1.9 — the FE needed no
      change (the leaderboard model never read it), so the "breaks the FE intel pane"
      caveat did not hold. The server-issued-secret alternative was not needed.
- [ ] **D3** WebSocket token transport out of the query string — do it in Phase 1
      or defer to Phase 3?
- [ ] **D4** Re-introducing any of the force-reverted work (GAME-01/GAME-10 et al.)
      is out of scope here; separate decision.
- [x] **D5** Answered 2026-09-16: disable RLS to match prod. Done in
      `21_disable_rls_to_match_prod.sql`; verified 14 tables/15 policies → 0/0.
- [x] **D6** Answered 2026-09-16 (3.1): **keep the viability thresholds as they
      are.** Real long-haul routes load at ~30% (CGK-DOH: 160.34 passengers/day
      on a 230-seat A321neo), so most will show `weak` — that is the economy
      being honestly reported, not a display bug. Lowering the bands to make the
      UI look better was rejected. The root cause (world demand tuning —
      `demand_pool_scale` / `airports.demand_index`) is tracked separately as
      item 3.8 below, deliberately outside 3.1.

## Roadmap items raised during Phase 3

- [ ] **3.8** World demand tuning (`demand_pool_scale`, `airports.demand_index`).
      Raised by 3.1's D6: long-haul routes load at ~30%, so the planner labels
      almost everything `weak`. The planner is faithful to the tick, so the
      question is whether the world's demand values are the intended balance.
      Needs its own analysis of the demand curve before any number moves.

## Deliberately out of scope (protect from churn)

See the synthesis doc's "Explicitly NOT doing" section — the union of the three
auditors' intentional-design lists (dashboard-shell cubit composition, callback-based
cubit decoupling, transient error states, debug-gated mock leaderboard, AUDIT-14…21
comment trails, `IndexedStack` + `LazyTabCubit`, static DI singletons, dark-only
theme, `DebitTxAllowNegative` for simulation costs, single-replica `tickMu`, bot tier
exemption, `?token=` WS auth until D3, float64 engine until 3.5, etc.).
