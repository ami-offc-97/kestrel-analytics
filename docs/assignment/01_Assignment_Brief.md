# AI and Data Engineer: Take-Home Assignment

**Kestrel Provisions Pvt Ltd: Analytical Foundation and Metric Layer**

Version 1.0 | Issued August 2026

---

## Before you start

This is not a test of whether you can finish. It is deliberately scoped larger than the time available.

We are evaluating three things: what you chose to build, what you chose not to build, and whether the thing you built holds up when someone pokes it. A small, honest, working pipeline with a clear rationale beats a large half-working one every time.

**Time expectation.** Around eight focused hours. You have four working days from receipt. If you need more time, ask HR. Extensions are granted on request and you do not need to give a reason.

**Tooling.** Use whatever you want, including Claude, Cursor, Copilot, or any other assistant, and any engine you like: DuckDB, Spark, Polars, Postgres, dbt, whatever fits. We use these tools every day and we expect you to. There is no penalty and no separate track for AI-assisted work.

**Hardware.** The shipped dataset is around ten million rows and runs on a laptop. You do not need a cluster.

**What you cannot do.** Do not use a client's real data.

---

## 1. The situation

Kestrel Provisions is a food and grocery distributor. Ambient, chilled and frozen product moves from eight distribution centres to roughly two and a half thousand retail outlets across five regions in India. Channels are general trade, modern trade, HORECA and e-commerce dark stores. Annual revenue is in the region of INR 900 crore.

The company has four systems that matter and none of them agree.

Point of sale transactions arrive nightly from modern trade and e-commerce partners. Reefer vehicles emit temperature telemetry from two different device vendors. The warehouse management system emits scan events at every handling stage. The ERP publishes change-data-capture extracts for masters and order headers.

There is no warehouse. There is a nightly script, written by an analyst who has left, that produces a weekly report for Finance. Everyone quotes different numbers in meetings and nobody can say which is right, because there is no written definition of any metric anywhere in the business.

---

## 2. Client brief

> **From:** Anand Krishnamurthy, Group Chief Financial Officer
> **To:** Delivery team
> **Subject:** One set of numbers
>
> Last month I sat in a review where four people quoted four different figures for the same week's sales. Nobody was lying. They had each built their own extract and each made their own assumptions, and none of those assumptions was written down anywhere.
>
> What I want out of this is not a dashboard. It is a foundation. I want a defined, documented, queryable set of numbers that the whole business agrees on, and I want to be able to trace any figure back to the row it came from.
>
> The weekly Finance report is what we publish today and what the board sees. Reconcile to it.
>
> I also want the ask-anything capability everyone keeps demonstrating to me. If it cannot show me the query it ran, I am not interested.

> **From:** Divya Raghavan, Head of Supply Chain Operations
> **Subject:** RE: One set of numbers
>
> Support this, with one caveat. Please do not treat the Finance weekly report as gospel. We have been telling them for eighteen months that it double counts and that it books sales on the wrong day. Nobody has ever proved it either way because nobody has had the time to go back to the raw feeds.
>
> From my side the things I need defined properly are service level, cold chain integrity, and warehouse cycle time. Cold chain especially. We think our excursion rate is somewhere around a third of all trips, which cannot possibly be right, and if it is right we have a much bigger problem than a reporting one.

---

## 3. What we have given you

| Asset | What it is |
|---|---|
| `data/raw/pos_transactions/` | Point of sale lines, partitioned by ingest date |
| `data/raw/reefer_telemetry/` | Vehicle temperature telemetry, partitioned by date |
| `data/raw/wms_scan_events/` | Warehouse handling scans, partitioned by date |
| `data/raw/erp_cdc/` | Change data capture for outlet master, product master, sales order header |
| `data/reference/` | UOM conversion, warehouse master, carrier master, fiscal calendar, and the legacy Finance weekly report |
| `data/_manifest/` | Expected partition and row counts as published by the ingestion job |
| `generate_dataset.py` | The generator that produced all of the above |

Roughly ten million rows, eighteen months to 30 June 2026, Parquet throughout.

**The generator is part of the assignment.** The dataset you have is `--scale 1`. The same script with `--scale 10` produces the same feeds at ten times the volume. We may run your pipeline against a larger scale. You do not have to make that work, but we will ask you what happens.

`02_Feed_Contracts.md` documents the feeds. It is incomplete and at least one statement in it is wrong. That is not an oversight. Real source documentation is always incomplete and frequently wrong, and how you handle that is part of what we are looking at.

---

## 4. What we are asking you to build

You decide.

Read the brief above. Work out what an analytical foundation for this business looks like, work out how much of it you can build properly in the time you have, and build that.

We are deliberately not giving you a feature list or a target architecture. Reading an ambiguous brief and deciding what to build is most of this job. Handing you the answer would remove the only part of the exercise we cannot assess any other way.

Four things are not optional.

**A working system.** A pipeline that runs end to end from the raw feeds on a documented command, and something a person can actually use on top of it. Not a notebook of exploratory cells.

**A KPI catalogue.** Every metric you define, in one place: the name, the business definition in plain English, the grain, the filters and exclusions, the source feeds, the owner, and any known limitation. Format is your call. This is the artefact the CFO actually asked for.

**A SQL query library.** The queries behind the catalogue, runnable, parameterised where it makes sense, and organised so that someone else can find the one they need.

**Two documents in the repository.**

- `README.md`. How to run it. Cold start, one machine, no tribal knowledge.
- `DECISIONS.md`, one page maximum. What you built. What you deliberately did not build. What you assumed where the brief was unclear or contradicted itself. What you would do next with two more weeks. What breaks first in production, and at what volume.

We read `DECISIONS.md` before we read the code.

Where the brief is ambiguous, make a judgement and record it. We are more interested in the judgement than in the answer you land on.

---

## 5. The kind of thing people ask

Illustrative, not a specification. Some of these may not be worth building for. Use them to sense check whatever you do build; we will run a different set against your submission.

1. Gross sales by channel for the last complete fiscal quarter.
2. How does that figure compare with the published Finance weekly report, and if it differs, why.
3. Units sold last month. In eaches.
4. What proportion of chilled trips breached temperature, by month and by carrier.
5. Median dock-to-dispatch cycle time by warehouse.
6. Which outlets changed channel classification during the period, and when.
7. Order value by source system, and whether the three sources are comparable.
8. Which days are missing data, in any feed, and how would we know without being told.

---

## 6. Submission

A single GitHub repository, public or shared with the address HR gave you. Nothing else. No video, no deck.

Do not commit the dataset. Reference the path and let us supply it, or regenerate it from the shipped generator.

Commit as you go rather than in one push at the end; we read commit history and it works in your favour.

---

## 7. How this is assessed

Your submission is read before your first interview. That interview is a defence of it. Expect to be asked why you defined a metric the way you did, what happens to your pipeline when a feed changes shape, and what you would do differently at a hundred times the volume.

A modest submission that is well understood and honestly described will go further than an ambitious one you cannot account for.

---

## 8. Notes on the data

The data is synthetic and generated for this exercise. It is not clean. Neither is anything you will meet in the field. Every distributor we have worked with has had the same categories of problem in their feeds, and finding them is part of the job rather than an obstacle to it.

You are not expected to fix the sources. You are expected to notice, to handle it in the pipeline, and to say so in writing.

---

*Kestrel Provisions and all named individuals are fictional. All data is synthetic and generated for assessment purposes.*
