# KPI Catalogue

**Kestrel Provisions Pvt Ltd — Analytical Foundation**

> *"What I want out of this is not a dashboard. It is a foundation. I want a
> defined, documented, queryable set of numbers that the whole business agrees
> on, and I want to be able to trace any figure back to the row it came from."*
> — Anand Krishnamurthy, Group CFO

This is the single definition of every metric this platform publishes. If a
number is quoted in a meeting and it is not in here, it is not a Kestrel
number.

Every entry names a runnable query under `sql/queries/`. That is the
traceability requirement: the definition and the SQL behind it never drift,
because the definition points at the SQL.

**Read the limitations.** Several metrics the business asked for cannot be
built from the feeds as they stand. Those are listed in
[Section 6: Requested but not buildable](#6-requested-but-not-buildable), with
the evidence, rather than being quietly approximated. A metric that is wrong
but plausible is more expensive than a metric that is absent.

---

## Conventions that apply to every metric

| Convention | Decision |
|---|---|
| **Business day** | Asia/Kolkata (IST). POS `event_ts` arrives in UTC and is converted (`+5:30`) in staging. Every date-grain metric uses `event_date_ist`, never the raw UTC timestamp and never the ingest date. |
| **Fiscal calendar** | April–March, from `data/reference/fiscal_calendar.csv` via `dim_calendar`. FY27-Q1 = Apr–Jun 2026. |
| **Event date, not ingest date** | ~4.49% of POS rows land 1–3 days after the sale. Metrics are reported on the day the sale *happened*. This is the single largest definitional difference from the legacy Finance report. |
| **Deduplication** | The POS collector is at-least-once. Exactly one row is kept per `(txn_id, txn_line_no)`. 84,000 duplicate lines are removed. |
| **Point-in-time attributes** | Outlet and product attributes are as-of the moment of the sale, not today's values. Use `rpt_sales_flat`, which encapsulates the SCD2 join. |
| **Deleted records** | An entity that is *ever* hard-deleted in CDC stays deleted. A later update does not resurrect it. |
| **Currency / units** | INR, unrounded in the marts. Crore (`/1e7`) and lakh (`/1e5`) only in presentation. |

**Data window:** 2025-01-01 to 2026-06-30. Last complete fiscal quarter:
**FY27-Q1**. Verified complete — 91 of 91 days present, and the final three
days sit within −0.5% to −2.5% of the quarter's daily mean, so there is no
material late-arrival truncation at the tail.

---

## 1. Sales

### KPI-01 — Gross Sales

| | |
|---|---|
| **Definition** | Value of goods sold at the till before discount and before tax. Quantity × unit price, summed. |
| **Grain** | One POS transaction line; reportable at any rollup (day, week, fiscal period, channel, outlet, SKU, category, region). |
| **Formula** | `SUM(qty_original * unit_price)` |
| **Filters / exclusions** | Deduplicated to one row per `(txn_id, txn_line_no)`. No date filter by default. Nothing else excluded — no outlet, channel or SKU is suppressed. |
| **Source feeds** | `pos_transactions` → `stg_pos_transactions` → `fct_sales` |
| **Owner** | Anand Krishnamurthy, Group CFO |
| **Query** | `sql/queries/sales/gross_sales_by_channel.sql` |
| **Known limitation** | `qty_original` mixes units of measure. Pre-2025-10-01 the feed carried no `uom` column at all, so ~50% of lines have an unknown unit. This does **not** affect the money — verified against the generator, `unit_price` is per transacted unit regardless of whether that unit is an each or a case, so revenue is correct either way. It only affects volume metrics (see KPI-05). |

### KPI-02 — Net Sales

| | |
|---|---|
| **Definition** | Gross sales less line-level discount. The taxable value of the sale. |
| **Grain** | POS transaction line |
| **Formula** | `SUM(qty_original * unit_price - discount_amount)` |
| **Filters / exclusions** | As KPI-01. |
| **Source feeds** | As KPI-01 |
| **Owner** | Anand Krishnamurthy, Group CFO |
| **Query** | `sql/queries/sales/sales_summary.sql` |
| **Known limitation** | None material. POS discount is genuinely derived from the line value in the source, so net is always ≤ gross and never negative — verified across all 4,000,000 lines. **Note this does not hold for orders** — see KPI-09 and X-04. |

### KPI-03 — Sales Including Tax

| | |
|---|---|
| **Definition** | Net sales plus line-level tax. The amount the customer actually paid. |
| **Grain** | POS transaction line |
| **Formula** | `SUM(qty_original * unit_price - discount_amount + tax_amount)` |
| **Filters / exclusions** | As KPI-01. |
| **Source feeds** | As KPI-01 |
| **Owner** | Anand Krishnamurthy, Group CFO |
| **Query** | `sql/queries/sales/sales_summary.sql` |
| **Known limitation** | Tax is taken as delivered on the line, not recomputed from `dim_product.gst_rate_pct` — that field is regeneration noise in the CDC feed and would produce a worse number than the POS-native one. |

### KPI-04 — Units Sold (as transacted)

| | |
|---|---|
| **Definition** | Sum of quantity exactly as the till recorded it, without unit conversion. |
| **Grain** | POS transaction line |
| **Formula** | `SUM(qty_original)` |
| **Filters / exclusions** | As KPI-01. |
| **Source feeds** | As KPI-01 |
| **Owner** | Anand Krishnamurthy, Group CFO |
| **Query** | `sql/queries/sales/units_sold.sql` |
| **Known limitation** | **This number mixes eaches and cases and is not a physical volume.** It is published only because it is the one unit metric available for 100% of lines, and because it is what the legacy report's `units_sold` column is comparable to. For a true volume figure use KPI-05 and accept the coverage loss. Do not sum KPI-04 across channels and call it volume. |

### KPI-05 — Units Sold in Eaches

| | |
|---|---|
| **Definition** | Physical selling units sold, converting case quantities to eaches via the UOM reference. |
| **Grain** | POS transaction line |
| **Formula** | `SUM(qty_eaches)` where `qty_eaches` = `qty` if `uom = 'EA'`, `qty × eaches_per_case` if `uom = 'CS'`, else `NULL` |
| **Filters / exclusions** | Lines with an unresolvable unit are **excluded** (NULL), not assumed. |
| **Source feeds** | `pos_transactions`, `data/reference/uom_conversion.csv` |
| **Owner** | Anand Krishnamurthy, Group CFO |
| **Query** | `sql/queries/sales/units_sold_in_eaches.sql` |
| **Known limitation** | **Coverage is only 49.63% of lines.** Two independent causes, reported separately by the query: (a) 49.97% of lines predate the 2025-10-01 schema change and carry no `uom` column at all — the source did not record whether the quantity was cases or eaches, and it is not recoverable; (b) 0.40% have a known unit but the SKU is absent from `uom_conversion.csv` (46 of 1,100 SKUs). We deliberately do **not** default the missing half to eaches. Doing so would understate volume on roughly 19% of those lines (the historical case share), silently and unquantifiably. Any eaches figure must be quoted with its coverage percentage attached. |

### KPI-06 — Basket Count and Average Basket Value

| | |
|---|---|
| **Definition** | Basket count = distinct shopper transactions. Average basket value = gross sales ÷ basket count. |
| **Grain** | `basket_id` |
| **Formula** | `COUNT(DISTINCT basket_id)`; `SUM(gross_sales_amount) / COUNT(DISTINCT basket_id)` |
| **Filters / exclusions** | As KPI-01. |
| **Source feeds** | As KPI-01 |
| **Owner** | Anand Krishnamurthy, Group CFO |
| **Query** | `sql/queries/sales/sales_summary.sql` |
| **Known limitation** | A basket spanning midnight IST is attributed to the day of each line, so a basket can be counted in two days when rolled up daily. Immaterial at current volumes; would need a basket-level date assignment to fix properly. |

---

## 2. Channel

### KPI-07 — Gross Sales by Channel

| | |
|---|---|
| **Definition** | KPI-01 split by the sales channel recorded at the till: GT (general trade), MT (modern trade), HORECA, ECOM (e-commerce dark stores). |
| **Grain** | POS transaction line, grouped by `channel_at_sale` |
| **Formula** | KPI-01, `GROUP BY channel_at_sale` |
| **Filters / exclusions** | As KPI-01. |
| **Source feeds** | `pos_transactions` (channel taken from the POS line itself) |
| **Owner** | Anand Krishnamurthy, Group CFO |
| **Query** | `sql/queries/sales/gross_sales_by_channel.sql` |
| **Known limitation** | Channel is deliberately taken from the **POS line**, not from `dim_outlet.channel`. The outlet master's channel field is re-randomised on every CDC update and is not real reclassification history — joining to it would produce a materially different and wrong split. See X-03. The consequence is that channel is a degenerate dimension on the sale: it is correct for the sale, but it cannot answer "what channel is this outlet *now*". |

---

## 3. Finance reconciliation

### KPI-08 — Published vs Actual Variance

| | |
|---|---|
| **Definition** | The difference between gross sales as this platform computes it and gross sales as the legacy weekly Finance report published it, on a common week × channel grain. Reported three ways: our correct basis, the legacy method faithfully reproduced, and the published figure. |
| **Grain** | (week_start, channel) — 312 cells over the 18-month window |
| **Formula** | See `rpt_finance_reconciliation`. `variance_pct = published / correct − 1` |
| **Filters / exclusions** | Weeks are `[week_start, week_start + 7 days)`, taken from the legacy file itself so buckets align by construction. |
| **Source feeds** | `fct_sales`, raw `pos_transactions` (un-deduplicated, for the emulated basis), `data/reference/legacy_finance_weekly_report.csv` |
| **Owner** | Anand Krishnamurthy, Group CFO |
| **Query** | `sql/queries/finance/reconciliation_summary.sql` |
| **Known limitation** | **The legacy report cannot be reconciled to, and this metric measures the gap rather than closing it.** Both defects Supply Chain alleged are real and are quantified here — booking on ingest date rather than event date, and no deduplication — but together they account for only **+2.1%** (₹11.57 cr and 84,000 duplicate lines). The published total is ₹458.93 cr against ₹562.39 cr on the fully bug-emulated basis. Correlation between published and actual is **0.0055** across all 312 cells; per-channel ratios run 0.42× to 3.20× in both directions; published revenue is near-flat across four channels (₹108–122 cr each) where actual sales vary more than eightfold (₹35–279 cr). Only 7 of 312 cells fall within 5%, which is what chance would produce. Confirmed in `generate_dataset.py`: the published figures are drawn as `rng.uniform(4_000_000, 26_000_000)` with no reference to any transaction. **The published report is not a buggy derivation of the POS feed; it is not derived from the feed at all.** Recommendation to the CFO: replace, do not reconcile. Tying out to it would require fabricating the tie. |

---

## 4. Orders

### KPI-09 — Order Value Gross (corrected)

| | |
|---|---|
| **Definition** | Total gross value of orders placed, with the known PARTNER_API freight double-count removed, at one row per order. |
| **Grain** | `order_number` — the latest non-deleted CDC version |
| **Formula** | `SUM(order_value_gross_corrected)`; PARTNER_API rows are divided by 1.085 |
| **Filters / exclusions** | `WHERE NOT is_deleted` excludes the 2,880 hard-deleted orders. Tombstoned orders stay in the fact for traceability but never in the metric. |
| **Source feeds** | `erp_cdc/sales_order_header` → `stg_sales_order_header` → `fct_orders` |
| **Owner** | Anand Krishnamurthy, Group CFO |
| **Query** | `sql/queries/orders/order_value_by_source_system.sql` |
| **Known limitation** | The uncorrected `order_value_gross` is also retained, so the correction is auditable rather than baked in silently. Verified: the correction removes exactly 8.5% from PARTNER_API and 0.0% from the other two systems. Order **net** and **tax** values are not published at all — see X-04. `order_status` never reaches DELIVERED in this dataset (structurally unreachable), so order-to-delivery metrics are not available. |

### KPI-10 — Order Count by Source System

| | |
|---|---|
| **Definition** | Distinct non-deleted orders, split by the system that captured them (SFA_MOBILE, ERP_WEB, PARTNER_API). Answers "are the three sources comparable?" |
| **Grain** | `order_number` |
| **Formula** | `COUNT(*)` over `fct_orders WHERE NOT is_deleted`, `GROUP BY source_system` |
| **Filters / exclusions** | As KPI-09. |
| **Source feeds** | As KPI-09 |
| **Owner** | Anand Krishnamurthy, Group CFO |
| **Query** | `sql/queries/orders/order_value_by_source_system.sql` |
| **Known limitation** | **Answer to the comparability question: on gross value, yes — after correction.** Average corrected order value is ₹241,384 (ERP_WEB), ₹241,607 (PARTNER_API), ₹240,653 (SFA_MOBILE) — statistically indistinguishable, which is what confirms the 8.5% correction is the right one and that the Finance ticket from 2025 was justified. On discount, tax and net value the three sources are **not** comparable, because those fields are not meaningful in any of them (X-04). |

---

## 5. Cold chain

### KPI-11 — Cold Chain Excursion Rate

| | |
|---|---|
| **Definition** | Proportion of temperature readings above the chilled band. The target band is 2–8 °C and the feed contract defines an excursion as *"any reading above the band"* — so this metric is strictly "above 8 °C", taken literally. |
| **Grain** | One telemetry reading. Reportable by month, vehicle, device, vendor, gateway. |
| **Formula** | `COUNT(*) FILTER (WHERE is_excursion) / COUNT(*) FILTER (WHERE NOT temp_reading_missing)` |
| **Filters / exclusions** | Readings where the sensor returned no value are excluded from **both** numerator and denominator — `is_excursion` is NULL, not FALSE, when there is no reading, so "no data" is never counted as "in band". 0.60% of readings. |
| **Source feeds** | `reefer_telemetry` → `stg_reefer_telemetry` → `fct_cold_chain_readings` |
| **Owner** | Divya Raghavan, Head of Supply Chain Operations |
| **Query** | `sql/queries/cold_chain/excursion_rate_by_month.sql` |
| **Known limitation** | **The rate is 7.19% at reading grain, not the ~33% Operations believed.** It is also remarkably stable month to month (7.11%–7.17% across the most recent four months), with no seasonality. Two things drive the discrepancy with the ~33% estimate: the grain, and the definition. A naive vehicle-day rollup — where any single bad reading marks the whole vehicle-day as breached — gives **75.07%**. Neither figure is a third, which suggests the original estimate came from a third, uncontrolled definition. **This metric is deliberately published at reading grain and not rolled up to "trips", because nothing in the feed demarcates a trip** (see X-05). Two normalisations are applied upstream before any reading is judged: one vendor reports Fahrenheit (converted), and the firmware 2.1.4 fleet has a +7h clock offset (corrected). |

### KPI-12 — Below-Band Reading Rate

| | |
|---|---|
| **Definition** | Proportion of readings **below** 2 °C. Tracked separately from KPI-11 and deliberately not folded into it. |
| **Grain** | One telemetry reading |
| **Formula** | `COUNT(*) FILTER (WHERE is_below_band) / COUNT(*) FILTER (WHERE NOT temp_reading_missing)` |
| **Filters / exclusions** | As KPI-11. |
| **Source feeds** | As KPI-11 |
| **Owner** | Divya Raghavan, Head of Supply Chain Operations |
| **Query** | `sql/queries/cold_chain/excursion_rate_by_month.sql` |
| **Known limitation** | **This metric exists because the contract's definition is arguably wrong, and it is 2.75× larger than the excursion rate it is excluded from: 19.83% of readings are below 2 °C versus 7.19% above 8 °C.** A reading of −5 °C is not an "excursion" under the contract's literal wording, even though for chilled product it is plausibly a worse failure than 9 °C. We implemented the contract as written and surfaced this separately rather than silently redefining it. **Open question for Divya before this is finalised:** should cold-chain integrity mean *outside* the band rather than *above* it? If yes, the combined breach rate is 27.02% and every excursion number in circulation changes. |

### KPI-13 — Telemetry Completeness

| | |
|---|---|
| **Definition** | Proportion of expected telemetry readings actually received, and the proportion received but null. |
| **Grain** | Reading; reportable by day, gateway, device |
| **Formula** | `COUNT(*) FILTER (WHERE temp_reading_missing) / COUNT(*)` for null rate |
| **Filters / exclusions** | None. |
| **Source feeds** | `reefer_telemetry` |
| **Owner** | Divya Raghavan, Head of Supply Chain Operations |
| **Query** | `sql/queries/cold_chain/telemetry_completeness.sql` |
| **Known limitation** | Two distinct failure modes, and the query reports them separately because a null check only finds the first. (a) 0.60% of readings arrive with a null temperature — sensor dropout, evenly spread across every vendor and firmware line (0.579%–0.612%), so it is a fleet-wide characteristic and not a bad device. (b) Readings that never arrive at all. Gateway `GW-017` has a total two-day outage on 2026-02-11 and 2026-02-12 — those rows are *absent*, not null, so they are invisible to a null count and present as low volume. This is exactly the failure mode ticket KP-3172 describes. Section 2 of the query detects it by comparing each gateway-day against that gateway's own median daily volume, and on this dataset it isolates both outage days with **zero false positives** across all gateways and all 546 days. Separately, 945 readings are permanently lost to one truncated Parquet file (`dt=2025-07-14/part-00000.parquet`), which the pipeline skips by name and logs rather than failing the run. **Scope limit:** this covers the telemetry feed only. Equivalent completeness monitoring for POS, WMS and CDC — reconciled against `data/_manifest/expected_partitions.csv` — is not built; see `DECISIONS.md`. |

---

## 6. Requested but not buildable

These were asked for explicitly — in the client brief, in the illustrative
questions, or by Operations. Each is listed with what would be needed to
build it. **None of them is approximated.**

### X-01 — Cold chain excursion rate by carrier

*Asked for directly by Divya Raghavan: "what proportion of chilled trips
breached temperature, by month and by carrier".*

**Blocker:** there is no carrier identifier anywhere in the telemetry feed, or
in any other raw feed. `carrier_master.csv` is fully orphaned reference data —
confirmed in `generate_dataset.py` that `carrier_id` is written once, into
that CSV, and referenced nowhere else. `dim_carrier` is built and conformed so
it is ready the day a link arrives, but it currently joins to nothing.

**The by-month half of this question is answerable** and is published as
KPI-11. Only the carrier split is blocked.

**To unblock:** a vehicle-to-carrier or route-to-carrier assignment feed, at
minimum `(vehicle_registration, carrier_id, valid_from, valid_to)`. Note that
`route_code` and `warehouse_code` on the telemetry feed cannot substitute —
both are re-randomised on every individual reading, and every one of the 340
vehicles sees readings against all 260 routes and all 8 warehouses. The feed
contract describes them as "assignment at time of reading", which is one of
the statements in that document that the data contradicts.

### X-02 — Median dock-to-dispatch cycle time by warehouse

*Illustrative question 5, and named by Divya as one of three metrics she needs
defined.*

**Blocker:** `wms_scan_events` contains no stitchable per-item journey.
`order_number`, `sku_code`, `batch_id`, `pallet_id` and `warehouse_code` are
each drawn independently per scan row, so no shared key ties one item's six
handling stages together. Verified three ways rather than assumed:
RECEIVE→DISPATCH stitched by `order_number` yields a **negative** duration for
50.13% of eligible orders — a coin flip, not a data-quality tail; the same
~50% negative rate holds keying by `batch_id` (49.91%) and `pallet_id`
(49.81%), which rules out "wrong join key"; and among the positive-duration
half the median implied cycle time is ~155 days, which is not a warehouse
cycle. Orders showing all six stages still touch ~8.6 distinct SKUs on
average.

`fct_warehouse_cycle_time` **is** built, at order grain with the six stage
timestamps pivoted and an `is_cycle_time_plausible` flag, purely as a
diagnostic so this conclusion is reproducible. **Do not publish a cycle time
from it**, including from the plausible half — that half is the same noise
with the sign flipped.

**To unblock:** a genuine handling-unit identifier that persists across scan
stages.

### X-03 — Outlets that changed channel classification, and when

*Illustrative question 6.*

**Blocker:** the outlet master's versioned attributes are not change history.
`channel`, `outlet_format`, `city`, `route_code`, `credit_limit` and
`credit_terms_days` — six of nine attributes — are independently re-randomised
on every CDC update, confirmed in the generator. Outlets with multiple
versions average 2.5–3.8 distinct values across these fields with no pattern:
OUT001011 cycles GT → MT → ECOM → GT → MT → GT → ECOM and five different
cities across 12 versions.

Answering this question from `dim_outlet.channel` would report that the large
majority of outlets changed channel. That is noise presented as a finding, and
it is the kind of number that ends up in a board pack.

Only `warehouse_code`, `gst_number` and `outlet_name` are genuinely stable.
The reliable channel value is `version_no = 1`, the initial insert, which
matches the POS-native channel for 100% of that outlet's sales.

**To unblock:** a source that emits change events only on genuine change, or a
reclassification log.

### X-04 — Order net value, order tax, order discount

**Blocker:** on `sales_order_header`, `discount_amount` and `tax_amount` are
drawn as free-standing uniforms with no reference to `order_value_gross`.
Verified on the built fact: `corr(gross, discount) = 0.0020`,
`corr(gross, tax) = 0.0027`, and the implied tax rate spans 0.04% to 2552%
(median 10.83%) where a real GST rate would cluster tightly. Because discount
is unbounded relative to gross, 1,743 orders (0.54%) compute to a negative net
value, at a near-identical rate in all three source systems — which rules out
the L14 freight correction as the cause.

`order_value_net` and `order_value_incl_tax` exist as columns on `fct_orders`
and are deliberately left unclamped, because removing them would hide the
finding. **No KPI is built on them.** Use KPI-09.

**Note the asymmetry, because the instinct is to generalise:** the POS feed
*does* derive discount and tax from the line value, so KPI-02 and KPI-03 are
sound. This limitation is specific to the order feed.

### X-05 — Trip-level cold chain integrity

*Implied by Divya's framing: "what proportion of chilled **trips** breached".*

**Blocker:** nothing in the telemetry feed demarcates a trip. There is no trip
identifier, no ignition or door-cycle boundary that closes a journey, and no
dispatch event to anchor one. The only genuinely stable identity on the feed is
`device_id → vehicle_registration` (verified 1:1, zero devices on more than
one vehicle).

Any trip definition would therefore be invented in the pipeline — and the
choice would drive the headline number, since a vehicle-day rollup already
moves the rate from 7.19% to 75.07%. `fct_cold_chain_readings` is deliberately
left at reading grain so that the rollup is an explicit, documented decision at
query time rather than an assumption baked into storage.

**To unblock:** a trip or shipment feed, or an ignition/door event stream from
which trip boundaries can be derived. **Then agree the definition with
Operations before publishing** — this is the number most likely to be
misquoted.

---

## 7. Ownership

| Owner | Role | Metrics |
|---|---|---|
| Anand Krishnamurthy | Group CFO | KPI-01 … KPI-10 |
| Divya Raghavan | Head of Supply Chain Operations | KPI-11 … KPI-13, and the definitional decision open on KPI-12 |
| Data Platform | — | Feed completeness and the conventions table above |

**Open decisions awaiting an owner's call**

1. **KPI-12 / KPI-11 — Divya.** Should a cold-chain excursion mean *outside*
   the 2–8 °C band rather than *above* it? Currently implemented as the feed
   contract literally states. Changing it moves the breach rate from 7.19% to
   27.02%.
2. **KPI-05 — Anand.** Accept 49.63% coverage on eaches, or accept an
   assumption for the pre-drift half with a stated error bar? Currently no
   assumption is made.
3. **KPI-08 — Anand.** Confirm the recommendation to retire the legacy weekly
   report rather than continue reconciling to it.
