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
from matplotlib.transforms import blended_transform_factory, ScaledTranslation

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


PROG_DISPLAY = {"doop": "DOOP", "polonius_int": "Polonius"}
RED = "#CF222E"


def _draw_group(ax, rows, x0, *, first, annotate, xfs):
    """Draw one program's grouped bars on a shared axis, leftmost group
    centred at x0. Returns (tick positions, labels, (x_first, x_last))."""
    n = len(rows)
    k = len(ENGINES)
    centers = x0 + np.arange(n)
    bar_w = 0.80 / k
    offsets = (np.arange(k) - (k - 1) / 2) * bar_w
    trans = blended_transform_factory(ax.transData, ax.transAxes)

    base = [r["t"].get("flowlog") for r in rows]
    for (ekey, label, color, _, _), off in zip(ENGINES, offsets):
        vals = np.array([r["t"].get(ekey, np.nan) for r in rows], float)
        ax.bar(centers + off, vals, bar_w,
               label=label if first else "_nolegend_", color=color,
               edgecolor="white", linewidth=0.4, zorder=3)
        for c, v, b in zip(centers, vals, base):
            if ekey == "flowlog":
                continue
            if not np.isfinite(v):
                # engine absent (e.g. DDlog timeout) — a cute mathtext × at
                # the slot base (LaTeX-style glyph, softer than a plot marker).
                ax.text(c + off, 0.10, r"$\times$", transform=trans,
                        ha="center", va="bottom", fontsize=13, color=RED,
                        zorder=6, clip_on=False)
                continue
            if annotate and b:
                s = v / b
                ax.text(c + off, v * 1.05,
                        f"{s:.0f}×" if s >= 10 else f"{s:.1f}×",
                        ha="center", va="bottom", fontsize=6.8, rotation=90,
                        color=color, fontweight="600")
    return list(centers), [r["label"] for r in rows], (centers[0], centers[-1])


def render(groups, stem, width, annotate):
    """All groups on ONE continuous log y-axis (single baseline, single
    y-axis), separated by a gap + a thin divider and a category header.
    Reads as one clean wide figure rather than disconnected panels."""
    total = sum(len(rows) for _, rows in groups)
    xfs = float(np.clip(np.interp(total, [4, 24], [14, 13]), 13, 14))

    allv = [v for _, rows in groups for r in rows for v in r["t"].values()
            if v and v > 0]
    ylo = 10 ** math.floor(math.log10(min(allv)))
    yhi = max(allv) * (4.0 if annotate else 1.6)

    fig, ax = plt.subplots(figsize=(width, 3.1))
    ax.set_yscale("log")
    ax.set_ylim(ylo, yhi)

    GAP = 0.3                      # just enough to seat the divider line
    ticks, labels = [], []
    cursor = 0.0
    for gi, (name, rows) in enumerate(groups):
        centers, labs, (xa, xb) = _draw_group(
            ax, rows, cursor, first=(gi == 0), annotate=annotate, xfs=xfs)
        ticks += centers
        labels += labs
        # category header, centred over the group, snug under the top line
        ax.text((xa + xb) / 2, 0.995, PROG_DISPLAY.get(name, name),
                transform=blended_transform_factory(ax.transData, ax.transAxes),
                ha="center", va="top", fontsize=12.5, fontweight="700",
                color=TEXT_DARK)
        if gi < len(groups) - 1:
            ax.axvline(xb + (1 + GAP) / 2, color=GRID_FAINT, linewidth=1.0,
                       ymax=0.92, zorder=1)
        cursor = xb + 1 + GAP

    ax.yaxis.set_major_locator(LogLocator(base=10, numticks=12))
    ax.yaxis.set_minor_locator(NullLocator())
    ax.set_ylabel("Execution time (s)", fontsize=12.5)
    ax.grid(True, axis="y", color=GRID_FAINT, linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    ax.set_xlim(-0.7, ticks[-1] + 0.7)
    ax.set_xticks(ticks)
    # Centre each rotated name under its column (ha="center" + anchor pivot),
    # rather than anchoring the label's end at the tick.
    ax.set_xticklabels(labels, rotation=28, ha="center", fontsize=xfs,
                       rotation_mode="anchor")
    shift = ScaledTranslation(0, -11 / 72, fig.dpi_scale_trans)
    for lab in ax.get_xticklabels():
        lab.set_transform(lab.get_transform() + shift)

    handles, lbls = ax.get_legend_handles_labels()
    fig.legend(handles, lbls, loc="lower center", ncol=len(ENGINES),
               frameon=False, fontsize=11.5, bbox_to_anchor=(0.5, -0.07),
               columnspacing=1.8, handlelength=3.4)

    fig.subplots_adjust(top=0.97, bottom=0.28, left=0.06, right=0.995)
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
    # ~0.62 in/dataset + margins (overridable with --width).
    width = args.width or 1.2 + 0.62 * total + 0.5 * (len(groups) - 1)
    stem = src.parent / f"{src.stem}-{'_'.join(names)}-paper"
    render(groups, stem, width, annotate=not args.no_annotate)
    print(f"wrote {stem.name}.{{pdf,png}} "
          f"({total} datasets in {len(groups)} groups, width={width:.1f}, "
          f"annotate={not args.no_annotate})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
