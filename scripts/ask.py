#!/usr/bin/env python3
"""
Ask the warehouse a question in plain English. It always shows the SQL.

    python3 scripts/ask.py "gross sales by channel last quarter"
    python3 scripts/ask.py "units in eaches last month"
    python3 scripts/ask.py "how does that compare to the finance report"
    python3 scripts/ask.py                       # interactive

This is the CFO's "ask anything" requirement, built to his actual stated
condition: "if it cannot show me the query it ran, I am not interested."

WHAT THIS IS NOT. It does not use an LLM and it does not write SQL. It
routes a question to a query that already exists in sql/queries/, defined
and owned in docs/kpi_catalogue.md, and prints that query before running
it. Every number it returns is one a human already defined.

That is a deliberate trade. A model writing fresh SQL against this schema
would answer more questions and would sometimes be confidently wrong - it
would happily join dim_outlet.channel, which we proved is regeneration
noise, and report a channel split that looks perfectly plausible. On a
dataset where six of nine outlet attributes are noise, "sounds right" is
the failure mode to design against. See DECISIONS.md.

The cost is a fixed vocabulary. When the router does not recognise a
question it says so and lists what it does know. It never guesses.

Two behaviours worth knowing:

  * Questions that SOUND answerable but are not - cycle time by
    warehouse, excursion rate by carrier, outlet channel changes - return
    the documented reason and a runnable proof instead of a number. The
    honest answer to a question the data cannot support is why, not a
    plausible figure.

  * Relative dates resolve against the LATEST DATE IN THE DATA, not
    today's clock. The shipped dataset ends 2026-06-30, so "last month"
    means June 2026. Anchoring to the wall clock would return zero rows
    and look like a broken pipeline rather than a stale feed.
"""

from __future__ import annotations

import argparse
import calendar
import json
import re
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

try:
    import duckdb
except ImportError:
    sys.exit("duckdb is not installed. Run: pip install duckdb pyarrow numpy pandas")

REPO_ROOT = Path(__file__).resolve().parent.parent
INTENTS_PATH = REPO_ROOT / "sql" / "queries" / "intents.json"

RULE = "=" * 74


# ----------------------------------------------------------------- matching

def normalise(text: str) -> str:
    return re.sub(r"[^a-z0-9 ]+", " ", text.lower())


def group_hit(question: str, group) -> bool:
    """A group is satisfied if any of its synonyms appears."""
    terms = group if isinstance(group, list) else [group]
    return any(t.lower() in question for t in terms)


def score(question: str, intent: dict) -> int:
    """
    Number of matched terms, or 0 for no match. Higher wins.

    all_of groups must ALL be satisfied. any_of needs one. The score is
    used only to break ties between intents that both matched, which is
    why specific intents list more terms than general ones - 'units in
    eaches' scores above plain 'units' and therefore wins.
    """
    m = intent.get("match") or {}
    total = 0

    all_of = m.get("all_of") or []
    for group in all_of:
        if not group_hit(question, group):
            return 0
        total += 1

    any_of = m.get("any_of")
    if any_of:
        hits = sum(1 for t in any_of if t.lower() in question)
        if hits == 0:
            return 0
        total += hits

    if not all_of and not any_of:
        return 0
    return total


# ------------------------------------------------------------------ periods

def data_max_date(con) -> date:
    """
    Anchor for all relative dates. See the module docstring: using
    today's date against a dataset that ends two months ago returns
    zero rows and reads as a broken pipeline.
    """
    try:
        return con.execute("SELECT max(event_date_ist) FROM fct_sales").fetchone()[0]
    except duckdb.Error:
        return date.today()


MONTHS = {m.lower(): i for i, m in enumerate(calendar.month_name) if m}
MONTHS.update({m.lower(): i for i, m in enumerate(calendar.month_abbr) if m})


def month_window(y: int, m: int) -> tuple[date, date]:
    return date(y, m, 1), date(y, m, calendar.monthrange(y, m)[1])


def resolve_date_range(question: str, anchor: date) -> tuple[date, date, str]:
    """Map a time phrase onto an explicit window. Returns (from, to, label)."""
    # "june 2026", "in march 2025"
    mm = re.search(r"\b(" + "|".join(MONTHS) + r")\w*\s+(\d{4})\b", question)
    if mm:
        y, m = int(mm.group(2)), MONTHS[mm.group(1)]
        f, t = month_window(y, m)
        return f, t, f"{calendar.month_name[m]} {y}"

    if "last 7 days" in question or "last week" in question:
        return anchor - timedelta(days=6), anchor, "last 7 days"
    if "last 30 days" in question:
        return anchor - timedelta(days=29), anchor, "last 30 days"
    if "last 90 days" in question:
        return anchor - timedelta(days=89), anchor, "last 90 days"

    if "last month" in question or "previous month" in question:
        first_of_anchor = anchor.replace(day=1)
        prev_end = first_of_anchor - timedelta(days=1)
        # The shipped data ends on a month boundary, so the anchor month
        # is itself complete and IS the last complete month.
        if anchor == date(anchor.year, anchor.month, calendar.monthrange(anchor.year, anchor.month)[1]):
            f, t = month_window(anchor.year, anchor.month)
            return f, t, f"{calendar.month_name[anchor.month]} {anchor.year}"
        f, t = month_window(prev_end.year, prev_end.month)
        return f, t, f"{calendar.month_name[prev_end.month]} {prev_end.year}"

    if "this month" in question:
        f, t = month_window(anchor.year, anchor.month)
        return f, min(t, anchor), f"{calendar.month_name[anchor.month]} {anchor.year}"

    if "last year" in question:
        return date(anchor.year - 1, 1, 1), date(anchor.year - 1, 12, 31), f"calendar {anchor.year - 1}"

    if "all time" in question or "whole period" in question or "everything" in question:
        return date(2000, 1, 1), anchor, "the whole period"

    # Default: the last complete fiscal quarter.
    f, t, label = resolve_fiscal_quarter(question, anchor)
    fy_start = fiscal_quarter_bounds(f, t)
    return fy_start[0], fy_start[1], label


def fiscal_quarter_bounds(fy: str, fq: str) -> tuple[date, date]:
    """FY runs April-March. FY27-Q1 = Apr-Jun 2026."""
    end_year = 2000 + int(fy[2:])          # FY27 -> 2027
    q = int(fq[1:])
    start_month = 4 + 3 * (q - 1)
    year = end_year - 1 if start_month >= 4 else end_year
    if start_month > 12:
        start_month -= 12
        year = end_year
    start = date(year, start_month, 1)
    em = start_month + 2
    ey = year
    if em > 12:
        em -= 12
        ey += 1
    return start, date(ey, em, calendar.monthrange(ey, em)[1])


def resolve_fiscal_quarter(question: str, anchor: date) -> tuple[str, str, str]:
    """Returns (fiscal_year, fiscal_quarter, label)."""
    # Explicit: "FY26 Q3", "fy26-q3"
    m = re.search(r"\bfy\s*(\d{2})\D{0,3}q([1-4])\b", question)
    if m:
        fy, fq = f"FY{m.group(1)}", f"Q{m.group(2)}"
        return fy, fq, f"{fy}-{fq}"

    # Derive the fiscal quarter containing the anchor date.
    fy_end_year = anchor.year + 1 if anchor.month >= 4 else anchor.year
    q = ((anchor.month - 4) % 12) // 3 + 1
    fy, fq = f"FY{str(fy_end_year)[-2:]}", f"Q{q}"

    if "previous quarter" in question or ("last quarter" in question and "complete" not in question):
        # The anchor quarter is complete only if the anchor is its final day.
        qs, qe = fiscal_quarter_bounds(fy, fq)
        if anchor < qe:
            q -= 1
            if q == 0:
                q = 4
                fy_end_year -= 1
            fy, fq = f"FY{str(fy_end_year)[-2:]}", f"Q{q}"
    return fy, fq, f"{fy}-{fq}"


# ------------------------------------------------------------------ running

def print_blocked(intent: dict) -> int:
    b = intent["blocked"]
    print(RULE)
    print(f"  {intent['label']}")
    print(f"  NOT ANSWERABLE from these feeds - catalogue {b['catalogue']}")
    print(RULE)
    print()
    for line in b["reason"]:
        print(f"  {line}" if line else "")
    print()
    if b.get("proof"):
        print("  Runnable proof of the above:")
        print(f"    python3 scripts/run_query.py {b['proof']}")
        print()
    print(f"  Full entry: docs/kpi_catalogue.md ({b['catalogue']})")
    print()
    print("  No number is returned, deliberately. A plausible figure here")
    print("  would be worse than no figure.")
    return 3


def answer(question_raw: str, db: str, dry_run: bool) -> int:
    intents = json.loads(INTENTS_PATH.read_text())["intents"]
    question = normalise(question_raw)

    # BLOCKED INTENTS WIN TIES, and this is the most important line in the
    # router. If a question names a concept the data cannot support -
    # "by carrier", "trips", "cycle time", "order net" - then answering
    # some nearby question instead is precisely the confidently-wrong
    # behaviour this whole design exists to avoid.
    #
    # Both cases were real. "excursion rate by carrier" tied with
    # excursion-by-month and, being listed later, silently lost - so it
    # returned a real number for a question nobody asked. "chilled trips
    # breached" scored HIGHER on the by-month intent (three keyword hits
    # against two) and lost outright, despite "trips" being the one word
    # that makes it unanswerable. Ranking by score alone is not enough:
    # a blocked match is a statement about the question, not a weaker
    # answer to it.
    ranked = sorted(
        ((score(question, i), i) for i in intents),
        key=lambda t: (t[0] > 0 and bool(t[1].get("blocked")), t[0]),
        reverse=True,
    )
    best_score, best = ranked[0]

    if best_score == 0:
        print(f'  I do not have a defined metric for: "{question_raw}"')
        print()
        print("  I only answer questions someone has defined in the KPI")
        print("  catalogue, so I cannot guess. What I do know:")
        print()
        for i in intents:
            mark = "  (not answerable - will explain why)" if i.get("blocked") else ""
            print(f"    - {i['label']}{mark}")
        print()
        print("  Full definitions: docs/kpi_catalogue.md")
        return 4

    if best.get("blocked"):
        return print_blocked(best)

    con = duckdb.connect(db, read_only=False)
    anchor = data_max_date(con)
    con.close()

    params: dict[str, str] = {}
    label = "the whole period"
    period = best.get("period")
    if period:
        if period["style"] == "fiscal_quarter":
            fy, fq, label = resolve_fiscal_quarter(question, anchor)
            params[period["params"][0]] = fy
            params[period["params"][1]] = fq
        else:
            f, t, label = resolve_date_range(question, anchor)
            params[period["params"][0]] = str(f)
            params[period["params"][1]] = str(t)

    # Optional grouping, where the query supports it.
    for gb, terms in (best.get("group_by_from_question") or {}).items():
        if any(t in question for t in terms):
            params["group_by"] = gb
            break

    print(RULE)
    print(f"  Question   : {question_raw}")
    print(f"  Metric     : {best['label']}  [{', '.join(best.get('kpi', []))}]")
    print(f"  Period     : {label}")
    print(f"  Query      : {best['query']}")
    print(f"  Data as of : {anchor}   (relative dates anchor here, not to today)")
    if best.get("caveat"):
        print(f"  Caveat     : {best['caveat']}")
    print(RULE)

    cmd = [sys.executable, str(REPO_ROOT / "scripts" / "run_query.py"), best["query"], "--db", db]
    for k, v in params.items():
        cmd += ["-p", f"{k}={v}"]

    print()
    print("  Reproduce this exactly:")
    print("    " + " ".join(cmd[1:]).replace(str(REPO_ROOT) + "/", ""))
    print()

    # The CFO's condition: show the SQL that will run, every time.
    sql = (REPO_ROOT / best["query"]).read_text()
    body = "\n".join(
        l for l in sql.splitlines()
        if l.strip() and not l.strip().startswith("--")
    )
    print("  SQL:")
    for line in body.splitlines():
        print(f"    {line}")
    print()

    if dry_run:
        print("  --dry-run set, not executing.")
        return 0

    print(RULE)
    # Flush before handing stdout to the child. Python block-buffers when
    # stdout is a pipe or file rather than a terminal, so without this the
    # child's RESULTS appear before this process's header and SQL - which
    # for a tool whose entire promise is "here is the query I ran, then the
    # answer" is not a cosmetic problem.
    sys.stdout.flush()
    return subprocess.call(cmd)


def main() -> int:
    p = argparse.ArgumentParser(
        description="Ask the warehouse a question in plain English.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("question", nargs="*", help="The question, in plain English")
    p.add_argument("--db", default="kestrel.duckdb", help="Database (default: kestrel.duckdb)")
    p.add_argument("--dry-run", action="store_true", help="Show the SQL and the plan, do not run it")
    args = p.parse_args()

    if not Path(args.db).exists():
        print(f"ERROR: database {args.db} not found.", file=sys.stderr)
        print("Build it first:  python3 scripts/run_pipeline.py", file=sys.stderr)
        return 2

    if args.question:
        return answer(" ".join(args.question), args.db, args.dry_run)

    print("Ask a question, or blank line to quit. Everything shows its SQL.")
    print('e.g. "gross sales by channel last quarter"\n')
    while True:
        try:
            q = input("ask> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if not q:
            return 0
        answer(q, args.db, args.dry_run)
        print()


if __name__ == "__main__":
    sys.exit(main())
