#!/usr/bin/env python3
"""FlowLog-vs-others perf charts: execution time + peak RSS.

Reads a benchmark CSV (raw 26-column sweep output OR the curated
docs/historical/perf-snapshot.csv schema) and writes two figures next
to it:

  <csv_stem>-time.{pdf,svg,png}     execution time, log scale, with
                                    per-pair slowdown annotations
  <csv_stem>-memory.{pdf,svg,png}   peak RSS in GiB

FlowLog is always the baseline (first series). Add comparison engines
with --engines; every engine after the first is drawn as an extra bar
group and annotated with its slowdown vs FlowLog.

  --engines flowlog,souffle          (default) two-bar FlowLog vs Soufflé
  --engines flowlog,souffle,ddlog    add DDlog as a third series
  --engines flowlog,ddlog            FlowLog vs DDlog only
  --engines flowlog,souffle,ddlog,ascent   all four engines

Rows are sorted by the LAST engine's slowdown (engine_time / flowlog_time)
so the widest gaps read left-to-right. A row is kept only if every
selected engine has both a time and a memory cell, so the two figures
share an identical row set.

Usage:
    python3 plot/plot_perf.py                                   # default CSV
    python3 plot/plot_perf.py results/benchmark/comparison_results.csv
    python3 plot/plot_perf.py <csv> --engines flowlog,souffle,ddlog
"""

import argparse
import csv
import math
import pathlib
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.ticker import LogLocator, NullLocator
from matplotlib.transforms import blended_transform_factory

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_CSV = REPO_ROOT / "docs" / "historical" / "perf-snapshot.csv"

TEXT_DARK = "#1F2328"
TEXT_MUTED = "#57606A"
GRID_FAINT = "#D0D7DE"

# Per-engine spec: display label, bar color, candidate time columns (first
# non-empty wins), and peak-RSS column. FlowLog keeps its historical
# Compiler_Exec preference and falls back to Compiler_Total; the comparison
# engines report a single total.
ENGINES = {
    "flowlog": {
        "label": "FlowLog (compiler)", "color": "#1F6FEB",
        "time": ("Compiler_Exec_s", "Compiler_Exec", "Compiler_Total"),
        "mem": "Compiler_PeakRss_MB",
    },
    "souffle": {
        "label": "Soufflé (compiled)", "color": "#D97706",
        "time": ("Souffle_Total_s", "Souffle_Total"),
        "mem": "Souffle_PeakRss_MB",
    },
    "ddlog": {
        "label": "DDlog (compiled)", "color": "#1A7F37",
        "time": ("Ddlog_Total_s", "Ddlog_Total"),
        "mem": "Ddlog_PeakRss_MB",
    },
    "ascent": {
        "label": "Ascent (compiled)", "color": "#8250DF",
        "time": ("Ascent_Total_s", "Ascent_Total"),
        "mem": "Ascent_PeakRss_MB",
    },
}

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


def load_rows(src, engines):
    """Parse the CSV for the selected engines. The BASELINE (first engine)
    is required per row; a comparison engine missing its time/memory cell is
    kept as absent (drawn later as a red ✗, not a bar) rather than dropping
    the whole row. Rows are sorted by the last engine's slowdown vs the
    baseline, descending; rows where the last engine is absent sort to the
    end."""
    base = engines[0]
    rows = []
    for r in csv.DictReader(src.open()):
        rec = {"label": f"{r['Program']}/{r['Dataset']}", "t": {}, "m": {}}
        for e in engines:
            spec = ENGINES[e]
            t = _pick(r, *spec["time"])
            m = _pick(r, spec["mem"])
            try:
                t, m = float(t), float(m)
            except (TypeError, ValueError):
                continue
            if t <= 0 or m <= 0:
                continue
            rec["t"][e], rec["m"][e] = t, m
        if base in rec["t"]:          # baseline present → keep the row
            rows.append(rec)
    last = engines[-1]
    rows.sort(key=lambda r: (r["t"][last] / r["t"][base]) if last in r["t"]
              else -1.0, reverse=True)
    return rows


def _bar_chart(stem, labels, engines, series, *, ylabel, title, log, decorate):
    """Render one grouped-bar chart over N engine series; save pdf/svg/png."""
    n = len(labels)
    k = len(engines)
    x = np.arange(n)
    # Total group width ~0.82; each engine gets an equal slice, centered.
    group_w = 0.82
    bar_w = group_w / k
    offsets = (np.arange(k) - (k - 1) / 2) * bar_w

    fig, ax = plt.subplots(figsize=(max(15, n * (0.45 + 0.13 * k)), 6))
    for e, off in zip(engines, offsets):
        ax.bar(x + off, series[e], bar_w, label=ENGINES[e]["label"],
               color=ENGINES[e]["color"], zorder=3)

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
        decorate(ax, offsets, bar_w)

    fig.tight_layout()
    for ext in ("pdf", "svg", "png"):
        fig.savefig(stem.with_suffix(f".{ext}"), bbox_inches="tight", dpi=140)
    plt.close(fig)


def _geomean(a):
    a = np.asarray(a, float)
    a = a[np.isfinite(a) & (a > 0)]
    return math.exp(np.mean(np.log(a))) if a.size else float("nan")


def _mark_missing(ax, x):
    """Stamp a red ✗ just above the x-axis at an absent engine's bar slot
    (e.g. ddlog OOM). y is in axes fraction so it sits at the baseline
    regardless of the data scale."""
    trans = blended_transform_factory(ax.transData, ax.transAxes)
    ax.plot([x], [0.018], marker="x", color="#CF222E", markersize=9,
            markeredgewidth=2.4, transform=trans, zorder=6, clip_on=False)


def _series(rows, key, engines):
    """engine -> array of values, np.nan where that engine is absent."""
    return {e: np.array([r[key].get(e, np.nan) for r in rows]) for e in engines}


def render_time(rows, stem, engines):
    base = engines[0]
    labels = [r["label"] for r in rows]
    series = _series(rows, "t", engines)
    fl = series[base]
    comps = engines[1:]
    speed = {e: series[e] / fl for e in comps}

    n = len(rows)
    bits = ", ".join(f"{_geomean(speed[e]):.2f}× ({ENGINES[e]['label'].split()[0]})"
                     for e in comps)
    names = " vs ".join(ENGINES[e]["label"].split()[0] for e in engines)
    title = f"{names} — execution time · {n} workloads · FlowLog faster by geomean {bits}"

    def annotate(ax, offsets, bar_w):
        off = dict(zip(engines, offsets))
        # 3+ engines pack the bars tightly → rotate labels vertical so a
        # "2.3×" doesn't spill onto the neighbouring bar.
        rot = 0 if len(engines) < 3 else 90
        fs = 8 if len(engines) < 3 else 7.5
        for i in range(n):
            for e in comps:
                s = speed[e][i]
                if not np.isfinite(s):          # engine absent → red ✗
                    _mark_missing(ax, i + off[e])
                    continue
                txt = f"{s:.1f}×" if s < 10 else f"{s:.0f}×"
                ax.text(i + off[e], series[e][i] * 1.06, txt,
                        ha="center", va="bottom", fontsize=fs, rotation=rot,
                        color=ENGINES[e]["color"], fontweight="600")
        ax.set_ylim(top=ax.get_ylim()[1] * (3.0 if rot else 2.2))

    _bar_chart(stem, labels, engines, series,
               ylabel="Execution time (s, log scale)",
               title=title, log=True, decorate=annotate)


def render_memory(rows, stem, engines):
    base = engines[0]
    labels = [r["label"] for r in rows]
    series = {e: v / 1024 for e, v in _series(rows, "m", engines).items()}
    comps = engines[1:]
    ratio = {e: series[e] / series[base] for e in comps}
    names = " vs ".join(ENGINES[e]["label"].split()[0] for e in engines)
    # Log scale once any engine's range spans >1 order of magnitude (ddlog).
    finite = np.concatenate([s[np.isfinite(s)] for s in series.values()])
    spread = finite.max() / finite.min()
    log = spread > 15
    scale = "log scale" if log else "linear"
    title = (f"{names} — peak memory · {len(rows)} workloads · "
             f"GiB, {scale} · lower is better")

    n = len(rows)
    rot = 0 if len(engines) < 3 else 90
    fs = 8 if len(engines) < 3 else 7.5

    def annotate(ax, offsets, bar_w):
        # Label each comparison engine's bar with its peak-RSS ratio vs
        # FlowLog (Soufflé < 1×, DDlog ~6×); absent engines get a red ✗.
        off = dict(zip(engines, offsets))
        for i in range(n):
            for e in comps:
                v = ratio[e][i]
                if not np.isfinite(v):
                    _mark_missing(ax, i + off[e])
                    continue
                txt = f"{v:.1f}×" if v < 10 else f"{v:.0f}×"
                ax.text(i + off[e], series[e][i] * 1.04, txt,
                        ha="center", va="bottom", fontsize=fs, rotation=rot,
                        color=ENGINES[e]["color"], fontweight="600")
        ax.set_ylim(top=ax.get_ylim()[1] * ((2.5 if log else 1.35) if rot
                                            else (1.8 if log else 1.12)))

    _bar_chart(stem, labels, engines, series,
               ylabel=f"Peak RSS (GiB{', log scale' if log else ''})",
               title=title, log=log, decorate=annotate)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="?", default=str(DEFAULT_CSV),
                    help="benchmark CSV (default: docs/historical/perf-snapshot.csv)")
    ap.add_argument("--engines", default="flowlog,souffle",
                    help="comma list; first is the baseline. "
                         "Choices: flowlog,souffle,ddlog,ascent. "
                         "Default: flowlog,souffle")
    args = ap.parse_args()

    engines = [e.strip().lower() for e in args.engines.split(",") if e.strip()]
    bad = [e for e in engines if e not in ENGINES]
    if bad:
        print(f"unknown engine(s): {bad} — choose from {list(ENGINES)}",
              file=sys.stderr)
        return 2
    if len(engines) < 2:
        print("need at least two engines (baseline + one comparison)",
              file=sys.stderr)
        return 2
    if engines[0] != "flowlog":
        print("note: first engine is treated as the baseline", file=sys.stderr)

    src = pathlib.Path(args.csv)
    if not src.exists():
        print(f"input not found: {src}", file=sys.stderr)
        return 1

    rows = load_rows(src, engines)
    if not rows:
        print(f"no usable rows in {src} — every selected engine needs a "
              f"time + memory cell per row", file=sys.stderr)
        return 1

    tag = "" if engines == ["flowlog", "souffle"] else "-" + "".join(
        e[:2] for e in engines)
    time_stem = src.parent / f"{src.stem}{tag}-time"
    mem_stem = src.parent / f"{src.stem}{tag}-memory"
    render_time(rows, time_stem, engines)
    render_memory(rows, mem_stem, engines)
    print(f"wrote {time_stem.name}.{{pdf,svg,png}} and "
          f"{mem_stem.name}.{{pdf,svg,png}} ({len(rows)} workloads, "
          f"engines: {','.join(engines)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
