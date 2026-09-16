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
- [ ] **0.2** Fix `00_baseline.sql` so a fresh DB can be bootstrapped:
      remove the two raw dump-output lines, replace Supabase-only roles/grants
      (`authenticated`, `service_role`), resolve the `pg_cron` dependency
      (`CREATE EXTENSION` or justify removal). Prefer a clean-room baseline
      regenerated from a verified apply of 00–18. *Breaking for fresh-apply only.*
- [ ] **0.3** Add a `schema_migrations` ledger + `make migrate` + `make drift-check`
      (normalized `pg_dump -s` vs a committed snapshot); standardize the
      `BEGIN;/COMMIT;` vs `psql -1` convention (migrations 01–06 lack `BEGIN`;
      headers say `-1` while files also `COMMIT`).
- [ ] **0.4** DB-backed test harness (`TEST_DATABASE_URL`, schema from migrations)
      + a CI service-Postgres step. Depends on 0.2.
- [ ] **0.5** Deploy hardening in `deploy/deploy-vps.sh`: keep
      `bin/skyward-api.prev`, gate restart on `/readyz` with rollback, atomic web
      swap (build to `web.new/` then rename), skip the API restart when only
      `apps/app/` changed, retain full build logs.
- [x] **0.6** CI: use `go-version-file: apps/api/go.mod` (was pinned 1.22 vs
      go.mod 1.26.5), add `go vet ./...`, add `permissions:` and `concurrency:`.
      Remaining: `golangci-lint` + migration smoke (after 0.2/0.4).
- [ ] **0.7** Backup/restore automation: scheduled `pg_dump` (custom format) with
      off-box copy + a documented restore drill; add a runbook §0 covering
      backup and the single-replica constraint.
- [x] **0.8** Docs sweep: migration index now covers 16–18, `docs/README.md`
      range, `maintainer-standard.md` §5 range, root `README.md` (Go floor,
      deploy description, Makefile targets), runbook retired-function status.
- [ ] **0.9** Seed reference data (`airports`, `aircraft_models`) via migration so
      a fresh env is actually usable (`INSERT … ON CONFLICT DO NOTHING` +
      `make dump-reference-data` exporter).

## Phase 1 — Correctness & security (small diffs; each fix gets a regression test)

Every item below must fail-then-pass with a DB-backed test once 0.4 lands.

- [ ] **1.1** P0 — loan payment: check the `UPDATE loans` error inside the tx and
      roll back; propagate servicing errors (`dayboundary.go:124,184`).
- [ ] **1.2** Worker: `ticker.Reset(w.interval)` on the success path (prevents
      permanent world-time acceleration) (`worker.go:140`).
- [ ] **1.3** Single `*engine.Engine` in `main`, passed into `registerRoutes`
      (restores the AUDIT-09 tick mutex) (`main.go:81,173`).
- [ ] **1.4** Check `tx.Commit` in the fleet/bank financing paths
      (`fleet.go:360`, `bank.go:322`).
- [ ] **1.5** Repay: malformed body must be 400, not "repay the whole loan"
      (`mutation.go:220`).
- [ ] **1.6** Abort day-boundary servicing when `GetBalance` fails instead of
      classifying every loan as missed (`dayboundary.go:92,154`).
- [ ] **1.7** Add `AND user_id = $n` to the four owner-table writes
      (`simulation.go:405`, `fleet.go:257`, `routes.go:71,190`).
- [ ] **1.8** Log 500s with a cause; stop passing `nil` loggers
      (`httperr`/all handlers).
- [ ] **1.9** Auth: stop exposing `hq_airport_iata` in public insights
      (password-recovery factor) and add a per-username login limiter.
      *Breaking: removes a public response field — coordinate with the FE intel pane.*
- [ ] **1.10** Delete dead code: `internal/domain`, unused ledger helpers,
      `store.Tx` (`engine.go:150-176`, `store/store.go:28`).
- [ ] **1.11** FE: `FleetError.props` includes `message`
      (`fleet_state.dart:144`).
- [ ] **1.12** FE: disconnect the WebSocket on logout/user-switch
      (`go_realtime_client.dart:205`).
- [ ] **1.13** FE: map auth errors on `ApiException.code`; stop returning
      `e.toString()` to users (`auth_cubit.dart:147`).
- [ ] **1.14** FE: remove `postgrest` + `cupertino_icons`, fix pubspec description.

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

## Deliberately out of scope (protect from churn)

See the synthesis doc's "Explicitly NOT doing" section — the union of the three
auditors' intentional-design lists (dashboard-shell cubit composition, callback-based
cubit decoupling, transient error states, debug-gated mock leaderboard, AUDIT-14…21
comment trails, `IndexedStack` + `LazyTabCubit`, static DI singletons, dark-only
theme, `DebitTxAllowNegative` for simulation costs, single-replica `tickMu`, bot tier
exemption, `?token=` WS auth until D3, float64 engine until 3.5, etc.).
