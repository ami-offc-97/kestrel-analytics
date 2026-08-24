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

- **Staging/mart tables use full rebuild (CREATE OR REPLACE), not incremental**: every
  pipeline run reprocesses the entire 18-month raw history via CREATE OR REPLACE TABLE
  AS SELECT, rather than incrementally processing only new partitions. This is simple,
  correct, and trivially idempotent - the right choice for this scope (a single batch
  run against static data). This is also the first thing that breaks in a real
  production setting: as a recurring daily job accumulates years of history, full
  rebuild means every run re-scans data that hasn't changed. The fix is well-understood
  and not attempted here for time: move to partition-level insert-overwrite (reprocess
  only new ingest_date/dt/extract_date partitions) or true upsert/merge on primary key
  for the CDC-sourced tables, using DuckDB's native MERGE INTO or delete+insert by
  partition.

- **stg_pos_transactions validated against expected generator behavior**: post-dedup
  row count (4,000,000) exactly matches the generator's pre-duplication target,
  confirming dedup correctness. Late-arrival rate (4.49%) and pre/post-drift uom split
  (81% EA / 19% CS, matching exactly) both match the generator's documented injection
  rates. Estimated ~9.5% of the full dataset (19% case-ambiguity x 50% pre-drift
  period) cannot be converted case-to-eaches due to the schema drift; documented as a
  known limitation on the relevant KPI rather than silently assumed.

- **stg_reefer_telemetry validated against expected generator behavior**: post-dedup
  row count (3,598,770) closely matches the pre-duplication target (3,600,000), with
  the small gap explained by the known 945-row loss from the corrupted file plus
  normal per-slice sampling variance. Clock-skew rate (9.12%), null-reading rate
  (0.60%), and vendor/unit split (33.5% F / 66.5% C) all match the generator's
  documented injection rates. temp_unit_resolved has zero nulls, confirming the
  vendor-based inference correctly resolved every row with a missing temp_unit.

- **stg_wms_scan_events validated - no duplicate defect confirmed empirically**:
  raw and staged row counts are identical (1,496,000 = 1,496,000), confirming this
  feed genuinely has no duplicate-record defect (unlike POS/telemetry) - tested
  directly rather than assumed from documentation. order_number, sku_code, and
  warehouse_code have zero nulls, confirming fct_warehouse_cycle_time's stage-
  stitching logic won't be undermined by missing join keys; any incomplete journey
  will be due to the genuine L11 missing-scan gap only.

- **CDC staging tables (outlet, product, orders) - full history retained, correctly
  ordered**: all three retain complete change history (not collapsed to latest-only)
  and are ordered by (__op_ts, __seq) rather than timestamp alone. Verified against
  real data: stg_outlet_history has confirmed genuine DEFECT L13 timestamp ties
  (e.g. OUT001011, two versions at identical op_ts, differing only by the +500,000
  seq offset). stg_product_history and stg_sales_order_header do NOT have the
  documented L12/L13 defects (confirmed in generator code - only outlet/product get
  L12's out-of-order extract lag, only outlet gets L13's tie injection) - however,
  stg_sales_order_header independently exhibits its own undocumented timestamp tie
  between each deleted order's I and D rows (the delete is a direct copy of the
  insert, sharing its timestamp). The (op_ts, seq) ordering - built as defensive
  practice, not because this specific tie was anticipated - correctly resolves it
  too, since deletes always carry a +10,000,000 seq offset. Further investigation
  surfaced that delete tombstones are sampled independently of an order's own
  scheduled updates, so a deleted order can have genuine "U" rows recorded
  chronologically AFTER its "D" row (verified: order SO-00286919 has updates at
  06:42 and 12:28 following a delete at 00:06). This affects how "is this order
  currently deleted" must be defined in fct_orders - see decision logged there.
  status field is hardcoded "ACTIVE" on every outlet/product record including
  deletes - __op = 'D' is the only reliable deletion signal, not status.
  Several fields re-randomize independently on every version regardless of real
  business change (product: brand, gst_rate_pct, shelf_life_days; orders:
  order_value_gross, discount_amount, tax_amount, line_count) - only mrp (product)
  and order_status (orders, capped at DISPATCHED - DELIVERED is unreachable given
  the generator's logic) represent genuine change signals. KPIs must use the latest
  non-deleted version for "current" order/product value, not a historical version
  or an average across versions.
