-- =============================================================
-- KPI-05 Units Sold in Eaches
-- Catalogue: docs/kpi_catalogue.md#kpi-05--units-sold-in-eaches
-- Answers brief question 3: "Units sold last month. In eaches."
--
-- Coverage is only ~49.6% of lines, for two independent reasons, and
-- this query reports the coverage alongside the number so the figure
-- can never be quoted bare. Unconvertible lines are EXCLUDED, never
-- assumed to be eaches - see the catalogue entry for why.
--
-- PARAMETERS
--   date_from, date_to : inclusive business-date (IST) window
-- =============================================================

SET VARIABLE date_from = DATE '2026-06-01';
SET VARIABLE date_to   = DATE '2026-06-30';

SELECT
    channel_at_sale                                    AS channel,

    -- The metric.
    sum(qty_eaches)                                     AS units_eaches,

    -- Coverage: what share of lines the number is actually based on.
    count(*)                                            AS lines_total,
    count(*) FILTER (WHERE qty_eaches IS NOT NULL)      AS lines_converted,
    ROUND(100.0 * count(*) FILTER (WHERE qty_eaches IS NOT NULL)
          / count(*), 2)                                AS pct_coverage,

    -- Why the rest could not be converted, split by cause.
    count(*) FILTER (WHERE uom_unknown_flag)            AS excluded_no_uom_in_feed,
    count(*) FILTER (WHERE uom_conversion_missing)      AS excluded_sku_not_in_ref
FROM rpt_sales_flat
WHERE event_date_ist BETWEEN getvariable('date_from') AND getvariable('date_to')
GROUP BY channel_at_sale
ORDER BY units_eaches DESC NULLS LAST;
