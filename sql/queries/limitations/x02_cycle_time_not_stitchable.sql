-- =============================================================
-- X-02 Dock-to-dispatch cycle time by warehouse - NOT BUILDABLE
-- Catalogue: docs/kpi_catalogue.md#x-02--median-dock-to-dispatch-cycle-time-by-warehouse
--
-- Brief question 5 asks for median cycle time by warehouse. The WMS
-- feed cannot support it: scan events are not one item's journey.
-- This query demonstrates that three independent ways, so the
-- conclusion is reproducible and not a matter of opinion.
--
-- DO NOT publish a cycle time by filtering to the plausible half.
-- Section 2 shows that half is the same noise with the sign flipped.
-- =============================================================

-- --- 1. Half of all stitched journeys run BACKWARDS ---------------
-- Dispatch before receive is a coin flip, not a data-quality tail.
SELECT
    count(*)                                                AS orders_with_both_scans,
    count(*) FILTER (WHERE cycle_time_seconds < 0)           AS negative_duration,
    ROUND(100.0 * count(*) FILTER (WHERE cycle_time_seconds < 0)
          / count(*), 2)                                    AS pct_negative
FROM fct_warehouse_cycle_time
WHERE cycle_time_seconds IS NOT NULL;

-- --- 2. The "plausible" half is not plausible either --------------
-- A warehouse dock-to-dispatch cycle measured in months is not a
-- cycle time. This is why filtering to positives does not rescue it.
SELECT
    count(*)                                                AS plausible_orders,
    ROUND(median(cycle_time_seconds) / 86400.0, 1)           AS median_days,
    ROUND(min(cycle_time_seconds) / 86400.0, 1)              AS min_days,
    ROUND(max(cycle_time_seconds) / 86400.0, 1)              AS max_days
FROM fct_warehouse_cycle_time
WHERE is_cycle_time_plausible;

-- --- 3. A six-stage "order" touches many unrelated items ----------
-- If these scans were one order's journey, each stage would handle the
-- same SKU. Expect ~8-9 distinct SKUs, which is the tell.
SELECT
    ROUND(avg(n_skus), 2)     AS avg_distinct_skus,
    ROUND(avg(n_batches), 2)  AS avg_distinct_batches,
    count(*)                  AS orders_with_all_6_stages
FROM (
    SELECT order_number,
           count(DISTINCT sku_code) AS n_skus,
           count(DISTINCT batch_id) AS n_batches
    FROM stg_wms_scan_events
    GROUP BY order_number
    HAVING count(DISTINCT event_type) = 6
);
