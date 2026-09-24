#!/usr/bin/env python3
"""Render this benchmark snapshot's plots and table from its recorded CSV."""

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
COLORS = ("#1576A4", "#BC916B")
LABELS = ("FlowLog", "Soufflé")
INK = "#193447"
MUTED = "#5C6B75"
GRID = "#E8EEF2"
GRAPH = {"tc", "sg", "reach", "bipartite", "dyck", "crdt", "galen"}
ANALYSIS = {"andersen", "polonius_str", "cspa", "csda", "cvc5", "z3"}
METRICS = (
    "flowlog_wall_s", "souffle_wall_s",
    "flowlog_peak_rss_mib", "souffle_peak_rss_mib",
)

# Matplotlib's cached font list can predate the Ubuntu font installation.
for font in sorted(font_manager.findSystemFonts()):
    if Path(font).stem in {"Ubuntu-R", "Ubuntu-B", "Ubuntu-Regular", "Ubuntu-Bold"}:
        font_manager.fontManager.addfont(font)
try:
    font_manager.findfont("Ubuntu", fallback_to_default=False)
except ValueError as error:
    raise RuntimeError(
        "Rendering requires the Ubuntu font (Ubuntu package: fonts-ubuntu)."
    ) from error

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
    "svg.hashsalt": "flowlog-souffle-2026-09-24",
})


def geomean(values):
    return math.exp(statistics.mean(math.log(value) for value in values))


def speedup(row):
    return float(row["souffle_wall_s"]) / float(row["flowlog_wall_s"])


def load_results():
    with (HERE / "all_results.csv").open() as stream:
        rows = list(csv.DictReader(stream))
    if len(rows) != 55 or len({(r["program"], r["dataset"]) for r in rows}) != 55:
        raise ValueError("Expected all 55 unique canonical cases")
    measured = [r for r in rows if r["scope"] == "compare"]
    if len(measured) != 50 or sum(r["program"] == "doop" for r in measured) != 20:
        raise ValueError("Expected 50 comparisons, including all 20 DOOP datasets")
    for row in measured:
        for engine in ("flowlog", "souffle"):
            if row[f"{engine}_status"] != "ok" or row[f"{engine}_runs_ok"] != "3":
                raise ValueError(f"Incomplete measurements: {row}")
        if not row["counts_check"].startswith("match("):
            raise ValueError(f"Shared relation counts do not agree: {row}")
        if any(not math.isfinite(float(row[key])) or float(row[key]) <= 0 for key in METRICS):
            raise ValueError(f"Invalid measurement: {row}")
        if not math.isclose(speedup(row), float(row["souffle_over_flowlog"])):
            raise ValueError(f"Recorded speedup disagrees with wall times: {row}")
        if row["program"] not in GRAPH | ANALYSIS | {"doop"}:
            raise ValueError(f"Unclassified program: {row['program']}")
    for row in rows:
        if row["scope"] != "compare" and row["souffle_status"] != "unsupported":
            raise ValueError(f"Unexpected excluded case: {row}")
    return rows, measured


def draw_panel(ax, rows, title, metric):
    rows = sorted(rows, key=speedup, reverse=True)
    memory = metric == "memory"
    suffix = "peak_rss_mib" if memory else "wall_s"
    divisor = 1024 if memory else 1
    values = [
        np.array([float(r[f"{engine}_{suffix}"]) / divisor for r in rows])
        for engine in ("flowlog", "souffle")
    ]
    positions = np.arange(len(rows))
    width = 0.34
    for offset, data, label, color in zip(
        (-width / 2, width / 2), values, LABELS, COLORS
    ):
        ax.bar(positions + offset, data, width, label=label, color=color,
               linewidth=0, zorder=3)
    ratios = values[1] / values[0]
    ratio_mean = geomean(ratios)
    if memory:
        detail = f"{ratio_mean:.2f}× geometric mean RSS · Soufflé / FlowLog"
        ax.set_ylabel("Peak RSS (GiB)")
        ax.set_ylim(0, max(map(max, values)) * 1.18)
        ax.yaxis.set_major_locator(MaxNLocator(nbins=5))
    else:
        wins = sum(value > 1 for value in ratios)
        detail = f"{ratio_mean:.2f}× geometric mean speedup · {wins}/{len(rows)} faster"
        ax.set_yscale("log")
        ax.yaxis.set_major_locator(LogLocator(base=10))
        ax.set_ylabel("Run time (seconds, log scale)")
        ax.set_ylim(10 ** math.floor(math.log10(min(map(min, values)))),
                    max(map(max, values)) * 2.0)
    ax.yaxis.set_major_formatter(FuncFormatter(
        lambda value, _: f"{value:,.0f}" if value >= 1 else f"{value:g}"
    ))
    ax.yaxis.set_minor_locator(NullLocator())
    ax.grid(axis="y", color=GRID, linewidth=0.7)
    ax.set_title(title, loc="left", fontsize=12, fontweight=700, pad=16)
    ax.text(1, 1.055, detail, transform=ax.transAxes, ha="right", va="bottom",
            fontsize=10.5, color=MUTED if memory else COLORS[0])
    labels = [
        r["dataset"] if r["program"] == "doop" else f"{r['program']}/{r['dataset']}"
        for r in rows
    ]
    ax.set_xticks(positions)
    ax.set_xticklabels(labels, rotation=40, ha="right", rotation_mode="anchor",
                       fontsize=10)
    ax.tick_params(axis="x", length=0, pad=8)
    ax.tick_params(axis="y", length=0, pad=6, labelsize=10)
    ax.margins(x=0.025)
    for index, ratio in enumerate(ratios):
        high = max(data[index] for data in values)
        height = high + ax.get_ylim()[1] * 0.018 if memory else high * 1.12
        ax.text(index, height, f"{ratio:.2f}×", ha="center", va="bottom",
                fontsize=9, color=MUTED)


def render(groups, stem, metric):
    height = 6.2 if len(groups) == 1 else 16.4
    fig, axes = plt.subplots(len(groups), 1, figsize=(16, height), squeeze=False)
    fig.subplots_adjust(left=0.068, right=0.985, top=1 - 1.3 / height,
                        bottom=1.22 / height, hspace=0.60)
    description = "Peak memory" if metric == "memory" else "Run time"
    fig.text(0.068, 1 - 0.30 / height, "FlowLog vs Soufflé",
             fontsize=20, fontweight=700, va="top")
    fig.text(0.068, 1 - 0.73 / height,
             f"{description}  ·  32 threads  ·  batch mode  ·  median of 3 runs",
             fontsize=10.5, color=MUTED, va="top")
    for ax, (title, rows) in zip(axes[:, 0], groups):
        draw_panel(ax, rows, title, metric)
    handles, labels = axes[0, 0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper right", ncol=2, frameon=False,
               bbox_to_anchor=(0.985, 1 - 0.30 / height), borderaxespad=0,
               handlelength=1.4, handleheight=0.8, columnspacing=1.6,
               fontsize=10.5)
    coverage = ("50 supported comparisons; 5 unsupported cases omitted"
                if len(groups) > 1 else "All 20 DOOP datasets, including Jython")
    fig.text(0.068, 0.39 / height,
             "Compiler 0.7.0 · runtime 0.5.0 · Soufflé 2.5 · September 24, 2026",
             color=MUTED, fontsize=8.5)
    fig.text(0.068, 0.15 / height,
             f"Loading included · compilation excluded · labels = Soufflé / FlowLog · {coverage}",
             color=MUTED, fontsize=8.5)
    for extension in ("png", "svg"):
        metadata = {"Date": None} if extension == "svg" else None
        path = HERE / f"{stem}.{extension}"
        fig.savefig(path, dpi=160, bbox_inches="tight", metadata=metadata)
        if extension == "svg":
            path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines()) + "\n")
    plt.close(fig)


def table(rows):
    lines = [
        "| Program | Dataset | FlowLog (s) | Soufflé (s) | Speedup | FlowLog RAM (MiB) | Soufflé RAM (MiB) |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        if row["scope"] != "compare":
            values = ["—"] * 5
        else:
            values = [
                f"{float(row['flowlog_wall_s']):,.2f}",
                f"{float(row['souffle_wall_s']):,.2f}",
                f"{speedup(row):.2f}×",
                f"{float(row['flowlog_peak_rss_mib']):,.1f}",
                f"{float(row['souffle_peak_rss_mib']):,.1f}",
            ]
        lines.append("| " + " | ".join([row["program"], row["dataset"], *values]) + " |")
    return "\n".join(lines)


def write_report(rows, measured, doop):
    all_mean = geomean(speedup(r) for r in measured)
    doop_mean = geomean(speedup(r) for r in doop)
    memory_ratio = geomean(
        float(r["flowlog_peak_rss_mib"]) / float(r["souffle_peak_rss_mib"])
        for r in measured
    )
    wins = sum(speedup(r) > 1 for r in measured)
    report = f"""# FlowLog vs Soufflé: 32-thread benchmarks

September 24, 2026 · **FlowLog compiler 0.7.0 / runtime 0.5.0, batch mode** · **Soufflé 2.5**

**50 completed comparisons, 300 successful executions.** Five further canonical
cases have no Soufflé translation and are listed as unsupported, not failures.

| Scope | Comparisons | FlowLog faster | Geometric-mean speedup |
|---|---:|---:|---:|
| All supported cases | 50 | {wins}/50 | **{all_mean:.2f}×** |
| DOOP | 20 | {sum(speedup(r) > 1 for r in doop)}/20 | **{doop_mean:.2f}×** |

Speedup means **Soufflé wall time / FlowLog wall time**; above 1 favors FlowLog.
Soufflé used less peak memory in all 50 cases. The geometric-mean
FlowLog/Soufflé peak-RSS ratio was **{memory_ratio:.2f}×**.

## All measured workloads

The panels separate graph/reasoning, program analysis, and DOOP so all labels
remain readable. Within each panel, both charts use descending runtime speedup
order. FlowLog uses its logo's blue (`#1576A4`); Soufflé uses muted copper
(`#BC916B`). Ubuntu typography matches
[FlowLog's brand font](https://github.com/flowlog-rs/flowlog-rs.github.io/blob/f6d409944f56595e12888b0e242c88fead14e6a8/src/css/custom.css),
with bold headings and light gridlines.

![All 50 runtime comparisons, grouped by workload family](all-time.png)

![All 50 peak-memory comparisons, grouped by workload family](all-memory.png)

Vector versions: [runtime](all-time.svg) · [memory](all-memory.svg).
Memory uses a linear GiB scale, as in the engine README.

## DOOP

![DOOP runtime comparison on all 20 datasets](doop-time.png)

![DOOP peak-memory comparison on all 20 datasets](doop-memory.png)

Vector versions: [runtime](doop-time.svg) · [memory](doop-memory.svg).

## Complete results table

Times are median **whole-process wall-clock seconds** over three executions,
including input loading but excluding compilation. RAM is the median of
per-execution peak RSS in MiB. Speedups use the unrounded recorded medians.

{table(rows)}

**—**: no comparison was run because the pinned repository has no Soufflé
translation for that CC/SSSP case. Unsupported cases are excluded from all
aggregate ratios and plots.

All shared relation cardinalities agree across engines and all three attempts.
This is **not full tuple-by-tuple verification**. CSPA additionally reports
`MemoryAlias` and `ValueAlias` counts only on the FlowLog side; those two counts
were not cross-checked. The DOOP comparisons agree on all 26 shared reported
relation counts, including `VarPointsTo`.

## Method and provenance

| Setting | Value |
|---|---|
| Measurement interval | September 24, 2026, 07:37:18–11:46:14 UTC |
| FlowLog release commit | `07ffd67d96c68dad43e6f13d6325d7b1396a3249` |
| Benchmark corpus commit | `caa5f4afb630f8c275f3ea541f628f9c58245a8d` |
| Prepared dataset revision | `da9e91b3ff75d94604f57ba2b21ef3aa97e241ec` |
| Host | AMD EPYC 7763; 32 physical cores / 64 logical CPUs; approximately 503 GiB RAM |
| CPU placement | Same 32 physical cores for both engines; SMT siblings excluded; NUMA node 0 memory binding |
| FlowLog compilation | Release build; `--mode batch --str-intern`; runtime source pinned to the release commit |
| FlowLog execution | `-w 32` |
| Soufflé compilation | `souffle -o <binary> -j 32 -F <facts> <program>` |
| Soufflé execution | `<binary> -j 32 -F <facts> -D <output>` |
| Profiling | Disabled in both timed executables |
| Samples | Three measured executions per engine/case; engines and cases run serially |
| Time metric | GNU-time process wall time; 0.01-second resolution; compile time excluded |
| Memory metric | GNU-time peak RSS per execution; median reported |
| Cache policy | No explicit warm-up or cache flush; ordinary OS-cache behavior |
| Per-execution timeout | 1,800 seconds; no measured execution failed or timed out |
| Toolchain | Rust/Cargo 1.95.0; Soufflé 2.5 with OpenMP |
| Memory-map limit | `vm.max_map_count=1048576` during the run; previous value restored afterward |

The runtime's Rust files were compared against the published `flowlog-runtime`
0.5.0 crate and matched exactly. All 48 prepared input archives were SHA256
verified against the pinned HuggingFace dataset; the DOOP repository itself was
not downloaded.

The benchmark harness corrections included in this branch remove unintended
Soufflé profiling from timed binaries, accept the released FlowLog size-log
spacing, and let compilation failures return to the per-case runner. No engine
source or Datalog benchmark program was modified.

The canonical Twitter reachability case was attempted despite its historical
Soufflé skip tag and completed successfully. Only FlowLog and Soufflé were run:
LDBC has no Soufflé translation here; other engines, join-order ablations, and
cross-version regressions are outside this comparison.

## Data and plot reproduction

- [All 55 case outcomes](all_results.csv): the source of both the table and plots.
- [All 300 execution measurements](attempts.csv): portable timing/RSS data, without local filesystem paths.
- [Aggregate statistics](summary.json).
- [Machine-readable provenance](metadata.json).
- [Render script](render.py): reproduces the figures and this document, without rerunning benchmarks.

With Python, Matplotlib, NumPy, and the Ubuntu font installed, run from the
repository root. On Ubuntu the font package is `fonts-ubuntu`.
SVG text is saved as outlines so the typography is preserved on other systems.

```bash
python3 docs/benchmarks/2026-09-24/render.py
```

These plots use whole-process wall time for **both** engines. The harness's
older `Compiler_Total` column instead reports FlowLog's internal dataflow time;
it is preserved as `flowlog_dataflow_s` in the CSV but is **not** the plotted
baseline.
"""
    (HERE / "README.md").write_text(report, encoding="utf-8")


def main():
    rows, measured = load_results()
    doop = [r for r in measured if r["program"] == "doop"]
    groups = [
        ("Graph analysis and knowledge reasoning", [r for r in measured if r["program"] in GRAPH]),
        ("Program analysis", [r for r in measured if r["program"] in ANALYSIS]),
        ("DOOP default analysis", doop),
    ]
    for metric in ("time", "memory"):
        render(groups, f"all-{metric}", metric)
        render([("DOOP default analysis", doop)], f"doop-{metric}", metric)
    write_report(rows, measured, doop)
    print("Rendered 50 comparisons in four PNG/SVG figures and all 55 table rows.")


if __name__ == "__main__":
    main()
