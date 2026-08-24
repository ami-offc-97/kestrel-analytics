-- =============================================================
-- STAGING: Sales Order Header (CDC history)
-- Source: data/raw/erp_cdc/sales_order_header/**/*.parquet
-- Grain: one row per CHANGE EVENT per order (full history retained).
--
-- Unlike outlet_master/product_master, this table does NOT have DEFECT L12
-- (out-of-order extract) or L13 (timestamp ties) - extract_date is set
-- directly from order_date with no lag, and __seq is strictly increasing
-- per order by construction. Ordering by (op_ts, seq) is kept anyway as
-- defensive practice, but no genuine ties are expected here.
--
-- IMPORTANT: order_value_gross, discount_amount, tax_amount, line_count are
-- independently re-randomized on EVERY version (insert and update alike) -
-- these do not represent a real order value changing over time, just
-- regeneration noise. Use the LATEST non-deleted version as the canonical
-- order value, not an average or a specific historical version.
--
-- order_status can only reach as far as DISPATCHED in this dataset -
-- DELIVERED is mathematically unreachable given the generator's step logic
-- (verified below in the test query).
-- =============================================================

CREATE OR REPLACE TABLE stg_sales_order_header AS

WITH raw AS (
    SELECT *
    FROM read_parquet(
        'data/raw/erp_cdc/sales_order_header/**/*.parquet',
        hive_partitioning = true
    )
),

deduped AS (
    SELECT
        order_number,
        __op                                       AS op_type,
        CAST(__op_ts AS TIMESTAMP)                  AS op_ts,
        __seq                                       AS seq,
        extract_date,

        outlet_code,
        warehouse_code,
        route_code,
        CAST(order_date AS DATE)                    AS order_date,
        CAST(requested_delivery_date AS DATE)        AS requested_delivery_date,
        order_status,
        line_count,

        order_value_gross,
        -- DEFECT L14: PARTNER_API inflates order_value_gross by 8.5% (freight
        -- double-counted). Keep the raw value for traceability, plus a
        -- corrected value with the known inflation factor backed out.
        CASE WHEN source_system = 'PARTNER_API'
             THEN ROUND(order_value_gross / 1.085, 2)
             ELSE order_value_gross
        END                                          AS order_value_gross_corrected,

        discount_amount,
        tax_amount,
        source_system,

        -- DEFECT L15: hard deletes must be tombstoned, never silently ignored.
        (__op = 'D')                                 AS is_deleted,

        ROW_NUMBER() OVER (
            PARTITION BY order_number, __seq
            ORDER BY extract_date
        ) AS rn,

        ROW_NUMBER() OVER (
            PARTITION BY order_number
            ORDER BY CAST(__op_ts AS TIMESTAMP), __seq
        ) AS version_no
    FROM raw
)

SELECT * EXCLUDE (rn)
FROM deduped
WHERE rn = 1
ORDER BY order_number, version_no;