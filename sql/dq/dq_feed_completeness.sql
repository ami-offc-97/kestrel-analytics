-- =============================================================
-- DQ (table): dq_feed_completeness
-- Source: all six raw feeds, against dim_calendar as a spine
-- Grain: one row per (feed, calendar_date). 6 feeds x 546 days.
--
-- Answers brief question 8 - "which days are missing data, in any feed,
-- and how would we know without being told" - for the ABSENT DAY and
-- VOLUME COLLAPSE cases, which dq_partition_reconciliation is
-- structurally unable to see (the manifest only knows about partitions
-- that were written).
--
-- The calendar spine is the whole point. Every feed is LEFT JOINed onto
-- dim_calendar, so a day with no data produces a row saying zero rather
-- than producing no row. Missing data that manifests as an absent
-- GROUP BY key is invisible; missing data that manifests as a zero is
-- an alert. This is ticket KP-3172 - "gateway outages are invisible,
-- missing data looks like low volume".
--
-- Two baselines, because one is not enough:
--   pct_of_feed_median    - against the feed's whole-period median.
--                           Catches sustained collapse.
--   pct_of_trailing_28d   - against a 28-day trailing mean. Catches a
--                           step change that a global median would
--                           absorb, and adapts to genuine growth.
--
-- LOW-VOLUME FEEDS ARE NOT MONITORED BY RELATIVE THRESHOLD, and this
-- is deliberate. erp_cdc/product_master runs a median of 4 rows a day
-- and outlet_master 12, because a CDC extract only carries the day's
-- actual changes. At that volume a percentage-of-median test is
-- meaningless: one product change instead of four reads as "25% of
-- median", i.e. a collapse. An earlier revision of this model did
-- exactly that and produced 342 alerts, every single one from those two
-- feeds and every single one noise. Feeds with a median below 100
-- rows/day are therefore marked NOT_MONITORABLE_LOW_VOLUME and only
-- true zero-row days are surfaced, as ZERO_ROWS_LOW_VOLUME_FEED.
--
-- Even those zeroes are not necessarily faults. product_master has four
-- zero-row days (2025-10-21, 2026-02-03, 2026-02-28, 2026-03-10). For a
-- CDC feed that most likely means NO PRODUCT CHANGED that day, which is
-- normal and expected - not a failed extract. The two cases are
-- genuinely indistinguishable from the data alone, and they cannot be
-- separated here because erp_cdc is absent from the manifest entirely
-- (see dq_partition_reconciliation). Distinguishing them needs a
-- delivery receipt from the ERP: "extract ran, produced 0 rows" is a
-- different fact from silence. Flagged as INFO, not as a defect.
--
-- HONEST LIMITATION, and it is the main one. For the four real-volume
-- feeds this model reports a completely clean bill of health, and that
-- must not be read as "the feeds are complete". Two known, real defects
-- are both invisible to it:
--   * The GW-017 gateway outage. Those two days carry 6,432 and 6,293
--     readings against a feed median of 6,802 - entirely inside normal
--     variance, because the dead gateway is only ~2.5% of feed volume.
--   * The truncated Parquet file. That day comes in at 85.0% of median,
--     and sales_order_header's quietest ordinary day is 85.9% - so no
--     feed-level threshold can separate the defect from normal
--     variation without firing on both.
--
-- Hence the division of labour across the three DQ models, which is the
-- real design here: the manifest catches short partitions definitively
-- (dq_partition_reconciliation), per-dimension baselines catch holes
-- inside a healthy-looking feed (dq_telemetry_gateway_health), and this
-- model catches whole absent days, which is the one thing neither of
-- the others can see. Feed-level completeness is necessary and nowhere
-- near sufficient on its own.
-- =============================================================

CREATE OR REPLACE TABLE dq_feed_completeness AS

WITH daily AS (
    SELECT 'pos_transactions' AS feed, CAST(ingest_date AS DATE) AS d, count(*) AS n
    FROM read_parquet(getvariable('data_root') || '/raw/pos_transactions/**/*.parquet',
                      union_by_name = true, hive_partitioning = true)
    GROUP BY 1, 2

    UNION ALL
    SELECT 'reefer_telemetry', CAST(dt AS DATE), count(*)
    FROM read_parquet(getvariable('data_root') || '/raw/reefer_telemetry/**/*.parquet',
                      hive_partitioning = true, filename = true)
    WHERE filename NOT LIKE '%dt=2025-07-14/part-00000.parquet'
    GROUP BY 1, 2

    UNION ALL
    SELECT 'wms_scan_events', CAST(dt AS DATE), count(*)
    FROM read_parquet(getvariable('data_root') || '/raw/wms_scan_events/**/*.parquet',
                      hive_partitioning = true)
    GROUP BY 1, 2

    UNION ALL
    SELECT 'erp_cdc/outlet_master', CAST(extract_date AS DATE), count(*)
    FROM read_parquet(getvariable('data_root') || '/raw/erp_cdc/outlet_master/**/*.parquet',
                      hive_partitioning = true)
    GROUP BY 1, 2

    UNION ALL
    SELECT 'erp_cdc/product_master', CAST(extract_date AS DATE), count(*)
    FROM read_parquet(getvariable('data_root') || '/raw/erp_cdc/product_master/**/*.parquet',
                      hive_partitioning = true)
    GROUP BY 1, 2

    UNION ALL
    SELECT 'erp_cdc/sales_order_header', CAST(extract_date AS DATE), count(*)
    FROM read_parquet(getvariable('data_root') || '/raw/erp_cdc/sales_order_header/**/*.parquet',
                      hive_partitioning = true)
    GROUP BY 1, 2
),

feeds AS (SELECT DISTINCT feed FROM daily),

-- The spine: every feed x every calendar day, whether data exists or not.
spine AS (
    SELECT f.feed, c.calendar_date
    FROM feeds f
    CROSS JOIN dim_calendar c
),

observed AS (
    SELECT
        s.feed,
        s.calendar_date,
        COALESCE(d.n, 0) AS rows_present,
        (d.n IS NULL)     AS day_absent
    FROM spine s
    LEFT JOIN daily d
           ON s.feed = d.feed AND s.calendar_date = d.d
),

baselined AS (
    SELECT
        o.*,
        median(o.rows_present) OVER (PARTITION BY o.feed) AS feed_median,
        avg(o.rows_present) OVER (
            PARTITION BY o.feed ORDER BY o.calendar_date
            ROWS BETWEEN 28 PRECEDING AND 1 PRECEDING
        ) AS trailing_28d_mean
    FROM observed o
)

SELECT
    feed,
    calendar_date,
    rows_present,
    day_absent,
    ROUND(feed_median, 0)                                       AS feed_median,
    ROUND(100.0 * rows_present / NULLIF(feed_median, 0), 1)      AS pct_of_feed_median,
    ROUND(trailing_28d_mean, 0)                                  AS trailing_28d_mean,
    ROUND(100.0 * rows_present / NULLIF(trailing_28d_mean, 0), 1) AS pct_of_trailing_28d,

    -- A relative threshold needs enough absolute volume to mean
    -- anything. Below ~100 rows/day it does not. See header.
    (feed_median >= 100)                                         AS is_volume_monitorable,

    CASE
        -- Low-volume feeds: report zeroes as INFO, never as a defect,
        -- and do not apply percentage tests at all.
        WHEN feed_median < 100 AND rows_present = 0
            THEN 'ZERO_ROWS_LOW_VOLUME_FEED'
        WHEN feed_median < 100
            THEN 'NOT_MONITORABLE_LOW_VOLUME'

        -- Real-volume feeds.
        WHEN day_absent OR rows_present = 0                 THEN 'DAY_ABSENT'
        WHEN rows_present < 0.50 * feed_median               THEN 'VOLUME_COLLAPSE'
        WHEN rows_present < 0.75 * feed_median               THEN 'VOLUME_LOW'
        WHEN trailing_28d_mean IS NOT NULL
             AND rows_present < 0.75 * trailing_28d_mean     THEN 'VOLUME_LOW_VS_TREND'
        ELSE 'OK'
    END AS status,

    -- Severity, so a caller can filter without knowing every status
    -- string. Nothing in this dataset reaches ALERT at feed level -
    -- which is the finding, not a reassurance.
    CASE
        WHEN feed_median < 100                               THEN 'INFO'
        WHEN day_absent OR rows_present = 0                  THEN 'ALERT'
        WHEN rows_present < 0.50 * feed_median               THEN 'ALERT'
        WHEN rows_present < 0.75 * feed_median               THEN 'WARN'
        WHEN trailing_28d_mean IS NOT NULL
             AND rows_present < 0.75 * trailing_28d_mean     THEN 'WARN'
        ELSE 'OK'
    END AS severity
FROM baselined
ORDER BY feed, calendar_date;
