# Decisions

**Kestrel Provisions — Analytical Foundation.** The full data-quality
investigation behind these decisions is in [`docs/findings.md`](docs/findings.md);
every metric is defined in [`docs/kpi_catalogue.md`](docs/kpi_catalogue.md).

## What I built

A medallion pipeline in DuckDB — 17 models, runnable end to end on one command
(`python3 scripts/run_pipeline.py`), ~15s at scale 1. Six staging models (one
per raw feed, deduped and defect-corrected), a nine-model star schema (4 facts,
5 dimensions, outlet and product as SCD2), and a reporting layer: a flat sales
view that encapsulates the point-in-time join, and a Finance reconciliation.
On top, a KPI catalogue of 13 metrics and a query library of 11 parameterised
queries, each cross-referenced to its catalogue entry so a number, its
definition and its SQL are never more than one hop apart.

I weighted the effort toward **being able to defend every number** rather than
toward breadth. The dataset is adversarial by design, so most of the real work
was establishing which columns mean anything at all.

## What I deliberately did not build

- **Metrics that cannot be built honestly.** Three of the brief's eight
  illustrative questions are unanswerable from these feeds: cycle time by
  warehouse (WMS scans are not one item's journey — ~50% of stitched journeys
  run backwards under every candidate key), excursion rate by carrier (no
  carrier key exists on any feed; `carrier_master.csv` is orphaned), and outlet
  channel reclassification (the outlet master re-randomises channel on every
  CDC update). Each is documented in the catalogue with evidence and has a
  runnable proof in `sql/queries/limitations/`. I did not approximate any of
  them. A plausible wrong number costs more than an absent one.
- **Incremental processing.** Every run is a full rebuild — simple, correct,
  trivially idempotent, and the right trade at this scope. See "what breaks
  first".
- **Feed-completeness reconciliation against the manifest.** Gateway-outage
  detection is built for telemetry and isolates the GW-017 two-day outage with
  no false positives, but the equivalent for POS, WMS and CDC is not. This is
  the largest thing I would do next.
- **The "ask-anything" interface.** The CFO asked for it. I judged a thin
  natural-language layer over a foundation I could not yet fully defend to be
  the wrong order of work. The query library is the honest version of it today:
  every number arrives with the SQL that produced it, which was his actual
  condition.
- **Materialised reporting tables.** Views are always in sync. At 4m rows
  DuckDB joins are not the bottleneck; `CREATE VIEW` → `CREATE TABLE AS` is the
  whole migration if that changes.

## What I assumed where the brief was unclear or self-contradictory

- **"Reconcile to the Finance weekly report" is not satisfiable, so I measured
  the gap instead.** The CFO said reconcile to it; Supply Chain said it double
  counts and books sales on the wrong day. Both allegations are real — and
  together worth only **+2.1%**. Reproducing both bugs exactly still gives
  ₹562 cr against a published ₹459 cr, with correlation **0.0055** across 312
  week × channel cells and published revenue near-flat across channels that
  actually differ eightfold. The published figures are not a buggy derivation
  of the POS feed; they are not derived from it at all. I built the
  reconciliation to prove that rather than assert it, and I recommend
  replacing the report rather than tying out to it. Tying out would require
  fabricating the tie.
- **Business day is IST, and the event date — not the ingest date.** POS
  `event_ts` arrives in UTC; ~4.49% of rows land 1–3 days late. This is the
  single largest definitional difference from the legacy report.
- **An excursion is "above the band", per the feed contract's literal wording.**
  I implemented it literally and surfaced below-band readings as a separate,
  equally visible metric — because they are 2.75× more common (19.83% vs
  7.19%) and arguably a worse cold-chain failure. **This needs a decision from
  Operations**, not from me: "outside the band" moves the breach rate to
  27.02%.
- **Eaches coverage is 49.63%, and I did not improve it by assuming.** Half the
  history predates the schema change and carries no `uom` column, so cases and
  eaches are indistinguishable. Defaulting to eaches would understate volume on
  ~19% of those lines, silently. Every eaches figure is published with its
  coverage attached.
- **Sale-time channel comes from the POS line, not from `dim_outlet`.** The
  outlet master's channel is noise; the POS-native value is the real one and
  matches for 100% of an outlet's sales.
- **"Ever deleted" means permanently deleted.** A later update does not
  resurrect a tombstoned record. On orders this is the entire result: no
  delete row is ever chronologically last, so a "latest op_type" test would
  flag zero of 2,880 deleted orders.
- **Order net and tax are arithmetic only.** On the order feed, discount and tax
  are independent of gross (corr 0.0020 / 0.0027; implied tax rate spans 0.04%
  to 2552%), so 0.54% of orders compute to a negative net. I kept the columns
  unclamped — removing them would hide the finding — and built no KPI on them.
  The same formulas *are* sound on the POS feed, where discount and tax are
  genuinely derived.

## What I would do next with two more weeks

1. **Feed completeness across all four feeds**, reconciled against
   `_manifest/expected_partitions.csv`, with volume-vs-baseline alerting.
   Answers "which days are missing data, and how would we know without being
   told" properly rather than for telemetry only.
2. **Incremental builds** — partition-level insert-overwrite on
   `ingest_date`/`dt`, `MERGE INTO` on the CDC tables.
3. **Tests as code.** The validation that produced every number in
   `docs/findings.md` currently lives in a gitignored scratchpad. It should be
   committed assertions that fail the pipeline, not prose claims a reader has
   to trust.
4. **Resolve the two open definitional questions** with Divya (excursion band)
   and Anand (eaches coverage), then lock the catalogue.
5. **The ask-anything layer**, constrained to the catalogue's metrics and
   always showing its SQL.

## What breaks first in production, and at what volume

**Full rebuild is the first thing to break, and it breaks on time, not on
size.** At scale 1 the pipeline runs in ~15s; the work is O(all history), so a
nightly job re-scans eighteen months to add one day. At `--scale 10` (~100m
rows) expect low single-digit minutes — still fine. The real wall is calendar
time: at three years of history and 10× volume, a nightly full rebuild stops
fitting a batch window, and the fix is incremental processing, not more
hardware.

**Second: memory on the SCD2 point-in-time join.** `rpt_sales_flat` joins 4m
fact rows to versioned dims on a range predicate, which DuckDB cannot hash-join
cleanly. It is comfortable now; at 10× fact volume with dimension history
growing too, this is where spilling starts. Mitigations in order of preference:
materialise the view, or resolve the dimension version key once at fact-build
time.

**Third: the single-file database.** `kestrel.duckdb` is one file with one
writer. It is right for this, and it is not a warehouse. Concurrent analyst
access, or any need for scheduled writes during reads, means moving the marts
to something else — the SQL is close to portable, since it is almost all
standard.

**What will not break: schema drift.** `union_by_name` already absorbed the
POS Q4-2025 column rename. A new column appears as NULL rather than failing the
run. A *renamed* column silently becomes NULL in the old name, which is worse
than an error — the completeness monitoring in item 1 above is what would catch
it.

## Known documentation debt

`docs/findings.md` is long by design — it is the evidence base, not a summary.
This file is the one-page account the brief asked for and links out to it.
