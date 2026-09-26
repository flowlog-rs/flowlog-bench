#!/usr/bin/env python3
"""Draw the two figures and print the result tables, from the CSVs in this folder."""

import csv
import math
from pathlib import Path
import statistics

import matplotlib

matplotlib.use("Agg")
from matplotlib import font_manager
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, LogLocator, MaxNLocator, NullLocator
import numpy as np


HERE = Path(__file__).resolve().parent
COLORS = {"main": "#F5A623", "pr": "#0087B9"}
LABELS = {"main": "main", "pr": "PR", "hash-fold": "hash fold"}
LEGEND = {"main": "main", "pr": "PR #380"}
INK = "#193447"
MUTED = "#5C6B75"
GRID = "#E8EEF2"
GIB = 1024 * 1024
BATCH = [
    ("cc", "livejournal"), ("cc", "orkut"), ("cc", "arabic"),
    ("sssp", "livejournal-sssp"), ("sssp", "orkut-sssp"), ("ic13", "ldbc_snb_interactive_sf3"),
]
INCREMENTAL = [
    ("cc_out", "cc-roadnet", "32"), ("sssp_out", "sssp-roadnet", "32"),
    ("cc_out", "cc-lj250k", "32"), ("cc_out", "cc-lj250k-shuf", "32"),
    ("sssp_out", "sssp-lj250k", "32"),
    ("cc_out", "cc-lj250k", "1"), ("cc_out", "cc-lj250k-shuf", "1"),
    ("sssp_out", "sssp-lj250k", "1"),
]
NAMES = {"cc-roadnet": "roadNet-CA", "sssp-roadnet": "roadNet-CA", "cc-lj250k": "lj250k",
         "sssp-lj250k": "lj250k", "cc-lj250k-shuf": "lj250k, shuffled ids"}
PROGRAMS = {"cc": "CC", "sssp": "SSSP", "ic13": "IC13", "cc_out": "CC", "sssp_out": "SSSP"}
DATASETS = {"livejournal": "LiveJournal", "orkut": "Orkut", "arabic": "Arabic",
            "livejournal-sssp": "LiveJournal", "orkut-sssp": "Orkut", "ldbc_snb_interactive_sf3": "LDBC SF3"}

# Matplotlib's cached font list can predate the Ubuntu font installation.
for font in sorted(font_manager.findSystemFonts()):
    if Path(font).stem in {"Ubuntu-R", "Ubuntu-B", "Ubuntu-Regular", "Ubuntu-Bold"}:
        font_manager.fontManager.addfont(font)
try:
    font_manager.findfont("Ubuntu", fallback_to_default=False)
except ValueError as error:
    raise RuntimeError("Rendering requires the Ubuntu font (package fonts-ubuntu).") from error

plt.rcParams.update({
    "font.family": "Ubuntu",
    "font.size": 11,
    "text.color": INK,
    "axes.labelcolor": MUTED,
    "axes.labelpad": 10,
    "axes.edgecolor": "#C8D3DA",
    "axes.linewidth": 0.7,
    "xtick.color": MUTED,
    "ytick.color": MUTED,
    "axes.spines.left": False,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.axisbelow": True,
    "figure.facecolor": "white",
    "savefig.facecolor": "white",
    "svg.fonttype": "path",
    "svg.hashsalt": "flowlog-aggregates-2026-09-26",
})


def read(name):
    with (HERE / name).open() as stream:
        return list(csv.DictReader(stream))


def medians(rows, keys, metrics):
    """Median of each metric per key, over measured runs (rep 0 is a warmup)."""
    groups = {}
    for row in rows:
        if row["rep"] != "0":
            groups.setdefault(tuple(row[k] for k in keys), []).append(row)
    return {
        key: {m: statistics.median(float(r[m]) for r in runs) for m in metrics} | {"n": len(runs)}
        for key, runs in groups.items()
    }


def batch_results(base, variants):
    rows = [r for r in read("batch-programs.csv") if r["base"] == base]
    stats = medians(rows, ("variant", "program", "dataset"), ("dataflow_s", "peak_rss_kib"))
    cases = [c for c in BATCH if all((v, *c) in stats for v in variants)]
    return cases, {c: {v: stats[(v, *c)] for v in variants} for c in cases}


def incremental_results(base):
    rows = [r for r in read("incremental-programs.csv") if r["base"] == base]
    stats = medians(rows, ("variant", "program", "workload", "workers"),
                    ("load_s", "updates_s", "peak_rss_kib"))
    cases = [c for c in INCREMENTAL if ("main", *c) in stats and ("pr", *c) in stats]
    return cases, {c: {v: stats[(v, *c)] for v in ("main", "pr")} for c in cases}


def check_outputs():
    """Fail unless the variants gave the same answers; return the cases checked."""
    groups = {}
    for row in read("batch-outputs.csv"):
        groups.setdefault((row["base"], row["program"], row["dataset"]), set()).add(
            (row["rows"], row["sha256_prefix"]))
    if any(len(v) != 1 for v in groups.values()):
        raise ValueError("A batch variant produced different output")
    incremental = read("incremental-outputs.csv")
    if any(row["identical"] != "true" for row in incremental):
        raise ValueError("An incremental variant produced different output")
    return len(groups), len(incremental)


def ratio(a, b):
    return f"{a / b:.2f}×"


def batch_table(base, variants):
    cases, results = batch_results(base, variants)
    head = ["Program", "Dataset", *[f"{LABELS[v]} (s)" for v in variants]]
    head += ["Speedup"] if len(variants) == 2 else [f"{LABELS[v]} speedup" for v in variants[1:]]
    head += [f"Peak RSS (GiB), {' → '.join(LABELS[v] for v in variants)}"]
    lines = ["| " + " | ".join(head) + " |", "|---|---|" + "---:|" * (len(head) - 2)]
    for case in cases:
        r = results[case]
        times = [f"{r[v]['dataflow_s']:.2f}" for v in variants]
        speed = [ratio(r["main"]["dataflow_s"], r[v]["dataflow_s"]) for v in variants[1:]]
        rss = " → ".join(f"{r[v]['peak_rss_kib'] / GIB:.1f}" for v in variants)
        lines.append("| " + " | ".join([*case, *times, *speed, rss]) + " |")
    return "\n".join(lines)


def incremental_table(base):
    cases, results = incremental_results(base)
    lines = [
        "| Program | Graph | Workers | Runs | Load (s), main → PR | Speedup "
        "| 10 updates (s), main → PR | Speedup | Peak RSS (GiB), main → PR |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for program, workload, workers in cases:
        m, p = results[(program, workload, workers)]["main"], results[(program, workload, workers)]["pr"]
        lines.append("| " + " | ".join([
            program.removesuffix("_out"), NAMES[workload], workers, str(m["n"]),
            f"{m['load_s']:.2f} → {p['load_s']:.2f}", ratio(m["load_s"], p["load_s"]),
            f"{m['updates_s']:.2f} → {p['updates_s']:.2f}", ratio(m["updates_s"], p["updates_s"]),
            f"{m['peak_rss_kib'] / GIB:.1f} → {p['peak_rss_kib'] / GIB:.1f}",
        ]) + " |")
    return "\n".join(lines)


def draw(ax, labels, series, memory, title):
    positions = np.arange(len(labels))
    width = 0.36
    for offset, (variant, values) in zip((-width / 2, width / 2), series.items()):
        ax.bar(positions + offset, values, width, label=LEGEND[variant],
               color=COLORS[variant], linewidth=0, zorder=3)
    values = list(series.values())
    if memory:
        ax.set_ylabel("Peak RSS (GiB)")
        ax.set_ylim(0, max(map(max, values)) * 1.2)
        ax.yaxis.set_major_locator(MaxNLocator(nbins=5))
    else:
        ax.set_yscale("log")
        ax.yaxis.set_major_locator(LogLocator(base=10))
        ax.set_ylabel("Time (s, log scale)")
        ax.set_ylim(10 ** math.floor(math.log10(min(map(min, values)))),
                    max(map(max, values)) * 2.2)
    ax.yaxis.set_major_formatter(FuncFormatter(
        lambda value, _: f"{value:,.0f}" if value >= 1 else f"{value:g}"))
    ax.yaxis.set_minor_locator(NullLocator())
    ax.grid(axis="y", color=GRID, linewidth=0.7)
    ax.set_title(title, loc="left", fontsize=12, fontweight=700, pad=14)
    ax.set_xticks(positions)
    ax.set_xticklabels(labels, fontsize=9.5, linespacing=1.35)
    ax.tick_params(axis="x", length=0, pad=8)
    ax.tick_params(axis="y", length=0, pad=6, labelsize=10)
    ax.margins(x=0.04)
    for index, (before, after) in enumerate(zip(*values)):
        high = max(before, after)
        height = high + ax.get_ylim()[1] * 0.02 if memory else high * 1.12
        ax.text(index, height, f"{before / after:.2f}×", ha="center", va="bottom",
                fontsize=9, color=MUTED)


def figure(stem, panels, note, stacked=False):
    count = len(panels)
    width, height = (12, 3.3 * count + 0.9) if stacked else (5.4 * count, 4.9)
    fig, axes = plt.subplots(count if stacked else 1, 1 if stacked else count,
                             figsize=(width, height), squeeze=False)
    fig.subplots_adjust(left=0.9 / width, right=1 - 0.15 / width, top=1 - 0.95 / height,
                        bottom=(0.8 if stacked else 1.03) / height, wspace=0.28, hspace=0.62)
    for ax, panel in zip(axes.flat, panels):
        draw(ax, *panel)
    fig.text(0.9 / width, 1 - 0.12 / height, note, fontsize=9, color=MUTED, va="top")
    handles, labels = axes[0, 0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper right", ncol=2, frameon=False,
               bbox_to_anchor=(1 - 0.15 / width, 1 - 0.08 / height), borderaxespad=0,
               handlelength=1.4, handleheight=0.8, columnspacing=1.6, fontsize=10.5)
    for extension in ("png", "svg"):
        metadata = {"Date": None} if extension == "svg" else None
        path = HERE / f"{stem}.{extension}"
        fig.savefig(path, dpi=160, bbox_inches="tight", metadata=metadata)
        if extension == "svg":
            path.write_text("\n".join(l.rstrip() for l in path.read_text().splitlines()) + "\n")
    plt.close(fig)


def series(cases, data, metric, scale=1):
    return {v: [data[c][v][metric] / scale for c in cases] for v in ("main", "pr")}


def render():
    note = "Ratio above each pair = main / PR #380. Above 1 means the PR is faster or uses less memory."
    cases, data = batch_results("438684e", ("main", "pr"))
    labels = [f"{PROGRAMS[p]}\n{DATASETS[d]}" for p, d in cases]
    figure("batch", [
        (labels, series(cases, data, "dataflow_s"), False, "Batch: run time, 32 workers"),
        (labels, series(cases, data, "peak_rss_kib", GIB), True, "Batch: peak memory"),
    ], note)
    cases, data = incremental_results("8d2d1a9")
    cases = [c for c in cases if "shuf" not in c[1]]
    labels = [f"{PROGRAMS[p]} · {NAMES[w]}\n{n} worker{'s' if n != '1' else ''}"
              for p, w, n in cases]
    figure("incremental", [
        (labels, series(cases, data, "load_s"), False, "Incremental: first load"),
        (labels, series(cases, data, "updates_s"), False, "Incremental: 10 updates"),
        (labels, series(cases, data, "peak_rss_kib", GIB), True, "Incremental: peak memory"),
    ], note, stacked=True)


def main():
    batch, incremental = check_outputs()
    render()
    print(f"Outputs are identical across variants in all {batch} batch "
          f"and {incremental} incremental cases.\n")
    for title, table in [
        ("Batch, main 438684e vs PR", batch_table("438684e", ("main", "pr"))),
        ("Batch, main 8d2d1a9 vs PR vs hash fold",
         batch_table("8d2d1a9", ("main", "pr", "hash-fold"))),
        ("Incremental, main 8d2d1a9 vs PR", incremental_table("8d2d1a9")),
        ("Incremental recheck, main 438684e vs PR", incremental_table("438684e")),
    ]:
        print(f"{title}:\n\n{table}\n")


if __name__ == "__main__":
    main()
