#!/usr/bin/env python3
"""
Summarise join-order variant sweeps.

Reads results/joinorder/<stem>_<dataset>.csv files (produced by
scripts/cross_joinorder.sh) and writes a single consolidated report:

    results/joinorder/SUMMARY.md

The report contains a top-level overview table (one row per (program,
dataset) — default time, fastest, slowest, speedup, # variants), followed
by per-pair details (top-3 fastest / bottom-3, default's percentile rank,
mismatch counts, plan signatures).

The same content is also printed to stdout so you can `make joinorder-summary`
without opening the file.

Usage:
    python3 scripts/joinorder_summary.py                    # all CSVs
    python3 scripts/joinorder_summary.py andersen medium    # filter substrings
    python3 scripts/joinorder_summary.py --no-write         # stdout only
"""
from __future__ import annotations

import argparse
import csv
import statistics
import sys
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
CSV_DIR = ROOT / "results/joinorder"
OUT_PATH = CSV_DIR / "SUMMARY.md"
PROG_ROOT = ROOT / "programs/oracle/flowlog"


def read_pair(csv_path: Path) -> list[dict]:
    with csv_path.open() as f:
        return list(csv.DictReader(f))


def safe_float(s: str) -> float | None:
    try:
        return float(s)
    except (ValueError, TypeError):
        return None


def gather_pair(csv_path: Path) -> dict | None:
    """Return a structured per-pair record, or None if no rows are timed."""
    rows = read_pair(csv_path)
    times: list[tuple[float, dict]] = []
    default_row: dict | None = None
    mismatches = 0
    failed = 0
    timeout_rows: list[dict] = []
    for r in rows:
        sp = r["SemanticPreserve"]
        if sp == "TIMEOUT":
            timeout_rows.append(r)
            continue
        if sp == "FAIL":
            failed += 1
            continue
        if sp == "MISMATCH":
            mismatches += 1
        t = safe_float(r["Total_s"])
        if t is None:
            failed += 1
            continue
        times.append((t, r))
        if r["Variant"] == "default":
            default_row = r
    if not times and not timeout_rows:
        return None
    times.sort(key=lambda x: x[0])
    return {
        "name": csv_path.stem,
        "rows": rows,
        "times": times,
        "default": default_row,
        "mismatches": mismatches,
        "failed": failed,
        "timeouts": len(timeout_rows),
        "timeout_rows": timeout_rows,
    }


def emit_overview_table(pairs: list[dict], out) -> None:
    """One-row-per-pair Markdown table. Time + peak RSS (MB) per cell."""
    out.write("## Overview\n\n")
    out.write("Each cell shows `time(s) / peakRSS(MB)`.\n\n")
    out.write("| Program/Dataset | #Var | T/O | Default | Fastest | Slowest | Median | Best speedup | Default rank |\n")
    out.write("|---|---:|---:|---:|---:|---:|---:|---:|---|\n")
    for p in pairs:
        times = p["times"]
        n = len(times)
        fastest_t, fastest_r = times[0]
        slowest_t, slowest_r = times[-1]
        median_t = statistics.median(t for t, _ in times)
        # Median peak RSS (each row's PeakRss_MB is itself a median over 3 runs;
        # we re-median over variants for the overview).
        rss_values = [safe_float(r["PeakRss_MB"]) for _, r in times]
        rss_values = [v for v in rss_values if v is not None]
        median_rss = statistics.median(rss_values) if rss_values else None
        fastest_rss = safe_float(fastest_r["PeakRss_MB"])
        slowest_rss = safe_float(slowest_r["PeakRss_MB"])

        default_t = safe_float(p["default"]["Total_s"]) if p["default"] else None
        default_rss = safe_float(p["default"]["PeakRss_MB"]) if p["default"] else None

        if default_t is not None and default_t > 0:
            speedup = default_t / fastest_t
            speedup_str = f"{speedup:.2f}×"
            rank = sum(1 for t, _ in times if t < default_t)
            rank_pct = rank * 100 / len(times) if len(times) else 0
            rank_str = f"{rank_pct:.0f}th pct"
            if rank_pct == 0:
                rank_str += " (best)"
            elif rank_pct == 100:
                rank_str += " (worst)"
        else:
            speedup_str = "—"
            rank_str = "—"

        def cell(t, rss):
            if t is None:
                return "—"
            if rss is None:
                return f"{t:.4f}"
            return f"{t:.4f} / {rss:.0f}"

        out.write(f"| {p['name']} | {n} | {p['timeouts']} | "
                  f"{cell(default_t, default_rss)} | "
                  f"{cell(fastest_t, fastest_rss)} | "
                  f"{cell(slowest_t, slowest_rss)} | "
                  f"{cell(median_t, median_rss)} | "
                  f"{speedup_str} | {rank_str} |\n")
    out.write("\n*Best speedup* = default time / fastest time (≥ 1× means a non-default variant beat the textual order).  \n")
    out.write("*Default rank* = percentile of default among all variants (0th = default is fastest).  \n")
    out.write("*T/O* = number of variants that hit the per-attempt timeout cap.\n\n")


def emit_pair_detail(p: dict, out) -> None:
    times = p["times"]
    name = p["name"]
    default_t = safe_float(p["default"]["Total_s"]) if p["default"] else None
    fastest_t, fastest = times[0]
    slowest_t, slowest = times[-1]
    median_t = statistics.median(t for t, _ in times)

    out.write(f"### {name}\n\n")
    out.write(f"- {len(times)} variants timed")
    if p.get("timeouts"):
        out.write(f", {p['timeouts']} timed out")
    if p["failed"]:
        out.write(f", {p['failed']} failed")
    if p["mismatches"]:
        out.write(f", **{p['mismatches']} semantic mismatches**")
    out.write("\n")
    if default_t is not None:
        default_rss = safe_float(p["default"]["PeakRss_MB"])
        rss_str = f", peak {default_rss:.0f} MB" if default_rss is not None else ""
        out.write(f"- Default: {default_t:.4f}s{rss_str}\n")
    fastest_rss = safe_float(fastest["PeakRss_MB"])
    f_rss_str = f", peak {fastest_rss:.0f} MB" if fastest_rss is not None else ""
    out.write(f"- Fastest: {fastest_t:.4f}s{f_rss_str} — `{fastest['Variant']}` (sig: `{fastest['Signature']}`)\n")
    if default_t is not None and default_t > 0:
        out.write(f"  - {default_t/fastest_t:.2f}× speedup over default\n")
    slowest_rss = safe_float(slowest["PeakRss_MB"])
    s_rss_str = f", peak {slowest_rss:.0f} MB" if slowest_rss is not None else ""
    out.write(f"- Slowest: {slowest_t:.4f}s{s_rss_str} — `{slowest['Variant']}`\n")
    if default_t is not None and default_t > 0:
        out.write(f"  - {slowest_t/default_t:.2f}× slowdown vs default\n")
    out.write(f"- Median:  {median_t:.4f}s\n")
    if default_t is not None:
        rank = sum(1 for t, _ in times if t < default_t)
        rank_pct = rank * 100 / len(times)
        out.write(f"- Default rank: {rank_pct:.0f}th percentile "
                  f"(default is faster than {100-rank_pct:.0f}% of variants)\n")
    out.write("\n**Top-3 fastest:**\n\n")
    out.write("| # | Time (s) | Peak RSS (MB) | Variant | Signature |\n|---:|---:|---:|---|---|\n")
    for i, (t, r) in enumerate(times[:3], 1):
        rss = safe_float(r["PeakRss_MB"])
        rss_s = f"{rss:.0f}" if rss is not None else "—"
        out.write(f"| {i} | {t:.4f} | {rss_s} | `{r['Variant']}` | `{r['Signature']}` |\n")
    out.write("\n**Bottom-3 slowest:**\n\n")
    out.write("| # | Time (s) | Peak RSS (MB) | Variant | Signature |\n|---:|---:|---:|---|---|\n")
    for i, (t, r) in enumerate(times[-3:], len(times) - 2):
        rss = safe_float(r["PeakRss_MB"])
        rss_s = f"{rss:.0f}" if rss is not None else "—"
        out.write(f"| {i} | {t:.4f} | {rss_s} | `{r['Variant']}` | `{r['Signature']}` |\n")
    out.write("\n")
    if p.get("timeout_rows"):
        out.write(f"**Timed out ({len(p['timeout_rows'])} variants, hit the per-attempt cap):**\n\n")
        out.write("| Peak RSS (MB) | Variant | Signature |\n|---:|---|---|\n")
        for r in p["timeout_rows"]:
            rss = safe_float(r["PeakRss_MB"])
            rss_s = f"{rss:.0f}" if rss is not None else "—"
            out.write(f"| {rss_s} | `{r['Variant']}` | `{r['Signature']}` |\n")
        out.write("\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("filters", nargs="*",
                    help="optional substring filters; pair name must contain all")
    ap.add_argument("--no-write", action="store_true",
                    help="don't write SUMMARY.md, only print to stdout")
    args = ap.parse_args()

    csvs = sorted(p for p in CSV_DIR.glob("*.csv") if p.name != "SUMMARY.md")
    if args.filters:
        csvs = [p for p in csvs if all(s in p.stem for s in args.filters)]
    if not csvs:
        print(f"No CSVs in {CSV_DIR} matching {args.filters or '*'}")
        return 1

    pairs = []
    skipped: list[str] = []
    for c in csvs:
        rec = gather_pair(c)
        if rec is None:
            skipped.append(c.stem)
            continue
        pairs.append(rec)

    buf = StringIO()
    buf.write("# Join-Order Variant Sweep — Summary\n\n")
    if skipped:
        buf.write(f"_Skipped {len(skipped)} pairs with no timed rows: "
                  f"{', '.join(skipped)}._\n\n")
    if not pairs:
        buf.write("(No timed pairs.)\n")
    else:
        emit_overview_table(pairs, buf)
        buf.write("## Per-pair detail\n\n")
        for p in pairs:
            emit_pair_detail(p, buf)

    text = buf.getvalue()
    sys.stdout.write(text)
    if not args.no_write:
        OUT_PATH.write_text(text)
        print(f"\n[wrote {OUT_PATH.relative_to(ROOT)}]", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
