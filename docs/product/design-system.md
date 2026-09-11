# Skyward Design System

Status: current | Last verified against code: 2026-09-11

This is the consolidated UI reference for the Skyward Flutter client (`apps/app`).
It supersedes the older `docs/architecture/ui-design-system.md`,
`UI_UX_DESIGN_SPEC.md`, and `REDESIGN_TASKLIST.md`. The shipped widgets in
`apps/app/lib/presentation/` and `apps/app/lib/core/theme/` are the spec; the
redesign tasklist is treated as done/obsolete. Items that were never shipped (or
were later removed) are listed under [Not adopted / removed](#not-adopted--removed).

Related docs: [Frontend notes](../architecture/frontend.md),
[Documentation index](../README.md).

## 1. Design philosophy

Skyward presents a **dark airline operations console** ("cockpit" / PFD-ATC
inspired). The identity is tactical, dense, and desktop-first; information density
is a feature, not a compromise.

Principles actually encoded in code:

- **Shadowless, 1px-border architecture.** Surfaces are flat and separated by
  crisp borders and tonal layering, not blurry shadows. `AppTheme` sets
  `elevation: 0` on themed app bars and buttons; `CraftCard` explicitly renders a
  1px border plus an optional 1px top-edge highlight bevel and no shadow
  (`apps/app/lib/presentation/widgets/craft_card.dart`).
- **Tonal surface hierarchy.** `SkywardColors` defines four background layers
  (`darkBg` → `darkSurface` → `darkSurface2` → `darkSurface3`) plus
  `darkSurfaceActive` for hover/active rows.
- **Tabular numerics.** Metric styles apply
  `FontFeature.tabularFigures()` so live world ticks do not jitter
  (`app_typography.dart`: `hudValue`, `dataEmphasis`, `largeKpi`, `monoValue`,
  delta styles). IBM Plex Mono is used for values; IBM Plex Sans for prose.
- **Spring motion.** `AppMotion` centralizes spring-style curves
  (`springSnappy` = `Cubic(0.2, 0.0, 0.0, 1.0)`, `springOut` =
  `Curves.easeOutCubic`), a `createSpring(...)` `SpringSimulation` factory, and
  press-scale constants. Widgets use these for press depth, hover, and slide-over
  transitions.
- **Tactile feedback.** Interactive controls scale down on press
  (`TactileButton` 0.98, `CraftCard` 0.99, `microPressScale` 0.96) and brighten
  borders/surfaces on hover.
- **Dark only.** No light theme is defined; the app boots `AppTheme.darkTheme`
  and `SkywardColors` has no light palette.

## 2. Tokens

### 2.1 Colors

Canonical tokens live in `apps/app/lib/core/theme/skyward_colors.dart`;
`app_theme.dart` re-exports them as semantic aliases (`AppTheme.*`). Prefer
`AppTheme.*` in widgets.

| `SkywardColors` | `AppTheme` alias | Value | Role |
|---|---|---|---|
| `darkBg` | `background` | `#080B10` | Base canvas |
| `darkSurface` | `surface` | `#0F1319` | Default card/panel |
| `darkSurface2` | `surfaceRaised` | `#161C25` | Raised surface, table headers |
| `darkSurface3` | `surfaceElevated` | `#1E2633` | Drawers, elevated panels |
| `darkSurfaceActive` | `surfaceActive` | `#242E3D` | Hover/active row |
| `darkBorder` | `border` | `0x1AFFFFFF` | 10% white structural border |
| `darkBorder2` / `darkBorderSubtle` | `borderSubtle` | `0x0DFFFFFF` | 5% white divider |
| `darkBorderHighlight` | `borderHighlight` | `0x26FFFFFF` | 15% white top-edge highlight |
| `darkBorderFocus` | `borderFocus` | `#5B9EE0` | Focus outline |
| `darkAccent` | `primary` | `#5B9EE0` | HUD blue accent |
| `darkAccentSubtle` | `accentSubtle` | `0x1A5B9EE0` | 10% accent fill |
| `darkAccentBright` | `accentBright` | `#8DBFF0` | Hover/pressed accent |
| `darkAccentGhost` | `accentGhost` | `0x0D5B9EE0` | 5% accent tint |
| `darkTeal` | `info` / `teal` | `#3AAFA0` | ATC teal data viz |
| `darkGreen` | `success` | `#34D07B` | Operational green |
| `darkAmber` | `warning` | `#E6A817` | Caution amber |
| `darkRed` | `error` | `#E05555` | Alert red |
| `darkOrange` | `orange` | `#D98E4E` | POOR condition band |
| `darkNeutral` | `neutral` | `#758489` | Steel gray |
| `darkPlatinum` / `darkGold` | `tierPlatinum` / `tierGold` | `#E5E4E2` / `#FFD700` | Tier accents |
| `darkTextPri` | `textPrimary` | `#DDE2EA` | Body text |
| `darkTextSec` | `textSecondary` | `#8090A3` | Secondary text |
| `darkTextDim` | `textMuted` | `#64748B` | Muted micro-labels |

There is also a `SkywardColors` opacity scale (`opacitySubtle` 0.06,
`opacityLight` 0.12, `opacityMedium` 0.24, `opacityHeavy` 0.48).

### 2.2 Condition colors

`apps/app/lib/core/theme/condition_colors.dart` defines a **5-band** aviation
condition model (`ConditionColors.bands`, `colorFor`, `labelFor`).

| Band label | Min threshold | Color |
|---|---|---|
| `PRISTINE` | ≥ 90% | `AppTheme.success` |
| `GOOD` | ≥ 70% | `AppTheme.primary` |
| `FAIR` | ≥ 50% | `AppTheme.warning` |
| `POOR` | ≥ 25% | `AppTheme.orange` |
| `CRITICAL` | ≥ 0% | `AppTheme.error` |

Note: `SegmentedProgressBar` uses its own 4-tier color thresholds (≥80 success,
≥60 teal, ≥40 warning, else error) rather than `ConditionColors`.

### 2.3 Typography

`apps/app/lib/presentation/theme/app_typography.dart` (IBM Plex Sans for UI,
IBM Plex Mono for numerics). Tabular figures are applied on the mono styles.

| Style | Font | Size | Weight | Notes |
|---|---|---|---|---|
| `screenTitleLarge` | Sans | 15 | w600 | ls 0.06 |
| `screenTitleMedium` | Sans | 13 | w600 | ls 0.06 |
| `sectionHeaderLarge` | Sans | 12 | w600 | ls 0.6 |
| `sectionHeaderMedium` | Sans | 11 | w600 | ls 0.6 |
| `bodyLarge` | Sans | 14 | normal | |
| `bodyMedium` | Sans | 13 | normal | |
| `microLabel` | Sans | 11 | w600 | ls 0.6 |
| `nanoLabel` | Sans | 10 | w600 | ls 0.08 |
| `captionRegular` | Sans | 12 | normal | |
| `captionLight` | Sans | 11 | w400 | muted |
| `badgeText` | Sans | 11 | w600 | ls 0.08 |
| `buttonText` | Sans | 12 | w600 | ls 0.08, black |
| `hudValue` | Mono | 13 | w600 | tabular |
| `dataEmphasis` | Mono | 15 | w700 | tabular |
| `largeKpi` | Mono | 20 | w700 | tabular, ls -0.02 |
| `telemetry` | Sans | 12 | w500 | |
| `monoValue` | Mono | 13 | w600 | tabular |
| `tabularDeltaPositive` / `tabularDeltaNegative` | Mono | 11 | w600 | tabular, green/red |

Letter-spacing tokens: `spacingNone` 0, `spacingTight` 0.04, `spacingNormal` 0.08,
`spacingRelaxed` 0.5, `spacingSection` 0.6, `spacingWide` 0.12.

### 2.4 Spacing

`apps/app/lib/presentation/theme/app_spacing.dart` — 4px grid.

| Scale | Value | Semantic | Value |
|---|---|---|---|
| `xs` | 4 | `pagePadding` | 16 |
| `sm` | 8 | `cardPadding` | 12 |
| `md` | 12 | `sectionGap` | 16 |
| `lg` | 16 | `blockGap` | 12 |
| `xl` | 20 | `compactGap` | 8 |
| `xxl` | 24 | `microGap` | 4 |
| `xxxl` | 32 | `tabContentGap` | 12 |
| `xxxxl` | 40 | | |
| `xxxxxl` | 48 | | |

Radius: `radiusTight` 2, `radiusDefault` 4, `radiusSoft` 8, `radiusRound` 12
(the live UI predominantly uses 2–4px).

### 2.5 Motion

`apps/app/lib/presentation/theme/app_motion.dart`.

| Token | Value | Use |
|---|---|---|
| `micro` | 120ms | Press, hover, toggles |
| `regular` | 200ms | Drawer slide, tab cross-fade, counter |
| `toast` | 300ms | Notification stack |
| `radarPulse` | 1400ms | Telemetry pulse cycle |
| `springOut` | `Curves.easeOutCubic` | Standard deceleration |
| `springSnappy` | `Cubic(0.2, 0, 0, 1)` | Snappy transitions |
| `pressCurve` | `Curves.easeInOut` | Press interactions |
| `buttonPressScale` | 0.98 | TactileButton |
| `cardPressScale` | 0.99 | CraftCard |
| `microPressScale` | 0.96 | Icon/chip press |
| `createSpring(...)` | `SpringSimulation` | Factory; damping 20, stiffness 180, mass 1 |

`pressCurve`, `microPressScale`, and `createSpring` are defined but currently
have no call sites outside `app_motion.dart` (unverified as intentional API).

## 3. Component inventory

Grouped by kind. Paths are relative to `apps/app/lib/`. "Role" is one line; key
params/variants are those found in code.

### Buttons / tactile

| Class | File | Role | Key params / variants |
|---|---|---|---|
| `TactileButton` | `presentation/widgets/tactile_button.dart` | Spring press-scale button with state morphing | `TactileButtonType {primary, secondary, destructive, ghost}`, `isLoading`, `isSuccess`, `icon`, `height` (36 default), `width`, `customBackground`, `customTextColor` |
| `AppButton` | `presentation/widgets/app_button.dart` | Simpler InkWell button | `AppButtonType {primary, secondary}`, `isLoading`, `icon`, `height` (40), `backgroundColor`, `textColor` |

### Surfaces

| Class | File | Role | Key params / variants |
|---|---|---|---|
| `CraftCard` | `presentation/widgets/craft_card.dart` | Shadowless bordered card with optional 1px top bevel | `header`, `headerAction`, `showTopHighlight`, `onTap` (spring press), `radius`, `borderColor`; named ctor `CraftCard.panel` (0 radius, no highlight) |
| `AppCard` | `presentation/widgets/app_card.dart` | Older bordered card primitive | `header`, `borderWidth` (0.5 default), `radius`, `customBorder`; named ctor `AppCard.panel` (1.0 border, radius 0) |
| `AppDialogShell` | `presentation/widgets/app_dialog_shell.dart` | Standard dialog frame | `title`, `titleColor`, `subtitle`, `headerTrailing`, `actions`, `maxWidth` (460 default) |
| `AppTableShell` | `presentation/widgets/app_table_shell.dart` | Scrollable table container | `child`, `label` |
| `AppTableHeaderCell` / `AppTableBodyCell` | `presentation/widgets/app_table_cells.dart` | Table cell typography/padding | `label` / `child`, `padding`, `color` |
| `AppInfoStrip` | `presentation/widgets/app_info_strip.dart` | Compact inline info strip | `child`, `padding`, `backgroundColor`, `borderColor` |

### Controls

| Class | File | Role | Key params / variants |
|---|---|---|---|
| `SegmentedPillControl<T>` | `presentation/widgets/segmented_pill_control.dart` | Sliding active-segment switcher | `items` (`SegmentedPillItem`: `value`, `label`, `icon`, `countBadge`), `selectedValue`, `onSelectionChanged`, `height` (32) |
| `AppDropdownField<T>` | `presentation/widgets/app_dropdown_field.dart` | Themed dropdown form field | `label`, `value`, `items`, `onChanged`, `isExpanded`, `tooltip`, `contentPadding` |
| `SearchableAirportDropdown` | `presentation/widgets/searchable_airport_dropdown.dart` | IATA/city/country airport picker with overlay | `label`, `airports`, `selectedValue`, `onSelected` |
| `AppMultiSelectField` | `presentation/widgets/app_multi_select_field.dart` | Multi-select via checkbox dialog | `label`, `options`, `selectedValues`, `onChanged` |
| `AppControlLabel` | `presentation/widgets/app_control_label.dart` | Small control label (optional tooltip) | `label`, `tooltip`, `color` |

### Data visualization

| Class | File | Role | Key params / variants |
|---|---|---|---|
| `AppSparkline` | `presentation/widgets/app_sparkline.dart` | Sparkline with optional scrubber | `data`, `width` (80), `height` (32), `color`, `strokeWidth`, `isInteractive`, `onHoverIndexChanged` |
| `AppLineChart` | `presentation/widgets/app_line_chart.dart` | Simple CustomPaint line chart | `data`, `width`, `height`, `lineColor`, `fillColor`, `showDots`, `showMinMaxLabels`, `yFormat`, `chartHeight` |
| `TabularMetricCounter` | `presentation/widgets/tabular_metric_counter.dart` | Animated tabular number | `value`, `prefix`, `suffix`, `style`, `fractionDigits`, `duration` (`AppMotion.regular`), `formatter` (`NumberFormat`) |
| `SegmentedProgressBar` | `presentation/widgets/segmented_progress_bar.dart` | PFD-style segmented bar | `value`, `segments` (10), `width`, `height` (4), `activeColor`, `inactiveColor` |
| `ExpenseBreakdownBar` | `presentation/widgets/expense_breakdown_bar.dart` | Proportional expense segments | `segments` (`ExpenseSegment`: `label`, `amount`, `color`), `height` (24) |
| `AppStatText` | `presentation/widgets/app_stat_text.dart` | Label + value statistic | `label`, `value`, `labelColor`, `valueColor`, `crossAxisAlignment`, `textAlign` |
| `AppLabeledValue` | `presentation/widgets/app_labeled_value.dart` | Stacked read-only label/value | `label`, `value`, `valueColor`, `emphasize` |
| `AppBadge` | `presentation/widgets/app_badge.dart` | Status badge | `label`, `color`, `backgroundColor`, `fontSize`, `letterSpacing`, `padding`, `showDot`; factories `.success/.error/.warning/.primary/.secondary` |

### Feedback

| Class | File | Role | Key params / variants |
|---|---|---|---|
| `SkywardSonner` | `presentation/widgets/skyward_sonner.dart` | Sonner-style toast stack | `notifications`, `onDismiss`, `onTap`; up to 4 filtered (excludes `event`), stack 3, expands on hover, swipe dismiss, 380px |
| `NotificationPanel` | `presentation/widgets/notification_panel.dart` | In-app notification list | `notifications`, `onNotificationTap`, `onMarkAllRead`, `onClose`; `GameNotification`, `NotificationType {info, success, warning, error, event}` |
| `HelpTooltip` | `presentation/widgets/help_tooltip.dart` | `?` icon with tooltip | `message`, `iconSize` (14) |
| `AppEmptyState` | `presentation/widgets/app_empty_state.dart` | Empty placeholder card | `icon`, `title`, `description`, `actionLabel`, `onAction`, `padding` |
| `TerminalLoader` | `core/widgets/terminal_loader.dart` | Terminal-style boot loader | `message`, `width` (160) |
| `PulseDot` | `core/widgets/pulse_dot.dart` | Radar-ping status dot | `color`, `size` (8), `duration` (2s); respects reduced motion |
| `AppSnackBar` | `presentation/widgets/app_snackbar.dart` | Themed snackbar utility | static `showSuccess/showError/showInfo/showWarning(context, message)` |

Additional presentational primitives: `AppSectionHeader`
(`presentation/widgets/app_section_header.dart`), `AppTableIconAction`
(`presentation/widgets/app_table_icon_action.dart`), and `SkywardLogo`
(`presentation/widgets/skyward_logo.dart`).

### Layout

| Class | File | Role | Key params / variants |
|---|---|---|---|
| `MasterDetailShell` | `presentation/layout/master_detail_shell.dart` | Responsive split view separated by a 1px divider | `master`, `detail`, `masterFlex` (7), `detailFlex` (3), `isDetailVisible`, `onCloseDetail`, `breakpoint` (1050) |
| `SlideOverDrawer` | `presentation/layout/slide_over_drawer.dart` | Right slide-over inspector (Vaul-style) | `title`, `subtitle`, `child`, `bottomActions`, `onClose`, `width` (460); `SlideOverDrawer.show<T>(...)` overlay helper with 0.45 scrim |
| `DashboardSidebar` | `features/dashboard/presentation/widgets/dashboard_sidebar.dart` | 52px icon rail with active pill | Nav items index 0–5, tooltip labels, active left 3px primary border, logout confirm dialog |
| `TopHud` | `features/dashboard/presentation/widgets/top_hud.dart` | 42px telemetry bar | `authState`, `simState`, `currencyFormat`, `dateFormat`, `unreadCount`, `onNotificationTap`; identity + pulse clock, tabular cash, fuel, bell, live status |
| `NotificationPanel` / `SkywardSonner` | see Feedback | Overlay chrome for the dashboard shell | — |

## 4. Screen patterns

- **Shell / navigation** (`features/dashboard/presentation/views/dashboard_screen.dart`):
  `DashboardSidebar` (52px) + `TopHud` (42px) + a lazy `IndexedStack` workspace
  (top-level tabs lazily activated). `SkywardSonner` is mounted at the shell
  level; the notification panel is toggled from the HUD bell.
- **Drawer-based master-detail**: `FleetView` uses `MasterDetailShell` with
  `FleetDrawerContent` as the detail column
  (`features/fleet/presentation/widgets/fleet_drawer.dart`). `RoutesView` opens
  `RouteDrawerContent` through `SlideOverDrawer.show`
  (`features/routes/presentation/widgets/route_drawer.dart`). Both drawers are
  built from `CraftCard` sections.
  - `FleetDrawerContent`: airframe condition card, maintenance dispatch, cabin
    configuration sliders (economy ×1, business ×2, first ×3 equivalent points).
  - `RouteDrawerContent`: city-pair selection (searchable airport dropdowns),
    great-circle distance, ticket price + weekly frequency sliders, optional
    aircraft assignment, dispatch CTA.
- **Overview KPI grid** (`features/dashboard/presentation/views/overview_tab.dart`):
  4 `CraftCard` KPI columns (Fleet Ready, Network Health, Avg Condition, Cash
  Runway) using `largeKpi`, `SegmentedProgressBar`, `AppSparkline`, and
  `HelpTooltip`, followed by an asymmetric 65/35 split (risk & competitive
  signals + quick actions vs. action queue), bankruptcy banner, active world
  events, and the achievements summary.
- **Finance view zones** (`features/finance/presentation/views/finance_view.dart`):
  3-way `SegmentedPillControl` (Overview / Transactions / Bank) with lazy tab
  loading. Overview uses `FinanceOverview` zone widgets
  (`finance_overview_zones.dart`: `FinanceHealthHero`, `FinancePerformanceSection`
  with `ExpenseBreakdownBar`, `FinancePositionStrip`); transactions use
  `FinanceLedgerFilters` + `IfrsReportPanel`; bank uses `BankPanel`.
- **Achievements**: `AchievementsSummaryCard` on the overview is tappable and
  opens `AchievementsFullDialog` (`AppDialogShell`, maxWidth 560), showing every
  catalog entry with locked/unlocked badges.

## 5. Theme / dark-mode rules & adding a screen

- Dark-only: use `AppTheme.darkTheme`; never add light-theme branches.
- Use `AppTheme.*` semantic aliases (or `SkywardColors.*` directly) — do not
  hardcode hex values in widgets.
- Separation = 1px border + tonal surface, never drop shadows. Prefer
  `CraftCard` / `AppCard` over raw `Container` + `BoxShadow`.
- Numeric/metric text must use an `AppTypography` mono style (tabular figures).
  Animated numbers should use `TabularMetricCounter`.
- Motion must come from `AppMotion`; press feedback from the tactile primitives.

Checklist for a new screen:

1. Read auth state; render a muted unauthorized/empty state when not
   authenticated (pattern used by existing views).
2. Build content inside the dashboard shell (sidebar + HUD are global) — return
   only the workspace body.
3. Use `AppSectionHeader` for sections and `CraftCard` for panels.
4. Use `AppSpacing` tokens for gaps and padding; `AppTypography` for all text.
5. Use `SegmentedPillControl` for sub-tab / filter switching.
6. Route deep workflows through `SlideOverDrawer.show` with a `...DrawerContent`
   widget; use `AppDialogShell` for confirmations.
7. Add loading (`TerminalLoader` / progress), empty (`AppEmptyState`), and error
   states.
8. Use `AppBadge` for status; `ConditionColors` for condition bands.
9. Wrap independent repaint-heavy areas in `RepaintBoundary` where appropriate
   (`TopHud`, `AppTableShell`, sparkline already do).
10. Run `make analyze` and `make test`.

## 6. Not adopted / removed

- **Command palette** (`CommandPalette`, Cmd/Ctrl+K): removed in commit
  `e5f5ffa` ("remove command palette"); it only filtered static nav items. The
  finance ledger search remains. Do not treat it as an existing feature.
- **`DarkShimmerSkeleton`** and **`AppTabItem`**: deleted as dead code
  (2026-09). Do not reference them.
- **Spec-only / not found in code** (from `UI_UX_DESIGN_SPEC.md` v2.0 and
  `REDESIGN_TASKLIST.md`, never shipped as described):
  - 200px expandable sidebar / audio toggle / profile modal in the rail
    (the shipped `DashboardSidebar` is a fixed 52px icon rail).
  - `TactileSidebar`, `BankPanel` loan/credit simulator details beyond the
    existing `bank_panel.dart`, and any `command_palette.dart`.
  - Explicit 460px/420px `SlideOverDrawer` responsive breakpoint matrix (the
    shipped drawer defaults to 460px but has no built-in breakpoint logic).
  - `AppTabItem`-based tab widgets and blur/shadow elevation language (the
    shipped system is shadowless; there are no blurry elevation tokens).
  - Any documented widget not present under `apps/app/lib/presentation/widgets/`,
    `apps/app/lib/presentation/layout/`, or `apps/app/lib/core/widgets/`.
