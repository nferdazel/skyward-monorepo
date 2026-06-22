# Catalog Replenishment Workflow

This folder is the repo-local maintenance surface for airport and aircraft
catalog data. It exists so catalog changes remain reviewable in git instead of
only living in the Supabase tables.

## Structure

- `reference/`
  - raw external snapshots
  - useful as lookup inputs, never as authoritative game data
- `curated/`
  - reviewed CSVs that describe game-owned catalog state or candidate batches
- `generated/`
  - optional generated SQL artifacts
  - convenience output only, not canonical truth
- `scripts/`
  - local transformation, review, and validation tools

## Canonical files

These are the files that currently matter for ongoing maintenance:

- `curated/airports_seed.csv`
  - baseline airport catalog snapshot used by validation and replenishment
    scripts
- `curated/aircraft_models_seed.csv`
  - baseline aircraft catalog snapshot used by validation
- `curated/airports_replenishment_candidates.csv`
  - machine-derived airport candidates from the external reference set
- `curated/airports_replenishment_batch_01.csv`
  - narrowed airport batch before review
- `curated/airports_replenishment_batch_01_reviewed.csv`
  - reviewed airport batch that generated migration `28`
- `curated/aircraft_replenishment_batch_01_reviewed.csv`
  - reviewed aircraft batch that generated migration `29`
- `curated/airports_batch_02.csv`
  - manually curated follow-up airport candidate batch
  - not yet promoted into a numbered migration
- `curated/aircraft_batch_02.csv`
  - manually curated follow-up aircraft candidate batch
  - not yet promoted into a numbered migration

## Tooling

- `scripts/validate_catalogs.dart`
  - validates the two baseline seed CSVs
- `scripts/import_catalogs.sql`
  - staging-table upsert template for seed import/update work
- `scripts/build_airport_replenishment_candidates.dart`
  - derives airport candidates and batch 01 from the raw reference data
- `scripts/review_airport_batch_01.dart`
  - applies review heuristics to airport batch 01
- `scripts/generate_airport_batch_01_migration.dart`
  - turns reviewed airport batch 01 into migration `28`
- `scripts/generate_aircraft_batch_01_migration.dart`
  - turns reviewed aircraft batch 01 into migration `29`

## Reference inputs

- `reference/ourairports_airports.csv`
- `reference/ourairports_countries.csv`
- `reference/openflights_planes.dat`

These are snapshot inputs for local review workflows only.

## Maintenance rules

1. Treat curated CSVs as the review surface.
2. Treat numbered SQL migrations in `migrations/` as the
   historical application record once a batch is accepted.
3. Do not treat `generated/` SQL files as canonical unless they are promoted
   into numbered migrations.
4. Do not blindly overwrite game-owned economics from public data sources.
