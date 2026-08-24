-- =============================================================
-- MART (dim): dim_warehouse
-- Source: data/reference/warehouse_master.csv
-- Grain: one row per warehouse. Static reference data - no CDC, no
-- versioning, no SCD Type 2 (unlike dim_outlet/dim_product). 8 warehouses.
-- =============================================================

CREATE OR REPLACE TABLE dim_warehouse AS

SELECT
    warehouse_code,
    warehouse_name,
    city,
    region_name,
    timezone,
    chilled_capacity_pallets
FROM read_csv(getvariable('data_root') || '/reference/warehouse_master.csv', header = true);