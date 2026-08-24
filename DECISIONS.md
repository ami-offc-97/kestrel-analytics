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
  established the shape of this precisely: the tombstone copies the INSERT row
  wholesale (op_ts included) while an order's updates land 6h+ later, so a "D"
  row is never chronologically last - ALL 2,880 deleted orders have a genuine
  "U" row after their "D" (verified 2,880/2,880; this is universal, not the
  occasional case an earlier revision of this note described). Also corrected
  against the data: the delete row is the only place this feed has extract lag
  (2,877 of 2,880 "D" rows carry extract_date = order_date + 2..30 days, vs.
  exactly 0 of the 960,427 I/U rows), so extract_date is not a safe proxy for
  event time here. Both findings were back-ported into
  `stg_sales_order_header.sql`, whose header had wrongly claimed this feed has
  neither ties nor extract lag. This determines how "is this order currently
  deleted" must be defined in fct_orders - see decision logged there.
  status field is hardcoded "ACTIVE" on every outlet/product record including
  deletes - __op = 'D' is the only reliable deletion signal, not status.
  Several fields re-randomize independently on every version regardless of real
  business change (product: brand, gst_rate_pct, shelf_life_days; orders:
  order_value_gross, discount_amount, tax_amount, line_count) - only mrp (product)
  and order_status (orders, capped at DISPATCHED - DELIVERED is unreachable given
  the generator's logic) represent genuine change signals. KPIs must use the latest
  non-deleted version for "current" order/product value, not a historical version
  or an average across versions.

- **dim_outlet/dim_product deletion semantics - "ever deleted" not "latest op_type"**:
  both dims use `MAX(op_type = 'D') OVER (PARTITION BY <key>)` to derive `is_deleted`,
  rather than checking whether the latest version's op_type is 'D'. Verified this
  matters on both entities independently, not assumed from the outlet finding:
  33 of 48 deleted outlets and 10 of 16 deleted SKUs have a genuine later "U" row
  chronologically following their "D" row, because delete tombstones are sampled on
  a timestamp independent of the entity's own scheduled updates. Using "latest
  op_type" would have incorrectly reactivated these 33 outlets / 10 SKUs as
  `is_current = true`. Tested directly in each dim's diagnostic script (query:
  count of `is_current = true` rows whose key ever appears with op_type = 'D';
  expected and confirmed 0 in both cases) rather than inferred from row counts alone.

- **dim_outlet: most versioned attributes are regeneration noise, not genuine
  history - likely the "at least one wrong statement" the brief warns about
  in 02_Feed_Contracts.md**: `02_Feed_Contracts.md` states outlet_master
  "attributes change over the life of an outlet," implying meaningful business
  evolution. Verified against real data this is misleading for 6 of 9
  attributes: `channel`, `outlet_format`, `city`, `route_code`,
  `credit_limit`, and `credit_terms_days` are independently re-randomized on
  every CDC update (confirmed in generator: `outlet_cols()` draws these
  unconditionally from `rng.choice()`/`rng.uniform()` on every call, insert
  or update alike). Outlets with multiple versions average 2.5-3.8 distinct
  values across these six fields with no discernible pattern - e.g. OUT001011
  cycles through GT/MT/ECOM/GT/MT/GT/ECOM channels and five different cities
  across 12 versions with no logic. Only `warehouse_code` (fixed per outlet
  by construction) and `gst_number` (deterministic on outlet index) are
  genuinely stable; `outlet_name` is likewise constant. Practical
  consequence: "which outlets changed channel classification, and when"
  (brief section 5, Q6) CANNOT be answered from dim_outlet's channel history
  as if it were real reclassification - doing so would report that the
  large majority of outlets "changed channel," which is noise, not signal.
  The one reliable channel value is version_no = 1 (the initial insert),
  which matches stg_pos_transactions.channel for 100% of that outlet's sales
  (verified: every POS row's channel appears somewhere in its outlet's own
  channel history, and specifically the true, non-noisy value is the
  outlet's original one, which POS also carries directly on every sale line).
  Design decision: fct_sales carries `channel_at_sale` as a degenerate
  dimension straight from stg_pos_transactions rather than joining
  dim_outlet.channel, since the POS-native value is the reliable one for
  sales-by-channel reporting. dim_outlet itself is left as-is (SCD2 windowing
  is still the mechanically correct way to store whatever the CDC stream
  says) but is annotated with this caution rather than silently trusted.

- **fct_cold_chain_readings: carrier is genuinely unlinkable, and route_code/
  warehouse_code on this feed are noise, not assignment - this is very likely
  the "at least one wrong statement" 02_Feed_Contracts.md warns about, and
  directly explains why "excursion rate by carrier" cannot be built as
  Divya's brief literally asks**. Verified two separate things, both against
  real data and the generator, not assumed:
  (1) There is no carrier field or carrier-linking key anywhere in
  `reefer_telemetry` - or in any other raw feed. `carrier_master.csv` /
  `dim_carrier` is fully orphaned reference data: confirmed in
  `generate_dataset.py` that `carrier_id` is written only once, into
  `carrier_master.csv` itself, and referenced nowhere else in the generator.
  No amount of staging logic can join it to a fact without fabricating a key,
  so it isn't fabricated - this is documented as a known limitation instead.
  (2) `route_code` and `warehouse_code`, which the feed contract describes as
  "assignment at time of reading," are independently re-randomized on every
  single reading with no tie to device or vehicle (confirmed in the
  generator: both drawn via `rng.integers` per row, not per device). Verified
  empirically: every one of the 340 vehicles sees readings against all 260
  route_codes and all 8 warehouse_codes - avg 260.0 and 8.0 distinct values
  per vehicle respectively, i.e. uniformly random, not a real assignment.
  Only `device_id` -> `vehicle_registration` is genuinely stable (1:1,
  verified 0 devices with more than one vehicle) - this is the one reliable
  identity dimension on the feed. Practical consequence: `fct_cold_chain_readings`
  carries `route_code`/`warehouse_code` through for traceability but with an
  explicit caution in the header, and has no carrier column at all - "by
  carrier" reporting is out of scope until/unless a real linking feed shows
  up. This also plausibly explains Divya's "we think it's a third of all
  trips, which cannot be right" comment: reading-level excursion rate is
  actually 7.19%, not a third; a naive vehicle-day rollup (any excursion
  reading that day marks the whole day breached) gives 75.07% - neither is
  "a third," suggesting whatever ad-hoc number produced that estimate used a
  different, uncontrolled definition. The mart is left at reading grain
  deliberately (no fabricated "trip" concept, since nothing in the data
  demarcates one) so the KPI layer can choose and document a rollup
  explicitly rather than inheriting an implicit one.

- **fct_cold_chain_readings: is_excursion follows the feed contract's literal
  wording ("above the band" only) - readings below the 2-8C band are tracked
  separately, not folded into the excursion flag**. `02_Feed_Contracts.md`
  defines an excursion as "any reading above the band," not "outside the
  band." Taken literally, a reading of -5C (too cold) is not an excursion
  even though it's arguably a worse cold-chain failure for chilled product
  than a reading of 9C. This is not a small edge case: 19.83% of non-missing
  readings are below 2C, vs. 7.19% above 8C. Rather than silently picking
  whichever reading felt right, `fct_cold_chain_readings` implements the
  contract literally as `is_excursion` and adds `is_below_band` as a
  separate, equally-visible flag - both NULL (not FALSE) when the reading
  itself is missing (`temp_reading_missing`), so "no data" is never
  conflated with "in band." Worth pinning down directly with Divya before
  finalizing the KPI catalogue entry, the same way the FY26-Q4-vs-FY27-Q1
  ambiguity was flagged for fct_sales rather than silently resolved.
  Note: this supersedes the earlier placeholder decision that used
  `excursion_high`/`excursion_low` naming - the actual built columns are
  `is_excursion`/`is_below_band`, matching the boolean-flag convention used
  elsewhere in the star schema (e.g. `dim_outlet.is_current`).

- **fct_warehouse_cycle_time: wms_scan_events has no stitchable per-order
  journey at all - supersedes the earlier "incomplete stage coverage"
  placeholder, which wrongly assumed order-level stitching worked modulo
  missing scans**: `order_number`, `sku_code`, `batch_id`, `pallet_id`, and
  `warehouse_code` are each drawn from independent `rng.integers()` calls in
  the generator - no shared key ties one item's scans together. Verified
  three ways: RECEIVE->DISPATCH stitched by `order_number` gives a negative
  duration (dispatch before receive) for 50.13% of eligible orders - a coin
  flip, not a data-quality tail; the same ~50% negative rate holds keying by
  `batch_id` (49.91%) and `pallet_id` (49.81%), ruling out "wrong key"; and
  among the "plausible" (positive-duration) half, median implied cycle time
  is ~155 days - absurd for a warehouse dock-to-dispatch cycle, confirming
  that half is the same noise, not signal. 6-stage orders still touch ~8.6
  distinct SKUs/batches on average, confirming scans aren't one item's
  journey. Conclusion: brief Q5 ("median cycle time by warehouse") is not
  answerable from this feed as generated - documented as a known limitation,
  not worked around by filtering to the positive half.
  `fct_warehouse_cycle_time` is still built at `order_number` grain (6 stage
  timestamps pivoted, `cycle_time_seconds`/`is_cycle_time_plausible`
  exposed) for transparency and diagnostic use.

- **fct_orders: `order_value_net` and `order_value_incl_tax` are arithmetic
  only, NOT KPI-safe - the order feed's discount and tax bear no relationship
  to its gross, unlike the POS feed's**: `discount_amount` and `tax_amount`
  on `sales_order_header` are drawn as free-standing uniforms
  (`rng.uniform(0, 9000)` and `rng.uniform(200, 52000)`) with no reference to
  `order_value_gross` (`rng.uniform(2000, 480000)`). Verified on the built
  fact rather than inferred from the generator alone: `corr(gross_corrected,
  discount) = 0.0020`, `corr(gross_corrected, tax) = 0.0027`, and the implied
  tax rate spans 0.04% to 2552% (median 10.83%) where a real 12% GST rate
  would cluster tightly. Because discount is unbounded relative to gross,
  1,743 orders (0.54%) compute to a NEGATIVE net - and the rate is
  near-identical across all three source systems (SFA_MOBILE 0.556%, ERP_WEB
  0.540%, PARTNER_API 0.541%), which rules out the L14 freight correction as
  the cause and confirms it as a property of the source. Design decision:
  the columns are retained and left unclamped/unfiltered, with an explicit
  CAUTION in the mart header - the same treatment given to telemetry's
  `route_code`/`warehouse_code`, and for the same reason (removing them
  would hide the finding rather than record it). `order_value_gross_corrected`
  is the order-value measure the KPI catalogue will use. Worth noting the
  asymmetry explicitly, because the instinct is to generalise: the POS feed
  DERIVES its discount and tax from the line value
  (`up*qty*choice([0,0,0,.05,.10])` and `up*qty*0.12`), so
  `fct_sales.net_sales_amount` and `sales_amount_incl_tax` genuinely are
  meaningful - verified 0 negative net lines across all 4,000,000 rows. The
  caution applies to the order feed only.

- **fct_orders: "ever deleted" is not a refinement here, it is the entire
  result**: because no "D" row is ever chronologically last on this feed (see
  the CDC bullet above), a "latest op_type = D" deletion test would flag ZERO
  of the 320,000 orders as deleted, against a true count of 2,880. The
  `MAX(is_deleted) OVER (PARTITION BY order_number)` rule recovers all 2,880
  with 0 missed. The corollary is that the canonical-version tie-break that
  pushes tombstones last is a verified NO-OP on this dataset - canonical and
  purely-chronological ranking agree on all 320,000 orders. It is kept as
  defence against a real source where a tombstone IS the final row, and
  labelled as such in the mart header rather than left to imply it is doing
  work. Also fixed while verifying this: the tie-break previously depended on
  DuckDB resolving a bare `is_deleted` to the staging table's row-level column
  in preference to a same-named window alias in the same SELECT. It does
  (tested on a synthetic case where the tombstone IS last), so behaviour was
  correct, but the shadowing was removed in favour of an explicit
  `op_type = 'D'` test and an `is_ever_deleted` alias. The rewrite was
  confirmed byte-identical to the previous build (0 rows differing in either
  direction) before the old version was replaced.

- **Known documentation debt**: this file is well past the brief's "one page
  maximum". What it currently is, is an investigation log - valuable, but not
  the artefact asked for. Before submission it should be split: a genuine
  one-page DECISIONS.md (what was built / deliberately not built / assumed /
  next with two more weeks / what breaks first and at what volume) with the
  per-feed forensics moved to a `docs/findings.md` it links to.

