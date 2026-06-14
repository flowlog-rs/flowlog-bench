#!/usr/bin/env python3
"""Paper-ready per-program perf figures: execution time + peak memory.

Unlike plot_perf.py (which packs every workload into one strip), this draws
ONE figure per program group — the workloads a paper actually argues about —
as two stacked panels sharing the x-axis: execution time (top) and peak RSS
(bottom). No title (the LaTeX caption carries it), colorblind-safe palette,
large fonts that survive column-width downscaling.

    python3 plot/plot_paper.py <csv> --group doop
    python3 plot/plot_paper.py <csv> --group polonius_int --width 6

Writes <csv_stem>-<group>-paper.{pdf,png} next to the CSV.
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

# Okabe-Ito colorblind-safe palette (also distinct in grayscale).
ENGINES = [
    ("flowlog", "FlowLog", "#0072B2", ("Compiler_Exec", "Compiler_Total"), "Compiler_PeakRss_MB"),
    ("souffle", "Soufflé", "#E69F00", ("Souffle_Total",), "Souffle_PeakRss_MB"),
    ("ddlog",   "DDlog",   "#009E73", ("Ddlog_Total",),   "Ddlog_PeakRss_MB"),
    ("ascent",  "Ascent",  "#CC79A7", ("Ascent_Total",),  "Ascent_PeakRss_MB"),
]

TEXT_DARK = "#1F2328"
TEXT_MUTED = "#57606A"
GRID_FAINT = "#D7DCE0"
MISS = "#B0B0B0"
EMPTY = {"n/a", "na", "-", ""}

plt.rcParams.update({
    "font.size": 12,
    "axes.edgecolor": TEXT_MUTED,
    "axes.linewidth": 0.8,
    "axes.labelcolor": TEXT_DARK,
    "xtick.color": TEXT_DARK,
    "ytick.color": TEXT_MUTED,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "savefig.facecolor": "white",
    "figure.facecolor": "white",
    "pdf.fonttype": 42,   # editable text in the PDF (TrueType, not Type-3)
    "ps.fonttype": 42,
})


def _num(row, *names):
    for n in names:
        v = (row.get(n) or "").strip()
        if v and v.lower() not in EMPTY:
            try:
                f = float(v)
                if f > 0:
                    return f
            except ValueError:
                pass
    return None


def load_group(src, group):
    """Rows for one program, sorted by FlowLog time ascending (small→large
    reads as a scaling trend). Each row carries per-engine time + mem (GiB)."""
    out = []
    for r in csv.DictReader(src.open()):
        if r["Program"] != group:
            continue
        rec = {"label": r["Dataset"], "t": {}, "m": {}}
        for key, _, _, tcols, mcol in ENGINES:
            t = _num(r, *tcols)
            m = _num(r, mcol)
            if t is not None:
                rec["t"][key] = t
            if m is not None:
                rec["m"][key] = m / 1024.0
        if "flowlog" in rec["t"]:
            out.append(rec)
    out.sort(key=lambda r: r["t"]["flowlog"])
    return out


def _geomean(xs):
    xs = [x for x in xs if x and x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float("nan")


def _panel(ax, rows, key, ylabel, *, annotate, headroom):
    n = len(rows)
    k = len(ENGINES)
    x = np.arange(n)
    group_w = 0.80
    bar_w = group_w / k
    offsets = (np.arange(k) - (k - 1) / 2) * bar_w

    # Explicit log y-limits from the data, so a stray annotation can never
    # stretch the panel across phantom decades and a "tight" save can't
    # blow the canvas up. Headroom on top leaves room for the ×-labels.
    allv = [v for r in rows for v in r[key].values() if v and v > 0]
    lo, hi = min(allv), max(allv)
    ax.set_yscale("log")
    ax.set_ylim(10 ** math.floor(math.log10(lo)), hi * headroom)
    trans = blended_transform_factory(ax.transData, ax.transAxes)

    base = [r[key].get("flowlog") for r in rows]
    for (ekey, label, color, _, _), off in zip(ENGINES, offsets):
        vals = np.array([r[key].get(ekey, np.nan) for r in rows], float)
        ax.bar(x + off, vals, bar_w, label=label, color=color,
               edgecolor="white", linewidth=0.3, zorder=3)
        if not annotate:
            continue
        for i, v in enumerate(vals):
            if ekey == "flowlog":
                continue
            if not np.isfinite(v):
                # engine absent (e.g. DDlog timeout) — mark just above axis.
                ax.text(i + off, 0.02, "T/O", transform=trans, rotation=90,
                        ha="center", va="bottom", fontsize=6.5, color=MISS)
                continue
            b = base[i]
            if not b:
                continue
            s = v / b
            ax.text(i + off, v * 1.05, f"{s:.0f}×" if s >= 10 else f"{s:.1f}×",
                    ha="center", va="bottom", fontsize=6.8, rotation=90,
                    color=color, fontweight="600")

    ax.yaxis.set_major_locator(LogLocator(base=10, numticks=12))
    ax.yaxis.set_minor_locator(NullLocator())
    ax.set_ylabel(ylabel, fontsize=12.5)
    ax.grid(True, axis="y", color=GRID_FAINT, linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    ax.set_xticks(x)
    ax.set_xlim(-0.5, n - 0.5)


def render(rows, stem, group, width):
    fig, (ax_t, ax_m) = plt.subplots(
        2, 1, figsize=(width, 6.2), sharex=True,
        gridspec_kw={"hspace": 0.12})

    # Time needs tall headroom (rotated ×-labels above the biggest bar);
    # memory's ratios are smaller, so it reads tighter with less.
    _panel(ax_t, rows, "t", "Execution time (s)", annotate=True, headroom=6.0)
    _panel(ax_m, rows, "m", "Peak memory (GiB)", annotate=True, headroom=3.0)

    ax_m.set_xticklabels([r["label"] for r in rows], rotation=40,
                         ha="right", fontsize=10.5)
    ax_t.tick_params(labelbottom=False)

    # One legend above both panels.
    handles, labels = ax_t.get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=len(ENGINES),
               frameon=False, fontsize=11.5, bbox_to_anchor=(0.5, 1.005),
               columnspacing=1.6, handlelength=1.3)

    # Geomean-vs-FlowLog footnote per comparison engine (time panel).
    gm = []
    for ekey, label, color, _, _ in ENGINES[1:]:
        ratios = [r["t"][ekey] / r["t"]["flowlog"]
                  for r in rows if ekey in r["t"] and "flowlog" in r["t"]]
        if ratios:
            gm.append(f"{label} {_geomean(ratios):.1f}×")
    ax_t.text(0.012, 0.97, "geomean vs FlowLog:  " + "   ".join(gm),
              transform=ax_t.transAxes, ha="left", va="top",
              fontsize=9.5, color=TEXT_MUTED)

    fig.subplots_adjust(top=0.93, bottom=0.16, left=0.085, right=0.99)
    for ext in ("pdf", "png"):
        fig.savefig(f"{stem}.{ext}", bbox_inches="tight", dpi=200)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--group", required=True,
                    help="Program to plot (e.g. doop, polonius_int)")
    ap.add_argument("--width", type=float, default=None,
                    help="Figure width in inches (default: scaled to #datasets)")
    args = ap.parse_args()

    src = pathlib.Path(args.csv)
    if not src.exists():
        print(f"input not found: {src}", file=sys.stderr)
        return 1
    rows = load_group(src, args.group)
    if not rows:
        print(f"no rows for program {args.group!r} in {src}", file=sys.stderr)
        return 1

    width = args.width or max(5.0, 1.0 + 0.62 * len(rows))
    stem = src.parent / f"{src.stem}-{args.group}-paper"
    render(rows, stem, args.group, width)
    print(f"wrote {stem.name}.{{pdf,png}} ({len(rows)} datasets, width={width:.1f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
