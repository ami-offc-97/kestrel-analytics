-- =============================================================
-- KPI-08 Published vs Actual Variance
-- Catalogue: docs/kpi_catalogue.md#kpi-08--published-vs-actual-variance
-- Answers brief question 2: "How does that figure compare with the
-- published Finance weekly report, and if it differs, why."
--
-- Three sections, run top to bottom. Section 1 is the answer; sections
-- 2 and 3 are the evidence for why it is the answer.
-- =============================================================

-- --- 1. Headline: the three bases, whole period -----------------
SELECT
    'A. our correct basis (event date, deduped)' AS basis,
    ROUND(sum(our_gross_correct) / 1e7, 2)        AS gross_cr
FROM rpt_finance_reconciliation
UNION ALL
SELECT
    'B. legacy method reproduced (ingest date, no dedup)',
    ROUND(sum(legacy_emulated_gross) / 1e7, 2)
FROM rpt_finance_reconciliation
UNION ALL
SELECT
    'C. as published to the board',
    ROUND(sum(legacy_published_gross) / 1e7, 2)
FROM rpt_finance_reconciliation;

-- --- 2. What each alleged defect is actually worth --------------
-- Both of Supply Chain's allegations are CONFIRMED real here, and both
-- are shown to be far too small to explain the published figure.
SELECT
    ROUND(sum(bug_impact_gross) / 1e7, 2)          AS bug_impact_cr,
    ROUND(100.0 * sum(legacy_emulated_gross)
          / sum(our_gross_correct) - 100.0, 2)     AS bug_inflation_pct,
    sum(duplicate_lines_counted)                    AS duplicate_lines,
    ROUND(sum(legacy_published_gross)
          - sum(legacy_emulated_gross), 2)          AS residual_unexplained_inr
FROM rpt_finance_reconciliation;

-- --- 3. Why it is not a reconciliation problem at all -----------
-- A double-count inflates uniformly. A date-grain bug shifts revenue
-- between adjacent weeks. Neither produces a flat, uncorrelated
-- distribution. corr ~ 0 is the finding.
SELECT
    count(*)                                                    AS cells,
    ROUND(corr(legacy_published_gross, our_gross_correct), 4)     AS corr_published_vs_actual,
    ROUND(corr(legacy_published_gross, legacy_emulated_gross), 4) AS corr_published_vs_emulated,
    count(*) FILTER (WHERE reconciliation_status
                     = 'RECONCILED_WITHIN_5PCT')                 AS cells_within_5pct,
    ROUND(min(variance_pct), 1)                                  AS worst_understatement_pct,
    ROUND(max(variance_pct), 1)                                  AS worst_overstatement_pct
FROM rpt_finance_reconciliation;
