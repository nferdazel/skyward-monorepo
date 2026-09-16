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
- [ ] **0.2c** Role provisioning. `00_baseline.sql` creates `anon`,
      `authenticated`, `service_role` (Supabase-era) but the API connects as
      **`skyward_app`** (present in prod, `login=true`), which no migration
      creates or grants to. A fresh env therefore still needs the role + grants
      set up by hand.
- [x] **0.3** Migration ledger + `make migrate`. `migrations/19_schema_migrations.sql`
      creates `schema_migrations` and backfills 00–18; `scripts/migrate.sh` applies
      pending files in order, records filename+checksum, verifies checksums of
      previously-recorded files, and refuses to run against a non-empty database
      that has no ledger. Runbook §5 updated (`-1` noted as legacy).
- [ ] **0.3b** `make drift-check`: normalized `pg_dump -s` snapshot committed and
      compared against a scratch apply, so schema drift is caught in CI.
- [x] **0.4** DB-backed test harness. `apps/api/internal/testsupport` (`NewTestPool`,
      `Reset` via `TRUNCATE users CASCADE`, seeds for user/season/model/aircraft/
      bank account/config/transaction) skips unless `TEST_DATABASE_URL` is set, so
      `go test ./...` stays hermetic. Its own smoke test proves connect + seed +
      reset against a real schema. CI runs a `postgres:18` service, applies
      migrations with `make migrate`, and exports `TEST_DATABASE_URL` for the Go test
      step. DB-backed runs need `go test -p 1`: packages execute in parallel and
      several share the test database while `Reset` truncates `users`, so without
      it they delete each other's fixtures. Runbook §6 documents the tunnel
      workflow.
- [ ] **0.5** Deploy hardening in `deploy/deploy-vps.sh`: keep
      `bin/skyward-api.prev`, gate restart on `/readyz` with rollback, atomic web
      swap (build to `web.new/` then rename), skip the API restart when only
      `apps/app/` changed, retain full build logs.
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
- [ ] **1.8b** *Needs a decision (client-visible).* `WriteError` echoes
      `he.Message` into the 500 response body, so server-side text reaches the
      client — e.g. `main.go` returns `Internal("tick failed: " + err.Error())`
      and the database's own error text would be shown to the user. Genericising
      the 500 message (log the cause, return "internal error") changes what
      clients display, so it needs an explicit call.
- [ ] **1.9** Auth: stop exposing `hq_airport_iata` in public insights
      (password-recovery factor) and add a per-username login limiter.
      *Breaking: removes a public response field — coordinate with the FE intel pane.*
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

- [ ] **2.1** Unified error model: `MutationResult.Success=false` only for business
      rejections; infra failures return wrapped errors (start with `BankService`).
- [ ] **2.2** Shared `coalescedLoad` helper adopted by
      fleet/routes/finance/leaderboard cubits; data-preserving `BankActionLoading`.
- [ ] **2.3** Config: route hardcoded values through `getConfigNum`
      (`routes.go:213`, `fleet.go:413`, credit-tier policy), enforce
      `max_unsecured_loan`/tier gates in `TakeLoan`, add a config-contract test
      (every key read is seeded, and vice versa).
- [ ] **2.4** Snapshot `game_config` + active events once per `WorldTick`
      (removes ~16N + 2NR queries/tick).
- [ ] **2.5** Replace `SELECT *` + positional scans with explicit column lists;
      check snapshot scan errors (`store/read.go:214,253-272`).
- [ ] **2.6** FE: one IFRS category classifier; single notification-refresh
      helper; 44 px tap targets.
- [ ] **2.7** BE: wrap `applyBankruptcy` in one tx; guard bot-pricing nil rows;
      small swallow fixes (`bots.go:483`, `simulation.go:471`).

## Phase 3 — Structural refactors (breaking; one approved batch at a time)

Each needs a short written proposal (blast radius + migration path + test plan).

- [ ] **3.1** Server-owned route assessment (`GET /routes/assess`); delete the
      ~300 LOC of client-side economics in the planner.
- [ ] **3.2** Unified mutation pipeline (`MutationRunner`) + push DTO knowledge
      out of cubits into gateways.
- [ ] **3.3** Decompose the five god views; shrink backend god files.
- [ ] **3.4** Per-tick config injection replacing ~30 `getConfigNum` call sites.
- [ ] **3.5** Money boundary: round at the Ledger, then migrate float64 →
      int64 cents / decimal inside the engine.
- [ ] **3.6** Clean-room baseline v2 (if not completed under 0.2).
- [ ] **3.7** Real deploy pipeline: versioned artifacts, gated migration step,
      health-gated rollback, retained logs.

## Owner decisions

- [ ] **D1** Approve a clean-room `00_baseline.sql` (breaking for the fresh-apply
      path; prod untouched).
- [ ] **D2** Auth recovery hardening: remove `hq_airport_iata` from the public
      insights response (breaks the FE intel pane) **or** switch recovery to a
      server-issued secret.
- [ ] **D3** WebSocket token transport out of the query string — do it in Phase 1
      or defer to Phase 3?
- [ ] **D4** Re-introducing any of the force-reverted work (GAME-01/GAME-10 et al.)
      is out of scope here; separate decision.
- [ ] **D5** RLS posture for self-hosted: disable RLS to match prod (recommended —
      the Go API is the sole writer and already scopes ownership in SQL), or keep
      RLS and grant the app role appropriately?

## Deliberately out of scope (protect from churn)

See the synthesis doc's "Explicitly NOT doing" section — the union of the three
auditors' intentional-design lists (dashboard-shell cubit composition, callback-based
cubit decoupling, transient error states, debug-gated mock leaderboard, AUDIT-14…21
comment trails, `IndexedStack` + `LazyTabCubit`, static DI singletons, dark-only
theme, `DebitTxAllowNegative` for simulation costs, single-replica `tickMu`, bot tier
exemption, `?token=` WS auth until D3, float64 engine until 3.5, etc.).
