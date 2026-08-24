-- =============================================================
-- STAGING: WMS Scan Events
-- Source: data/raw/wms_scan_events/**/*.parquet (Hive-partitioned by dt)
-- Grain: one row per warehouse handling scan event
-- Known defect: DEFECT L11 - ~6.5% of scan events were never emitted (missing,
-- not null). This is a generation-time gap with no fix possible in staging -
-- it surfaces downstream as incomplete stage coverage in fct_warehouse_cycle_time.
-- =============================================================

CREATE OR REPLACE TABLE stg_wms_scan_events AS

WITH raw AS (
    SELECT *
    FROM read_parquet(
        getvariable('data_root') || '/raw/wms_scan_events/**/*.parquet',
        hive_partitioning = true
    )
),

deduped AS (
    SELECT
        scan_id,
        warehouse_code,
        event_type,
        order_number,
        sku_code,
        batch_id,
        qty_cases,
        pallet_id,
        dock_door,
        operator_id,
        handheld_device,
        CAST(event_ts AS TIMESTAMP) AS event_ts,
        dt,

        -- No duplicate defect is documented for this feed (unlike POS/telemetry),
        -- but scan_id should be unique by construction regardless. This dedup is
        -- a safety net, not a known-defect fix - see test query below, which
        -- reports how many rows (if any) this actually removes.
        ROW_NUMBER() OVER (
            PARTITION BY scan_id
            ORDER BY dt
        ) AS rn
    FROM raw
)

SELECT * EXCLUDE (rn)
FROM deduped
WHERE rn = 1;