-- =============================================================
-- MART (fact): fct_cold_chain_readings
-- Source: stg_reefer_telemetry
-- Grain: one row per temperature reading (same grain as
-- stg_reefer_telemetry post-dedup - no aggregation here; "trip" or
-- "day" rollups happen in reporting views/KPI queries, not here).
--
-- CAUTION - route_code and warehouse_code are carried through for
-- row-level traceability but are NOT reliable for "by route" or "by
-- warehouse" cold-chain reporting. Verified against real data: every
-- vehicle_registration appears against all 260 route_codes and all 8
-- warehouse_codes with no concentration (avg 260.0 distinct routes and
-- 8.0 distinct warehouses per vehicle - i.e. uniformly random). This
-- contradicts 02_Feed_Contracts.md's description of these fields as
-- "assignment at time of reading" - confirmed in the generator: both
-- are drawn independently per reading (rng.integers per row), with no
-- tie to device/vehicle. Only device_id, vehicle_registration, and
-- telemetry_vendor are genuinely stable per device (device->vehicle is
-- 1:1). See DECISIONS.md.
--
-- CAUTION - there is NO carrier field or carrier-linking key anywhere
-- in this feed (or in any other raw feed). carrier_master.csv /
-- dim_carrier cannot be joined to this fact without fabricating a key.
-- "Excursion rate by carrier" (brief Q4 / Divya's ask) is NOT
-- answerable from this dataset as given - documented as a known
-- limitation rather than silently worked around. See DECISIONS.md.
--
-- is_excursion follows 02_Feed_Contracts.md's literal definition:
-- "target band is 2 to 8 degrees C; an excursion is any reading ABOVE
-- the band." Readings below 2C (19.83% of non-missing readings) are
-- NOT excursions under this definition - flagged separately via
-- is_below_band so the ambiguity is visible rather than silently
-- dropped. NULL (not FALSE) when the reading itself is missing.
-- =============================================================

CREATE OR REPLACE TABLE fct_cold_chain_readings AS

SELECT
    device_id,
    vehicle_registration,
    telemetry_vendor,
    firmware_version,
    gateway_id,

    route_code,                                                    -- see CAUTION above: noise, not a real assignment
    warehouse_code,                                                -- see CAUTION above: noise, not a real assignment

    reading_ts_corrected                                           AS reading_ts,
    dt,

    temp_value_celsius,
    temp_reading_missing,

    CASE WHEN temp_reading_missing THEN NULL
         ELSE temp_value_celsius > 8 END                           AS is_excursion,
    CASE WHEN temp_reading_missing THEN NULL
         ELSE temp_value_celsius < 2 END                           AS is_below_band,

    humidity_pct,
    door_open_flag,
    battery_pct,
    gps_lat,
    gps_lon

FROM stg_reefer_telemetry;