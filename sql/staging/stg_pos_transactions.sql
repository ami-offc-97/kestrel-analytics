-- =============================================================
-- STAGING: POS Transactions
-- Source: data/raw/pos_transactions/**/*.parquet (Hive-partitioned by ingest_date)
-- Grain: one row per transaction line item
-- =============================================================

CREATE OR REPLACE TABLE stg_pos_transactions AS

WITH raw AS (
    -- union_by_name=true: required because of DEFECT L4 (schema drift on 2025-10-01).
    --   Pre-drift partitions:  qty column, NO uom, NO loyalty_id
    --   Post-drift partitions: quantity_units column (renamed from qty), HAS uom, HAS loyalty_id
    -- union_by_name aligns columns by name across all files and fills missing
    -- columns with NULL, rather than erroring on mismatched schemas.
    --
    -- hive_partitioning=true: recovers ingest_date from the folder name
    -- (ingest_date=YYYY-MM-DD), since the generator drops it from the file itself.
    SELECT *
    FROM read_parquet(
        getvariable('data_root') || '/raw/pos_transactions/**/*.parquet',
        union_by_name = true,
        hive_partitioning = true
    )
),

reconciled AS (
    SELECT
        txn_id,
        txn_line_no,
        basket_id,
        outlet_code,
        channel,
        sku_code,

        -- DEFECT L2 (UTC vs IST): event_ts is stored in UTC. IST = UTC + 5:30.
        -- Keep both: raw UTC value for audit/traceability, corrected IST value for
        -- all business-day / reporting logic.
        CAST(event_ts AS TIMESTAMP)                                   AS event_ts_utc,
        CAST(event_ts AS TIMESTAMP) + INTERVAL '5 hours 30 minutes'   AS event_ts_ist,
        CAST(CAST(event_ts AS TIMESTAMP) + INTERVAL '5 hours 30 minutes' AS DATE)
                                                                       AS event_date_ist,

        -- DEFECT L4 (schema drift): qty and quantity_units never co-exist in the
        -- same partition, so exactly one of them is NULL per row. COALESCE picks
        -- whichever one is actually present.
        COALESCE(quantity_units, qty)                                 AS qty_original,

        -- uom is genuinely absent (not just null-valued) for all pre-drift rows.
        -- We cannot recover whether those historical rows were cases or eaches.
        uom                                                            AS uom_original,
        (uom IS NULL)                                                  AS uom_unknown_flag,

        unit_price,
        discount_amount,
        tax_amount,
        payment_mode,
        till_id,
        cashier_id,
        promo_code,
        loyalty_id,
        source_file,
        ingest_date,

        -- DEFECT L1 (late arrival): surfaced as an explicit, queryable flag rather
        -- than left implicit — lets anyone directly measure "how late" the feed runs.
        (ingest_date <> CAST(CAST(event_ts AS TIMESTAMP) + INTERVAL '5 hours 30 minutes' AS DATE))
                                                                       AS is_late_arrival,

        -- Row-level dedup key. txn_id + txn_line_no is a completed record, so an
        -- arbitrary deterministic tiebreaker (ingest_date) is fine for DEFECT L3 dedup.
        ROW_NUMBER() OVER (
            PARTITION BY txn_id, txn_line_no
            ORDER BY ingest_date
        ) AS rn
    FROM raw
)

-- DEFECT L3 (duplicates): keep exactly one row per (txn_id, txn_line_no).
SELECT * EXCLUDE (rn)
FROM reconciled
WHERE rn = 1;
