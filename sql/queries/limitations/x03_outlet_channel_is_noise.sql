-- =============================================================
-- X-03 Outlets that changed channel classification - NOT BUILDABLE
-- Catalogue: docs/kpi_catalogue.md#x-03--outlets-that-changed-channel-classification-and-when
--
-- Brief question 6 asks which outlets changed channel and when. The
-- naive answer looks impressive and is wrong: the outlet master
-- re-randomises channel on every CDC update, so almost every
-- multi-version outlet appears to have "changed channel".
--
-- Section 1 is the trap. Section 2 shows why it is a trap. Section 3
-- is the reliable value.
-- =============================================================

-- --- 1. THE TRAP: what a naive channel-history query reports ------
-- Do not publish this. It is counting regeneration noise as business
-- events.
SELECT
    count(*)                                          AS outlets_appearing_to_change_channel,
    (SELECT count(DISTINCT outlet_code) FROM dim_outlet) AS outlets_total
FROM (
    SELECT outlet_code
    FROM dim_outlet
    GROUP BY outlet_code
    HAVING count(DISTINCT channel) > 1
);

-- --- 2. WHY IT IS A TRAP: six of nine attributes are noise --------
-- A real outlet master would show 1 distinct value for stable
-- attributes and occasional changes elsewhere. Here the supposedly
-- volatile fields average 2.5-3.8 distinct values with no pattern,
-- while the genuinely stable ones sit at exactly 1.
SELECT
    ROUND(avg(n_channel), 2)       AS avg_distinct_channel,
    ROUND(avg(n_format), 2)        AS avg_distinct_outlet_format,
    ROUND(avg(n_city), 2)          AS avg_distinct_city,
    ROUND(avg(n_route), 2)         AS avg_distinct_route_code,
    ROUND(avg(n_credit), 2)        AS avg_distinct_credit_limit,
    -- These two are real. Expect exactly 1.00.
    ROUND(avg(n_warehouse), 2)     AS avg_distinct_warehouse_code,
    ROUND(avg(n_name), 2)          AS avg_distinct_outlet_name
FROM (
    SELECT outlet_code,
           count(DISTINCT channel)        AS n_channel,
           count(DISTINCT outlet_format)  AS n_format,
           count(DISTINCT city)           AS n_city,
           count(DISTINCT route_code)     AS n_route,
           count(DISTINCT credit_limit)   AS n_credit,
           count(DISTINCT warehouse_code) AS n_warehouse,
           count(DISTINCT outlet_name)    AS n_name
    FROM dim_outlet
    GROUP BY outlet_code
    HAVING count(*) > 2
);

-- --- 3. A worked example of the noise ----------------------------
-- One outlet cycling through channels and cities with no logic.
SELECT outlet_code, version_no, channel, outlet_format, city, route_code,
       warehouse_code, valid_from
FROM dim_outlet
WHERE outlet_code = 'OUT001011'
ORDER BY version_no;

-- --- 4. THE RELIABLE VALUE: version 1, the initial insert ---------
-- This matches the POS-native channel for 100% of that outlet's sales,
-- and is what KPI-07 uses via fct_sales.channel_at_sale.
SELECT channel AS reliable_channel, count(*) AS outlets
FROM dim_outlet
WHERE version_no = 1
GROUP BY channel
ORDER BY outlets DESC;
