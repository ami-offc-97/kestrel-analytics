-- =============================================================
-- MART (dim): dim_calendar
-- Source: data/reference/fiscal_calendar.csv
-- Grain: one row per calendar date. Static reference data - no CDC, no
-- versioning. 546 days, 2025-01-01 through 2026-06-30 (FY25-FY27).
--
-- is_weekend arrives as 0/1 in the source CSV; cast to BOOLEAN here so it
-- joins/filters naturally against other boolean flags in the star schema
-- (e.g. dim_outlet.is_current, dim_product.is_deleted).
-- =============================================================

CREATE OR REPLACE TABLE dim_calendar AS

SELECT
    CAST(calendar_date AS DATE) AS calendar_date,
    fiscal_year,
    fiscal_quarter,
    fiscal_month_no,
    iso_week,
    day_of_week,
    CAST(is_weekend AS BOOLEAN) AS is_weekend
FROM read_csv(getvariable('data_root') || '/reference/fiscal_calendar.csv', header = true);