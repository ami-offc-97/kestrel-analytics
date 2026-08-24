# Decisions

**Kestrel Provisions — Analytical Foundation.** The full data-quality
investigation behind these decisions is in [`docs/findings.md`](docs/findings.md);
every metric is defined in [`docs/kpi_catalogue.md`](docs/kpi_catalogue.md).

## What I built

A medallion pipeline in DuckDB — 20 models, runnable end to end on one command
(`python3 scripts/run_pipeline.py`), ~15s at scale 1. Six staging models (one
per raw feed, deduped and defect-corrected), a nine-model star schema (4 facts,
5 dimensions, outlet and product as SCD2), three data-quality models, and a
reporting layer: a flat sales view that encapsulates the point-in-time join,
and a Finance reconciliation. On top, a KPI catalogue of 14 metrics and a query
library of 12 parameterised queries, each cross-referenced to its catalogue
entry so a number, its definition and its SQL are never more than one hop
apart.

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
- **Per-dimension completeness monitoring beyond telemetry gateways.** Feed
  completeness now covers all six feeds at three grains, but the
  spine-times-dimension check that actually finds holes inside a healthy feed
  exists only for telemetry gateways. POS needs the same per till/outlet, WMS
  per warehouse, before either could honestly be called monitored.
- **An LLM writing SQL for the "ask-anything" interface.** I built the
  interface (`scripts/ask.py`) but deliberately not that way. It routes a
  plain-English question to a query that already exists in the library, prints
  the SQL, then runs it — so every number it returns is one a human already
  defined and owns. A model generating fresh SQL would answer more questions
  and would sometimes be confidently wrong: on this schema it would happily
  join `dim_outlet.channel` and report a channel split that looks entirely
  plausible and is noise. Where six of nine outlet attributes are meaningless,
  "sounds right" is the failure mode to design against, and the whole
  submission argues for not publishing numbers we cannot defend. The cost is a
  fixed vocabulary, held as data in `sql/queries/intents.json`; when the router
  does not recognise a question it says so and lists what it knows rather than
  guessing.
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
- **Completeness cannot be checked at one grain.** I built three models rather
  than one because each catches a class of failure the others structurally
  cannot see, and this dataset contains one example of each. The manifest is
  the only thing that can prove a partition is *short* (it isolates the
  truncated file at 85.9% of expected); a calendar spine is the only thing that
  can see a day that was never written (the manifest is built by scanning what
  *was* written, so an absent day reconciles clean on both sides); and a
  per-gateway baseline is the only thing that finds the GW-017 outage, which
  sits at ~95% of feed-level volume because one dead gateway is 2.5% of
  telemetry. Nor could a feed-level threshold be tuned to cover the gap — the
  truncated-file day is 85.0% of median and another feed's quietest *ordinary*
  day is 85.9%.
- **Both DQ detectors were retuned after their first version produced only
  noise**, which I mention because the failure was mine and the lesson is the
  transferable part. An 80% floor at gateway grain gave 74 alerts, all ordinary
  variance (the 0.1st percentile of non-zero gateway-days is 77.2%). Relative
  thresholds on the tiny CDC feeds gave 342 more — `product_master` runs a
  median of 4 rows/day, where "25% of median" means one change instead of four.
  Both now sit at zero false positives across 21,294 gateway-days and 3,276
  feed-days. Feeds under 100 rows/day are explicitly marked unmonitorable
  rather than monitored badly, and their zero-row days are reported as INFO,
  because for a CDC feed "no rows" most likely means "nothing changed" — which
  cannot be distinguished from a failed extract without a delivery receipt the
  ERP does not send.

## What I would do next with two more weeks

1. **Per-dimension completeness for POS and WMS** — the spine-times-dimension
   pattern that found GW-017, applied per till/outlet and per warehouse. Feed
   totals are demonstrably too coarse to catch a 2.5% hole.
2. **Incremental builds** — partition-level insert-overwrite on
   `ingest_date`/`dt`, `MERGE INTO` on the CDC tables.
3. **Tests as code.** The validation that produced every number in
   `docs/findings.md` currently lives in a gitignored scratchpad. It should be
   committed assertions that fail the pipeline, not prose claims a reader has
   to trust.
4. **Resolve the two open definitional questions** with Divya (excursion band)
   and Anand (eaches coverage), then lock the catalogue.
5. **Upgrade ask.py to generate SQL**, with the guardrails that would make it
   trustworthy: generation restricted to `rpt_sales_flat` and the marts, the
   catalogue's definitions and known-noise columns supplied as context, a
   refusal path for the five documented unbuildable metrics, and the generated
   SQL shown and logged every time. The routing layer already built is the
   thing that makes this safe to attempt — it defines what "correct" looks
   like for each question, so a generated answer can be checked against it.

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
