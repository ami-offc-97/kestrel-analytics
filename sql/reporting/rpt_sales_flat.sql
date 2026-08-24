-- =============================================================
-- REPORTING (view): rpt_sales_flat
-- Source: fct_sales + dim_outlet, dim_product (point-in-time),
--         dim_calendar, dim_warehouse
-- Grain: one row per POS transaction line - same as fct_sales.
--
-- WHY THIS EXISTS. The star schema stores outlet and product as SCD2
-- (one row per version, valid_from/valid_to). That is correct storage,
-- but it means every analyst who wants "the product category on the day
-- of the sale" has to write the point-in-time predicate themselves, and
-- the failure mode is silent: join on outlet_code alone and a sale
-- fans out across every version of that outlet, inflating revenue by
-- the version count. This view writes that join once, correctly, so no
-- report can get it wrong.
--
-- It is a VIEW, not a table: always in sync with the facts, never a
-- second source of truth. At 4m rows the joins are not a bottleneck in
-- DuckDB. If that changes, CREATE VIEW -> CREATE TABLE AS is the whole
-- migration (see DECISIONS.md).
--
-- POINT-IN-TIME SEMANTICS. valid_to is EXCLUSIVE (it is the next
-- version's valid_from, or 9999-12-31 for the open window), so the
-- predicate is >= valid_from AND < valid_to. Verified: zero overlapping
-- windows on either dim, and every fct_sales row resolves to exactly
-- one outlet version and one product version.
--
-- The join uses event_ts_ist, the business-time timestamp, not
-- event_date_ist - matching at date grain would misattribute sales on
-- the day a version changes. ASSUMPTION: CDC __op_ts is business-local
-- (IST), so it is directly comparable to event_ts_ist. The generator
-- applies no timezone offset to CDC timestamps, so this holds here;
-- against a real ERP it is the first thing to confirm.
--
-- LEFT JOINed deliberately. The dims are verified to cover every fact
-- row today, but an inner join would silently drop sales if that ever
-- stopped being true. Revenue that quietly disappears is worse than
-- revenue with a null attribute.
--
-- DELIBERATELY NOT EXPOSED - regeneration noise, not history. These
-- columns exist on the dims but are re-randomised on every CDC version
-- (see DECISIONS.md), so surfacing them in a reporting view would
-- invite exactly the reports they cannot support:
--   from dim_outlet:  channel, outlet_format, city, route_code,
--                     credit_limit, credit_terms_days
--   from dim_product: brand, gst_rate_pct, shelf_life_days
-- channel in particular is served here by fct_sales.channel_at_sale,
-- the POS-native value, which IS reliable. Anyone who genuinely needs
-- the noisy attributes can still query the dims directly - this view
-- just declines to make the wrong thing easy.
-- =============================================================

CREATE OR REPLACE VIEW rpt_sales_flat AS

SELECT
    -- ---------- transaction identity ----------
    f.txn_id,
    f.txn_line_no,
    f.basket_id,

    -- ---------- when ----------
    f.event_ts_ist,
    f.event_date_ist,
    c.fiscal_year,
    c.fiscal_quarter,
    c.fiscal_month_no,
    c.iso_week,
    c.day_of_week,
    c.is_weekend,
    f.is_late_arrival,

    -- ---------- outlet (point-in-time; reliable attributes only) ----------
    f.outlet_code,
    o.outlet_name,
    o.gst_number                       AS outlet_gst_number,
    o.warehouse_code                   AS outlet_warehouse_code,
    o.version_no                       AS outlet_version_no,
    o.is_deleted                       AS outlet_is_deleted,

    -- ---------- serving warehouse ----------
    w.warehouse_name,
    w.region_name                      AS warehouse_region,
    w.city                             AS warehouse_city,

    -- ---------- channel (POS-native - the reliable one) ----------
    f.channel_at_sale,

    -- ---------- product (point-in-time; reliable attributes only) ----------
    f.sku_code,
    p.product_name,
    p.category                         AS product_category,
    p.is_chilled                       AS product_is_chilled,
    p.case_pack                        AS product_case_pack,
    p.mrp                              AS product_mrp_at_sale,
    p.list_price                       AS product_list_price_at_sale,
    p.version_no                       AS product_version_no,
    p.is_deleted                       AS product_is_deleted,

    -- ---------- quantity ----------
    f.qty_original,
    f.uom_original,
    f.uom_unknown_flag,
    f.uom_conversion_missing,
    f.eaches_per_case,
    f.qty_eaches,

    -- ---------- money ----------
    f.unit_price,
    f.gross_sales_amount,
    f.discount_amount,
    f.net_sales_amount,
    f.tax_amount,
    f.sales_amount_incl_tax,

    -- ---------- payment ----------
    f.payment_mode,
    f.promo_code,
    f.source_file

FROM fct_sales f

LEFT JOIN dim_outlet o
       ON f.outlet_code  = o.outlet_code
      AND f.event_ts_ist >= o.valid_from
      AND f.event_ts_ist <  o.valid_to

LEFT JOIN dim_product p
       ON f.sku_code     = p.sku_code
      AND f.event_ts_ist >= p.valid_from
      AND f.event_ts_ist <  p.valid_to

LEFT JOIN dim_calendar c
       ON f.event_date_ist = c.calendar_date

LEFT JOIN dim_warehouse w
       ON o.warehouse_code = w.warehouse_code;
