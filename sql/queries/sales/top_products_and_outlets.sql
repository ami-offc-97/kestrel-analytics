-- =============================================================
-- KPI-01 Gross Sales, ranked
-- Catalogue: docs/kpi_catalogue.md#kpi-01--gross-sales
--
-- "What sells best" and "who buys most" - the two most commonly asked
-- ranking questions, on the same date window so the answers are
-- comparable.
--
-- Product attributes come from rpt_sales_flat, so they are the values
-- that were true AT THE TIME OF SALE, not today's. A SKU that changed
-- category mid-period is counted under the category it had on each
-- sale, which is the point of the SCD2 join.
--
-- PARAMETERS
--   date_from, date_to : inclusive business-date (IST) window
--   top_n              : how many rows per ranking
-- =============================================================

SET VARIABLE date_from = DATE '2026-04-01';
SET VARIABLE date_to   = DATE '2026-06-30';
SET VARIABLE top_n     = 10;

-- --- 1. Top products by gross sales ------------------------------
SELECT
    sku_code,
    any_value(product_name)                    AS product_name,
    any_value(product_category)                 AS category,
    any_value(product_is_chilled)               AS is_chilled,
    count(*)                                    AS lines,
    ROUND(sum(gross_sales_amount), 2)           AS gross_sales,
    sum(qty_eaches)                             AS units_eaches,
    ROUND(100.0 * sum(gross_sales_amount)
          / sum(sum(gross_sales_amount)) OVER (), 2) AS pct_of_window
FROM rpt_sales_flat
WHERE event_date_ist BETWEEN getvariable('date_from') AND getvariable('date_to')
GROUP BY sku_code
ORDER BY gross_sales DESC
LIMIT getvariable('top_n');

-- --- 2. Top outlets by gross sales -------------------------------
SELECT
    outlet_code,
    any_value(outlet_name)                      AS outlet_name,
    any_value(channel_at_sale)                   AS channel,
    any_value(warehouse_region)                  AS region,
    count(DISTINCT basket_id)                    AS baskets,
    ROUND(sum(gross_sales_amount), 2)            AS gross_sales,
    ROUND(sum(gross_sales_amount)
          / NULLIF(count(DISTINCT basket_id), 0), 2) AS avg_basket_value
FROM rpt_sales_flat
WHERE event_date_ist BETWEEN getvariable('date_from') AND getvariable('date_to')
GROUP BY outlet_code
ORDER BY gross_sales DESC
LIMIT getvariable('top_n');

-- --- 3. Top categories by gross sales ----------------------------
SELECT
    product_category                             AS category,
    count(DISTINCT sku_code)                     AS skus_sold,
    ROUND(sum(gross_sales_amount), 2)            AS gross_sales,
    ROUND(100.0 * sum(gross_sales_amount)
          / sum(sum(gross_sales_amount)) OVER (), 2) AS pct_of_window
FROM rpt_sales_flat
WHERE event_date_ist BETWEEN getvariable('date_from') AND getvariable('date_to')
GROUP BY product_category
ORDER BY gross_sales DESC;
