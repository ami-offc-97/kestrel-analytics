# Decisions

- **Data handling**: `data/raw/` is gitignored per the brief's instruction not to
  commit the dataset; it's regenerated via `generate_dataset.py --scale 1`. Small
  reference CSVs under `data/reference/` ARE committed, since they're tiny
  lookup/dimension tables (not "the dataset" the brief means) and the repo is
  easier to understand with them present.

- **Repo layout**: original assignment brief/docs moved to `docs/assignment/`
  (unmodified) to avoid a naming collision with this repo's own README.md,
  and to make clear which files are the brief vs. the submission.

- **Data validation approach**: before building any pipeline logic, generated data was
  reconciled against `data/_manifest/expected_partitions.csv` feed-by-feed. 
  `pos_transactions` and `wms_scan_events` matched the manifest's expected row counts
  exactly (4,084,000 and 1,496,000 respectively). `reefer_telemetry` showed a shortfall
  of 945 rows against its expected 3,714,871 — traced to one truncated Parquet file
  (`dt=2025-07-14/part-00000.parquet`). Confirmed as file-level corruption rather than
  a generation issue, since all 7 sibling files in the same partition read cleanly.
  Pipeline design decision: skip the specific corrupt file (not the whole
  partition/day) and log it, rather than failing the run.

- **Cold chain excursion definition**: per 02_Feed_Contracts.md, target band is 2-8°C,
  and an excursion is defined there as "any reading above the band" (i.e. >8°C only).
  KPI catalogue follows this literal definition as `excursion_high`; readings below 2°C
  are tracked separately as `excursion_low` since they may also be business-relevant,
  but are not counted in the doc's stated excursion definition.

- **Warehouse cycle time with incomplete stage coverage**: due to ~6.5% missing WMS
  scans (known limitation, DEFECT L11), fct_warehouse_cycle_time retains one row per
  journey with NULL for any missing stage timestamp, rather than dropping incomplete
  journeys. Cycle-time metrics are computed only where both endpoint timestamps are
  present; the KPI catalogue documents the resulting coverage percentage as a known
  limitation.

- **Star schema vs. flat reporting tables**: marts are built as a normalized
  fact/dimension star schema (single source of truth, no duplication). Flat,
  pre-joined reporting views are layered on top for analyst convenience, kept
  automatically in sync since they're views, not materialized copies. If query
  performance ever demands it, these views can be trivially materialized into
  physical tables (CREATE VIEW to CREATE TABLE AS) - a cheap, well-understood
  next step, not attempted now since DuckDB joins at this row scale are not
  a genuine bottleneck.
