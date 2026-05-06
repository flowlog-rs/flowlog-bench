#!/usr/bin/env python3
"""Plot compiler vs interpreter speedup from benchmark CSV results.

Reads ``results/benchmark/comparison_results.csv`` (or any path passed
as argv[1]) and writes ``speedup_figure.{pdf,png}`` next to it.

Rows whose ``Load_Speedup`` / ``Exec_Speedup`` / ``Total_Speedup``
columns are blank are silently skipped — the comparison config can
mark pairs ``[interp:skip]``, in which case the CSV writer leaves
those cells empty and there's no speedup to chart.
"""

import csv
import os
import sys
from itertools import groupby

import matplotlib
import matplotlib.pyplot as plt
import numpy as np

matplotlib.rcParams["font.family"] = "serif"
matplotlib.rcParams["font.size"] = 11

BAR_WIDTH = 0.25
FIG_SIZE = (18, 6)


def read_csv(path):
    """Read benchmark CSV and return programs, datasets, and speedup lists.

    Rows missing any of the three speedup columns are dropped so that
    interpreter-skipped pairs don't crash ``float("")``.
    """
    programs, datasets = [], []
    load_sp, exec_sp, total_sp = [], [], []

    with open(path, "r") as f:
        for row in csv.DictReader(f):
            try:
                load = float(row["Load_Speedup"])
                exec_ = float(row["Exec_Speedup"])
                total = float(row["Total_Speedup"])
            except (KeyError, ValueError):
                continue  # skip rows with missing/non-numeric speedups
            prog = os.path.splitext(os.path.basename(row["Program"]))[0]
            programs.append(prog)
            datasets.append(row["Dataset"])
            load_sp.append(load)
            exec_sp.append(exec_)
            total_sp.append(total)

    return programs, datasets, load_sp, exec_sp, total_sp


def build_group_info(programs):
    """Find consecutive groups of the same program for axis labeling."""
    groups = []
    idx = 0
    for prog, grp in groupby(programs):
        count = sum(1 for _ in grp)
        groups.append((prog, idx, idx + count - 1))
        idx += count
    return groups


def plot_speedup(programs, datasets, load_sp, exec_sp, total_sp):
    """Create the grouped bar chart with 1.0 baseline."""
    n = len(datasets)
    x = np.arange(n)

    fig, ax = plt.subplots(figsize=FIG_SIZE)

    # Bars grow up/down from the 1.0 baseline.
    series = [
        (x - BAR_WIDTH, load_sp, "Load Speedup", "#2196F3"),
        (x, exec_sp, "Execute Speedup", "#FF5722"),
        (x + BAR_WIDTH, total_sp, "Total Speedup", "#4CAF50"),
    ]
    for xpos, vals, label, color in series:
        ax.bar(xpos, [v - 1.0 for v in vals], BAR_WIDTH,
               bottom=1.0, label=label, color=color, zorder=3)

    ax.axhline(y=1.0, color="black", linestyle="-", linewidth=1.5, alpha=0.9)

    ax.set_xticks(x)
    ax.set_xticklabels(datasets, rotation=45, ha="right", fontsize=7)

    for prog, start, end in build_group_info(programs):
        mid = (start + end) / 2.0
        ax.text(mid, -0.18, prog, ha="center", va="top", fontsize=8,
                fontweight="bold", transform=ax.get_xaxis_transform())
        if start > 0:
            ax.axvline(x=start - 0.5, color="lightgray",
                       linewidth=0.8, linestyle="-", alpha=0.5)

    ax.set_ylabel("Speedup (Compiler / Interpreter)", fontsize=12)
    ax.set_title("Compiler vs Interpreter Speedup across Benchmarks",
                 fontsize=14, fontweight="bold")
    ax.legend(loc="upper right", fontsize=10, framealpha=0.9)
    ax.grid(axis="y", alpha=0.3)
    ax.set_xlim(-0.5, n - 0.5)

    plt.tight_layout()
    plt.subplots_adjust(bottom=0.22)
    return fig


def main():
    if len(sys.argv) != 2:
        print("Usage: python plot_speedup.py <csv_path>", file=sys.stderr)
        sys.exit(2)

    csv_path = sys.argv[1]
    if not os.path.isfile(csv_path):
        print(f"ERROR: csv not found: {csv_path}", file=sys.stderr)
        sys.exit(2)

    programs, datasets, load_sp, exec_sp, total_sp = read_csv(csv_path)
    if not programs:
        print(f"ERROR: no plottable rows in {csv_path} "
              f"(every row was missing one of Load_Speedup / Exec_Speedup / "
              f"Total_Speedup — interpreter probably skipped for every pair)",
              file=sys.stderr)
        sys.exit(1)

    fig = plot_speedup(programs, datasets, load_sp, exec_sp, total_sp)

    output_dir = os.path.dirname(os.path.abspath(csv_path))
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(output_dir, f"speedup_figure.{ext}"),
                    dpi=300, bbox_inches="tight")

    print(f"Saved speedup_figure.{{pdf,png}} to {output_dir}")


if __name__ == "__main__":
    main()
