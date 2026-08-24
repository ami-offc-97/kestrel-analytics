-- =============================================================
-- MART (fact): fct_warehouse_cycle_time
-- Source: stg_wms_scan_events
-- Grain: one row per order_number that appears anywhere in the feed,
-- with the first-seen timestamp of each of the 6 handling stages
-- (RECEIVE/PUTAWAY/PICK/PACK/STAGE/DISPATCH) pivoted into columns.
--
-- *** CAUTION - READ BEFORE USING cycle_time_seconds FOR ANY KPI ***
-- order_number, sku_code, batch_id, pallet_id, and warehouse_code are
-- ALL independently randomized per scan row in the generator (each
-- drawn via its own rng.integers() call) - there is NO structural link
-- tying one item's stage-by-stage handling together. This was verified
-- three separate ways, not assumed:
--   - Orders with all 6 stages present average ~8.6 DISTINCT sku_codes
--     and ~8.6 DISTINCT batch_ids across those 6 scans (i.e. every scan
--     row is essentially an unrelated random event, not one item's
--     journey).
--   - Stitching RECEIVE -> DISPATCH by order_number gives a NEGATIVE
--     cycle time (dispatch recorded before receive) for 50.13% of
--     orders that have both stages - a physical impossibility, and the
--     signature of pure noise, not a real process.
--   - The same ~50% negative-duration rate holds when stitching by
--     batch_id (49.91%) or pallet_id (49.81%) instead of order_number -
--     ruling out "wrong stitching key" as the explanation. Only
--     warehouse_code avoids this (0% negative), but that's because it
--     only has 8 distinct values across 18 months of data, so it's
--     trivially always true, not a real cycle time.
-- CONCLUSION: this feed captures warehouse handling-scan VOLUME, not a
-- stitchable per-item/per-order PIPELINE. `cycle_time_seconds` and
-- `is_cycle_time_plausible` are exposed here for transparency and
-- diagnostic use only. Brief Q5 ("median dock-to-dispatch cycle time by
-- warehouse") is NOT reliably answerable from this data as generated -
-- restricting to `is_cycle_time_plausible = true` rows does NOT fix
-- this, since that subset is statistically indistinguishable from the
-- "lucky half" of the same noise process, not a verified real duration
-- (median implied duration among "plausible" rows is ~155 days -
-- absurd for a warehouse cycle, confirming it's still noise). This is
-- a known, severe limitation to raise with the business directly.
-- See DECISIONS.md.
--
-- Missing-stage coverage (DEFECT L11, ~6.5% of scan events never
-- emitted) still applies independently on top of the above and is why
-- some stage columns are NULL even where the noise issue doesn't apply.
-- =============================================================

CREATE OR REPLACE TABLE fct_warehouse_cycle_time AS

WITH stage_first_seen AS (
    SELECT
        order_number,
        event_type,
        min(event_ts) AS first_ts
    FROM stg_wms_scan_events
    GROUP BY 1, 2
),

pivoted AS (
    SELECT
        order_number,
        max(CASE WHEN event_type = 'RECEIVE'  THEN first_ts END) AS receive_ts,
        max(CASE WHEN event_type = 'PUTAWAY'  THEN first_ts END) AS putaway_ts,
        max(CASE WHEN event_type = 'PICK'     THEN first_ts END) AS pick_ts,
        max(CASE WHEN event_type = 'PACK'     THEN first_ts END) AS pack_ts,
        max(CASE WHEN event_type = 'STAGE'    THEN first_ts END) AS stage_ts,
        max(CASE WHEN event_type = 'DISPATCH' THEN first_ts END) AS dispatch_ts,
        count(*)                                                 AS n_stages_present
    FROM stage_first_seen
    GROUP BY 1
),

with_dominant_warehouse AS (
    -- Most-frequently-scanned warehouse_code for this order_number.
    -- NOT a claim that this order "belongs to" that warehouse (see
    -- caution above: warehouse_code is noise per scan too) - this is
    -- a majority-vote label for row-level readability/grouping only.
    SELECT order_number, warehouse_code,
           row_number() OVER (
               PARTITION BY order_number
               ORDER BY count(*) DESC, warehouse_code
           ) AS rn
    FROM stg_wms_scan_events
    GROUP BY 1, 2
)

SELECT
    p.order_number,
    w.warehouse_code                                            AS dominant_warehouse_code,

    p.receive_ts,
    p.putaway_ts,
    p.pick_ts,
    p.pack_ts,
    p.stage_ts,
    p.dispatch_ts,
    p.n_stages_present,

    CASE WHEN p.receive_ts IS NOT NULL AND p.dispatch_ts IS NOT NULL
         THEN date_diff('second', p.receive_ts, p.dispatch_ts)
    END                                                          AS cycle_time_seconds,

    CASE WHEN p.receive_ts IS NOT NULL AND p.dispatch_ts IS NOT NULL
         THEN p.dispatch_ts >= p.receive_ts
    END                                                          AS is_cycle_time_plausible

FROM pivoted p
LEFT JOIN with_dominant_warehouse w
    ON p.order_number = w.order_number AND w.rn = 1;