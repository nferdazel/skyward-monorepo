# Skyward Documentation

Status: current | Last verified against code: 2026-09-11

Single home for all project documentation. The repo root keeps only `README.md`
(landing) and `AGENTS.md` (agent working rules).

## Reading paths

| I want to… | Read |
|---|---|
| New to the project / onboard | [architecture/overview.md](architecture/overview.md) first, then [backend.md](architecture/backend.md) / [frontend.md](architecture/frontend.md) |
| Understand the database | [architecture/database.md](architecture/database.md) |
| Work on UI | [product/design-system.md](product/design-system.md) |
| Pick up work / plan features | [product/roadmap.md](product/roadmap.md) |
| Operate / debug the live product | [operations/runbook.md](operations/runbook.md) |
| Know the repo rules & quality bar | [standards/maintainer-standard.md](standards/maintainer-standard.md) + [../AGENTS.md](../AGENTS.md) |
| See why a decision was made | [reviews/](reviews/) — dated, immutable audit artifacts (kept local-only per `.gitignore`; links below work on the owner's machine) |

## Layout

```
docs/
├── architecture/     current system truth
│   ├── overview.md      system shape, tick/season clock, auth, realtime
│   ├── backend.md       Go API: engine domains, routes, worker, config
│   ├── frontend.md      Flutter: cubits, gateways, sync, test layers
│   └── database.md      schema groups + migrations 00–15 index
├── product/
│   ├── design-system.md token & component spec verified against code
│   └── roadmap.md       living backlog + open questions + eng debt
├── operations/
│   └── runbook.md       audit SQL, troubleshooting, admin tools, deploy
├── standards/
│   └── maintainer-standard.md
└── reviews/             dated historical audits (not living docs; gitignored, local-only)
    ├── aviation-realism-review-2026-09.md
    └── game-design-review-2026-09.md
```

## Conventions

- Filenames `kebab-case.md`; dated artifacts get a `-YYYY-MM` suffix (reviews only).
- Every doc opens with a `Status: … | Last verified against code: …` line. Update the
  date whenever you verify content against code, not only when you edit it.
- Migrations are referenced by **filename** (`migrations/07_wave4_aviation_data_fixes.sql`),
  never by old "Migration NN" numbers.
- One topic per file; cross-link relatively instead of duplicating content.

## Doc history

2026-09-11 — full restructure after the Go-API revamp. Superseded docs were removed.
Tracked-then-removed (recoverable from git history): `ai-handover.md`,
`supabase-contracts.md` (legacy RPC era), `ui-design-system.md`, all of `docs/plans/`,
and `docs/operations/{audit-queries,simulation-guide,owner-tools,backend-hardening-plan}.md`.
Local-only files (never tracked; preserved in `_audit/docs-pre-restructure-2026-09-11/`
at the repo root): the five root checklists/specs (`AUDIT_TASKLIST`,
`FLUTTER_ENHANCEMENT_CHECKLIST`, `GAME_REVIEW_TASKLIST`, `REDESIGN_TASKLIST`,
`UI_UX_DESIGN_SPEC`) and `reviews/wave2-design-doc.md`.
