-- =============================================================
-- KPI-04 Units Sold (as transacted)
-- Catalogue: docs/kpi_catalogue.md#kpi-04--units-sold-as-transacted
--
-- WARNING, and it is the whole point of this query's existence:
-- qty_original MIXES EACHES AND CASES. This is not a physical volume.
-- It is published because it covers 100% of lines and because it is
-- what the legacy report's units_sold column compares to.
-- For a real volume number use units_sold_in_eaches.sql and accept
-- the coverage loss.
--
-- PARAMETERS
--   date_from, date_to : inclusive business-date (IST) window
-- Defaults to the last complete calendar month in the dataset.
-- =============================================================

SET VARIABLE date_from = DATE '2026-06-01';
SET VARIABLE date_to   = DATE '2026-06-30';

SELECT
    channel_at_sale                                   AS channel,
    sum(qty_original)                                  AS units_as_transacted,

    -- The composition of that number, so the mixing is visible.
    sum(qty_original) FILTER (WHERE uom_original = 'EA')  AS units_known_eaches,
    sum(qty_original) FILTER (WHERE uom_original = 'CS')  AS units_known_cases,
    sum(qty_original) FILTER (WHERE uom_unknown_flag)      AS units_unknown_uom,
    ROUND(100.0 * sum(qty_original) FILTER (WHERE uom_unknown_flag)
          / sum(qty_original), 2)                      AS pct_unknown_uom
FROM rpt_sales_flat
WHERE event_date_ist BETWEEN getvariable('date_from') AND getvariable('date_to')
GROUP BY channel_at_sale
ORDER BY units_as_transacted DESC;
