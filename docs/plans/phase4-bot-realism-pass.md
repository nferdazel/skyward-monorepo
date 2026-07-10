# Phase 4 Plan: Bot Realism Pass

## Goal

Make bots feel less scripted and more operator-like without breaking balance.
Bots should make decisions that look like a human player managing an airline,
not a state machine following rigid rules.

## Design Principle

**Parity first**: Every data surface and decision helper used by bots must also
be available to players. No bot-specific tables. If bots need route performance
data, players get it too. This is the same principle that guided Phase 3.

## Current State Summary

After migrations 16-35, the bot system has:
- ✅ Distress stages (stable/cautious/defensive/desperate) with cooldown timers
- ✅ Shared mutation helpers for all fleet/route/bank actions
- ✅ Per-bot error isolation (one bad bot doesn't crash the tick)
- ✅ Demand-biased destination selection
- ✅ Smooth price blending (55% current + 45% target)
- ✅ Archetype-specific parameters (Regional/Aggressive/Balanced)

But bots still feel scripted because:
- ❌ No route-level commercial awareness (revenue, profit, load factor)
- ❌ No aircraft disposal (fleet only grows, never shrinks)
- ❌ No route reassignment (aircraft locked to first route)
- ❌ HQ-locked origin (never establish secondary hubs)
- ❌ Monolithic fleet per archetype (ATR/A320/787 only)
- ❌ No competitive pricing response (only competitor presence/absence)
- ❌ Purchase threshold too high ($45M+ required, most bots never buy)
- ❌ No dead route cleanup (routes persist even if unprofitable)
- ❌ No loan repayment strategy
- ❌ Desperate stage has no recovery mechanism

## Scope

### 4.1 Shared Route Performance Helper

**What**: A shared function that computes per-route financial performance from
existing data. Both player dashboard and bot decisions can use it.

**Why not a bot-specific table?** The parity principle says: if bots need this
data, players should get it too. The simulation already computes route economics
every game-day. We just need to surface it.

**Implementation**:
- Create `get_route_performance(p_user_id uuid)` function:
  - Returns per-route: origin, destination, distance, ticket_price, flights_per_week,
    estimated_revenue, estimated_cost, estimated_profit, load_factor
  - Revenue computed from `calculate_route_expected_passengers()` × ticket_price
  - Cost computed from fuel + crew + maintenance formulas (already in simulation)
  - Load factor = expected_passengers / effective_capacity
  - Works for both human players and AI actors
- Player benefit: Route analytics dashboard (future feature)
- Bot benefit: Data-driven route decisions (4.2, 4.3)

**Data source**: Existing tables — `route_assignments`, `fleet_aircraft`,
`aircraft_models`, `airports`. No new tables.

**Migration**: New function in migration file

### 4.2 Smart Route Trimming & Deletion

**What**: Bots should delete chronically unprofitable routes, not just trim
them when in distress.

**Implementation**:
- Current behavior: Route deletion only happens in `desperate` stage
- New behavior:
  - Use `get_route_performance()` to evaluate each active route
  - Any stage: Delete route if estimated_profit < 0 for 7+ consecutive
    game-days (tracked via a counter in the decision loop, not a table)
  - Cautious: Delete route if profit < 0 for 5+ days
  - Defensive/Desperate: Keep current behavior (delete highest-frequency
    unprofitable route)
- After deleting a route, the aircraft becomes idle and can be reassigned
  (see 4.3)
- Add a `last_route_audit_at` cooldown (4 game-hours) separate from
    `last_route_change_at` so audits don't block other route actions

**Tracking consecutive loss days**: Instead of a separate table, use a simple
counter in `bot_profiles`:
- Add `consecutive_loss_days` (integer, default 0) to `bot_profiles`
- Increment when all active routes have negative profit
- Reset to 0 when any route has positive profit
- This is bot-specific metadata (decision state), not data that players need

**Migration**: Schema addition + modify `execute_bot_decisions()`

### 4.3 Route Reassignment

**What**: Bots should be able to move aircraft between routes when a better
opportunity exists.

**Implementation**:
- After route creation check, add a "route optimization" phase:
  - If idle aircraft exists AND no good new route found AND current routes
    have underperforming aircraft:
    - Use `get_route_performance()` to find worst route
    - Unassign its aircraft (makes it idle)
    - Let the next tick's route creation logic reassign it
  - Cooldown: 24 game-hours (`last_route_optimization_at` in `bot_profiles`)
- This creates a natural "route rotation" behavior without explicit
  reassignment logic
- Use existing `delete_actor_route_assignment()` with `p_cancel_instead=FALSE`
  to unassign, then let route creation handle reassignment

**Migration**: Modify `execute_bot_decisions()`

### 4.4 Secondary Hub Exploration

**What**: Bots should occasionally establish routes from non-HQ origins to
create more realistic network shapes.

**Implementation**:
- Add `secondary_hub_iata` to `bot_profiles` (nullable)
- In route creation phase, 20% chance of using a secondary hub instead of HQ:
  - Pick from airports where the bot already has a route destination
  - This creates natural hub-and-spoke growth from existing network edges
  - Only if bot has >= 3 routes (needs network to form a hub)
- Secondary hub changes every 7 game-days (evaluated in pricing review phase)
- This creates more varied network patterns without breaking the HQ-centric
  model

**Migration**: Schema addition + modify `execute_bot_decisions()`

### 4.5 Fleet Diversity

**What**: Bots should occasionally use different aircraft models, not just
one model per archetype.

**Implementation**:
- Current: Regional=ATR, Aggressive=A320, Balanced=787 (deterministic)
- New: 70% chance of primary model, 30% chance of "alternative" model:
  - Regional alternatives: Any model with range 600-1500km
  - Aggressive alternatives: Any model with range 1200-2500km
  - Balanced alternatives: Any model with range 3000-6000km
- Selection: Cheapest available model in the range band
- This creates fleet diversity without unbalanced choices

**Migration**: Modify model selection logic in `execute_bot_decisions()`

### 4.6 Purchase Threshold Adjustment

**What**: Lower the purchase threshold so bots can actually buy aircraft
in reasonable timeframes.

**Implementation**:
- Current: Requires `v_bot_cash > v_starting_cash * 3` ($45M+)
- New: Requires `v_bot_cash > v_starting_cash * 1.5` ($22.5M+)
- Add purchase bias based on fleet composition:
  - If bot has 0 owned aircraft: +0.10 bias (encourage first purchase)
  - If bot has > 50% leased fleet: +0.05 bias (encourage ownership)
- Keep the `distress_stage = 'stable'` requirement

**Migration**: Modify purchase gate in `execute_bot_decisions()`

### 4.7 Competitive Pricing Response

**What**: Bots should react to competitor pricing, not just competitor
presence.

**Implementation**:
- In pricing review phase, when competitors exist on same O-D pair:
  - Query average competitor price for that route
  - If bot's price is > 20% above competitor average: apply 5% discount
  - If bot's price is < 20% below competitor average: apply 3% increase
  - Otherwise: keep current blending formula
- This creates natural price competition without race-to-bottom
- Only applies in `stable` and `cautious` stages (distressed bots cut
  prices regardless)

**Migration**: Modify pricing review in `execute_bot_decisions()`

### 4.8 Desperate Stage Recovery

**What**: Bots in desperate stage should have a path to recovery, not just
death spiral.

**Implementation**:
- Current: desperate = no growth, no repair, route deletion only
- New:
  - Allow repair of **grounded** aircraft if condition >= 60 (previously
    blocked entirely in desperate)
  - Allow one "recovery loan" if no active loans and cash > $500K:
    - Amount: $2M (smaller than normal loans)
    - Term: 26 weeks
    - Only once per desperate episode
  - If cash_ratio recovers above 0.25 for 2 consecutive ticks, upgrade
    to `defensive` stage (currently only recovers via
    `consecutive_negative_days` dropping)
- Add `recovery_loan_taken` (boolean, default false) to `bot_profiles`

**Migration**: Schema addition + modify distress logic

### 4.9 Loan Repayment Strategy

**What**: Bots should actively repay loans when cash allows, not just
service them passively.

**Implementation**:
- In a new "financial management" phase (after pricing review):
  - If bot has active loans AND cash > `v_min_cash_reserve * 1.5`:
    - Find the loan with highest interest rate
    - Repay up to 20% of remaining balance (if cash allows)
    - Cooldown: 12 game-hours (`last_financial_action_at` in `bot_profiles`)
  - This prevents bots from sitting on cash while paying interest
- Use existing `repay_loan()` shared helper

**Migration**: Schema addition + add new phase to `execute_bot_decisions()`

## Implementation Order

| Priority | Item | Impact | Risk |
|----------|------|--------|------|
| 1 | 4.1 Shared Route Performance Helper | High | Low |
| 2 | 4.2 Smart Route Trimming | High | Low |
| 3 | 4.3 Route Reassignment | High | Medium |
| 4 | 4.6 Purchase Threshold | Medium | Low |
| 5 | 4.7 Competitive Pricing | Medium | Low |
| 6 | 4.5 Fleet Diversity | Medium | Low |
| 7 | 4.8 Desperate Recovery | Medium | Medium |
| 8 | 4.9 Loan Repayment | Medium | Low |
| 9 | 4.4 Secondary Hubs | Low | Medium |

**Rationale**: Items 1-3 create the biggest behavioral improvement with
lowest risk. Items 4-6 are quick wins. Items 7-9 are more nuanced.

## Migration Strategy

- One migration file: `20260709150000_bot_realism_pass.sql`
- Contains:
  1. `get_route_performance()` function (shared, player + bot)
  2. `bot_profiles` schema additions:
     - `consecutive_loss_days` (integer, default 0)
     - `secondary_hub_iata` (varchar(3), nullable)
     - `last_route_optimization_at` (timestamptz)
     - `last_route_audit_at` (timestamptz)
     - `last_financial_action_at` (timestamptz)
     - `recovery_loan_taken` (boolean, default false)
  3. `execute_bot_decisions()` full rewrite with all new phases
- The rewrite follows the same structure as migration 33 (per-bot error
  isolation, shared helpers, configurable magic numbers)

## New game_config Entries

| Key | Default | Description |
|-----|---------|-------------|
| `bot_consecutive_loss_days_threshold` | 7 | Days of loss before route deletion |
| `bot_route_optimization_cooldown_hours` | 24 | Hours between route optimization attempts |
| `bot_secondary_hub_chance` | 0.20 | Chance of using secondary hub for new route |
| `bot_fleet_diversity_chance` | 0.30 | Chance of using alternative aircraft model |
| `bot_purchase_cash_multiplier` | 1.5 | Cash must be > starting_cash * this to purchase |
| `bot_competitive_price_threshold` | 0.20 | Price deviation % before competitive response |
| `bot_recovery_loan_amount` | 2000000 | Loan amount for desperate recovery |
| `bot_loan_repayment_ratio` | 0.20 | Max % of loan balance to repay per action |

## Exit Criteria

- [ ] Bot decisions look consistent over time (no random flailing)
- [ ] Bots delete chronically unprofitable routes
- [ ] Bots occasionally reassign aircraft to better routes
- [ ] Bots have diverse fleet compositions
- [ ] Bots respond to competitor pricing
- [ ] Desperate bots can recover with intervention
- [ ] Bots actively repay loans when cash allows
- [ ] `get_route_performance()` works for both players and bots
- [ ] No bot-specific tables — all data surfaces are shared
- [ ] No major regressions in finance stability
- [ ] `flutter analyze` clean
- [ ] `flutter test` passing
- [ ] Native SQL audit passes against linked DB

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Bots become too aggressive | Keep cooldown timers, test with live DB |
| Price war race-to-bottom | 3% minimum change threshold, blended formula |
| Route thrashing (delete/recreate) | Consecutive loss days threshold, cooldown timers |
| Financial instability | Recovery loan is small ($2M), repayment capped at 20% |
| Performance impact | `get_route_performance()` uses existing indexes, no new tables |

## Verification Plan

1. Apply migration to linked DB
2. Run `flutter analyze` and `flutter test`
3. Verify `get_route_performance()` works for a human player:
   ```sql
   SELECT * FROM get_route_performance('<your_user_id>');
   ```
4. Tick the world 100+ times and observe:
   - Bot fleet compositions (should see variety)
   - Bot route networks (should see secondary hubs)
   - Bot distress transitions (should see recovery)
   - Bot pricing (should see competitive response)
   - Bot loan behavior (should see active repayment)
5. Run native SQL audit to verify no regressions
