-- =============================================================
-- KPI-11 Cold Chain Excursion Rate / KPI-12 Below-Band Rate
-- Catalogue: docs/kpi_catalogue.md#5-cold-chain
-- Answers the answerable half of brief question 4: "what proportion of
-- chilled trips breached temperature, by month and by carrier."
--   by month   -> this query
--   by carrier -> NOT POSSIBLE, see limitations/x01_carrier_unlinkable.sql
--   "trips"    -> NOT DEFINED in the feed, see the note below
--
-- Reported at READING grain. A vehicle-day rollup gives 75.07% instead
-- of 7.19% - the grain is not a detail, it is most of the answer. The
-- rollup is left as an explicit choice rather than baked into the mart.
--
-- Readings with no temperature are excluded from BOTH numerator and
-- denominator, so "no data" is never counted as "in band".
-- =============================================================

SELECT
    date_trunc('month', reading_ts)                     AS month,

    count(*)                                             AS readings_total,
    count(*) FILTER (WHERE NOT temp_reading_missing)      AS readings_valid,

    -- KPI-11: above the 2-8C band, per the feed contract's literal wording.
    ROUND(100.0 * count(*) FILTER (WHERE is_excursion)
          / NULLIF(count(*) FILTER (WHERE NOT temp_reading_missing), 0), 2)
                                                          AS excursion_pct_above_band,

    -- KPI-12: below the band. Tracked separately, deliberately NOT
    -- folded into the excursion rate - and 2.75x larger than it.
    ROUND(100.0 * count(*) FILTER (WHERE is_below_band)
          / NULLIF(count(*) FILTER (WHERE NOT temp_reading_missing), 0), 2)
                                                          AS below_band_pct,

    -- What the rate becomes if "outside the band" is the definition.
    -- Open question for Divya - see the catalogue.
    ROUND(100.0 * count(*) FILTER (WHERE is_excursion OR is_below_band)
          / NULLIF(count(*) FILTER (WHERE NOT temp_reading_missing), 0), 2)
                                                          AS outside_band_pct,

    ROUND(100.0 * count(*) FILTER (WHERE temp_reading_missing)
          / count(*), 2)                                  AS missing_reading_pct
FROM fct_cold_chain_readings
GROUP BY month
ORDER BY month;
