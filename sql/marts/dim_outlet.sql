-- =============================================================
-- MART (dim): dim_outlet
-- Source: stg_outlet_history
-- Grain: one row per outlet PER VERSION (point-in-time / SCD Type 2)
--
-- valid_from/valid_to define the window during which this version of the
-- outlet's attributes was true.
--
-- is_deleted uses an "ever deleted = permanently deleted" rule, NOT
-- "latest version's op_type". Reason: delete tombstones are generated on
-- an independent random timestamp from an outlet's own scheduled updates,
-- so a genuine later "U" row can chronologically follow a "D" row (verified:
-- 33 of 48 deleted outlets have this pattern). Treating deletion as
-- reversible-by-later-update would incorrectly reactivate these outlets.
-- =============================================================

CREATE OR REPLACE TABLE dim_outlet AS

WITH windowed AS (
    SELECT
        outlet_code,
        version_no,
        outlet_name,
        channel,
        outlet_format,
        city,
        route_code,
        warehouse_code,
        credit_limit,
        credit_terms_days,
        gst_number,
        op_ts                                                        AS valid_from,
        COALESCE(
            LEAD(op_ts) OVER (PARTITION BY outlet_code ORDER BY version_no),
            TIMESTAMP '9999-12-31'
        )                                                             AS valid_to,
        (LEAD(op_ts) OVER (PARTITION BY outlet_code ORDER BY version_no) IS NULL)
                                                                       AS is_last_version,
        MAX(op_type = 'D') OVER (PARTITION BY outlet_code)            AS is_deleted
    FROM stg_outlet_history
)

SELECT
    outlet_code, version_no, outlet_name, channel, outlet_format, city,
    route_code, warehouse_code, credit_limit, credit_terms_days, gst_number,
    is_deleted, valid_from, valid_to,
    (is_last_version AND NOT is_deleted) AS is_current
FROM windowed;