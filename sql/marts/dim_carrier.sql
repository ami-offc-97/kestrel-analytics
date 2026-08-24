-- =============================================================
-- MART (dim): dim_carrier
-- Source: data/reference/carrier_master.csv
-- Grain: one row per carrier. Static reference data - no CDC, no
-- versioning, no SCD Type 2. 5 carriers.
-- =============================================================

CREATE OR REPLACE TABLE dim_carrier AS

SELECT
    carrier_id,
    carrier_name,
    mode,
    sla_hours,
    rate_per_km
FROM read_csv('data/reference/carrier_master.csv', header = true);