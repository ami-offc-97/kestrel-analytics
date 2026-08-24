-- =============================================================
-- KPI-01 Gross Sales / KPI-02 Net Sales / KPI-03 Sales Incl Tax
-- KPI-06 Basket Count and Average Basket Value
-- Catalogue: docs/kpi_catalogue.md#1-sales
--
-- The headline sales block, at whatever grain you ask for.
--
-- PARAMETERS
--   date_from, date_to : inclusive business-date (IST) window
--   group_by           : one of 'month', 'fiscal_quarter', 'channel',
--                        'category', 'region'
-- =============================================================

SET VARIABLE date_from = DATE '2026-04-01';
SET VARIABLE date_to   = DATE '2026-06-30';
SET VARIABLE group_by  = 'month';

SELECT
    CASE getvariable('group_by')
        WHEN 'month'          THEN strftime(event_date_ist, '%Y-%m')
        WHEN 'fiscal_quarter' THEN fiscal_year || '-' || fiscal_quarter
        WHEN 'channel'        THEN channel_at_sale
        WHEN 'category'       THEN product_category
        WHEN 'region'         THEN warehouse_region
    END                                              AS grouping,

    count(*)                                          AS transaction_lines,
    count(DISTINCT basket_id)                         AS baskets,

    ROUND(sum(gross_sales_amount), 2)                 AS gross_sales,
    ROUND(sum(discount_amount), 2)                    AS discount,
    ROUND(sum(net_sales_amount), 2)                   AS net_sales,
    ROUND(sum(tax_amount), 2)                         AS tax,
    ROUND(sum(sales_amount_incl_tax), 2)              AS sales_incl_tax,

    -- KPI-06. Guarded against a zero denominator.
    ROUND(sum(gross_sales_amount)
          / NULLIF(count(DISTINCT basket_id), 0), 2)  AS avg_basket_value,

    -- Feed-health context, so a number is never read without it.
    ROUND(100.0 * count(*) FILTER (WHERE is_late_arrival) / count(*), 2)
                                                       AS pct_late_arriving
FROM rpt_sales_flat
WHERE event_date_ist BETWEEN getvariable('date_from') AND getvariable('date_to')
GROUP BY grouping
HAVING grouping IS NOT NULL
ORDER BY grouping;
