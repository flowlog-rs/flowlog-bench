#!/usr/bin/env python3
"""FlowLog-vs-Souffle perf charts: execution time + peak RSS.

Reads a benchmark CSV (raw 26-column sweep output OR the curated
docs/historical/perf-snapshot.csv schema) and writes two figures next
to it:

  <csv_stem>-time.{pdf,svg}     execution time, log scale, with per-pair
                                speedup annotations
  <csv_stem>-memory.{pdf,svg}   peak RSS in GiB, linear scale

Rows are sorted by speedup (Souffle / FlowLog) so the strongest wins
read left-to-right. Both figures share the row set, so the i-th bar in
one matches the i-th bar in the other.

Usage:
    python3 plot/plot_perf.py                       # default CSV
    python3 plot/plot_perf.py path/to/results.csv
"""

import csv
import math
import pathlib
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.ticker import LogLocator, NullLocator

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_CSV = REPO_ROOT / "docs" / "historical" / "perf-snapshot.csv"

FLOWLOG_BLUE = "#1F6FEB"
SOUFFLE_AMBER = "#D97706"
TEXT_DARK = "#1F2328"
TEXT_MUTED = "#57606A"
GRID_FAINT = "#D0D7DE"

BAR_WIDTH = 0.38
EMPTY_CELLS = {"n/a", "na", "-", ""}

plt.rcParams.update({
    "axes.edgecolor": GRID_FAINT,
    "axes.linewidth": 0.8,
    "axes.labelcolor": TEXT_DARK,
    "xtick.color": TEXT_MUTED,
    "ytick.color": TEXT_MUTED,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "savefig.facecolor": "white",
    "figure.facecolor": "white",
})


def _pick(row, *names):
    """First non-empty cell among `names`, or None."""
    for n in names:
        v = (row.get(n) or "").strip()
        if v and v.lower() not in EMPTY_CELLS:
            return v
    return None


def load_rows(src):
    """Parse the CSV. Accepts both the raw sweep and curated snapshot
    schemas. Drops rows missing time OR memory on either engine — both
    figures share the row set."""
    rows = []
    for r in csv.DictReader(src.open()):
        fl_t = _pick(r, "Compiler_Exec_s", "Compiler_Exec")
        su_t = _pick(r, "Souffle_Total_s", "Souffle_Total")
        fl_m = _pick(r, "Compiler_PeakRss_MB")
        su_m = _pick(r, "Souffle_PeakRss_MB")
        if not (fl_t and su_t and fl_m and su_m):
            continue
        try:
            fl_t, su_t = float(fl_t), float(su_t)
            fl_m, su_m = float(fl_m), float(su_m)
        except ValueError:
            continue
        if fl_t <= 0 or su_t <= 0:
            continue
        rows.append({
            "label": f"{r['Program']}/{r['Dataset']}",
            "fl_t": fl_t, "su_t": su_t,
            "fl_m": fl_m, "su_m": su_m,
        })
    rows.sort(key=lambda r: r["su_t"] / r["fl_t"], reverse=True)
    return rows


def _bar_chart(stem, labels, fl, su, *, ylabel, title, log=False, decorate=None):
    """Render one paired-bar chart and save as <stem>.{pdf,svg}."""
    n = len(labels)
    x = np.arange(n)
    fig, ax = plt.subplots(figsize=(max(15, n * 0.55), 6))

    ax.bar(x - BAR_WIDTH / 2, fl, BAR_WIDTH, label="FlowLog (compiler)",
           color=FLOWLOG_BLUE, zorder=3)
    ax.bar(x + BAR_WIDTH / 2, su, BAR_WIDTH, label="Soufflé (compiled)",
           color=SOUFFLE_AMBER, zorder=3)

    if log:
        ax.set_yscale("log")
        ax.yaxis.set_major_locator(LogLocator(base=10, numticks=12))
        ax.yaxis.set_minor_locator(NullLocator())

    ax.set_ylabel(ylabel, fontsize=11)
    ax.set_title(title, loc="left", color=TEXT_DARK, fontsize=12,
                 fontweight="600", pad=18)
    ax.grid(True, axis="y", color=GRID_FAINT, linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    ax.legend(loc="upper right", frameon=False, fontsize=10)
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=45, ha="right", fontsize=9)

    if decorate:
        decorate(ax)

    fig.tight_layout()
    for ext in ("pdf", "svg"):
        fig.savefig(stem.with_suffix(f".{ext}"), bbox_inches="tight")
    plt.close(fig)


def render_time(rows, stem):
    labels = [r["label"] for r in rows]
    fl = np.array([r["fl_t"] for r in rows])
    su = np.array([r["su_t"] for r in rows])
    speedups = su / fl

    n = len(rows)
    geomean = math.exp(np.mean(np.log(speedups)))
    wins = int((speedups > 1).sum())
    title = (f"FlowLog vs Soufflé — execution time · {n} workloads · "
             f"FlowLog wins {wins}/{n} · geomean {geomean:.2f}× · "
             f"range {speedups.min():.2f}× → {speedups.max():.2f}×")

    def annotate(ax):
        for i, (a, b, s) in enumerate(zip(fl, su, speedups)):
            ax.text(i, max(a, b) * 1.18, f"{s:.1f}×",
                    ha="center", va="bottom", fontsize=8.5,
                    color=FLOWLOG_BLUE, fontweight="600")
        # Headroom so the speedup labels don't collide with the title.
        ax.set_ylim(top=ax.get_ylim()[1] * 2.4)

    _bar_chart(stem, labels, fl, su,
               ylabel="Execution time (s, log scale)",
               title=title, log=True, decorate=annotate)


def render_memory(rows, stem):
    labels = [r["label"] for r in rows]
    fl = np.array([r["fl_m"] for r in rows]) / 1024
    su = np.array([r["su_m"] for r in rows]) / 1024
    title = (f"FlowLog vs Soufflé — peak memory · {len(rows)} workloads · "
             f"lower is better")
    _bar_chart(stem, labels, fl, su,
               ylabel="Peak RSS (GiB)", title=title)


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    src = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_CSV
    if not src.exists():
        print(f"input not found: {src}", file=sys.stderr)
        return 1

    rows = load_rows(src)
    if not rows:
        print(f"no usable rows in {src} — both Compiler_* and Souffle_* "
              f"time + memory cells are required", file=sys.stderr)
        return 1

    time_stem = src.parent / f"{src.stem}-time"
    mem_stem = src.parent / f"{src.stem}-memory"
    render_time(rows, time_stem)
    render_memory(rows, mem_stem)
    print(f"wrote {time_stem}.{{pdf,svg}} and {mem_stem}.{{pdf,svg}} "
          f"({len(rows)} workloads)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
