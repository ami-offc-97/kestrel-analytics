-- =============================================================
-- KPI-13 Telemetry Completeness
-- Catalogue: docs/kpi_catalogue.md#kpi-13--telemetry-completeness
--
-- Two different failure modes, and the second is the dangerous one:
--   1. reading arrives with a NULL temperature (sensor dropout)
--   2. reading never arrives at all (gateway outage) - invisible to a
--      null check, looks like low volume. Ticket KP-3172.
--
-- Section 2 finds mode 2 by comparing each gateway-day against that
-- gateway's own median volume, which is what a null count cannot do.
-- =============================================================

-- --- 1. Null-reading rate by vendor and firmware ----------------
SELECT
    telemetry_vendor,
    firmware_version,
    count(*)                                            AS readings,
    count(*) FILTER (WHERE temp_reading_missing)         AS null_readings,
    ROUND(100.0 * count(*) FILTER (WHERE temp_reading_missing)
          / count(*), 3)                                AS null_pct
FROM fct_cold_chain_readings
GROUP BY telemetry_vendor, firmware_version
ORDER BY telemetry_vendor, firmware_version;

-- --- 2. Gateway outages: days that are HOLES, not nulls ---------
-- Flags any gateway-day below 40% of that gateway's median daily
-- volume, plus days entirely absent from the feed.
WITH gateway_days AS (
    SELECT gateway_id, dt, count(*) AS readings
    FROM fct_cold_chain_readings
    GROUP BY gateway_id, dt
),
baseline AS (
    SELECT gateway_id, median(readings) AS median_daily
    FROM gateway_days
    GROUP BY gateway_id
),
spine AS (
    SELECT b.gateway_id, c.calendar_date AS dt, b.median_daily
    FROM baseline b
    CROSS JOIN dim_calendar c
)
SELECT
    s.gateway_id,
    s.dt,
    COALESCE(g.readings, 0)                             AS readings,
    ROUND(s.median_daily, 0)                            AS median_daily,
    ROUND(100.0 * COALESCE(g.readings, 0)
          / NULLIF(s.median_daily, 0), 1)               AS pct_of_median,
    CASE WHEN g.readings IS NULL THEN 'DAY_ABSENT'
         ELSE 'VOLUME_COLLAPSE' END                     AS finding
FROM spine s
LEFT JOIN gateway_days g
       ON s.gateway_id = g.gateway_id AND s.dt = g.dt
WHERE COALESCE(g.readings, 0) < 0.4 * s.median_daily
ORDER BY s.gateway_id, s.dt;
