#!/usr/bin/env python3
"""Merge the fresh flowlog-only CSV with the PR#14 4-engine baseline into
results/benchmark/REPORT.md — one row per pair, four engines, time + RSS.

Run automatically after cross_engine.sh by the detached overnight wrapper;
safe to re-run by hand at any time.
"""
import csv
import os
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.abspath(__file__))
NEW_CSV = os.path.join(ROOT, "benchmark", "comparison_results.csv")
BASE_CSV = os.path.join(ROOT, "pr14-baseline.csv")
OUT_MD = os.path.join(ROOT, "benchmark", "REPORT.md")


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return {(r["Program"], r["Dataset"]): r for r in csv.DictReader(f)}


def num(row, key):
    v = (row or {}).get(key, "")
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def fmt_t(x):
    return f"{x:.1f}" if x is not None else "—"


def fmt_rss(x):
    return f"{x/1024:.1f}" if x is not None else "—"  # MB -> GB


def slowdown(x, fl):
    if x is None or fl is None or fl <= 0:
        return ""
    return f" ({x/fl:.1f}x)"


def main():
    new, base = load(NEW_CSV), load(BASE_CSV)
    pairs = list(new.keys()) + [k for k in base if k not in new]
    # Only report pairs from the rerun config: doop + polonius
    pairs = [p for p in pairs if p[0] in ("doop", "polonius_int")]
    pairs.sort()

    lines = [
        "# FlowLog rerun (main @ 6c111b729e4b) vs PR#14 baseline engines",
        "",
        f"Generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}.",
        "FlowLog: fresh run, this host, WORKERS=32, median of 3.",
        "Soufflé 2.5 / DDlog 1.2.3 / Ascent 0.8: docs/historical/"
        "sweep-20260611-4engine-w32 (PR#14), WORKERS=32, median of 3.",
        "Times in seconds (engine slowdown vs FlowLog in parens), RSS in GB.",
        "",
        "| Pair | FlowLog t | FL RSS | FL prev t | FL prev RSS | Soufflé t | Sf RSS | DDlog t | DD RSS | Ascent t | As RSS |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for prog, ds in pairs:
        n, b = new.get((prog, ds)), base.get((prog, ds))
        fl_t = num(n, "Compiler_Total")
        fl_r = num(n, "Compiler_PeakRss_MB")
        fl_prev = num(b, "Compiler_Total")
        fl_prev_r = num(b, "Compiler_PeakRss_MB")
        cells = [f"{prog}/{ds}", fmt_t(fl_t), fmt_rss(fl_r),
                 fmt_t(fl_prev), fmt_rss(fl_prev_r)]
        for eng in ("Souffle", "Ddlog", "Ascent"):
            t = num(b, f"{eng}_Total")
            r = num(b, f"{eng}_PeakRss_MB")
            cells += [fmt_t(t) + slowdown(t, fl_t), fmt_rss(r)]
        lines.append("| " + " | ".join(cells) + " |")

    fl_old = [(p, num(base.get(p), "Compiler_Total")) for p in pairs]
    lines += [
        "",
        "## FlowLog then vs now (baseline sweep ran older flowlog)",
        "",
        "| Pair | baseline FL t | new FL t | new/old |",
        "|---|---|---|---|",
    ]
    for (prog, ds), old_t in fl_old:
        new_t = num(new.get((prog, ds)), "Compiler_Total")
        ratio = (
            f"{new_t/old_t:.2f}x" if new_t is not None and old_t else "—"
        )
        lines.append(
            f"| {prog}/{ds} | {fmt_t(old_t)} | {fmt_t(new_t)} | {ratio} |"
        )

    with open(OUT_MD, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {OUT_MD} ({len(pairs)} pairs)")


if __name__ == "__main__":
    main()
