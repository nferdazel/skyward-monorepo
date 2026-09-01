# Financials Page Redesign Plan

Status: Proposed — awaiting go-ahead
Scope: `lib/features/finance/presentation/**`, `app_strings.dart`, widget tests
Explicitly out of scope: cubit/gateway/backend changes, new RPCs, IFRS report panel internals, Bank tab logic

---

## 1. What was audited

| File | Role |
|---|---|
| `lib/features/finance/presentation/views/finance_view.dart` | 1,224-line view, 3 tabs (Overview / Transactions / Bank) |
| `lib/features/finance/presentation/cubit/finance_cubit.dart` | Data aggregation, rolling metrics, daily bucketing |
| `lib/features/finance/presentation/cubit/finance_state.dart` | `FinanceMetrics` value object, all computed totals |
| `lib/features/finance/domain/finance_snapshot.dart` | Server snapshot contract |
| `lib/features/bank/presentation/widgets/bank_panel.dart` | Bank tab (already redesigned once — its patterns are reusable) |
| `lib/presentation/widgets/app_card.dart`, `app_info_strip.dart` | Shared primitives |
| `lib/core/theme/app_theme.dart`, `app_strings.dart` | Theme tokens, label inventory |

**Key finding: the data layer is sufficient.** No backend changes are needed for ~90% of this redesign. The problems are almost entirely information architecture in the view layer.

---

## 2. Problems (honest audit)

### 2.1 The Overview says everything three times

The same numbers repeat in different wrappers — dashboard confetti:

| Data | Appears in |
|---|---|
| Net worth | Summary card → Current Position grid → Net Worth Trend chart |
| 30d revenue / expense / net | "Profitability" card → "Last 30 in-game days" row → expense bar total |
| Expense categories | "Where your money goes" bar → "Ledger Category Analytics" grid |
| Cash | Summary subtitle → Current Position grid → hero of every signal |

A player scrolling the tab reads the same story 3× before reaching the one actionable element ("View Full Report"), which is buried at the very bottom of the page.

### 2.2 Zero visual hierarchy

Every card is the same component, same micro-label, same top-border accent. Consequences:

- **Cash — the single number that decides whether the airline is alive — has the same visual weight as "LEDGER WINDOW: 30 days"**, which is a system implementation detail posing as a metric.
- "Fleet mix" (`1 owned / 1 leased`) is trivia given a full card in the primary grid.

### 2.3 The important answers are buried mid-page

The four questions a CEO actually has:

| Question | Current state |
|---|---|
| Am I making money? | Split across two separate cards |
| How long until I'm broke? | ¼ of a cramped 4-column info strip, rendered in `badgeText` (~11px) |
| What's eating my cash? | Section 5 of 6 down the page |
| Am I getting better or worse? | **Unanswerable** — no period-over-period comparison exists anywhere |

### 2.4 Weak dataviz

- Net worth "trend" is a 60px sparkline with no axes, no min/max labels, no visible date range — decorative, not readable.
- The expense breakdown bar and the category analytics grid duplicate each other instead of merging into one interactive component.
- Sparklines inside cards show 7 points with no reference to whether the movement is good or bad.

### 2.5 Transactions tab is a data dump

- No filtering (by category / credit-debit / date range), no search — even though the model fully supports it (`ifrsCategory`, `ifrsSubcategory` are populated per transaction).
- `balanceAfter` exists on `BankTransaction` but is never displayed — the single most useful column in a ledger is missing.
- No day grouping, even though the cubit already buckets transactions into `dailySnapshots` by game day (free data, unused).
- Column headers are roleplay-jargon: `AUDITED CATEGORY`, `CASH FLOW YIELD`, `GAME CALENDAR`.

### 2.6 Jargon & mixed time windows

- Labels mix "IFRS", "AUDITED TRANSACTION LOGS", "EST. NET WORTH", "30D CASH INFLOW", and plain "PROFITABILITY" — inconsistent register.
- Cards freely mix three different time bases without labeling which is which:
  - 30-day rolling (`rollingRevenue30d` etc.)
  - all-time ledger window (`totalTicketSales`, `totalOperations` … computed over up to 5,000 loaded transactions)
  - point-in-time (`cash`, `netWorth`)

---

## 3. Redesign concept: "Command, then detail"

Keep the dark terminal aesthetic (IBM Plex, uppercase micro-labels, hairline borders) — it's the brand. Fix hierarchy **inside** that language. Three tiers of attention: **glance → understand → audit.**

### 3.1 OVERVIEW tab — reorganized into 3 zones (down from 7 sections)

#### Zone 1 — Health Hero (one strip; answers "am I okay?")

A single full-width card replacing the current two summary cards + info strip:

- **CASH** as the dominant number (`displayLarge`, ~28–32px) with the cash sparkline beside it.
- **30D NET** with +/- success/error coloring **and a delta vs the previous 7 days** — computable client-side from `dailySnapshots` (the ledger holds up to 5,000 transactions, so a 7d-vs-prior-7d comparison costs nothing extra).
- **RUNWAY** promoted from the strip to hero status:
  - Big number + color-coded risk badge: `<14d` = error/red, `<45d` = warning/amber, else success/green (thresholds already exist in `_FinanceOverview.fromState`).
  - One-line plain-English verdict: *"At current burn, cash lasts 23 days."*
- **NET WORTH** as a secondary figure with the trend chart inline beside it — chart upgraded to ~120px height with min/max value labels and first/last date markers.

#### Zone 2 — Performance (30d, one merged section)

- Three compact stats in one row: **Money in / Money out / Margin** — this *replaces* both the "Profitability" card and the "Last 30 in-game days" row. One of the two current implementations gets deleted.
- **Merge the expense bar + category analytics grid into one component:**
  - Horizontal stacked bar on top (existing `ExpenseBreakdownBar`).
  - Legend rows below: `icon · label · amount · % share`, sorted descending by amount.
  - Tapping a legend row **deep-links into the Transactions tab pre-filtered to that category** — the cross-tab interaction the page currently lacks entirely.
- Largest expense called out in prose: *"Fleet leasing is 51% of your burn."*
- The signals strip (burn mix, revenue coverage) folds into this zone as secondary text under the margin stat — it stops being its own section.

#### Zone 3 — Position (collapsed to a compact strip)

Balance-sheet-lite as a single visual equation, not a 6-card grid:

```
Cash + Owned assets = Net worth
```

Followed by small-type facts: monthly lease exposure, fleet mix.

**Delete the "Ledger Window" card entirely** — move "30d" into section headers where it belongs as context, not as a metric.

#### Header change

"VIEW FULL REPORT" moves from a lonely centered footer button to the **section header as a trailing button** — the pattern already used by `BankPanel`'s "TAKE LOAN" CTA (`AppSectionHeader(trailing: ...)`).

### 3.2 TRANSACTIONS tab — from dump to ledger

1. **Filter chips row:** `All · Revenue · Expenses · Leasing · Fuel/Ops · Repairs · Purchases` — client-side filtering over existing state; the cubit already exposes `totalLease`/`totalOperations`/`totalRepair`/`totalPurchase` subcategory sets (`_leaseSubcategories`, `_repairSubcategories`, `_purchaseSubcategories` in `finance_cubit.dart`) to mirror.
2. **Group by game day:** day header rows showing date + day net subtotal. The cubit already computes `dailySnapshots` buckets — this is presentation-only.
3. **Add running-balance column** using `BankTransaction.balanceAfter` (already in the model), right-aligned, mono style (`AppTypography.monoValue` / `badgeText` family).
4. **Rename headers to plain language:** `Category · Description · Date · Amount · Balance`.
5. **Search field** over description text — cheap to implement, high value at 5,000 rows.

### 3.3 BANK tab — mostly fine

It was already redesigned once (per its own header comment: "Financial Command Center"). Two touches only:

- Surface **outstanding debt + weekly loan payment** into the Overview hero's runway context — debt payments are the silent killer the current runway presentation ignores. (Data already exists: `BankLoaded` exposes `loans` with `remainingBalance` and `weeklyPayment`; `bank_panel.dart` already computes `totalOutstanding` / `totalWeekly` locally.)
- Match the new Overview's card hierarchy so the three tabs feel like one product.

---

## 4. Implementation phases

### Phase 1 — Overview restructure (view-layer only; biggest win)

- Rebuild `_buildOverviewTab` in `finance_view.dart` into the 3-zone layout.
- Delete duplicated sections: keep one of `_buildExecutiveSummary` / `_buildIFRSSummaryCards`, remove the other.
- Merge `_buildExpenseBreakdownBar` + `_buildCategoryAnalyticsGrid` into one widget with a tappable legend.
- New/updated `AppStrings` entries for plain-language labels; delete strings orphaned by the consolidation.
- Move "VIEW FULL REPORT" into `AppSectionHeader(trailing:)`.
- All changes confined to `finance_view.dart` + `app_strings.dart` (+ possibly one new private widget file). **Cubit untouched.**
- Verify: `flutter analyze` and `flutter test test/layer2_widget/views/finance_view_test.dart`.

### Phase 2 — Transactions UX

- Filter chips + day-grouped list + balance column + description search.
- Small new widget file (e.g. `finance_ledger_filters.dart`); filter state stays local to the view (no cubit changes).
- Update widget tests for grouping and filter behavior.

### Phase 3 — Polish

- Upgraded net-worth chart: axis labels, min/max — **extend `AppLineChart`, don't fork it.**
- Category-bar → Transactions deep-link wiring.
- Optional: 7d-vs-prior-7d delta badge on the 30d-net hero stat.
- Doc touch-up in `docs/` if any labels or contracts referenced there change.

### Explicitly out of scope

- Cubit / gateway / backend changes
- New RPCs or migrations
- IFRS report panel (`ifrs_report_panel.dart`) internals
- Bank tab business logic

---

## 5. Open decision

The hero concept bets that **Cash + Runway + 30d Net** are the three numbers players care about most.

If the game's economy makes something else the survival metric (e.g. **weekly loan obligations** — `totalWeekly` from active loans), that should be swapped into the hero instead. The Bank tab already computes it; it's a presentation decision, not a data problem.

**Default:** proceed with Cash / Runway / 30d Net unless told otherwise.
