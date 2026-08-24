-- =============================================================
-- MART (dim): dim_product
-- Source: stg_product_history
-- Grain: one row per SKU PER VERSION (point-in-time / SCD Type 2)
--
-- valid_from/valid_to define the window during which this version of the
-- product's attributes was true.
--
-- is_deleted uses an "ever deleted = permanently deleted" rule, NOT
-- "latest version's op_type" - same trap as dim_outlet. Delete tombstones
-- are generated on an independent random timestamp from a SKU's own
-- scheduled updates, so a genuine later "U" row can chronologically follow
-- a "D" row (verified: 10 of 16 deleted SKUs have this pattern). Treating
-- deletion as reversible-by-later-update would incorrectly reactivate
-- these SKUs.
--
-- category, case_pack, list_price are NOT genuine change signals (rewritten
-- identically on every version by the source system - see
-- stg_product_history header comment) but are carried through per-version
-- anyway for point-in-time consistency with the rest of the row; do not
-- treat differences in these fields across versions as real history.
-- brand, gst_rate_pct, shelf_life_days re-randomize independently on every
-- version and are NOT genuine change signals either - only mrp is.
-- =============================================================

CREATE OR REPLACE TABLE dim_product AS

WITH windowed AS (
    SELECT
        sku_code,
        version_no,
        product_name,
        category,
        brand,
        case_pack,
        mrp,
        list_price,
        gst_rate_pct,
        shelf_life_days,
        is_chilled,
        op_ts                                                        AS valid_from,
        COALESCE(
            LEAD(op_ts) OVER (PARTITION BY sku_code ORDER BY version_no),
            TIMESTAMP '9999-12-31'
        )                                                             AS valid_to,
        (LEAD(op_ts) OVER (PARTITION BY sku_code ORDER BY version_no) IS NULL)
                                                                       AS is_last_version,
        MAX(op_type = 'D') OVER (PARTITION BY sku_code)               AS is_deleted
    FROM stg_product_history
)

SELECT
    sku_code, version_no, product_name, category, brand, case_pack,
    mrp, list_price, gst_rate_pct, shelf_life_days, is_chilled,
    is_deleted, valid_from, valid_to,
    (is_last_version AND NOT is_deleted) AS is_current
FROM windowed;