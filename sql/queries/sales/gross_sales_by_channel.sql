-- =============================================================
-- KPI-01 Gross Sales / KPI-07 Gross Sales by Channel
-- Catalogue: docs/kpi_catalogue.md#kpi-07--gross-sales-by-channel
-- Answers brief question 1: "Gross sales by channel for the last
-- complete fiscal quarter."
--
-- PARAMETERS - edit these two lines, nothing else.
--   fiscal_year    : e.g. 'FY27'
--   fiscal_quarter : e.g. 'Q1'
-- The last complete fiscal quarter in the shipped dataset is FY27-Q1
-- (Apr-Jun 2026), verified complete at 91 of 91 days.
--
-- Channel comes from channel_at_sale, the POS-native value, NOT from
-- dim_outlet.channel - see KPI-07's limitation and X-03.
-- =============================================================

SET VARIABLE fiscal_year    = 'FY27';
SET VARIABLE fiscal_quarter = 'Q1';

SELECT
    channel_at_sale                                AS channel,
    count(*)                                        AS transaction_lines,
    count(DISTINCT basket_id)                       AS baskets,
    ROUND(sum(gross_sales_amount), 2)               AS gross_sales_inr,
    ROUND(sum(gross_sales_amount) / 1e7, 2)         AS gross_sales_cr,
    ROUND(sum(net_sales_amount), 2)                 AS net_sales_inr,
    ROUND(sum(sales_amount_incl_tax), 2)            AS sales_incl_tax_inr,
    ROUND(100.0 * sum(gross_sales_amount)
          / sum(sum(gross_sales_amount)) OVER (), 2) AS pct_of_total
FROM rpt_sales_flat
WHERE fiscal_year    = getvariable('fiscal_year')
  AND fiscal_quarter = getvariable('fiscal_quarter')
GROUP BY channel_at_sale
ORDER BY gross_sales_inr DESC;
