# Decisions and open work

Status: current | Last verified against code: 2026-09-17

The refactor backlog (audit-driven, phases 0–3) was worked through in September
2026 and the tracked plan was retired once the items closed. This page is what
remains relevant: the owner decisions behind the current shape of the code, and
the work that is still open. The item-by-item history is gone on purpose —
narrative backlogs rot and become misleading. Commit messages carry the detail.

Origin of that backlog: an independent audit of `6b779f3` by three read-only
reviewers (frontend, backend, infra/DB/docs).

## Owner decisions

- **D1 — no clean-room rewrite** (2026-09-16). The system is patched additively;
  a greenfield baseline was considered and rejected.
- **D2 — remove `hq_airport_iata`** (2026-09-16). Done; the Flutter client
  needed no change.
- **D3 — WebSocket auth via one-time ticket** (2026-09-17). The handshake is
  `GET /ws?ticket=<opaque>`; `POST /ws/ticket` (behind `AuthGuard`) issues a
  30-second single-use ticket. The JWT never enters a URL.
- **D4 — force-reverted gameplay work: still open.** Re-introducing GAME-01 /
  GAME-10 and friends is product work with design spikes, not refactor work.
- **D5 — disable RLS to match prod** (2026-09-16).
- **D6 — keep the viability thresholds as-is** (2026-09-16). The ~30% load
  factor on long-haul routes is the economy reported honestly, not a display
  bug. Demand tuning was split out (see below).

## Open work

Nothing here is scheduled. Each needs a decision before it needs code.

- **`MutationRunner`** — one mutation pipeline across the Flutter client, and
  pushing DTO knowledge out of the cubits. No concrete pain drives it yet; do it
  when the duplication actually hurts, not pre-emptively.
- **Decompose the god views** — five large view files, plus the large backend
  files. Large and unbounded; wants its own session.
- **Deploy pipeline** — versioned artifacts, a gated migration step, and
  health-gated rollback. Needs to be built and tested against a real deploy.
  Increasingly valuable as unreleased commits pile up.
- **World demand tuning** — `demand_pool_scale` and `airports.demand_index`
  (split out of D6). Needs a design first.
- **Six realtime tests wait on wall-clock time** — `go_realtime_client_test.dart`
  and `go_realtime_refcount_test.dart` wait 2.5-8 real seconds for reconnect
  backoff. Under parallel CPU load the scheduling slips and the default 30 s
  timeout fires; this was observed once and looked like a failure. Their timeouts
  were raised to 2 minutes, which treats the symptom. The real fix is to make
  time injectable in `core/realtime/go_realtime_client.dart` and drive these with
  `fakeAsync`, which needs a clock seam the class does not have today. Not done
  because it is a separate piece of work from the DRY pass.
- **Dead SQL functions in `00_baseline.sql`** — ~113 dumped from the Supabase
  era, 13 still reachable. Pruning was attempted 2026-09-17 and **abandoned**:
  a dependency analysis by reading code missed live callers twice (once a
  trigger chain, once `haversine_distance` called from Go), and the failure mode
  is silent — wrong economy numbers, not an error. Verified evidence for the 13
  live functions is in the file's header. Revisit only with a way to prove
  safety, e.g. shadow traffic.

## Standing rules that came out of this work

- **Money**: accept/reject comparisons use the helpers in
  `internal/engine/money.go`, never raw operators on `float64`. Amounts are
  rounded to the cent once, at the ledger boundary. Thresholds against policy
  constants stay raw. Details: `../standards/maintainer-standard.md`.
- **Config**: the tick reads `TickSnapshot`, not `getConfigNum`. The remaining
  `getConfigNum` callers are outside the tick and must read the freshest value.
- **Route economics**: the server is authoritative. The client does not model
  demand, fares, or wear; it renders `GET /routes/assess`.
