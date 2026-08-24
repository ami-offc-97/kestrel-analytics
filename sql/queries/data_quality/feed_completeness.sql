-- =============================================================
-- KPI-14 Feed Completeness
-- Catalogue: docs/kpi_catalogue.md#kpi-14--feed-completeness
-- Answers brief question 8: "Which days are missing data, in any feed,
-- and how would we know without being told."
--
-- Run this first, every day, before trusting any other number.
--
-- Five sections, in the order you should read them. The design point is
-- that no single check is sufficient - each section catches a class of
-- failure the others structurally cannot see:
--   1. Is anything short against what the ingestion job claims it wrote?
--   2. Is any feed unmonitorable, or unmonitored entirely?
--   3. Is any whole day absent?
--   4. Is there a hole INSIDE a feed that looks healthy in total?
--   5. One line: is it safe to publish today?
-- =============================================================

-- --- 1. Manifest reconciliation: short or unreadable partitions ---
-- The definitive check, and the only one that can prove a partition is
-- short rather than merely quiet. Closes ticket KP-3168.
SELECT
    feed,
    partition,
    expected_rows,
    actual_rows,
    row_delta,
    pct_of_expected,
    status
FROM dq_partition_reconciliation
WHERE status NOT IN ('MATCH', 'NO_MANIFEST_BASELINE')
ORDER BY row_delta;

-- --- 2. Control gaps: feeds with no reconciliation baseline -------
-- A feed nobody can reconcile is a feed nobody is checking. All three
-- ERP CDC feeds are absent from the manifest entirely.
SELECT feed, actual_rows AS rows_loaded, status
FROM dq_partition_reconciliation
WHERE status = 'NO_MANIFEST_BASELINE'
ORDER BY feed;

-- --- 3. Absent or collapsed days, across all six feeds ------------
-- The calendar spine makes a missing day appear as a zero row rather
-- than as no row at all. Expect zero rows here on a healthy dataset.
SELECT
    feed,
    calendar_date,
    rows_present,
    feed_median,
    pct_of_feed_median,
    status,
    severity
FROM dq_feed_completeness
WHERE severity IN ('ALERT', 'WARN')
ORDER BY severity, feed, calendar_date;

-- --- 4. Holes inside a healthy-looking feed -----------------------
-- THIS is the section that earns its keep. The GW-017 outage is
-- invisible in section 3 - those days sit at 95% of feed median,
-- because one dead gateway is only ~2.5% of telemetry volume. Only a
-- per-gateway baseline finds it. Ticket KP-3172.
SELECT
    gateway_id,
    calendar_date,
    readings,
    gateway_median,
    pct_of_gateway_median,
    status
FROM dq_telemetry_gateway_health
WHERE status <> 'OK'
ORDER BY status, gateway_id, calendar_date;

-- --- 5. One-line verdict -----------------------------------------
SELECT
    (SELECT count(*) FROM dq_partition_reconciliation
      WHERE status NOT IN ('MATCH', 'NO_MANIFEST_BASELINE'))  AS short_partitions,
    (SELECT sum(row_delta) FROM dq_partition_reconciliation
      WHERE status = 'SHORTFALL')                             AS rows_missing,
    (SELECT count(*) FROM dq_partition_reconciliation
      WHERE status = 'NO_MANIFEST_BASELINE')                  AS unreconcilable_feeds,
    (SELECT count(*) FROM dq_feed_completeness
      WHERE severity = 'ALERT')                               AS feed_day_alerts,
    (SELECT count(*) FROM dq_telemetry_gateway_health
      WHERE status = 'OUTAGE')                                AS gateway_outage_days,
    CASE WHEN (SELECT count(*) FROM dq_partition_reconciliation
                WHERE status NOT IN ('MATCH', 'NO_MANIFEST_BASELINE')) = 0
          AND (SELECT count(*) FROM dq_feed_completeness
                WHERE severity = 'ALERT') = 0
          AND (SELECT count(*) FROM dq_telemetry_gateway_health
                WHERE status = 'OUTAGE') = 0
         THEN 'CLEAN'
         ELSE 'DEFECTS PRESENT - read sections 1-4 before publishing'
    END                                                        AS verdict;
