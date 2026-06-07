#!/usr/bin/env python3
"""Bar charts for the 32/48-thread DOOP FlowLog-vs-Souffle benchmark.

Reads results.csv (dataset,engine,threads,wall_s,peak_rss_mb,exit) and writes,
next to it, grouped bar charts for runtime and peak memory at each thread count,
plus a speedup chart. Style matches flowlog-bench/plot/plot_perf.py.
"""
import csv
import pathlib
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

FLOWLOG_BLUE = "#1F6FEB"
SOUFFLE_AMBER = "#D97706"
SPEEDUP_GREEN = "#1A7F37"
TEXT_DARK = "#1F2328"
TEXT_MUTED = "#57606A"
GRID_FAINT = "#D0D7DE"

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
    "font.size": 10,
})


def load(csv_path):
    data = {}
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            if r["exit"] != "0":
                continue
            key = (r["dataset"], r["engine"], r["threads"])
            data[key] = (float(r["wall_s"]), float(r["peak_rss_mb"]))
    all_ds = {k[0] for k in data}
    # keep only datasets with the full 4-cell set (both engines × both thread counts)
    complete = [d for d in all_ds
                if all((d, e, t) in data for e in ("flowlog", "souffle") for t in ("32", "48"))]
    datasets = sorted(complete, key=lambda d: data[(d, "flowlog", "32")][0])
    return data, datasets


def _grouped_bar(ax, datasets, fl_vals, sf_vals, ylabel, title, log=False):
    x = np.arange(len(datasets))
    w = 0.4
    b1 = ax.bar(x - w/2, fl_vals, w, label="FlowLog", color=FLOWLOG_BLUE)
    b2 = ax.bar(x + w/2, sf_vals, w, label="Soufflé", color=SOUFFLE_AMBER)
    ax.set_ylabel(ylabel)
    ax.set_title(title, fontsize=12, fontweight="bold", color=TEXT_DARK, loc="left")
    ax.set_xticks(x)
    ax.set_xticklabels(datasets, rotation=45, ha="right")
    if log:
        ax.set_yscale("log")
    ax.grid(axis="y", color=GRID_FAINT, linewidth=0.6, alpha=0.7)
    ax.set_axisbelow(True)
    ax.legend(frameon=False, loc="upper left")
    return b1, b2


def runtime_chart(data, datasets, threads, out):
    fl = [data[(d, "flowlog", threads)][0] for d in datasets]
    sf = [data[(d, "souffle", threads)][0] for d in datasets]
    fig, ax = plt.subplots(figsize=(13, 5.5))
    _grouped_bar(ax, datasets, fl, sf,
                 "wall-clock time (s, log scale)",
                 f"DOOP context-insensitive — runtime @ {threads} threads (lower is better)",
                 log=True)
    # speedup annotation above each pair
    for i, d in enumerate(datasets):
        sp = sf[i] / fl[i] if fl[i] else 0
        ax.annotate(f"{sp:.1f}×", (i, max(fl[i], sf[i])), textcoords="offset points",
                    xytext=(0, 4), ha="center", fontsize=8, color=SPEEDUP_GREEN, fontweight="bold")
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)
    print("wrote", out)


def memory_chart(data, datasets, threads, out):
    fl = [data[(d, "flowlog", threads)][1] / 1024 for d in datasets]
    sf = [data[(d, "souffle", threads)][1] / 1024 for d in datasets]
    fig, ax = plt.subplots(figsize=(13, 5.5))
    _grouped_bar(ax, datasets, fl, sf,
                 "peak RSS (GiB, log scale)",
                 f"DOOP context-insensitive — peak memory @ {threads} threads (lower is better)",
                 log=True)
    for i, d in enumerate(datasets):
        ratio = fl[i] / sf[i] if sf[i] else 0
        ax.annotate(f"{ratio:.1f}×", (i, max(fl[i], sf[i])), textcoords="offset points",
                    xytext=(0, 4), ha="center", fontsize=8, color=TEXT_MUTED)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)
    print("wrote", out)


def speedup_chart(data, datasets, out):
    sp32 = [data[(d, "souffle", "32")][0] / data[(d, "flowlog", "32")][0] for d in datasets]
    sp48 = [data[(d, "souffle", "48")][0] / data[(d, "flowlog", "48")][0] for d in datasets]
    order = sorted(range(len(datasets)), key=lambda i: sp32[i], reverse=True)
    ds = [datasets[i] for i in order]
    sp32 = [sp32[i] for i in order]
    sp48 = [sp48[i] for i in order]
    x = np.arange(len(ds))
    w = 0.4
    fig, ax = plt.subplots(figsize=(13, 5.5))
    ax.bar(x - w/2, sp32, w, label="32 threads", color=FLOWLOG_BLUE)
    ax.bar(x + w/2, sp48, w, label="48 threads", color="#79B8FF")
    ax.axhline(1.0, color=TEXT_MUTED, linewidth=0.8, linestyle="--")
    ax.set_ylabel("speedup  (Soufflé time ÷ FlowLog time)")
    ax.set_title("FlowLog speedup over Soufflé per dataset (higher = FlowLog faster)",
                 fontsize=12, fontweight="bold", color=TEXT_DARK, loc="left")
    ax.set_xticks(x)
    ax.set_xticklabels(ds, rotation=45, ha="right")
    ax.grid(axis="y", color=GRID_FAINT, linewidth=0.6, alpha=0.7)
    ax.set_axisbelow(True)
    ax.legend(frameon=False, loc="upper right")
    for i in range(len(ds)):
        ax.annotate(f"{sp32[i]:.1f}×", (i - w/2, sp32[i]), textcoords="offset points",
                    xytext=(0, 3), ha="center", fontsize=7.5, color=TEXT_DARK)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)
    print("wrote", out)


def main():
    csv_path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/bench/results.csv")
    outdir = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else csv_path.parent
    outdir.mkdir(parents=True, exist_ok=True)
    data, datasets = load(csv_path)
    runtime_chart(data, datasets, "32", outdir / "doop_runtime_32t.png")
    runtime_chart(data, datasets, "48", outdir / "doop_runtime_48t.png")
    memory_chart(data, datasets, "32", outdir / "doop_memory_32t.png")
    memory_chart(data, datasets, "48", outdir / "doop_memory_48t.png")
    speedup_chart(data, datasets, outdir / "doop_speedup.png")


if __name__ == "__main__":
    main()
