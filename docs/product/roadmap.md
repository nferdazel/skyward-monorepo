# Skyward Product & Engineering Roadmap

Status: current | Last verified against code: 2026-09-11

Living backlog, distilled 2026-09-11 from the (now retired, gitignored) root
`GAME_REVIEW_TASKLIST.md` (90/135 done — full copy kept at repo-root
`_audit/docs-pre-restructure-2026-09-11/`), `../reviews/game-design-review-2026-09.md`,
`../reviews/aviation-realism-review-2026-09.md`, and the two page-audit plans (removed;
digest below). IDs `GAME-xx` / `AVIATION-xx` trace back to the two review docs.

Rule of use: tick an item off **in the same commit** that implements it. This file is the
only product backlog — no shadow checklists at repo root.

## 1. Gameplay systems (big — design spike first)

- [ ] **GAME-01 · Active decision points in the core loop** — design doc proposing 3–5
      active events requiring player choice; implement one pilot end-to-end (e.g. fuel
      shock response); surface via notifications (feature exists, commit `93f7f3b`).
- [ ] **GAME-14 · Real/async competition** — async competition vs other players'
      snapshots or weekly challenge leaderboards; increase bot realism/response (builds
      on GAME-22 bot price response, done in `cb0a7bc`).
- [ ] **GAME-09 · Late-game money sinks** — slot fees / crew training / compliance /
      hangar capacity.
- [ ] **GAME-10 · Repair & maintenance depth** — partial repair; maintenance
      scheduling; component wear.
- [ ] **GAME-16 · Replayability hooks** — scenario modes; difficulty settings; new-game+.
- [ ] **AVIATION-14 · ETOPS / overwater constraints** — design ETOPS radius model
      (180/207/330 min × cruise); tag routes crossing water and restrict twin-engine
      wide-bodies; surface ETOPS rating per aircraft in fleet UI.
- [ ] **AVIATION-15 · Hub-and-spoke / connecting-pax bonus** — design hub-bonus
      multiplier for multi-route airports.
- [ ] **AVIATION-16 · Seasonality / day-of-week demand** in the demand-pool model.
- [ ] **AVIATION-17 · Slot constraints** at congested airports.
- [ ] **Phase-2b (deferred from GAME-02)** — shared demand pool across players + bots.

## 2. Player UX & decision support (small wins)

- [ ] **GAME-12 · P/L trends (partially done)** — KPI sparklines on Overview shipped in
      `9645222`; remaining: P/L chart on the Finance page.
- [ ] **GAME-17 · Pre-fill recommended fare** in route planner + "recommended" badge.
- [ ] **GAME-18 · Route profitability preview before creation** — projected weekly P/L
      in planner (depends on the GAME-02 demand model); deferred sub-item:
      load-factor-vs-frequency preview.
- [ ] **GAME-19 · Beginner guidance in fleet catalog** — "recommended"/"best value"
      badges; progression guidance.
- [ ] **GAME-20 · Promote Bank** to top-level nav or add a CTA.
- [ ] **GAME-23 · Mini route map** on Overview.
- [ ] **GAME-24 · Visible game clock + speed control.**
- [ ] **AVIATION-11 · Label/document fuel-burn units** in UI.
- [ ] **AVIATION-23 · Document the 168-flights/week cap** as theoretical max.

## 3. Page redesigns (carried over from removed plans — re-audit before starting)

- [ ] **Financials page — "Command, then detail"** (from deleted
      `docs/plans/financials-page-redesign.md`): Overview rebuild into 3 zones
      (view-layer only, cubit untouched), dedupe executive-vs-IFRS summary, transactions
      tab from data-dump to filterable day-grouped ledger, dataviz polish (extend
      `AppLineChart`, don't fork). Partially addressed by `1f7d6be` (ledger headers,
      debt-aware runway, dead columns).
- [ ] **Fleet page pass** (from deleted `docs/plans/fleet-page-audit.md`):
      P0 — finance-term label bug, repair cost visible + fixed-width action cell, honest
      STATUS (EARNING/IDLE/GROUNDED with lease burn); P1 — fleet summary strip, merged
      identity cell + cycles-to-grounding, catalog SPEED column + per-row affordability;
      P2 — acquire-dialog cash impact & lease-vs-buy breakeven, filter result counts,
      finance dialog presets, bulk repair (needs a gateway check first). Partially
      addressed by `e5f5ffa` (fleet row UX). All view+strings except bulk repair.

## 4. Open product questions

- [ ] **GAME-21 · Cargo's fate** — keep cosmetic or make real? Conflicts with
      **AVIATION-20** (raise cargo share to ~8%). Deliberated 2026-09-11: **not now**;
      revisit when a gameplay slot opens.
- **Financials hero metric** — Cash / Runway / 30d-Net is the default; swap in weekly
  loan obligations if the economy makes that the survival number (presentation decision).

## 5. Engineering debt

- [ ] Backend infra test gap: `handler/`, `store/`, `middleware/`, `worker/`,
      `realtime/` have zero tests (`engine/` + `auth/` are covered).
- [ ] Worker tick interval does not re-read `season_clock.tick_interval_seconds` at
      runtime (`internal/worker/worker.go` TODO).
- [ ] `worker.Status.NextTickAfter` declared but never populated.
- [ ] `internal/domain` is dead: no importers; `domain.Money` is a string skeleton while
      money flows as `float64` (the decimal claim in the old api README was aspirational).
- [ ] `apps/app/lib/core/config/app_env.dart` still declares unused `SUPABASE_URL` /
      `SUPABASE_KEY` env fields.
- [ ] SQL audit surfaces `get_world_tick_scheduler_health()` / guardrail reports still
      reference the pg_cron era — verify or retire (see `../operations/runbook.md`).
- [ ] Add tests where stale-state regressions are likely (carried from the old
      backend-hardening plan; Phase-3/6 doc-hygiene items were closed by the 2026-09-11
      docs restructure).

**Standing rule** (from the game review): `game_config` is authoritative at runtime —
any balance change must update the DB row, not just the `game_constants.dart` fallback.
