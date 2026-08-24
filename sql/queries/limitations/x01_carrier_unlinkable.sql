-- =============================================================
-- X-01 Excursion rate by carrier - NOT BUILDABLE
-- Catalogue: docs/kpi_catalogue.md#x-01--cold-chain-excursion-rate-by-carrier
--
-- Divya asked for excursion rate "by month and by carrier". By month is
-- KPI-11. By carrier cannot be built, and this query is the proof
-- rather than the assertion. Run it before proposing a workaround.
-- =============================================================

-- --- 1. dim_carrier exists, is conformed, and joins to nothing ----
-- There is no carrier column on any fact. Confirmed in the generator:
-- carrier_id is written once, into carrier_master.csv, and referenced
-- nowhere else in the entire dataset.
SELECT * FROM dim_carrier;

-- --- 2. Why route_code cannot be used as a proxy ------------------
-- The feed contract calls route_code/warehouse_code "assignment at
-- time of reading". The data says otherwise: they are re-randomised on
-- every individual reading. If these were real assignments, a vehicle
-- would see a handful of routes. Every vehicle sees all of them.
SELECT
    count(DISTINCT vehicle_registration)          AS vehicles,
    ROUND(avg(n_routes), 1)                        AS avg_routes_per_vehicle,
    ROUND(avg(n_warehouses), 1)                    AS avg_warehouses_per_vehicle,
    max(n_routes)                                  AS max_routes_per_vehicle,
    (SELECT count(DISTINCT route_code)
     FROM fct_cold_chain_readings)                 AS routes_in_existence
FROM (
    SELECT vehicle_registration,
           count(DISTINCT route_code)     AS n_routes,
           count(DISTINCT warehouse_code) AS n_warehouses
    FROM fct_cold_chain_readings
    GROUP BY vehicle_registration
);

-- --- 3. The one identity on this feed that IS real ----------------
-- device_id -> vehicle_registration is a genuine 1:1. Expect 0 rows.
SELECT device_id, count(DISTINCT vehicle_registration) AS n_vehicles
FROM fct_cold_chain_readings
GROUP BY device_id
HAVING count(DISTINCT vehicle_registration) > 1;
