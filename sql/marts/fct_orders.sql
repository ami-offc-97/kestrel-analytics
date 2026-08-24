-- =============================================================
-- MART (fact): fct_orders
-- Source: stg_sales_order_header
-- Grain: one row per order_number.
--
-- The CDC feed contains the full order history, but this fact is
-- intentionally a one-row-per-order snapshot rather than one row
-- per CDC version.
--
-- IMPORTANT - canonical version:
-- Financial/order attributes are regenerated independently on every
-- CDC version in the synthetic source. Therefore the fact uses the
-- LATEST NON-DELETED version as the canonical order snapshot.
--
-- This is deliberately NOT "latest row regardless of op_type":
-- delete tombstones copy the original insert values, so the final
-- physical row could regress the order to stale insert values.
--
-- VERIFIED: in this dataset the delete tombstone is a byte copy of
-- the insert row, timestamp included (generator: dels = df[__op=='I']
-- .sample(...)), while updates sit 6h+ later. So the D row is NEVER
-- chronologically last - all 2,880 deleted orders have at least one
-- U row after their D. Consequence: the "deprioritise delete rows"
-- tie-break below is a confirmed NO-OP on this data (canonical and
-- purely-chronological ranking agree on all 320,000 orders). It is
-- retained as defence against a source where a tombstone IS last,
-- not because it changes anything today.
--
-- is_deleted follows the "ever deleted = permanently deleted" rule
-- used by dim_outlet/dim_product. Here that rule is not a refinement
-- but the whole result: because no D row is ever chronologically
-- last, a "latest op_type" test would flag ZERO deleted orders
-- instead of the true 2,880. A deleted order is retained in the fact
-- for traceability, but is excluded from active-order KPIs by
-- filtering is_deleted = false.
--
-- CAUTION - regeneration noise, NOT genuine history. The generator
-- redraws these independently on every order version, so the value
-- carried here is simply whichever draw landed on the canonical
-- version. Retained for traceability; must not be read as order
-- routing/scheduling history:
--   outlet_code, route_code      (independent rng.integers per row)
--   warehouse_code               (follows the randomly drawn outlet)
--   requested_delivery_date      (order_date + rng.integers(1,4) per row)
--   line_count                   (independent rng.integers per row)
-- order_date IS stable per order (the day index is shared across all
-- of an order's versions) and is safe to use as the event date.
--
-- order_status can only reach DISPATCHED in this dataset.
-- DELIVERED is mathematically unreachable because each order gets
-- at most three generated update steps.
--
-- Partner API gross value is corrected upstream in staging for the
-- known 8.5% freight double-counting defect (DEFECT L14). Both raw
-- and corrected values are retained here so source-system
-- comparisons remain auditable. Verified: the correction removes
-- exactly 8.5% from PARTNER_API and 0.0% from the other two systems.
--
-- CAUTION - order_value_net and order_value_incl_tax are arithmetic
-- only; they are NOT reliable business measures on this feed, and no
-- KPI should be built on them. discount_amount and tax_amount are
-- drawn as independent uniforms (rng.uniform(0, 9000) and
-- rng.uniform(200, 52000)) with no relationship whatsoever to
-- order_value_gross. Verified against the built fact:
--   corr(gross_corrected, discount) = 0.0020
--   corr(gross_corrected, tax)      = 0.0027
--   implied tax rate spans 0.04% to 2552% (median 10.83%)
-- Because discount is unbounded relative to gross, 1,743 orders
-- (0.54%, evenly spread across all three source systems) come out
-- with a NEGATIVE order_value_net, worst case -6,851.84. That is a
-- property of the source, not of this SQL, so the columns are kept
-- visible rather than filtered or clamped - hiding them would hide
-- the finding. Use order_value_gross_corrected as the order-value
-- measure for reporting.
--
-- NOTE the asymmetry with fct_sales: the POS feed derives its
-- discount and tax FROM the line value (up*qty*choice([0,0,0,.05,.10])
-- and up*qty*0.12), so fct_sales.net_sales_amount and
-- sales_amount_incl_tax ARE meaningful. Only this order feed's
-- equivalents are noise. Do not generalise either way.
-- =============================================================

CREATE OR REPLACE TABLE fct_orders AS

WITH versioned AS (
    SELECT
        order_number,
        op_type,
        op_ts,
        seq,
        outlet_code,
        warehouse_code,
        route_code,
        order_date,
        requested_delivery_date,
        order_status,
        line_count,
        order_value_gross,
        order_value_gross_corrected,
        discount_amount,
        tax_amount,
        source_system,

        -- "ever deleted" - see header. Aliased distinctly from the
        -- row-level is_deleted column on the staging table so the
        -- two are never confused (an earlier revision named both
        -- is_deleted, which left the tie-break below depending on
        -- DuckDB's column-vs-alias resolution order).
        MAX(is_deleted) OVER (
            PARTITION BY order_number
        ) AS is_ever_deleted,

        -- Canonical = latest version, with delete tombstones pushed
        -- last so they can never win. op_type is tested directly
        -- rather than via a column alias, to keep the intent explicit.
        ROW_NUMBER() OVER (
            PARTITION BY order_number
            ORDER BY
                CASE WHEN op_type = 'D' THEN 1 ELSE 0 END,
                op_ts DESC,
                seq DESC
        ) AS canonical_rank

    FROM stg_sales_order_header
)

SELECT
    order_number,
    order_date,
    requested_delivery_date,
    order_status,

    outlet_code,
    warehouse_code,
    route_code,

    source_system,

    line_count,

    order_value_gross,
    order_value_gross_corrected,

    discount_amount,
    tax_amount,

    -- Arithmetic only - see CAUTION in header. Not KPI-safe.
    order_value_gross_corrected - discount_amount
        AS order_value_net,

    order_value_gross_corrected - discount_amount + tax_amount
        AS order_value_incl_tax,

    is_ever_deleted AS is_deleted,

    op_ts AS snapshot_op_ts,
    seq AS snapshot_seq

FROM versioned
WHERE canonical_rank = 1;