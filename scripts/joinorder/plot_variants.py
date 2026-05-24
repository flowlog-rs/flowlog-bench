#!/usr/bin/env python3
"""Strip-plot of FlowLog join-order variants per program.

Circle = successful timed run, x = TIMEOUT (drawn at the timeout cap).
Green dashed line = median over successful runs only.

Reads every <program>_<dataset>.csv in a `pairs/` directory and lays
panels out in a grid. By default it skips pairs with < 10 variants
(the plan-flat ones — strip plots over 2-4 dots are not informative).

Usage:
  python plot_variants.py <pairs_dir> [-o out.png] [--min-variants N]
                                       [--timeout-s 600] [--all]
"""

from __future__ import annotations

import argparse
import csv
import math
import random
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.transforms as mtransforms
import numpy as np
from matplotlib.ticker import LogLocator, LogFormatterMathtext, NullFormatter
from scipy.signal import find_peaks
from scipy.stats import gaussian_kde

# Per-cluster circle colors. Index 0 = "good basin" (default-ish), 1 = mid
# tail, 2 = near-timeout tail. Extra colors are wrap-around safe.
CLUSTER_COLORS = ["#d6232a", "#f08d28", "#7e2b8e", "#2b6fbf"]


def assign_clusters(times: list[float], bw_factor: float = 0.15,
                    min_prom_rel: float = 0.03) -> list[int]:
    """KDE on log10(times) → find peaks → assign each time to nearest peak.

    KDE handles boundary-straddling basins gracefully (biojava's good
    basin sits across the √10 decade boundary; a fixed-bucket scheme
    would split it). Adjacent clusters whose centres are within
    half-a-decade are merged afterwards so a single natural mode never
    ends up as two artificial clusters.
    """
    n = len(times)
    if n < 6:
        return [0] * n
    arr = np.asarray(times, dtype=float)
    log_t = np.log10(arr)
    if log_t.max() - log_t.min() < 0.20:
        return [0] * n
    kde = gaussian_kde(log_t, bw_method=bw_factor)
    xs = np.linspace(log_t.min() - 0.1, log_t.max() + 0.1, 2000)
    ys = kde(xs)
    peaks, _ = find_peaks(ys, prominence=ys.max() * min_prom_rel)
    if len(peaks) == 0:
        return [0] * n
    centres = list(xs[peaks])
    # Merge any two adjacent centres that are within half-a-decade (i.e.
    # not really an order of magnitude apart).
    merged: list[float] = []
    for c in centres:
        if merged and abs(c - merged[-1]) < 0.5:
            merged[-1] = 0.5 * (merged[-1] + c)
        else:
            merged.append(c)
    if len(merged) == 1:
        return [0] * n
    # Boundaries at midpoints between adjacent centres
    bounds = [-np.inf]
    for i in range(len(merged) - 1):
        bounds.append(0.5 * (merged[i] + merged[i + 1]))
    bounds.append(np.inf)
    labels = [0] * n
    for i in range(len(merged)):
        lo, hi = bounds[i], bounds[i + 1]
        for j, v in enumerate(log_t):
            if lo <= v < hi:
                labels[j] = i
    return labels


def read_pair(path: Path) -> tuple[list[float], int, int, int]:
    """Return (timed_seconds, n_timeout, n_fail, n_total) for one pair CSV."""
    timed: list[float] = []
    n_timeout = 0
    n_fail = 0
    n_total = 0
    with open(path) as f:
        for row in csv.DictReader(f):
            n_total += 1
            v = (row.get("Total_s") or "").strip().upper()
            if v == "TIMEOUT":
                n_timeout += 1
                continue
            if v in ("FAIL", "ERROR", "N/A", ""):
                n_fail += 1
                continue
            try:
                timed.append(float(row["Total_s"]))
            except (TypeError, ValueError):
                n_fail += 1
    return timed, n_timeout, n_fail, n_total


def plot_panel(ax, label: str, timed: list[float], n_timeout: int,
               n_fail: int, n_total: int, timeout_s: float) -> None:
    rng = random.Random(0xF10)
    jitter = lambda: rng.uniform(-0.22, 0.22)

    # Successful runs — colored by cluster
    cluster_meta: list[tuple[float, int]] = []  # list of (median, count) per cluster
    if timed:
        labels = assign_clusters(timed)
        n_clusters = (max(labels) + 1) if labels else 1
        for c in range(n_clusters):
            pts = [t for t, lab in zip(timed, labels) if lab == c]
            if not pts:
                continue
            xs = [jitter() for _ in pts]
            color = CLUSTER_COLORS[c % len(CLUSTER_COLORS)]
            ax.scatter(
                xs, pts, s=42, facecolors="none", edgecolors=color,
                linewidths=1.2, alpha=0.85, zorder=3,
            )
            cluster_meta.append((float(np.median(pts)), len(pts)))
    # Timeouts — × drawn in a band above the timeout cap, so they're
    # visually separated from any run that finished close to the cap.
    timeout_band_y = timeout_s * 1.3
    if n_timeout:
        xs = [jitter() for _ in range(n_timeout)]
        ax.scatter(
            xs, [timeout_band_y] * n_timeout, s=42, marker="x",
            color="#1f3da8", linewidths=1.4, alpha=0.55, zorder=4,
        )

    # Median (over successful runs only) — drawn ON TOP of every marker
    med: float | None = None
    if timed:
        med = float(np.median(timed))
        ax.hlines(med, -0.45, 0.45, colors="#26a23a", linestyles="dashed",
                  linewidths=2.2, zorder=10)

    ax.set_yscale("log")
    ax.set_xticks([0])
    ax.set_xticklabels([label], fontsize=10)
    # Data jitters in [-0.22, 0.22]; minimal right margin since % labels
    # are right-anchored to the panel frame via a blended transform.
    ax.set_xlim(-0.4, 0.4)
    ax.grid(axis="y", which="both", linestyle=":", color="#cccccc", linewidth=0.6)
    ax.set_axisbelow(True)
    # Only label decade boundaries (10^k); silence minor ticks so a
    # narrow-range panel (e.g., z3) doesn't get a wall of "1.475 × 10^1"
    # labels.
    ax.yaxis.set_major_locator(LogLocator(base=10.0))
    ax.yaxis.set_major_formatter(LogFormatterMathtext(base=10.0))
    ax.yaxis.set_minor_locator(LogLocator(base=10.0, subs=tuple(range(2, 10))))
    ax.yaxis.set_minor_formatter(NullFormatter())
    # Make sure the panel covers at least one full decade so the major
    # label is always visible, and that the × band has air above it.
    if timed:
        data_lo = min(timed)
        data_hi = max(timed)
        if n_timeout:
            data_hi = max(data_hi, timeout_band_y)
        ylim_lo, ylim_hi = data_lo / 1.2, data_hi * 1.2
        if math.log10(ylim_hi) - math.log10(ylim_lo) < 1.0:
            mid = math.sqrt(ylim_lo * ylim_hi)
            ylim_lo, ylim_hi = mid / math.sqrt(10), mid * math.sqrt(10)
        ax.set_ylim(ylim_lo, ylim_hi)

    # M = ... rides on the title bar above the panel rectangle, so it
    # cannot overlap × markers, circles, or the median dashed line.
    if med is not None:
        ax.set_title(
            f"M = {med:.1f}s", color="#26a23a", fontsize=12,
            fontweight="bold", pad=6,
        )
    else:
        ax.set_title("no successful runs", color="#888", fontsize=10, pad=6)

    # Per-cluster percentages and the timeout percentage — all
    # right-anchored to the panel frame (x in axes coords, y in data
    # coords) so they sit flush against the right border.
    blend = mtransforms.blended_transform_factory(ax.transAxes, ax.transData)
    total_with_to = n_total - n_fail  # treat FAILs as out-of-scope
    if total_with_to and n_timeout:
        ax.text(
            0.98, timeout_band_y, f"{100 * n_timeout / total_with_to:.0f}%",
            ha="right", va="center", color="#1f3da8",
            fontsize=10, fontweight="bold", zorder=11, transform=blend,
        )
    if len(cluster_meta) > 1 and total_with_to:
        for i, (c_med, c_n) in enumerate(cluster_meta):
            color = CLUSTER_COLORS[i % len(CLUSTER_COLORS)]
            ax.text(
                0.98, c_med, f"{100 * c_n / total_with_to:.0f}%",
                ha="right", va="center", color=color,
                fontsize=10, fontweight="bold", zorder=11, transform=blend,
            )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("pairs_dir", help="Directory containing <pair>.csv files")
    p.add_argument("-o", "--out", default=None,
                   help="Output image path (default: <pairs_dir>/../variants_strip.png)")
    p.add_argument("--min-variants", type=int, default=10,
                   help="Skip pairs with fewer than this many variants total")
    p.add_argument("--timeout-s", type=float, default=600.0,
                   help="Timeout cap (where x markers are drawn)")
    p.add_argument("--all", action="store_true",
                   help="Don't skip small pairs — plot every pair")
    p.add_argument("--exclude", default="",
                   help="Comma-separated pair stems to skip (e.g. z3_z3,eclipse_eclipse)")
    args = p.parse_args(argv)

    pairs_dir = Path(args.pairs_dir).resolve()
    csvs = sorted(pairs_dir.glob("*.csv"))
    if not csvs:
        print(f"No CSVs in {pairs_dir}", file=sys.stderr)
        return 1

    exclude = {s.strip() for s in args.exclude.split(",") if s.strip()}
    panels: list[tuple[str, list[float], int, int, int]] = []
    skipped: list[str] = []
    for csv_path in csvs:
        timed, n_to, n_fail, n_total = read_pair(csv_path)
        label = csv_path.stem
        if label in exclude:
            skipped.append(f"{label} (excluded)")
            continue
        if not args.all and n_total < args.min_variants:
            skipped.append(f"{label} (n={n_total})")
            continue
        panels.append((label, timed, n_to, n_fail, n_total))

    if not panels:
        print("No pairs passed the min-variants threshold", file=sys.stderr)
        return 1

    if skipped:
        print(f"Skipped {len(skipped)} plan-flat pair(s): {', '.join(skipped)}",
              file=sys.stderr)

    # Layout: a single row up to 4 panels (matches academic figures);
    # otherwise wrap to 3-wide.
    n = len(panels)
    if n <= 4:
        ncols = n
    else:
        ncols = 3
    nrows = math.ceil(n / ncols)
    fig, axes = plt.subplots(
        nrows, ncols, figsize=(2.8 * ncols, 3.7 * nrows),
        squeeze=False, sharey=False,
    )
    fig.subplots_adjust(hspace=0.55, wspace=0.35)
    for idx, (label, timed, n_to, n_fail, n_total) in enumerate(panels):
        ax = axes[idx // ncols][idx % ncols]
        plot_panel(ax, label, timed, n_to, n_fail, n_total, args.timeout_s)
        if idx % ncols == 0:
            ax.set_ylabel("Runtime (s, log scale)")
    # Hide unused axes
    for idx in range(n, nrows * ncols):
        axes[idx // ncols][idx % ncols].set_visible(False)

    fig.tight_layout()

    out = Path(args.out) if args.out else pairs_dir.parent / "variants_strip.png"
    fig.savefig(out, dpi=150, bbox_inches="tight")
    print(f"Wrote {out}  ({n} panels)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
