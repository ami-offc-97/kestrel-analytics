# SQL Query Library

The runnable queries behind [`docs/kpi_catalogue.md`](../../docs/kpi_catalogue.md).
Every metric in the catalogue names a file here, and every file here names its
catalogue entry in its header. That pairing is the traceability requirement:
a number, its definition, and the SQL that produced it are never more than one
hop apart.

## Running a query

```bash
python3 scripts/run_query.py sql/queries/sales/gross_sales_by_channel.sql
```

List everything available:

```bash
python3 scripts/run_query.py --list
```

Queries are parameterised with `SET VARIABLE` at the top of the file. Edit the
file, or override at the command line without touching it:

```bash
python3 scripts/run_query.py sql/queries/sales/sales_summary.sql \
    -p date_from=2025-04-01 -p date_to=2025-06-30 -p group_by=channel
```

The defaults in each file are chosen to be the question most likely to be
asked — usually the last complete fiscal quarter or the last complete month —
so a file with no arguments answers something useful.

If you have the DuckDB CLI installed you can also pipe a file straight in
(`duckdb kestrel.duckdb < <file>`), but the CLI is not required and is not
installed by `pip install duckdb`. `run_query.py` is the supported path.

## Layout

| Directory | Contents |
|---|---|
| `sales/` | Revenue, units, baskets, channel split. KPI-01 … KPI-07 |
| `finance/` | Reconciliation against the legacy weekly board report. KPI-08 |
| `orders/` | Order value and source-system comparability. KPI-09, KPI-10 |
| `cold_chain/` | Excursion rates and telemetry completeness. KPI-11 … KPI-13 |
| `data_quality/` | Feed completeness. **Run this first, every day.** KPI-14 |
| `limitations/` | **Proofs that a requested metric cannot be built.** See below |

## The `limitations/` directory

These files return no metric. Each one demonstrates, against the real data,
why a specific thing the business asked for cannot be produced from the feeds
as they stand.

They exist because the failure mode they guard against is not "we forgot to
build it" — it is someone rebuilding the wrong version six months from now,
finding a plausible number, and publishing it. Each file shows the trap and the
evidence, so the conclusion can be re-derived in one command rather than
re-litigated.

| File | Question it closes off |
|---|---|
| `x01_carrier_unlinkable.sql` | Cold chain excursion rate **by carrier** — no carrier key exists on any feed, and `route_code` cannot substitute |
| `x02_cycle_time_not_stitchable.sql` | Median **dock-to-dispatch cycle time** — WMS scans are not one item's journey; ~50% of stitched journeys run backwards under every candidate key |
| `x03_outlet_channel_is_noise.sql` | Which outlets **changed channel**, and when — the outlet master re-randomises channel on every CDC update |

Run them before proposing a workaround for any of the three.

## Coverage of the brief's illustrative questions

| # | Question | Where |
|---|---|---|
| 1 | Gross sales by channel, last complete fiscal quarter | `sales/gross_sales_by_channel.sql` |
| 2 | Comparison with the published Finance weekly report | `finance/reconciliation_summary.sql` |
| 3 | Units sold last month, in eaches | `sales/units_sold_in_eaches.sql` |
| 4 | Chilled trips breaching temperature, by month and carrier | `cold_chain/excursion_rate_by_month.sql` — by month only. Carrier: `limitations/x01`. "Trips" are undefined in the feed (catalogue X-05) |
| 5 | Median dock-to-dispatch cycle time by warehouse | **Not answerable** — `limitations/x02` |
| 6 | Outlets that changed channel classification, and when | **Not answerable** — `limitations/x03` |
| 7 | Order value by source system, and comparability | `orders/order_value_by_source_system.sql` |
| 8 | Which days are missing data, in any feed | `data_quality/feed_completeness.sql` — manifest reconciliation across all feeds, absent-day detection on a calendar spine, and per-gateway hole detection |

Three of eight resolve to "not answerable from these feeds". Question 4 is
answerable by month but not by carrier. That is the honest count, and each
limitation is evidenced rather than asserted.

## Start here each morning

```bash
python3 scripts/run_query.py sql/queries/data_quality/feed_completeness.sql
```

Section 5 gives a one-line verdict. If it does not say `CLEAN`, read sections
1–4 before publishing any number from the other queries.
