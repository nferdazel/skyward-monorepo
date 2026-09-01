# Fleet Page UI/UX Audit

Status: Audit complete — no implementation planned yet
Scope: `lib/features/fleet/**`, related strings/widgets
Related: `docs/plans/financials-page-redesign.md` (same design-system language applies)

---

## 1. What was audited

| File | Role |
|---|---|
| `lib/features/fleet/presentation/views/fleet_view.dart` | 1,956-line view — 2 tabs (Active Fleet / Acquire Aircraft), 4 dialogs |
| `lib/features/fleet/presentation/cubit/fleet_state.dart` | Fleet/catalog state, filter state (`selectedManufacturers`, `selectedCategories`, `selectedRangeBrackets`, `sortBy`) |
| `lib/features/fleet/domain/fleet_models.dart` | `AircraftModel`, `UserFleetAircraft` (condition, repair cost, sale value, termination fee math) |
| `lib/core/theme/condition_colors.dart` | Condition bands: PRISTINE ≥90, GOOD ≥70, FAIR ≥50, POOR ≥25, CRITICAL <25 |
| `lib/core/constants/game_constants.dart` | Wear rates (owned 0.5 / leased 0.7 per cycle), safety floor 30% |
| `lib/presentation/widgets/app_table_icon_action.dart` | Icon-only action button used by both tables |
| `lib/features/routes/domain/route_models.dart` | Confirms `speedKmh` and `maintenanceCostPerHour` are load-bearing in route economics |

**Overall verdict:** the Fleet page is the most *functional* surface in the app so far — real filters, real transactions, honest cost math in the finance dialog. Its problems are not missing features; they are **density, legibility, and decision support**. The two tables are treated as the whole UX, and both are overloaded.

---

## 2. Tab 1 — ACTIVE FLEET

### 2.1 No fleet-level summary at all

The tab opens directly into a bare table. There is no header strip answering the questions a CEO asks *before* reading rows:

- How many aircraft do I have? (owned vs leased split)
- How many are grounded / need repair **right now**?
- What is my total monthly lease burn?
- What would it cost to repair everything?

Every one of these is computable client-side from existing state (`fleet` list + `acquisitionType`, `isMaintenanceGrounded`, `model.leasePricePerMonth`, `repairCost`). The dashboard (`AppStrings.overview*`) already proves the app believes in at-a-glance strips — this tab just doesn't have one. The Finance overview's hero concept (cash/runway/net) has its Fleet analogue here: **Ready / Grounded / Lease burn / Repair liability**.

### 2.2 The row is doing too much — and the wrong things are big

Current row anatomy (7 columns):

```
TAIL (badge + nickname) │ AIRCRAFT (name + manufacturer + pax) │ ACQ │
CONDITION (% + bar + band label) │ STATUS │ CABIN (E/B/F + slots) │ ACTIONS
```

Problems:

- **AIRCRAFT column stacks three lines** (model name bold, MANUFACTURER, `180 PAX CAP` in accent-colored mono). Capacity is already implied by the CABIN column's slot math — the third line is redundant.
- **TAIL and AIRCRAFT split identity across two columns.** A player thinks of the plane as *one thing* — "PK-ABC · A320neo". Splitting tail, nickname, model, and manufacturer across two columns forces horizontal scanning to assemble one entity.
- **CONDITION is the tallest cell in the row** (percentage + 10-segment bar + band label = 3 stacked elements) yet the bar is only 64px wide. The segmented bar reads as decoration; the actionable fact is just "how close to my grounding threshold am I?"
- **The grounding threshold is invisible.** `autoGroundingThreshold` (default 30%, user-configurable) decides whether the STATUS badge shows GROUNDED, but nothing in the row shows distance-to-threshold. A plane at 31% and a plane at 89% both show healthy-looking bars — one is one flight from grounding.
- Wear rates differ by acquisition type (owned 0.5% / leased 0.7% per cycle, `GameConstants`), so "cycles until grounding" is computable per row: `(condition - threshold) / wearPerCycle`. That single number would be more useful than the bar.

### 2.3 CABIN column: correct math, wrong presentation

`E 144  B 12  F 0` + `168 / 180 slots` — the slot-weighting system (E=1, B=2, F=3) is a genuinely interesting mechanic, but:

- The column can't say *why it matters*: cabin config drives route revenue, and there is no link from here to route performance.
- `E/B/F` abbreviations with no legend assume the player already learned the system in a dialog.
- Over-capacity shows red `slots` text — but the row gives no way to fix it except knowing the tune icon exists.

### 2.4 ACTIONS column: icon-only, order-inconsistent, and one is a landmine

Three icon buttons (32px, icon-only, tooltip-dependent):

1. **Dispose** — `sell_outlined` (owned) or `assignment_return_outlined` (leased). Two different metaphors for the same slot; the leased icon reads as "return a form", not "terminate lease, pay fee".
2. **Configure seats** — `tune`.
3. **Repair** — `build_outlined`, with the cost *only in the tooltip*. **But** when condition is 100%, the third slot becomes an `OK` badge — so the actions column **changes width row-to-row**, breaking column alignment and rhythm in the table.

Specific UX defects:

- **Repair cost hidden behind hover.** The single most important number for the decision (this is a money decision) requires a tooltip. On touch targets there is no hover at all.
- **Repair appears even when pointless** — any condition < 100% shows it, including 99%, encouraging money-wasting clicks with no "repair to full" preview of cost-vs-benefit.
- **Dispose-disabled state is only discoverable by trying.** Assigned aircraft show a disabled icon with the tooltip `disposeUnavailableTooltip`; the STATUS column meanwhile just says ACTIVE — the *reason* disposal is blocked ("assigned to route X") never surfaces in the row.
- **No repair-all / bulk maintenance** — a 10-plane fleet with wear means 10 individual dialogs.

### 2.5 STATUS column lies by omission

Badge logic: `GROUNDED` (error) / `ACTIVE` (success) / `MAINTENANCE` (warning). But "ACTIVE" here means "not grounded" — **not** "assigned to a route and earning". An idle airframe that earns nothing and (if leased) still burns monthly lease shows the same green ACTIVE as a revenue-generating one. `assignedFleetIds` is already computed in the view (from `RoutesCubit`) — used only to disable the dispose button, never to enrich status. The single most important operational distinction — **earning vs idle** — is invisible.

### 2.6 Empty state is the tab's best moment

`YOUR FLEET AWAITS.` + description + `BROWSE AIRCRAFT` CTA that switches to the Acquire tab — this is the one place the page has clear hierarchy and a single action. It proves the design language *can* do hierarchy; the populated state just never got the same treatment.

---

## 3. Tab 2 — ACQUIRE AIRCRAFT

### 3.1 The comparison problem: shopping with no comparison tools

The catalog is a 7-column table: AIRCRAFT / CLASS / RANGE / SEATS / BURN / PRICING / ACTIONS. Choosing an aircraft is the **highest-stakes decision in the game** (7–9 figure purchases, or lease commitments), and the tool provided is a flat sorted list.

What's missing for a real decision:

- **Speed is hidden.** `AircraftModel.speedKmh` exists, drives flight duration in route economics (`route_models.dart`), and is never displayed. Two aircraft with identical range/seats can have wildly different cycle times — the player can't see it.
- **Maintenance cost is hidden.** `maintenanceCostPerHour` exists on the model and feeds route P&L — invisible in the catalog.
- **No derived economics.** Range ÷ burn, cost per seat, lease-vs-buy breakeven (`purchasePrice / leasePricePerMonth` months) — all computable client-side, all absent. The player must do mental math across columns.
- **No comparison / shortlist.** Can't favorite, can't put two rows side by side.
- **PRICING column crams both prices** ("Lease $X/mo" + "Buy $Y" stacked) — fine — but nothing indicates affordability. Cash is known (SimulationCubit), financing cap is known (BankCubit `maxFinancingAmount`), yet the table renders every row identically: no "can't afford" dimming, no "financeable" hint until you open the dialog.

### 3.2 Filters: solid mechanism, dead-end presentation

- Three multi-selects (manufacturer / category / range bracket) + 5 sort orders, memoized client-side filtering. Mechanically good.
- **No result count** ("14 of 42 models"), no active-filter chips with one-tap clear, no reset-all. When the result is empty, the message is `NO AIRCRAFT MATCH CRITERIA.` — a dead end with no "clear filters" escape hatch.
- Manufacturer list is **hardcoded in the view** (10 names) instead of derived from the loaded catalog — a catalog entry from a new manufacturer would be unfilterable-invisible (row shows, but no filter option). Low-probability, but it's a view-layer lie waiting to happen.
- Sort control itself wasn't visible in the bar layout — sortBy lives in state with 5 options; verify it has an actual UI control (the filter bar builds only the three multi-selects).

### 3.3 Three acquisition paths, zero guidance

Per row: lease (clock icon), buy (cart icon), finance (credit-card icon) — icon-only again. The page never explains the trade-offs:

- Lease = low upfront, monthly burn, 0.7%/cycle wear, termination fee 25% of monthly
- Buy = huge upfront, owns asset, 0.5%/cycle wear, resale at 72% × condition
- Finance = down payment + APR against credit tier

The tooltips say only "Lease aircraft" / "Buy aircraft". A new player facing a $111M A320neo has no in-context help choosing. The *concepts* are explained once in the dashboard's Tips section (`advisoryLeaseBody`) — three screens away from the decision point.

### 3.4 Acquire dialog: seat config before money confirmation

Flow: click lease/buy → seat-config dialog (E/B/F sliders + slot bar) → confirm → RPC.

- **Defaults are all-economy** (`economy = capacity, business = 0, first = 0`) — sensible, but the dialog opens with the explanation of the slot system (`realisticSpaceConfigurationDesc`) doing heavy lifting every single time. Repeat acquirers can't skip.
- **Cost context is one muted line** at the top ("Lease down payment: $X, then $X/mo"). The *cash impact* — "you have $A, this leaves you with $B" — is absent, despite cash being available. For a lease, monthly burn vs current cash/runway is the decision; the dialog doesn't show it.
- **Nickname is silently set to the model name** (`nickname: model.modelName` in the RPC call). The code comment says "No naming prompt" is an intentional pillar — noted, but then the TAIL column shows an uppercase model name under a tail number, which reads oddly ("A320NEO" as a nickname for your A320neo).
- Sliders max out per-class (`maxPossible`), which prevents invalid states but hides the interesting tension: you can't *see* what an all-first-class config would cost in slots without dragging.

### 3.5 Finance dialog: the best dialog in the page — with one real bug

Down-payment slider, term dropdown, full cost breakdown strip (price / cap / rate / down / monthly / weekly / total / vs-buy-outright premium). The `vs Buy Outright +$X` line is exactly the kind of decision-support the rest of the page lacks.

**Bug — broken term labels:**

```dart
items: [12, 24, 36, 48, 60]
    .map((m) => DropdownMenuItem(
          value: m,
          child: Text('${m ~/ 12} months (${(m ~/ 12)} yr)'),
        ))
```

`m ~/ 12` yields `1, 2, 3, 4, 5` — so every option reads **"1 months (1 yr)", "2 months (2 yr)" … "5 months (5 yr)"**. It should be `$m months (${m ~/ 12} yr)`. The dropdown currently misstates every financing term in the UI. (Values sent to the RPC are correct — it's a label-only bug, but it's on a money decision.)

Also:

- **Hardcoded strings throughout** — this dialog bypasses `AppStrings` entirely ("FINANCE: ...", "Secured pricing uses your current credit tier.", "Down Payment:", "Monthly Servicing"...). Inconsistent with the rest of the page and blocks any future localization.
- `_formatNumber` uses `AppFormatters.compactNumber` with a manually prefixed `$` — the rest of the app uses `AppFormatters.currency`; "$1.2M"-style compact formatting on a financing summary undermines confidence at the exact moment of commitment.
- Eligibility check (`purchasePrice <= maxFinancingAmount`) only *disables* the button — no "improve credit tier to unlock" pointer, though the credit system exists.
- No down-payment-presets (10/20/30/50 quick chips) — slider-only on a dialog is fiddly.

### 3.6 Repair & disposal dialogs: honest but bare

- Repair confirm: one sentence with the cost. No before/after condition preview ("65% → 100%"), no note that repair cost scales with wear (the model math supports showing it).
- Disposal confirm: shows fee/proceeds via `AppLabeledValue` strip — good — plus a redundant `ASSIGNED FLEET: IDLE` labeled value that exists only because the dialog can't be opened when assigned. Dead UI.
- Destructive confirm buttons use the same primary style as everything else; lease termination (a fee-paying destructive act) gets an amber *title* but the button itself doesn't carry the danger weight.

---

## 4. Cross-cutting issues

| Issue | Detail |
|---|---|
| **Icon-only actions everywhere** | Both tables rely on tooltips for meaning: 3 actions per fleet row, 3 per catalog row. Touch-unfriendly, discoverability-zero, and two of the six icons are ambiguous metaphors. |
| **Hidden economics** | The game has real cost models (wear/cycle, repair scaling, resale 72%×condition, termination 25%×monthly, route P&L using speed + maintenance cost) — almost none of it is visible where decisions happen. |
| **No cross-feature surfacing** | Route assignment is known but shown only as a disabled button. Finance/cash is known but shown only inside one dialog. The page is an island. |
| **Width sensitivity unaddressed** | 7-column tables with fixed flex widths; the filter bar has a 1180px breakpoint but the tables themselves have no narrow-story at all (no horizontal scroll, no priority-column collapse). |
| **Strings** | Mostly centralized, but the entire finance dialog + several inline literals (`'$value Seats'`, `'${model.rangeKm} KM'`, `'E $economy  B $business  F $first'`) are hardcoded. |
| **Badge/color semantics drift** | Acquisition badge: LEASED=warning/amber, OWNED=primary/accent — amber implies a problem with leasing, which is a legitimate strategy. Condition "GOOD" band uses primary (accent) instead of a green-family color, so a healthy plane's bar renders in the accent hue while PRISTINE is green — two different "good" greens-adjacent hues in one cell. |

---

## 5. What a redesign should solve (prioritized)

**P0 — correctness & decision safety**
1. Fix the finance term label bug (`$m months (${m ~/ 12} yr)`).
2. Show repair cost in the row, not the tooltip; hide/disable repair when cost ≈ 0 benefit (e.g. condition ≥ 95% band with dimmed state) — or at minimum stop the actions column from changing width (fixed 3-slot action cell, `OK` badge rendered in the same 32px box).
3. Make STATUS honest: EARNING (assigned) / IDLE (unassigned, not grounded) / GROUNDED — `assignedFleetIds` is already in hand; for leased aircraft, IDLE should carry the monthly burn as secondary text.

**P1 — hierarchy & glanceability**
4. Fleet summary strip above the table: `READY n · GROUNDED n · LEASE BURN $/mo · REPAIR ALL $` (all client-computable).
5. Merge TAIL+AIRCRAFT into one identity cell (tail badge + model name + manufacturer on two lines); free the reclaimed width for CONDITION to show **cycles-to-grounding** instead of the decorative segmented bar.
6. Catalog: add SPEED column (and surface maintenance cost in row detail or tooltip at minimum); show per-row affordability state (affordable cash / financeable / out-of-reach) using SimulationCubit cash + BankCubit cap — both already loaded app-wide.

**P2 — decision support & polish**
7. Acquire dialog: cash-impact line ("cash after: $X"), lease-vs-buy breakeven months, skip-seat-config option for repeat buyers.
8. Filters: result count, clear-all chip, derive manufacturer list from catalog; empty state gains a "CLEAR FILTERS" action. Verify the sort control actually renders.
9. Finance dialog: move strings to `AppStrings`, use `AppFormatters.currency` (drop manual `$` + compactNumber), add down-payment preset chips, add unlock-pointer when ineligible.
10. Bulk maintenance action from the summary strip ("REPAIR ALL $X" → confirm → sequential RPCs or a backend batch RPC if one exists — check `fleet_gateway.dart` before promising).
11. Repair dialog: before/after condition preview; disposal dialog: drop the dead ASSIGNED strip; destructive actions get danger-styled buttons.

**Out of scope for a view-layer pass:** wear-rate mechanics, pricing, credit tier logic, new RPCs (except possibly a batch-repair RPC, flagged as optional), the seat-slot economic model itself.

---

## 6. Effort estimate

| Item | Size | Files touched |
|---|---|---|
| Finance label bug + strings + formatter | XS | `fleet_view.dart`, `app_strings.dart` |
| Fixed-width actions cell + repair cost in row | S | `fleet_view.dart` |
| Honest STATUS (earning/idle/grounded) | S | `fleet_view.dart` |
| Fleet summary strip | M | `fleet_view.dart` (+ maybe 1 small widget) |
| Identity-cell merge + cycles-to-grounding | M | `fleet_view.dart`, `app_strings.dart` |
| Catalog speed column + affordability | M | `fleet_view.dart` |
| Filter result count / clear / derived manufacturers | S | `fleet_view.dart` |
| Acquire dialog cash impact + breakeven | M | `fleet_view.dart`, `app_strings.dart` |
| Finance dialog presets + eligibility pointer | S | `fleet_view.dart` |
| Repair/disposal dialog polish | S | `fleet_view.dart` |
| Bulk repair | M–L | view + possibly `fleet_gateway.dart` / RPC |

Everything except bulk-repair is view + strings only — `FleetCubit`, `FleetState`, gateways, and backend contracts remain untouched. Verify with `flutter analyze` + `flutter test test/layer2_widget/views/fleet_view_test.dart`.
