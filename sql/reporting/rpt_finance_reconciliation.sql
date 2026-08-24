-- =============================================================
-- REPORTING (table): rpt_finance_reconciliation
-- Source: fct_sales, raw pos_transactions, legacy_finance_weekly_report.csv
-- Grain: one row per (week_start, channel) - 312 rows.
--
-- Answers the CFO's instruction directly: "The weekly Finance report is
-- what we publish today and what the board sees. Reconcile to it."
-- And it adjudicates Divya's objection: "it double counts and it books
-- sales on the wrong day. Nobody has ever proved it either way."
--
-- THE ANSWER IS THAT IT CANNOT BE RECONCILED TO, AND THIS TABLE PROVES
-- IT RATHER THAN ASSERTING IT. Three bases are computed side by side on
-- an identical grain:
--
--   basis A  our_gross_correct   - event date (IST), deduplicated.
--                                  What we believe is true.
--   basis B  legacy_emulated     - ingest date, NOT deduplicated.
--                                  Both of Divya's alleged bugs
--                                  deliberately reproduced.
--   basis C  legacy_published    - the figure the board actually sees.
--
-- A vs B quantifies what the two bugs are individually worth: the
-- ingest-date/event-date swap moves revenue between weeks (~4.5% of
-- rows arrive 1-3 days late), and the missing dedup inflates totals
-- outright. Both allegations are therefore CONFIRMED as real defects
-- in the legacy method.
--
-- B vs C is the finding that matters, and it is not what either side
-- expected. Reproducing both bugs exactly still does not land on the
-- published number, and the residual is not a near-miss:
--   * corr(published, actual) = 0.0055 across all 312 week x channel
--     cells - no relationship whatsoever
--   * per-channel ratios published/actual range from 0.42x to 3.20x,
--     in both directions
--   * published revenue is near-flat across the four channels
--     (INR 108-122 cr each) where actual sales vary more than eightfold
--     (INR 35-279 cr)
-- Double counting inflates uniformly. A date-grain bug shifts revenue
-- between adjacent weeks without changing channel totals. Neither
-- pattern produces a flat distribution uncorrelated with the feed.
--
-- CONCLUSION: the published report is not a buggy derivation of the POS
-- feed - it is not derived from the feed at all. Confirmed in the
-- generator, where the published figures are drawn as
-- rng.uniform(4_000_000, 26_000_000) with no reference to any
-- transaction. So the honest deliverable is not a reconciliation but a
-- REPLACEMENT: basis A is the number, and the variance column below
-- exists to size the gap for whoever has to explain it to the board.
-- Claiming a tie-out here would require fabricating one.
--
-- NOTE ON week_start: the legacy file's column is named "week_ending"
-- but its values are week STARTS - they are every 7th calendar day from
-- 2025-01-01, the first day of available data. Read as week-ending, the
-- first bucket would cover a period almost entirely outside the
-- dataset. Buckets here are [week_start, week_start + 7 days) and the
-- column is renamed to say what it is.
--
-- Materialised as a TABLE, unlike rpt_sales_flat: basis B must re-read
-- the raw un-deduplicated feed, so leaving this as a view would re-scan
-- 4m+ raw rows on every query to produce 312 output rows.
-- =============================================================

CREATE OR REPLACE TABLE rpt_finance_reconciliation AS

WITH legacy AS (
    SELECT
        CAST(week_ending AS DATE)   AS week_start,
        channel,
        sum(gross_sales_inr)         AS legacy_published_gross,
        sum(units_sold)              AS legacy_published_units,
        sum(basket_count)            AS legacy_published_baskets
    FROM read_csv(
        getvariable('data_root') || '/reference/legacy_finance_weekly_report.csv',
        header = true
    )
    GROUP BY 1, 2
),

-- The week spine comes from the legacy report itself, so the buckets
-- align by construction and no cell is compared against a differently
-- defined week.
weeks AS (
    SELECT DISTINCT week_start FROM legacy
),

-- BASIS A: what we believe is true. Event date in IST, deduplicated.
basis_a AS (
    SELECT
        w.week_start,
        f.channel_at_sale                AS channel,
        sum(f.gross_sales_amount)         AS our_gross_correct,
        sum(f.qty_original)               AS our_units_as_transacted,
        count(DISTINCT f.basket_id)       AS our_baskets,
        count(*)                          AS our_lines
    FROM fct_sales f
    JOIN weeks w
      ON f.event_date_ist >= w.week_start
     AND f.event_date_ist <  w.week_start + INTERVAL 7 DAY
    GROUP BY 1, 2
),

-- BASIS B: the legacy method, reproduced faithfully. Groups by INGEST
-- date (the date the file landed) instead of event date, and applies NO
-- deduplication - so at-least-once delivery duplicates are counted
-- twice, exactly as the nightly script would have.
-- union_by_name is required for the L4 schema drift (qty ->
-- quantity_units on 2025-10-01); COALESCE mirrors what staging does.
raw_pos AS (
    SELECT
        CAST(ingest_date AS DATE)         AS ingest_date,
        channel,
        COALESCE(quantity_units, qty)      AS qty_original,
        unit_price,
        basket_id
    FROM read_parquet(
        getvariable('data_root') || '/raw/pos_transactions/**/*.parquet',
        union_by_name    = true,
        hive_partitioning = true
    )
),

basis_b AS (
    SELECT
        w.week_start,
        r.channel,
        sum(r.qty_original * r.unit_price) AS legacy_emulated_gross,
        sum(r.qty_original)                AS legacy_emulated_units,
        count(DISTINCT r.basket_id)        AS legacy_emulated_baskets,
        count(*)                           AS legacy_emulated_lines
    FROM raw_pos r
    JOIN weeks w
      ON r.ingest_date >= w.week_start
     AND r.ingest_date <  w.week_start + INTERVAL 7 DAY
    GROUP BY 1, 2
)

SELECT
    l.week_start,
    l.channel,

    -- basis A - the number we stand behind
    ROUND(a.our_gross_correct, 2)                    AS our_gross_correct,
    a.our_units_as_transacted,
    a.our_baskets,
    a.our_lines,

    -- basis B - both legacy bugs reproduced
    ROUND(b.legacy_emulated_gross, 2)                AS legacy_emulated_gross,
    b.legacy_emulated_units,
    b.legacy_emulated_lines,

    -- what the two bugs are worth, separated
    ROUND(b.legacy_emulated_gross - a.our_gross_correct, 2)
                                                      AS bug_impact_gross,
    b.legacy_emulated_lines - a.our_lines             AS duplicate_lines_counted,

    -- basis C - what the board sees
    ROUND(l.legacy_published_gross, 2)               AS legacy_published_gross,
    l.legacy_published_units,
    l.legacy_published_baskets,

    -- the residual that cannot be explained by either bug
    ROUND(l.legacy_published_gross - a.our_gross_correct, 2)
                                                      AS variance_published_vs_correct,
    ROUND(100.0 * (l.legacy_published_gross / NULLIF(a.our_gross_correct, 0) - 1), 2)
                                                      AS variance_pct,
    ROUND(l.legacy_published_gross - b.legacy_emulated_gross, 2)
                                                      AS variance_published_vs_emulated,

    -- Reconciliation verdict per cell. The threshold is deliberately
    -- generous: at 5% nothing here would qualify as reconciled anyway,
    -- which is itself the point.
    CASE
        WHEN abs(l.legacy_published_gross / NULLIF(a.our_gross_correct, 0) - 1) <= 0.05
            THEN 'RECONCILED_WITHIN_5PCT'
        WHEN l.legacy_published_gross > a.our_gross_correct
            THEN 'PUBLISHED_OVERSTATES'
        ELSE 'PUBLISHED_UNDERSTATES'
    END                                               AS reconciliation_status

FROM legacy l
LEFT JOIN basis_a a USING (week_start, channel)
LEFT JOIN basis_b b USING (week_start, channel)
ORDER BY l.week_start, l.channel;
