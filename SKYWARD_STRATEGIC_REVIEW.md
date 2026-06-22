# SKYWARD STRATEGIC REVIEW COMPLETE

**Date:** 2026-06-23
**Council:** 15 auditors across product, UI/UX, architecture, database, simulation, gameplay, aviation, QA, security, documentation

---

## OVERALL SCORES

| Dimension | Score | Trend |
|-----------|-------|-------|
| **Overall** | **7.5/10** | ↑ from 6.0 |
| Product | 7.0/10 | Strong foundation, missing engagement loops |
| UX | 7.0/10 | Good flows, onboarding needs work |
| UI | 8.0/10 | Bespoke aviation theme, some AI-ish patterns |
| Architecture | 8.5/10 | Exceptionally clean gateway pattern |
| Database | 7.5/10 | Well-hardened, 87 migrations (needs consolidation) |
| Simulation | 8.5/10 | Best-in-class depth |
| Gameplay | 6.5/10 | Deep systems, weak retention hooks |
| Aviation Realism | 7.5/10 | Accurate aircraft data, simplified operations |
| Security | 8.0/10 | Strong RLS + SECURITY DEFINER, minor gaps |
| Documentation | 9.0/10 | Exceptional for this stage |
| Testing | 6.5/10 | Good patterns, coverage gaps |

---

## TOP 10 RISKS

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| 1 | `aircraft_financing` schema conflict (migrations 85 vs 87) | Critical | Create migration 88 to reconcile |
| 2 | 8+ realtime channels per user — scalability ceiling at ~50 users | High | Centralize subscriptions, remove duplicates |
| 3 | No active gameplay loop — idle game masquerading as strategy | High | Add time-limited decisions, competitive actions |
| 4 | No progression/unlock system — everything available from day 1 | High | Gate mechanics behind milestones |
| 5 | Onboarding dumps user on empty dashboard | High | Wire action buttons, auto-navigate to Fleet |
| 6 | Help system is 100% dead code | High | Wire into Settings or TopHud |
| 7 | Ledger auto-pruning destroys history | Medium | Schedule compaction before pruning |
| 8 | Bot AI non-reactive to player actions | Medium | Add competitive response behaviors |
| 9 | Self-healing over-generous for slack schedules | Medium | Cap idle healing or require explicit maintenance |
| 10 | 87 migrations with ~12K duplicate lines | Medium | Consolidation sprint |

---

## TOP 10 OPPORTUNITIES

| # | Opportunity | Impact | Effort |
|---|-------------|--------|--------|
| 1 | Surface built achievements (invisible to players) | Very High | Low |
| 2 | Alliance/codeshare system (social stickiness) | Very High | High |
| 3 | Unlockable progression (tech tree, milestones) | High | Medium |
| 4 | Event system expansion (strategic, not random) | High | Medium |
| 5 | Mobile companion app (market expansion) | High | High |
| 6 | Bot competitive response AI | High | Medium |
| 7 | Airport slot system (strategic scarcity) | Medium | Medium |
| 8 | Historical trend charts (sparklines → full charts) | Medium | Low |
| 9 | Ambient audio design | Medium | Low |
| 10 | Aircraft catalog expansion (100+ models) | Medium | Medium |

---

## WHAT SKYWARD IS TODAY

A well-engineered, single-player airline tycoon simulation with:
- ✅ Best-in-class simulation depth (fare buckets, maintenance, cargo, credit)
- ✅ Exceptional architecture (gateway pattern, Cubit-only, backend-authoritative)
- ✅ Strong security posture (6-phase auth hardening, RLS, SECURITY DEFINER)
- ✅ Excellent documentation (3,800+ lines across 17 files)
- ✅ 232 passing tests, 87 database migrations
- ✅ Distinctive dark tactical console UI with aviation-inspired design

The foundation is **production-grade**. The engine is deeper than most competitors.

---

## WHAT SKYWARD SHOULD BECOME

The definitive **desktop airline management simulation** — deeper than Airlines Manager, more accessible than AirwaySim, more modern than any competitor.

**The path requires 3 investments:**
1. **Retention mechanics** — achievements, progression, daily hooks, social features
2. **Engagement loops** — active decisions, competitive actions, event responses
3. **Aviation depth** — alliances, slots, weather, crew management

---

## RECOMMENDED FLAGSHIP FEATURES

1. **Alliance System** — Form alliances with other players/bots. Shared codeshare revenue, alliance leaderboard, internal communication.
2. **Progression System** — CEO levels, tech tree, aircraft unlock tiers, region expansion.
3. **Event-Driven Gameplay** — Strategic events (fuel hedging, weather response, slot auctions) that require active decisions.
4. **Historical Analytics** — Financial trend charts, performance benchmarking, route profitability over time.
5. **Mobile Companion** — Read-only dashboard, notifications, quick actions for mobile users.

---

## RECOMMENDED FEATURES TO REMOVE

1. **Lease-vs-own wear differential** (0.70 vs 0.50) — Punishes new players, creates no-brainer decisions. Differentiate via economics, not hidden penalties.
2. **Hardcoded ticker tape** — Now dynamic (connected to game state), but still decorative. Consider making it optional.
3. **System Monitor decorative lines** — "RADAR: OPERATIONAL" and "SATCOM: LINK ACTIVE" are fake. Remove or connect to real state.

---

## RECOMMENDED MAJOR REDESIGNS

1. **Realtime Subscription Architecture** — Centralize from 8+ per-user channels to 3-4 shared channels. Eliminates duplicate subscriptions.
2. **Migration Consolidation** — Squash 87 migrations into a baseline snapshot + incremental changes. Reduces onboarding friction.
3. **Gateway Return Types** — Retrofit all gateways to return typed domain models instead of `List<dynamic>`. Follows `AuthGateway` pattern.
4. **SimulationCubit Decomposition** — Extract timer management, world clock sync, and settings caching into separate services.

---

## NEXT PROMPT RECOMMENDATION

```
Execute the Skyward audit action plan:
1. Create migration 88 to reconcile aircraft_financing schema
2. Wire help system into Settings view
3. Remove duplicate user_fleet subscription from RoutesCubit
4. Schedule ledger compaction via pg_cron
5. Implement onboarding action buttons (navigate to Fleet/Routes)
```
