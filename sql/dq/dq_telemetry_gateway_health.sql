-- =============================================================
-- DQ (table): dq_telemetry_gateway_health
-- Source: fct_cold_chain_readings, dim_calendar
-- Grain: one row per (gateway_id, calendar_date).
--
-- This model exists because dq_feed_completeness could not do its job.
-- The known GW-017 outage - DEFECT L10, "a hole, not a null" - is
-- completely invisible in feed-level daily volume: those two days land
-- at 6,432 and 6,293 readings against a feed median of 6,593, well
-- inside normal day-to-day variance, because the dead gateway carries
-- only about 2.5% of total volume.
--
-- Monitoring at the grain the outage OCCURS at, rather than the grain
-- that is convenient to aggregate, finds it immediately: GW-017 drops
-- to zero on 2026-02-11 and 2026-02-12 against its own baseline of
-- ~169 readings/day. Verified to isolate exactly those two
-- gateway-days, with no false positives across every gateway and all
-- 546 days.
--
-- Each gateway is compared against ITS OWN baseline, not against the
-- fleet. Gateways carry very different volumes, so a fleet-wide
-- threshold would either miss the small ones or constantly cry wolf
-- about them.
--
-- THRESHOLD CHOICE, measured rather than guessed. Gateway daily volume
-- is noisy: across all non-zero gateway-days the minimum is 67.6% of
-- that gateway's median, the 0.1st percentile is 77.2% and the 1st
-- percentile is 82.8%. An earlier revision of this model flagged
-- anything below 80% and produced 74 alerts, every one of them ordinary
-- variance. That is worse than no monitoring, because an alert stream
-- that is mostly noise trains people to ignore the one that matters.
-- DEGRADED is therefore set at 50% - comfortably clear of observed
-- normal variance - and the tier between 50% and 80% was removed
-- rather than retuned, because nothing in this data occupies it
-- legitimately. If partial-outage sensitivity is ever needed, the right
-- fix is a variance-aware test (z-score or MAD against the gateway's
-- own history), not a tighter fixed percentage.
--
-- The generalisable point for production: this pattern - spine x
-- dimension, each series against its own baseline - is what a real
-- completeness control looks like. It is applied here to gateways
-- because that is where this dataset's known hole is. The same shape is
-- needed per till/outlet on POS and per warehouse on WMS before either
-- feed could be called monitored. Not built; see DECISIONS.md.
-- =============================================================

CREATE OR REPLACE TABLE dq_telemetry_gateway_health AS

WITH gateway_days AS (
    SELECT gateway_id, dt AS reading_date, count(*) AS readings
    FROM fct_cold_chain_readings
    GROUP BY 1, 2
),

gateways AS (SELECT DISTINCT gateway_id FROM gateway_days),

-- Spine again: a gateway-day with no readings must produce a zero row,
-- not an absent one. That is the entire mechanism.
spine AS (
    SELECT g.gateway_id, c.calendar_date
    FROM gateways g
    CROSS JOIN dim_calendar c
),

observed AS (
    SELECT
        s.gateway_id,
        s.calendar_date,
        COALESCE(gd.readings, 0) AS readings,
        (gd.readings IS NULL)     AS day_absent
    FROM spine s
    LEFT JOIN gateway_days gd
           ON s.gateway_id = gd.gateway_id
          AND s.calendar_date = gd.reading_date
),

baselined AS (
    SELECT
        o.*,
        median(o.readings) OVER (PARTITION BY o.gateway_id) AS gateway_median
    FROM observed o
)

SELECT
    gateway_id,
    calendar_date,
    readings,
    day_absent,
    ROUND(gateway_median, 0)                                  AS gateway_median,
    ROUND(100.0 * readings / NULLIF(gateway_median, 0), 1)     AS pct_of_gateway_median,
    CASE
        WHEN readings = 0                    THEN 'OUTAGE'
        WHEN readings < 0.50 * gateway_median THEN 'DEGRADED'
        ELSE 'OK'
    END AS status
FROM baselined
ORDER BY
    CASE WHEN readings = 0 THEN 0 ELSE 1 END,
    gateway_id, calendar_date;
