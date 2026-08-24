-- =============================================================
-- STAGING: Reefer Telemetry
-- Source: data/raw/reefer_telemetry/**/*.parquet (Hive-partitioned by dt)
-- Grain: one row per temperature reading
-- =============================================================

CREATE OR REPLACE TABLE stg_reefer_telemetry AS

WITH raw AS (
    -- DEFECT L18: one file (dt=2025-07-14/part-00000.parquet) is truncated and
    -- unreadable. read_parquet with a glob fails hard on a corrupt file by
    -- default, so we exclude it explicitly here (file-level, not partition-level,
    -- exclusion — the other 7 files for that same date are fine and must be kept).
    SELECT *, filename
    FROM read_parquet(
        'data/raw/reefer_telemetry/**/*.parquet',
        hive_partitioning = true,
        filename = true
    )
    WHERE filename NOT LIKE '%dt=2025-07-14/part-00000.parquet'
),

corrected AS (
    SELECT
        device_id,
        telemetry_vendor,
        firmware_version,
        vehicle_registration,
        route_code,
        warehouse_code,
        gateway_id,

        -- DEFECT L5 (clock skew): firmware 2.1.4 devices report timestamps 7 hours
        -- ahead of actual. Subtract 7 hours back for those devices specifically.
        CAST(reading_ts AS TIMESTAMP)
            - CASE WHEN firmware_version = '2.1.4' THEN INTERVAL '7 hours' ELSE INTERVAL '0 hours' END
                                                                        AS reading_ts_corrected,

        -- DEFECT L6/L7 (unit ambiguity): temp_unit is null for ~8% of rows. Infer
        -- the true unit from vendor where missing — COLDEYE always reports
        -- Fahrenheit, THERMLOG always reports Celsius, by construction.
        COALESCE(temp_unit,
                 CASE WHEN telemetry_vendor = 'COLDEYE' THEN 'F' ELSE 'C' END)
                                                                        AS temp_unit_resolved,

        -- Normalize every reading to Celsius, regardless of original unit.
        -- temp_value itself may be NULL (DEFECT L8) — arithmetic on NULL stays
        -- NULL, so this correctly propagates rather than needing special-casing.
        CASE
            WHEN COALESCE(temp_unit, CASE WHEN telemetry_vendor = 'COLDEYE' THEN 'F' ELSE 'C' END) = 'F'
                THEN (temp_value - 32) * 5.0 / 9.0
            ELSE temp_value
        END                                                            AS temp_value_celsius,

        (temp_value IS NULL)                                           AS temp_reading_missing,

        humidity_pct,
        door_open_flag,
        gps_lat,
        gps_lon,
        battery_pct,
        dt,

        ROW_NUMBER() OVER (
            PARTITION BY device_id, reading_ts, gps_lat, gps_lon
            ORDER BY dt
        ) AS rn
    FROM raw
)

-- DEFECT L9 (duplicates): keep one row per distinct reading.
-- Note: no single natural unique ID column exists on this feed (unlike POS's
-- txn_id), so the dedup key is a composite of fields that together identify
-- one real-world reading event.
SELECT * EXCLUDE (rn)
FROM corrected
WHERE rn = 1;