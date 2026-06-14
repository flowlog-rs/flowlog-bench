#!/usr/bin/env python3
"""Paper-ready execution-time figure for the program groups a paper argues
about (e.g. DOOP + Polonius).

Unlike plot_perf.py (which packs every workload into one strip), this draws
the selected groups as side-by-side sub-panels sharing one log y-axis —
panel widths track each group's dataset count so bar widths match, a gap +
per-panel header keep the groups distinct. No title (the LaTeX caption
carries it), colorblind-safe Okabe-Ito palette, embedded TrueType in the PDF.

    python3 plot/plot_paper.py <csv> --groups polonius_int,doop
    python3 plot/plot_paper.py <csv> --groups doop --width 13

Writes <csv_stem>-<groups>-paper.{pdf,png} next to the CSV.
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


PROG_DISPLAY = {"doop": "DOOP", "polonius_int": "Polonius"}


def _panel(ax, rows, key, *, ylim, show_y, ylabel, annotate, xfs):
    """One program's grouped bars on a shared log y-axis."""
    n = len(rows)
    k = len(ENGINES)
    x = np.arange(n)
    group_w = 0.80
    bar_w = group_w / k
    offsets = (np.arange(k) - (k - 1) / 2) * bar_w

    ax.set_yscale("log")
    ax.set_ylim(*ylim)
    trans = blended_transform_factory(ax.transData, ax.transAxes)

    base = [r[key].get("flowlog") for r in rows]
    for (ekey, label, color, _, _), off in zip(ENGINES, offsets):
        vals = np.array([r[key].get(ekey, np.nan) for r in rows], float)
        ax.bar(x + off, vals, bar_w, label=label, color=color,
               edgecolor="white", linewidth=0.3, zorder=3)
        for i, v in enumerate(vals):
            if ekey == "flowlog":
                continue
            if not np.isfinite(v):
                # engine absent (e.g. DDlog timeout) — always mark it.
                ax.text(i + off, 0.02, "T/O", transform=trans, rotation=90,
                        ha="center", va="bottom", fontsize=xfs - 1, color=MISS)
                continue
            if not annotate:
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
    ax.grid(True, axis="y", color=GRID_FAINT, linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    ax.set_xticks(x)
    ax.set_xlim(-0.5, n - 0.5)
    if show_y:
        ax.set_ylabel(ylabel, fontsize=12.5)
    else:
        ax.tick_params(labelleft=False)
        ax.spines["left"].set_visible(False)
        ax.tick_params(left=False)


def render(groups, stem, width, annotate):
    """One figure, one sub-panel per (name, rows) group, sharing a log
    y-axis. Panel widths track each group's dataset count so bar widths
    match across panels; a gap + per-panel header separate the groups."""
    counts = [len(rows) for _, rows in groups]
    total = sum(counts)
    # Shrink the x-tick labels as the apps pack tighter (24 apps in a
    # figure* width need ~8 pt, 4 apps can afford 11).
    xfs = float(np.clip(np.interp(total, [4, 24], [11, 8]), 8, 11))

    # Common y-limits across all groups (shared axis); just enough headroom
    # to clear the tallest bar (×-labels need more, the clean version little).
    allv = [v for _, rows in groups for r in rows for v in r["t"].values()
            if v and v > 0]
    ylim = (10 ** math.floor(math.log10(min(allv))),
            max(allv) * (4.0 if annotate else 1.5))

    # Wide-and-flat reads best for figure*; the height only needs to cover
    # the bars + the rotated x-labels + the legend strip beneath.
    fig, axes = plt.subplots(
        1, len(groups), figsize=(width, 2.7), sharey=True,
        gridspec_kw={"width_ratios": counts, "wspace": 0.04})
    if len(groups) == 1:
        axes = [axes]

    for ax, (name, rows) in zip(axes, groups):
        _panel(ax, rows, "t", ylim=ylim, show_y=(ax is axes[0]),
               ylabel="Execution time (s)", annotate=annotate, xfs=xfs)
        ax.set_xticklabels([r["label"] for r in rows], rotation=40,
                           ha="right", fontsize=xfs)
        ax.set_title(PROG_DISPLAY.get(name, name), fontsize=12,
                     color=TEXT_DARK, fontweight="600", pad=4)

    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=len(ENGINES),
               frameon=False, fontsize=10.5, bbox_to_anchor=(0.5, -0.02),
               columnspacing=1.6, handlelength=1.2)

    fig.subplots_adjust(top=0.9, bottom=0.30, left=0.075, right=0.995)
    for ext in ("pdf", "png"):
        fig.savefig(f"{stem}.{ext}", bbox_inches="tight", dpi=200)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--groups", required=True,
                    help="Comma list of programs, left→right "
                         "(e.g. polonius_int,doop)")
    ap.add_argument("--width", type=float, default=None,
                    help="Figure width in inches (default: scaled to #datasets)")
    ap.add_argument("--no-annotate", action="store_true",
                    help="Drop the per-bar ×-vs-FlowLog labels (cleaner when "
                         "many apps are packed into a narrow figure*)")
    args = ap.parse_args()

    src = pathlib.Path(args.csv)
    if not src.exists():
        print(f"input not found: {src}", file=sys.stderr)
        return 1

    names = [g.strip() for g in args.groups.split(",") if g.strip()]
    groups = [(g, load_group(src, g)) for g in names]
    missing = [g for g, rows in groups if not rows]
    if missing:
        print(f"no rows for program(s) {missing} in {src}", file=sys.stderr)
        return 1

    total = sum(len(rows) for _, rows in groups)
    # ~0.62 in/dataset + margins + a slot per inter-group gap.
    width = args.width or 1.2 + 0.62 * total + 0.5 * (len(groups) - 1)
    stem = src.parent / f"{src.stem}-{'_'.join(names)}-paper"
    render(groups, stem, width, annotate=not args.no_annotate)
    print(f"wrote {stem.name}.{{pdf,png}} "
          f"({total} datasets in {len(groups)} groups, width={width:.1f}, "
          f"annotate={not args.no_annotate})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
