-- =============================================================
-- KPI-09 Order Value Gross (corrected) / KPI-10 Order Count
-- Catalogue: docs/kpi_catalogue.md#4-orders
-- Answers brief question 7: "Order value by source system, and whether
-- the three sources are comparable."
--
-- Shows raw and corrected side by side so the DEFECT L14 freight
-- correction (PARTNER_API, 8.5%) is auditable rather than baked in.
--
-- order_value_net and order_value_incl_tax are deliberately NOT
-- reported here. They are not meaningful on this feed - see X-04.
--
-- PARAMETERS
--   date_from, date_to : inclusive order_date window
-- =============================================================

SET VARIABLE date_from = DATE '2025-01-01';
SET VARIABLE date_to   = DATE '2026-06-30';

SELECT
    source_system,
    count(*)                                          AS orders,

    ROUND(sum(order_value_gross) / 1e7, 2)             AS gross_raw_cr,
    ROUND(sum(order_value_gross_corrected) / 1e7, 2)   AS gross_corrected_cr,
    ROUND(100.0 * sum(order_value_gross)
          / sum(order_value_gross_corrected) - 100.0, 2) AS inflation_removed_pct,

    -- The comparability test. If these are close across all three
    -- systems after correction, the sources ARE comparable on gross.
    ROUND(avg(order_value_gross_corrected), 0)         AS avg_order_value,
    ROUND(median(order_value_gross_corrected), 0)      AS median_order_value,

    ROUND(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct_of_orders
FROM fct_orders
WHERE NOT is_deleted
  AND order_date BETWEEN getvariable('date_from') AND getvariable('date_to')
GROUP BY source_system
ORDER BY gross_corrected_cr DESC;
