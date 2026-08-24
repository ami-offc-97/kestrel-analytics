-- =============================================================
-- MART (fact): fct_sales
-- Source: stg_pos_transactions, joined to dim_outlet/dim_product (point-in-
-- time), data/reference/uom_conversion.csv
-- Grain: one row per POS transaction line (same grain as stg_pos_transactions -
-- no aggregation here; aggregation happens in reporting views/KPI queries).
--
-- channel_at_sale is carried as a DEGENERATE DIMENSION straight from
-- stg_pos_transactions, NOT joined from dim_outlet.channel. Reason: verified
-- (see DECISIONS.md) that dim_outlet's versioned channel field is
-- regeneration noise after the outlet's first CDC version - it is NOT safe
-- to use for sales-by-channel reporting. The POS-native channel is the real,
-- generation-time value and is stable for 100% of an outlet's sales.
--
-- Revenue definitions (verified against generator: unit_price * qty gives
-- the correct line value regardless of whether qty represents cases or
-- eaches - the uom label does not scale the price):
--   gross_sales_amount     = qty_original * unit_price          (pre-discount, pre-tax)
--   net_sales_amount       = gross_sales_amount - discount_amount (taxable value)
--   sales_amount_incl_tax  = net_sales_amount + tax_amount        (amount paid)
--
-- Units-in-eaches conversion (qty_eaches): converts case quantities to eaches
-- using data/reference/uom_conversion.csv. NULL when unconvertible, for two
-- independent reasons, both tracked separately:
--   - uom_unknown_flag: the row itself has no uom (pre-schema-drift feed,
--     ~50% of history - see stg_pos_transactions DEFECT L4)
--   - uom_conversion_missing: uom is known but the SKU has no entry in
--     uom_conversion.csv (46 of 1,100 SKUs sold are missing from that
--     reference file - a data-quality gap not previously documented)
-- =============================================================

CREATE OR REPLACE TABLE fct_sales AS

SELECT
    p.txn_id,
    p.txn_line_no,
    p.basket_id,
    p.outlet_code,
    p.channel                                                    AS channel_at_sale,
    p.sku_code,
    p.event_ts_utc,
    p.event_ts_ist,
    p.event_date_ist,
    p.is_late_arrival,

    p.qty_original,
    p.uom_original,
    p.uom_unknown_flag,
    u.eaches_per_case,
    (p.uom_original = 'CS' AND u.eaches_per_case IS NULL)         AS uom_conversion_missing,
    CASE
        WHEN p.uom_original = 'EA' THEN p.qty_original
        WHEN p.uom_original = 'CS' AND u.eaches_per_case IS NOT NULL
            THEN p.qty_original * u.eaches_per_case
        ELSE NULL
    END                                                            AS qty_eaches,

    p.unit_price,
    p.discount_amount,
    p.tax_amount,
    (p.qty_original * p.unit_price)                                AS gross_sales_amount,
    (p.qty_original * p.unit_price - p.discount_amount)            AS net_sales_amount,
    (p.qty_original * p.unit_price - p.discount_amount + p.tax_amount)
                                                                    AS sales_amount_incl_tax,

    p.payment_mode,
    p.promo_code,
    p.source_file

FROM stg_pos_transactions p
LEFT JOIN read_csv(getvariable('data_root') || '/reference/uom_conversion.csv', header = true) u
    ON p.sku_code = u.sku_code;