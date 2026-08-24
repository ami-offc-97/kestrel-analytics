#!/usr/bin/env python3
"""
Run a query from the SQL library and print its result.

    python3 scripts/run_query.py sql/queries/sales/gross_sales_by_channel.sql

Queries in the library are multi-statement: parameters are declared with
SET VARIABLE at the top, and some files contain several numbered result
sections. This runner executes them in order and prints every section
that returns rows, so the file reads the same way as its output.

Parameters can be overridden without editing the file:

    python3 scripts/run_query.py sql/queries/sales/sales_summary.sql \\
        -p date_from=2025-04-01 -p date_to=2025-06-30 -p group_by=channel

Overrides are applied after the file's own SET VARIABLE statements, so
the file's defaults act as documentation of the expected shape.

With no arguments, lists the library.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import duckdb
except ImportError:
    sys.exit("duckdb is not installed. Run: pip install duckdb pyarrow numpy pandas")

REPO_ROOT = Path(__file__).resolve().parent.parent
QUERY_ROOT = REPO_ROOT / "sql" / "queries"


def list_library() -> int:
    print("Query library (docs/kpi_catalogue.md has the definitions)\n")
    for domain in sorted(p for p in QUERY_ROOT.iterdir() if p.is_dir()):
        print(f"  {domain.name}/")
        for q in sorted(domain.glob("*.sql")):
            # First non-blank comment line after the rule is the title.
            title = ""
            for line in q.read_text().splitlines():
                s = line.strip()
                if s.startswith("--") and not set(s) <= set("-= "):
                    title = s.lstrip("- ").strip()
                    break
            print(f"    {q.relative_to(REPO_ROOT)}")
            if title:
                print(f"        {title}")
        print()
    return 0


def split_statements(sql: str) -> list[str]:
    """
    Split SQL into executable statements, stripping comments as we go.

    Comment-awareness is not optional here: the library's header blocks
    contain prose, and prose contains semicolons and the words SET
    VARIABLE. A naive split on ";" turns a comment into a bogus
    statement, and a statement that still carries its leading comment
    block cannot be classified by startswith(). Both bugs were real.

    Handles single-quoted literals (with '' escapes), -- line comments
    and /* */ block comments.
    """
    out: list[str] = []
    buf: list[str] = []
    i, n = 0, len(sql)

    while i < n:
        two = sql[i : i + 2]

        if two == "--":                       # line comment: skip to EOL
            j = sql.find("\n", i)
            i = n if j == -1 else j + 1
            buf.append(" ")
            continue

        if two == "/*":                       # block comment: skip to close
            j = sql.find("*/", i + 2)
            i = n if j == -1 else j + 2
            buf.append(" ")
            continue

        if sql[i] == "'":                     # string literal: copy verbatim
            buf.append("'")
            i += 1
            while i < n:
                if sql[i] == "'":
                    if i + 1 < n and sql[i + 1] == "'":
                        buf.append("''")
                        i += 2
                        continue
                    buf.append("'")
                    i += 1
                    break
                buf.append(sql[i])
                i += 1
            continue

        if sql[i] == ";":                     # statement boundary
            out.append("".join(buf))
            buf = []
            i += 1
            continue

        buf.append(sql[i])
        i += 1

    out.append("".join(buf))
    return [s for s in (x.strip() for x in out) if s]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a query from sql/queries/ and print its result.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("query", nargs="?", help="Path to a .sql file in the library")
    parser.add_argument("--db", default="kestrel.duckdb", help="Database (default: kestrel.duckdb)")
    parser.add_argument(
        "-p",
        "--param",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="Override a SET VARIABLE parameter. Repeatable.",
    )
    parser.add_argument("--list", action="store_true", help="List the query library and exit")
    args = parser.parse_args()

    if args.list or not args.query:
        return list_library()

    path = Path(args.query)
    if not path.exists():
        path = REPO_ROOT / args.query
    if not path.exists():
        print(f"ERROR: no such query: {args.query}", file=sys.stderr)
        print("Run with --list to see the library.", file=sys.stderr)
        return 2

    if not Path(args.db).exists():
        print(f"ERROR: database {args.db} not found.", file=sys.stderr)
        print("Build it first:  python3 scripts/run_pipeline.py", file=sys.stderr)
        return 2

    overrides = {}
    for raw in args.param:
        if "=" not in raw:
            print(f"ERROR: --param expects NAME=VALUE, got {raw!r}", file=sys.stderr)
            return 2
        name, value = raw.split("=", 1)
        overrides[name.strip()] = value.strip()

    con = duckdb.connect(args.db, read_only=False)
    statements = split_statements(path.read_text())

    # Section titles: the "--- n. label ---" banners in the library files.
    titles = re.findall(r"--\s*-+\s*(\d+\.[^-\n]*?)\s*-+\s*\n", path.read_text())

    print(f"# {path.relative_to(REPO_ROOT) if path.is_relative_to(REPO_ROOT) else path}")
    if overrides:
        print(f"# overrides: {', '.join(f'{k}={v}' for k, v in overrides.items())}")
    print()

    applied = False
    section = 0
    for stmt in statements:
        is_set = stmt.upper().startswith("SET VARIABLE")

        # Overrides must land AFTER the file's own SET VARIABLE defaults
        # but BEFORE the first statement that reads them. Applying them
        # any later has no effect on the result.
        if not is_set and not applied:
            for name, value in overrides.items():
                literal = value if re.fullmatch(r"-?\d+(\.\d+)?", value) else f"'{value}'"
                try:
                    con.execute(f"SET VARIABLE {name} = {literal}")
                except duckdb.Error as exc:
                    print(f"ERROR applying override {name}: {exc}", file=sys.stderr)
                    return 1
            applied = True

        try:
            if is_set:
                con.execute(stmt)
                continue
            rel = con.sql(stmt)
        except duckdb.Error as exc:
            print(f"ERROR in statement:\n{stmt[:300]}\n\n{exc}", file=sys.stderr)
            return 1

        if rel is None:
            continue
        if section < len(titles):
            print(f"-- {titles[section]}")
        section += 1
        rel.show(max_rows=60)
        print()

    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
