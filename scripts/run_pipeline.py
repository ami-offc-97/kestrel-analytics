#!/usr/bin/env python3
"""
Kestrel Provisions - analytical pipeline runner.

Builds the whole warehouse from the raw feeds in one command:

    python3 scripts/run_pipeline.py

Layers are executed in dependency order (staging -> marts -> reporting).
Every model is a CREATE OR REPLACE, so the run is idempotent: it can be
re-run any number of times and always lands on the same result. There is
no incremental state to corrupt and nothing to clean up after a failure.

The data root is injected as a DuckDB variable rather than hardcoded in
the SQL, so the same models run against a rescaled dataset:

    python3 generate_dataset.py --scale 10 --out data_10x
    python3 scripts/run_pipeline.py --data-root data_10x --db kestrel_10x.duckdb

See README.md for the full cold-start sequence.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

try:
    import duckdb
except ImportError:
    sys.exit("duckdb is not installed. Run: pip install duckdb pyarrow numpy pandas")


REPO_ROOT = Path(__file__).resolve().parent.parent

# Dependency-ordered build plan. Within a layer, models are independent of
# each other and could be parallelised; across layers they cannot, because
# marts read staging tables and reporting views read marts.
#
# The order inside MARTS is not arbitrary: fct_sales reads no dimension, but
# the reporting layer joins facts to dims, so all dims must exist before the
# reporting layer runs. Dims are listed first for readability.
LAYERS: dict[str, list[str]] = {
    "staging": [
        "sql/staging/stg_pos_transactions.sql",
        "sql/staging/stg_reefer_telemetry.sql",
        "sql/staging/stg_wms_scan_events.sql",
        "sql/staging/stg_outlet_history.sql",
        "sql/staging/stg_product_history.sql",
        "sql/staging/stg_sales_order_header.sql",
    ],
    "marts": [
        "sql/marts/dim_outlet.sql",
        "sql/marts/dim_product.sql",
        "sql/marts/dim_warehouse.sql",
        "sql/marts/dim_carrier.sql",
        "sql/marts/dim_calendar.sql",
        "sql/marts/fct_sales.sql",
        "sql/marts/fct_orders.sql",
        "sql/marts/fct_cold_chain_readings.sql",
        "sql/marts/fct_warehouse_cycle_time.sql",
    ],
    # Runs after marts because dq_feed_completeness and
    # dq_telemetry_gateway_health need dim_calendar as a date spine, and
    # the gateway model reads fct_cold_chain_readings.
    "dq": [
        "sql/dq/dq_partition_reconciliation.sql",
        "sql/dq/dq_feed_completeness.sql",
        "sql/dq/dq_telemetry_gateway_health.sql",
    ],
    "reporting": [
        "sql/reporting/rpt_sales_flat.sql",
        "sql/reporting/rpt_finance_reconciliation.sql",
    ],
}

LAYER_ORDER = ["staging", "marts", "dq", "reporting"]


def object_name(sql_path: Path) -> str:
    """The table/view a model builds, by convention its filename."""
    return sql_path.stem


def row_count(con, name: str) -> int | None:
    try:
        return con.execute(f'SELECT count(*) FROM "{name}"').fetchone()[0]
    except duckdb.Error:
        return None


def preflight(data_root: Path) -> None:
    """Fail early and legibly if the raw feeds are not where we expect."""
    required = [
        "raw/pos_transactions",
        "raw/reefer_telemetry",
        "raw/wms_scan_events",
        "raw/erp_cdc/outlet_master",
        "raw/erp_cdc/product_master",
        "raw/erp_cdc/sales_order_header",
        "reference/uom_conversion.csv",
        "reference/warehouse_master.csv",
        "reference/carrier_master.csv",
        "reference/fiscal_calendar.csv",
    ]
    missing = [p for p in required if not (data_root / p).exists()]
    if missing:
        print(f"ERROR: data root {data_root} is incomplete. Missing:", file=sys.stderr)
        for m in missing:
            print(f"  - {m}", file=sys.stderr)
        print(
            "\nThe raw dataset is not committed to this repo. Generate it with:\n"
            f"  python3 generate_dataset.py --scale 1 --out {data_root}",
            file=sys.stderr,
        )
        sys.exit(2)


def run(args: argparse.Namespace) -> int:
    data_root = Path(args.data_root)
    if not data_root.is_absolute():
        data_root = (REPO_ROOT / data_root).resolve()
    preflight(data_root)

    layers = LAYER_ORDER if args.layer == "all" else [args.layer]
    models = [(ly, REPO_ROOT / p) for ly in layers for p in LAYERS[ly]]

    missing_sql = [p for _, p in models if not p.exists()]
    if missing_sql:
        print("ERROR: SQL model files not found:", file=sys.stderr)
        for p in missing_sql:
            print(f"  - {p.relative_to(REPO_ROOT)}", file=sys.stderr)
        return 2

    print("=" * 74)
    print("Kestrel Provisions - analytical pipeline")
    print("=" * 74)
    print(f"  data root : {data_root}")
    print(f"  database  : {args.db}")
    print(f"  layers    : {', '.join(layers)}")
    print(f"  models    : {len(models)}")
    print("=" * 74)

    con = duckdb.connect(args.db)
    # Injected once per connection; every model reads it via getvariable().
    con.execute("SET VARIABLE data_root = ?", [str(data_root)])
    if args.threads:
        con.execute(f"SET threads = {args.threads}")

    failures: list[tuple[str, str]] = []
    run_started = time.perf_counter()
    current_layer = None

    for layer, path in models:
        if layer != current_layer:
            current_layer = layer
            print(f"\n-- {layer.upper()} " + "-" * (70 - len(layer)))

        name = object_name(path)
        started = time.perf_counter()
        try:
            con.execute(path.read_text())
        except duckdb.Error as exc:
            elapsed = time.perf_counter() - started
            print(f"  {name:<32} FAILED     {elapsed:7.2f}s")
            print(f"      {str(exc).splitlines()[0]}")
            failures.append((name, str(exc)))
            if args.fail_fast:
                print("\n--fail-fast set, stopping here.", file=sys.stderr)
                break
            continue

        elapsed = time.perf_counter() - started
        rows = row_count(con, name)
        shown = f"{rows:>12,}" if rows is not None else f"{'view':>12}"
        print(f"  {name:<32} {shown} rows  {elapsed:7.2f}s")

    total = time.perf_counter() - run_started
    print("\n" + "=" * 74)
    if failures:
        print(f"FAILED - {len(failures)} of {len(models)} models errored in {total:.1f}s")
        for name, _ in failures:
            print(f"  - {name}")
        print("=" * 74)
        return 1

    print(f"OK - {len(models)} models built in {total:.1f}s")
    print("=" * 74)
    db_flag = "" if args.db == "kestrel.duckdb" else f" --db {args.db}"
    print(
        "\nNext:\n"
        f"  python3 scripts/run_query.py --list{db_flag}\n"
        f"  python3 scripts/run_query.py sql/queries/sales/gross_sales_by_channel.sql{db_flag}\n"
        "\nMetric definitions: docs/kpi_catalogue.md"
        "\nWhat was built and why: DECISIONS.md"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build the Kestrel analytical warehouse from the raw feeds.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--data-root",
        default=os.environ.get("KESTREL_DATA_ROOT", "data"),
        help="Directory holding raw/ and reference/ (default: data)",
    )
    parser.add_argument(
        "--db",
        default=os.environ.get("KESTREL_DB", "kestrel.duckdb"),
        help="DuckDB database file to build into (default: kestrel.duckdb)",
    )
    parser.add_argument(
        "--layer",
        choices=[*LAYER_ORDER, "all"],
        default="all",
        help="Build a single layer instead of everything (default: all)",
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=None,
        help="Cap DuckDB worker threads. Useful on a small machine at --scale 10.",
    )
    parser.add_argument(
        "--fail-fast",
        action="store_true",
        help="Stop at the first failing model instead of continuing.",
    )
    return run(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
