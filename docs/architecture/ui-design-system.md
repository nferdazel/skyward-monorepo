# Skyward UI/UX Extraction

Last verified against code on 2026-07-10.

This document extracts the current UI/UX structure, design language, and screen responsibilities from the live Flutter codebase so redesign work can stay grounded in the actual product.

## 1. The Vision & Identity

### Core Purpose

The one thing this app must do perfectly is provide a clear operational command center for running an airline simulation.

The UI is not optimized for storytelling, browsing, or passive consumption. It is optimized for:
- monitoring operational health
- spotting pressure and risk quickly
- taking corrective or growth actions
- seeing backend-authoritative outcomes reflected back into the interface

### Target Audience

The current product is best understood as targeting:
- simulation and management-game players
- users comfortable with dashboards, tables, KPIs, and operational workflows
- desktop-first users who value information density over decorative whitespace

This is not currently designed like a casual consumer app or a lightweight content experience.

### Brand Personality

The implemented interface reads as:
- tactical
- operational
- high-tech
- disciplined
- dense but controlled

### Visual Direction

Current direction:
- dark airline operations console
- flat surfaces with 4px border-radius (3px for badges)
- border-led hierarchy rather than shadow-led hierarchy
- IBM Plex Mono for metric values and labels
- IBM Plex Sans for general UI text
- status colors used as operational signals only

Primary dark palette from [skyward_colors.dart](../../lib/core/theme/skyward_colors.dart:1):
- background: `#080B10` (near-black base)
- surface: `#0F1319` (card backgrounds)
- surface raised: `#161C25` (raised elements)
- border: `0x1AFFFFFF` (10% white)
- primary accent: `#5B9EE0` (HUD blue)
- success: `#34D07B` (operational green)
- danger: `#E05555` (critical red)
- warning: `#E6A817` (caution amber)
- neutral: `#758489` (muted text)

Runtime theme note:
- only the dark theme is defined
- the app boots with `AppTheme.darkTheme`

References:
- [main.dart](../../lib/main.dart:1)
- [app_theme.dart](../../lib/core/theme/app_theme.dart:1)
- [skyward_colors.dart](../../lib/core/theme/skyward_colors.dart:1)

## 2. Application Architecture

### Sitemap

Current major screens and views:

1. Auth
2. Dashboard Shell
3. Overview
4. Fleet
5. Routes
6. Finance
7. Leaderboard
8. Settings

Sub-views:

- Auth
  - Login
  - Register
- Fleet
  - Active Fleet
  - Acquire Aircraft
- Routes
  - Flight Connections
  - Blueprint Network

References:
- [auth_screen.dart](../../lib/features/auth/presentation/views/auth_screen.dart:1)
- [dashboard_screen.dart](../../lib/features/dashboard/presentation/views/dashboard_screen.dart:1)
- [overview_tab.dart](../../lib/features/dashboard/presentation/views/overview_tab.dart:1)
- [fleet_view.dart](../../lib/features/fleet/presentation/views/fleet_view.dart:1)
- [routes_view.dart](../../lib/features/routes/presentation/views/routes_view.dart:1)
- [finance_view.dart](../../lib/features/finance/presentation/views/finance_view.dart:1)
- [leaderboard_view.dart](../../lib/features/leaderboard/presentation/views/leaderboard_view.dart:1)
- [settings_view.dart](../../lib/features/settings/presentation/views/settings_view.dart:1)

### Navigation Logic

The app is dashboard-centric rather than route-centric.

Post-auth flow:
- if auth is loading, show a terminal-style loader
- if authenticated, enter a single dashboard shell
- if unauthenticated, show the auth screen

Desktop navigation model:
- left vertical sidebar (44px icon-only with tooltips)
- top system ticker strip (24px, scrolling)
- top HUD/status bar (40px)
- main content workspace rendered through an `IndexedStack`

Within sections:
- Fleet uses a 2-tab internal workspace
- Routes uses a 2-tab internal workspace

Lazy loading:
- top-level tabs are lazily activated
- Fleet and Routes internal tabs are also lazily activated

References:
- [main.dart](../../lib/main.dart:1)
- [dashboard_sidebar.dart](../../lib/features/dashboard/presentation/widgets/dashboard_sidebar.dart:1)
- [top_hud.dart](../../lib/features/dashboard/presentation/widgets/top_hud.dart:1)

### User Roles

The UI does not currently branch into significantly different interfaces for different human roles such as Admin vs Viewer.

Current model:
- one authenticated player
- AI competitors appear as data surfaces, not alternate UI roles

Result:
- the interface is player-state-driven, not role-driven

## 3. Functional Requirements

### Overall Complexity Level

This is a high-density data application.

Dominant UI patterns:
- tables
- KPI cards
- badges
- status chips
- compact forms
- dialogs
- read-heavy control surfaces
- interactive world map (available for Routes view)

This is not a high-whitespace marketing or editorial layout.

### Screen 1: Overview

Reference:
- [overview_tab.dart](../../lib/features/dashboard/presentation/views/overview_tab.dart:1)

Primary role:
- command-center home
- health triage
- action routing into Fleet and Routes

Layout:
- 3-region layout: identity+cash band, health KPIs + risk signals, quick actions

Critical data that should remain easy to see:
- company name
- CEO name
- cash or liquidity position
- runway estimate
- fleet readiness
- active routes
- network pressure
- operational status
- weekly slack hours
- average condition
- top route risk
- competitive gap to the leader

Primary calls to action:
- navigate to Fleet
- navigate to Routes

### Screen 2: Routes

References:
- [routes_view.dart](../../lib/features/routes/presentation/views/routes_view.dart:1)
- [blueprint_planner_form.dart](../../lib/features/routes/presentation/widgets/blueprint_planner_form.dart:1)
- [route_network_map.dart](../../lib/features/routes/presentation/widgets/route_network_map.dart:1)

Primary role:
- strategic network planning
- active route management
- maintenance-pressure awareness

Critical data that should remain easy to see:
- route origin and destination
- city pair
- distance
- flights per week
- ticket price
- load factor
- demand multiplier
- maintenance slack
- assigned aircraft status
- route preview on the world map
- planning assessment and recommended route viability signals

Primary calls to action:
- create route
- assign aircraft
- update route schedule and price
- delete route

### Screen 3: Finance

Reference:
- [finance_view.dart](../../lib/features/finance/presentation/views/finance_view.dart:1)

Primary role:
- executive audit and cash diagnostics

Critical data that should remain easy to see:
- cash
- net worth
- owned asset value
- monthly lease exposure
- fleet composition
- ledger window
- rolling revenue
- rolling expense
- rolling net
- cash runway
- burn ratio and operating signals
- category analytics
- audited transaction logs

Primary calls to action:
- mostly analytical, not mutation-heavy
- this screen informs decisions taken elsewhere

### Additional Main Screens

#### Fleet

Reference:
- [fleet_view.dart](../../lib/features/fleet/presentation/views/fleet_view.dart:1)

Primary role:
- active fleet management
- acquisition workflow
- repair workflow
- cabin configuration workflow

Table columns:
- Tail #, Model/Manufacturer, Type (OWNED/LEASED), Condition (progress bar + %), Status (READY/GROUNDED), Cabin Config, Actions

Primary calls to action:
- purchase aircraft
- lease aircraft
- repair aircraft
- configure seats
- sell aircraft
- terminate lease

Important visible data:
- tail number
- aircraft model and manufacturer
- acquisition type
- condition (with color-coded progress bar)
- grounded vs ready status
- cabin configuration
- assignment state

#### Leaderboard

Reference:
- [leaderboard_view.dart](../../lib/features/leaderboard/presentation/views/leaderboard_view.dart:1)

Primary role:
- ranking surface
- competitor intelligence surface

Primary calls to action:
- select competitor
- inspect competitor intel

Important visible data:
- rank
- company and CEO
- cash
- net worth
- fleet size
- monthly revenue
- selected competitor insights

#### Settings

Reference:
- [settings_view.dart](../../lib/features/settings/presentation/views/settings_view.dart:1)

Primary role:
- airline profile management
- HQ management
- operational safety threshold management
- UI scale control
- reset flow

Sections:
- Airline Profile (company name, HQ airport)
- Operational Thresholds (auto-grounding)
- Interface (UI scale)
- Danger Zone (reset airline)

Primary calls to action:
- save settings
- adjust grounding threshold
- reset airline

Important visible data:
- company name
- HQ airport
- auto-grounding threshold
- UI scale
- dangerous irreversible actions

## 4. Technical & Design Constraints

### Layout Style

The dominant layout is a full-width fluid dashboard.

Exceptions:
- auth form is width-constrained on desktop (420px)
- settings content is centered in a constrained content region (1080px)

So the actual pattern is:
- fluid shell
- constrained forms where needed

Breakpoint logic:
- desktop at `>= 950px`
- mobile below `950px`

### Interactive Elements

The current app contains several non-trivial interactive components:
- interactive world map using `flutter_map`
- route blueprint planner
- searchable airport dropdown
- lazy-loaded tab workspaces
- modal dialogs for operational actions
- sliders
- dense tables with row-level actions

Not present in the current UX:
- drag-and-drop builders
- freeform canvas tools
- visual automation builders

### New Widget Signatures

#### Notification Panel

In-app notification system for game events:
- `GameNotification` model with title, message, type, timestamp, read state
- `NotificationType` enum: info, success, warning, error, event
- `NotificationPanel` widget with read/unread state management
- `NotificationBadge` for unread count display

Reference:
- [notification_panel.dart](../../lib/presentation/widgets/notification_panel.dart:1)

#### Onboarding Overlay

First-time player guidance overlay:
- persists completion state via `SharedPreferences`
- `OnboardingStep` model with title, description, icon, optional action
- step-by-step walkthrough with progress indicator
- dark overlay with highlighted content area

Reference:
- [onboarding_overlay.dart](../../lib/presentation/widgets/onboarding_overlay.dart:1)

#### Help Tooltip

Contextual inline help:
- small `?` icon that shows a tooltip on tap/hover
- themed to match the dark operations console style
- configurable icon size

Reference:
- [help_tooltip.dart](../../lib/presentation/widgets/help_tooltip.dart:1)

### Design System

#### Color Tokens

From [app_theme.dart](../../lib/core/theme/app_theme.dart:1):

| Token | Hex | Usage |
|-------|-----|-------|
| `primary` | `#5B9EE0` | Accent, active states |
| `accentSubtle` | `#1A5B9EE0` | Subtle accent backgrounds |
| `background` | `#080B10` | Page background |
| `surface` | `#0F1319` | Card/panel background |
| `surfaceRaised` | `#161C25` | Elevated surfaces, table headers |
| `border` | `0x1AFFFFFF` | Borders, dividers |
| `borderSubtle` | `0x0DFFFFFF` | Subtle backgrounds |
| `success` | `#34D07B` | Positive states |
| `error` | `#E05555` | Destructive, errors |
| `warning` | `#E6A817` | Caution states |
| `neutral` | `#758489` | Muted elements |

#### Spacing Tokens

From [app_spacing.dart](../../lib/presentation/theme/app_spacing.dart:1):

| Token | Value |
|-------|-------|
| `xs` | 4.0 |
| `sm` | 8.0 |
| `md` | 12.0 |
| `lg` | 16.0 |
| `xl` | 20.0 |
| `xxl` | 24.0 |
| `xxxl` | 32.0 |
| `xxxxl` | 40.0 |
| `xxxxxl` | 48.0 |

Semantic tokens:
- `pagePadding`: 16
- `cardPadding`: 12
- `sectionGap`: 16
- `blockGap`: 12
- `compactGap`: 8
- `microGap`: 4
- `tabContentGap`: 12

Border radius tokens:
- `radiusTight`: 2
- `radiusDefault`: 4
- `radiusSoft`: 8
- `radiusRound`: 12

Letter-spacing tokens:
- `spacingNone`: 0.0
- `spacingRelaxed`: 0.5
- `spacingSection`: 0.6

#### Typography

Font families:
- IBM Plex Mono via Google Fonts — used for numeric metric values, HUD values, KPI text, and data emphasis only
- IBM Plex Sans via Google Fonts — used for screen titles, section headers, body text, captions, buttons

Current typographic hierarchy:
- screen titles: 13–15px, IBM Plex Sans, w600, letterSpacing +0.06em
- section headers: 11–12px, IBM Plex Sans, w600, UPPERCASE, letterSpacing +0.10em
- body text: 13–14px, IBM Plex Sans
- captions and hints: 11–12px, IBM Plex Sans
- micro labels: 11px, IBM Plex Sans, w600, letterSpacing +0.06em
- badge text: 11px, IBM Plex Sans, w600, letterSpacing +0.08em
- button text: 12px, IBM Plex Sans, w600, letterSpacing +0.08em
- HUD values: 13px, IBM Plex Mono, w600
- data emphasis: 15px, IBM Plex Mono, w700
- large KPI: 20px, IBM Plex Mono, w700, letterSpacing -0.02em
- telemetry: 12px, IBM Plex Sans, w500
- nano labels: 10px, IBM Plex Sans, w600, letterSpacing +0.08em
- mono value: 13px, IBM Plex Mono, w600

References:
- [app_theme.dart](../../lib/core/theme/app_theme.dart:1)
- [app_typography.dart](../../lib/presentation/theme/app_typography.dart:1)

#### Component Language

Current shared primitives:
- cards (4px border-radius)
- buttons (4px border-radius)
- badges (4px border-radius)
- dialogs (4px border-radius)
- empty states
- table shells and table cells
- stat text
- dropdown fields
- labeled values
- info strips
- notification panel
- onboarding overlay
- help tooltip
- sparkline charts (`AppSparkline`)
- line charts (`AppLineChart`)
- segmented progress bars (`SegmentedProgressBar`)
- expense breakdown bars (`ExpenseBreakdownBar`)
- skyward logo (`SkywardLogo`)
- multi-select fields (`AppMultiSelectField`)
- snackbars (`AppSnackbar`)
- tab items (`AppTabItem`)

Visual behavior of primitives:
- cards are flat bordered blocks with 4px radius
- buttons have rounded corners and status colors
- inputs use filled dark surfaces with rounded outline borders
- emphasis is achieved through border, color, and type instead of depth

References:
- [app_card.dart](../../lib/presentation/widgets/app_card.dart:1)
- [app_button.dart](../../lib/presentation/widgets/app_button.dart:1)
- [app_theme.dart](../../lib/core/theme/app_theme.dart:1)

## 5. Notable UI Signatures

### Terminal Loader

The app uses a terminal-style loader for auth restore and bootstrapping:
- all-caps operational messaging
- thin progress indicator
- blue accent on dark background

Reference:
- [terminal_loader.dart](../../lib/core/widgets/terminal_loader.dart:1)

### HUD Bar

Desktop and mobile both prioritize a compact operational HUD showing:
- company identity
- CEO
- game time
- cash balance
- fuel price
- sync/live status

40px height with pipe separators and UPPERCASE labels.

Reference:
- [top_hud.dart](../../lib/features/dashboard/presentation/widgets/top_hud.dart:1)

### Sidebar

Desktop sidebar:
- 44px fixed width (icon-only with tooltips)
- Section grouping: OPERATIONS, ANALYTICS, SYSTEM
- Active state with left accent border
- "SKYWARD" wordmark at top

Reference:
- [dashboard_sidebar.dart](../../lib/features/dashboard/presentation/widgets/dashboard_sidebar.dart:1)

### Tactical Labeling

The interface frequently uses:
- uppercase micro-labels
- compact abbreviations
- badge-like numeric or status emphasis
- operational language instead of playful copy

This creates the "control room" feeling.

## 6. Practical Redesign Summary

If the UI is redesigned, the current product should be treated as:

- product type: desktop-first airline operations simulator
- UX archetype: command center
- visual archetype: dark tactical operations console
- information model: tabbed workspace with dense operational panels
- interaction model: inspect, decide, act, verify

### Preserve

- strong command-center identity
- desktop-first dense dashboard shell
- overview as triage surface
- visible HUD for time, cash, fuel, and sync state
- route map and planner as strategic surfaces
- data-dense Fleet, Routes, and Finance tabs

### Improve

- consistency across spacing and section framing
- clarity of action hierarchy in table-heavy screens
- mobile compression of dense tables and analytics
- stronger distinction between summary metrics and actionable controls

### Avoid

- redesigning into a generic SaaS dashboard
- over-rounding controls
- replacing the tactical identity with soft marketing aesthetics
- reducing critical data density so far that operational scanning gets slower
