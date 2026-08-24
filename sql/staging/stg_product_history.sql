-- =============================================================
-- STAGING: Product Master (CDC history)
-- Source: data/raw/erp_cdc/product_master/**/*.parquet
-- Grain: one row per CHANGE EVENT per SKU (full history retained, same as
-- stg_outlet_history - not collapsed to latest-per-SKU here).
--
-- IMPORTANT, from reading the generator directly:
--   - category, case_pack: fixed at generation, identical across every version
--     of a product's history despite being re-written on every row.
--   - list_price: always derived from the ORIGINAL mrp value (constant),
--     even though mrp itself genuinely varies across versions.
--   - brand, gst_rate_pct, shelf_life_days: randomized independently on
--     EVERY row (insert and update alike) - apparent "changes" in these
--     fields between versions are regeneration noise, not real business
--     events, and should not be interpreted as meaningful change history.
--   - mrp is the only field with a genuine, meaningful change signal.
--   - status is hardcoded "ACTIVE" on every row, including deletes - same
--     trap as outlet_master; use __op = 'D' to detect deletion, not status.
-- =============================================================

CREATE OR REPLACE TABLE stg_product_history AS

WITH raw AS (
    SELECT *
    FROM read_parquet(
        getvariable('data_root') || '/raw/erp_cdc/product_master/**/*.parquet',
        hive_partitioning = true
    )
),

deduped AS (
    SELECT
        sku_code,
        __op                                       AS op_type,
        CAST(__op_ts AS TIMESTAMP)                  AS op_ts,
        __seq                                       AS seq,
        extract_date,

        product_name,
        category,
        brand,
        case_pack,
        mrp,
        list_price,
        gst_rate_pct,
        shelf_life_days,
        is_chilled,
        status,

        ROW_NUMBER() OVER (
            PARTITION BY sku_code, __seq
            ORDER BY extract_date
        ) AS rn,

        -- DEFECT L12/L13: same ordering fix as stg_outlet_history.
        ROW_NUMBER() OVER (
            PARTITION BY sku_code
            ORDER BY CAST(__op_ts AS TIMESTAMP), __seq
        ) AS version_no
    FROM raw
)

SELECT * EXCLUDE (rn)
FROM deduped
WHERE rn = 1
ORDER BY sku_code, version_no;