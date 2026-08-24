-- =============================================================
-- STAGING: Sales Order Header (CDC history)
-- Source: data/raw/erp_cdc/sales_order_header/**/*.parquet
-- Grain: one row per CHANGE EVENT per order (full history retained).
--
-- This table does not carry the DOCUMENTED L12/L13 defects (those are
-- injected only into outlet_master/product_master - confirmed in the
-- generator). It does, however, exhibit its own undocumented equivalents,
-- so ordering by (op_ts, seq) is load-bearing here, not merely defensive:
--
--   * TIMESTAMP TIES DO EXIST. The delete tombstone is a byte copy of the
--     order's insert row, __op_ts included (generator: dels =
--     df[__op=='I'].sample(...)), so every deleted order has an I/D pair
--     sharing one timestamp. Verified: 2,880 orders affected. The tie is
--     resolved by __seq, since deletes carry a +10,000,000 offset.
--     (An earlier revision of this header claimed no ties were expected.
--     That was wrong; corrected against the data.)
--
--   * EXTRACT LAG DOES EXIST, on delete rows only. I and U rows have
--     extract_date = order_date exactly, but tombstones are stamped
--     order_date + 2..30 days. Verified: 2,877 of 2,880 D rows have
--     extract_date <> order_date. Harmless to the dedup below (which
--     partitions by (order_number, __seq)), but it means extract_date
--     cannot be used as a proxy for event time on this feed.
--
-- __seq IS strictly increasing per order by construction (insert < its
-- updates < its tombstone), so (op_ts, seq) fully orders every history.
--
-- Because the tombstone copies the INSERT's timestamp while updates land
-- 6h+ later, a D row is never chronologically last: all 2,880 deleted
-- orders have a genuine U row after their D. Downstream deletion tests
-- must therefore be "ever deleted", never "latest op_type" - see fct_orders.
--
-- The rn dedup below is a verified no-op on this feed (raw 963,307 =
-- staged 963,307); it is retained as a guard, matching the other CDC
-- staging tables, not because duplicates were found.
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
        getvariable('data_root') || '/raw/erp_cdc/sales_order_header/**/*.parquet',
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