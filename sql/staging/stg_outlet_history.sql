-- =============================================================
-- STAGING: Outlet Master (CDC history)
-- Source: data/raw/erp_cdc/outlet_master/**/*.parquet
-- Grain: one row per CHANGE EVENT per outlet (full history retained -
-- this table is NOT collapsed to "latest per outlet". Point-in-time
-- windowing (valid_from/valid_to, is_current) happens downstream in
-- dim_outlet, not here.
--
-- IMPORTANT: the "status" field is hardcoded to "ACTIVE" on every record,
-- including deleted outlets. It is NOT a reliable signal of whether an
-- outlet is currently active. The only correct way to identify a deleted
-- outlet is __op = 'D'.
-- =============================================================

CREATE OR REPLACE TABLE stg_outlet_history AS

WITH raw AS (
    SELECT *
    FROM read_parquet(
        'data/raw/erp_cdc/outlet_master/**/*.parquet',
        hive_partitioning = true
    )
),

deduped AS (
    SELECT
        outlet_code,
        __op                                       AS op_type,
        CAST(__op_ts AS TIMESTAMP)                  AS op_ts,
        __seq                                       AS seq,
        extract_date,

        outlet_name,
        channel,
        outlet_format,
        city,
        route_code,
        warehouse_code,
        credit_limit,
        credit_terms_days,
        gst_number,
        status,

        -- (outlet_code, __seq) should be a unique key by construction, since __seq
        -- is a single monotonically increasing counter across the whole table's
        -- generation. This is a safety-net dedup, not a documented defect fix -
        -- see test query, which reports whether this actually removes any rows.
        ROW_NUMBER() OVER (
            PARTITION BY outlet_code, __seq
            ORDER BY extract_date
        ) AS rn,

        -- DEFECT L12/L13: correct chronological version number per outlet,
        -- ordered by (op_ts, seq) - NOT by extract_date (which can arrive late,
        -- DEFECT L12) and NOT by op_ts alone (which can tie, DEFECT L13).
        ROW_NUMBER() OVER (
            PARTITION BY outlet_code
            ORDER BY CAST(__op_ts AS TIMESTAMP), __seq
        ) AS version_no
    FROM raw
)

SELECT * EXCLUDE (rn)
FROM deduped
WHERE rn = 1
ORDER BY outlet_code, version_no;