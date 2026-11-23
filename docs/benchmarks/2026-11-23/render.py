#!/usr/bin/env python3
"""Render this benchmark snapshot's plots and table from its recorded CSV.

Plot code and style are copied unchanged from ../2026-09-24/render.py.
"""

import csv
from datetime import date
import json
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
COLORS = ("#0087B9", "#F5A623")
LABELS = ("FlowLog", "Soufflé")
INK = "#193447"
MUTED = "#5C6B75"
GRID = "#E8EEF2"
WORKERS = 16
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
    "svg.hashsalt": "flowlog-souffle-2026-11-23",
})


def geomean(values):
    return math.exp(statistics.mean(math.log(value) for value in values))


def speedup(row):
    return float(row["souffle_wall_s"]) / float(row["flowlog_wall_s"])


def load_results():
    with (HERE / "all_results.csv").open() as stream:
        rows = list(csv.DictReader(stream))
    if len(rows) != 20 or len({r["dataset"] for r in rows}) != 20:
        raise ValueError("Expected all 20 unique DOOP datasets")
    for row in rows:
        if row["program"] != "doop" or row["scope"] != "compare":
            raise ValueError(f"Unexpected case: {row}")
        for engine in ("flowlog", "souffle"):
            if row[f"{engine}_status"] != "ok" or row[f"{engine}_runs_ok"] != "3":
                raise ValueError(f"Incomplete measurements: {row}")
        if row["counts_check"] != "match(26)":
            raise ValueError(f"Shared relation counts do not agree: {row}")
        if any(not math.isfinite(float(row[key])) or float(row[key]) <= 0 for key in METRICS):
            raise ValueError(f"Invalid measurement: {row}")
        if not math.isclose(speedup(row), float(row["souffle_over_flowlog"])):
            raise ValueError(f"Recorded speedup disagrees with wall times: {row}")
    return rows


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
    if memory:
        ax.set_ylabel("Peak RSS (GiB)")
        ax.set_ylim(0, max(map(max, values)) * 1.18)
        ax.yaxis.set_major_locator(MaxNLocator(nbins=5))
    else:
        ax.set_yscale("log")
        ax.yaxis.set_major_locator(LogLocator(base=10))
        ax.set_ylabel("Run time (s, log)")
        ax.set_ylim(10 ** math.floor(math.log10(min(map(min, values)))),
                    max(map(max, values)) * 2.0)
    ax.yaxis.set_major_formatter(FuncFormatter(
        lambda value, _: f"{value:,.0f}" if value >= 1 else f"{value:g}"
    ))
    ax.yaxis.set_minor_locator(NullLocator())
    ax.grid(axis="y", color=GRID, linewidth=0.7)
    if title:
        ax.set_title(title, loc="left", fontsize=12, fontweight=700, pad=16)
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
    single = len(groups) == 1
    height = 4.8 if single else 14.2
    fig, axes = plt.subplots(len(groups), 1, figsize=(16, height), squeeze=False)
    fig.subplots_adjust(left=0.068, right=0.985,
                        top=1 - (0.45 if single else 0.80) / height,
                        bottom=(0.85 if single else 1.05) / height, hspace=0.60)
    fig.text(0.068, 1 - 0.15 / height, "Ratios: Soufflé / FlowLog",
             fontsize=9, color=MUTED, va="top")
    for ax, (title, rows) in zip(axes[:, 0], groups):
        draw_panel(ax, rows, "" if single else title, metric)
    handles, labels = axes[0, 0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper right", ncol=2, frameon=False,
               bbox_to_anchor=(0.985, 1 - 0.15 / height), borderaxespad=0,
               handlelength=1.4, handleheight=0.8, columnspacing=1.6,
               fontsize=10.5)
    for extension in ("png", "svg"):
        metadata = {"Date": None} if extension == "svg" else None
        path = HERE / f"{stem}.{extension}"
        fig.savefig(path, dpi=160, bbox_inches="tight", metadata=metadata)
        if extension == "svg":
            path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines()) + "\n")
    plt.close(fig)


def table(rows):
    lines = [
        "| Dataset | FlowLog (s) | Soufflé (s) | Speedup | FlowLog RAM (MiB) | Soufflé RAM (MiB) |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for row in sorted(rows, key=lambda r: r["dataset"]):
        values = [
            f"{float(row['flowlog_wall_s']):,.2f}",
            f"{float(row['souffle_wall_s']):,.2f}",
            f"{speedup(row):.2f}×",
            f"{float(row['flowlog_peak_rss_mib']):,.1f}",
            f"{float(row['souffle_peak_rss_mib']):,.1f}",
        ]
        lines.append("| " + " | ".join([row["dataset"], *values]) + " |")
    return "\n".join(lines)


def interval(meta):
    start, end = meta["started_utc"], meta["finished_utc"]
    if start[:10] != end[:10]:
        raise ValueError("Measurement interval spans two dates")
    day = date.fromisoformat(start[:10])
    return f"{day:%B} {day.day}, {day.year}, {start[11:19]}–{end[11:19]} UTC"


def write_report(rows):
    meta = json.loads((HERE / "metadata.json").read_text())
    if meta["workers"] != WORKERS:
        raise ValueError("metadata.json disagrees with the plotted worker count")
    day = date.fromisoformat(meta["started_utc"][:10])
    ratios = [speedup(r) for r in rows]
    memory_ratio = geomean(
        float(r["flowlog_peak_rss_mib"]) / float(r["souffle_peak_rss_mib"]) for r in rows
    )
    leaner = sum(
        float(r["souffle_peak_rss_mib"]) < float(r["flowlog_peak_rss_mib"]) for r in rows
    )
    cpus = meta["bound_cpus"]
    maps = meta["peak_map_count_sampled"]
    source = meta["release_source_verification"]
    report = f"""# FlowLog vs Soufflé: {WORKERS}-thread DOOP benchmarks

{day:%B} {day.day}, {day.year} · **FlowLog compiler {meta['flowlog_compiler_version']} / runtime {meta['flowlog_runtime_version']}, batch** · **Soufflé {meta['souffle_version']}**

**{len(rows)} completed comparisons, {len(rows) * 6} successful executions.** This
snapshot reruns the DOOP default points-to analysis (`doop/default.dl`) on all
20 DaCapo datasets at {WORKERS} threads to refresh the FlowLog README figures.
Other workloads were not rerun; the [2026-09-24 snapshot](../2026-09-24/README.md)
remains the 32-thread record for the full suite.

| Comparisons | FlowLog faster | Geometric-mean speedup | Speedup range | Soufflé lower peak RSS | FlowLog/Soufflé peak RSS |
|---:|---:|---:|---:|---:|---:|
| {len(rows)} | {sum(v > 1 for v in ratios)}/{len(rows)} | **{geomean(ratios):.2f}×** | {min(ratios):.2f}–{max(ratios):.2f}× | {leaner}/{len(rows)} | {memory_ratio:.2f}× (geomean) |

Speedup means **Soufflé wall time / FlowLog wall time**; above 1 favors FlowLog.

## DOOP

Both charts use descending runtime speedup order. FlowLog uses light-theme blue
(`#0087B9`); Soufflé uses orange (`#F5A623`). Plot code and style are unchanged
from the 2026-09-24 snapshot.

![DOOP runtime comparison on all 20 datasets](doop-time.png)

![DOOP peak-memory comparison on all 20 datasets](doop-memory.png)

Vector versions: [runtime](doop-time.svg) · [memory](doop-memory.svg).
Memory uses a linear GiB scale, as in the engine README.

## Complete results table

Times are median **whole-process wall-clock seconds** over three executions,
including input loading but excluding compilation. RAM is the median of
per-execution peak RSS in MiB. Speedups use the unrounded recorded medians.

{table(rows)}

Every case agrees on all 26 shared reported relation counts, including
`VarPointsTo`, across both engines and all three attempts. This is **not full
tuple-by-tuple verification**.

## Method and provenance

| Setting | Value |
|---|---|
| Measurement interval | {interval(meta)} |
| FlowLog release commit | `{meta['flowlog_commit']}` |
| Benchmark corpus commit | `{meta['benchmark_corpus_commit']}` |
| Prepared dataset revision | `{meta['dataset_revision']}` |
| Host | {meta['cpu']}; {meta['physical_cores']} physical cores / {meta['logical_cpus']} logical CPUs; approximately {meta['ram_gib_approx']} GiB RAM |
| CPU placement | Same {len(cpus)} physical cores (CPUs {cpus[0]}–{cpus[-1]}) for both engines; no SMT on this host; NUMA node {meta['numa_memory_binding']} memory binding |
| FlowLog compilation | Release build; `--str-intern`; batch; runtime source pinned to the release commit |
| FlowLog execution | `-w {WORKERS}` |
| Soufflé compilation | `souffle -o <binary> -j {WORKERS} -F <facts> <program>` |
| Soufflé execution | `<binary> -j {WORKERS} -F <facts> -D <output>` |
| Profiling | Disabled in both timed executables |
| Samples | Three measured executions per engine/case; engines and cases run serially |
| Time metric | GNU-time process wall time; 0.01-second resolution; compile time excluded |
| Memory metric | GNU-time peak RSS per execution; median reported |
| Cache policy | No explicit warm-up or cache flush; ordinary OS-cache behavior |
| Per-execution timeout | {meta['timeout_seconds']:,} seconds; no measured execution failed or timed out |
| Toolchain | {meta['toolchain']} |
| Memory-map limit | `vm.max_map_count={meta['max_map_count_during_run']}` (host default); highest sampled map count: FlowLog {maps['flowlog']:,}, Soufflé {maps['souffle']:,} |

### Changes from the 2026-09-24 run

- **Threads:** {WORKERS} instead of 32, for both engines.
- **FlowLog:** compiler {meta['flowlog_compiler_version']} / runtime
  {meta['flowlog_runtime_version']} instead of 0.7.0 / 0.5.0. This compiler has no
  `--mode` flag; it builds batch whenever every input relation is static, as in
  DOOP, so the run drops `--mode batch` from the FlowLog flags and keeps every
  other flag.
- **Host:** {meta['cpu']} VM instead of AMD EPYC 7763, and Rust 1.97.1
  instead of 1.95.0. Absolute times are therefore not comparable across the
  two snapshots.
- **Memory-map limit:** the host default was kept because the run had no root
  access; the sampled peaks above stay far below it.
- **Soufflé install:** the same 2.5 release, from its official
  `x86_64-ubuntu-2204-souffle-2.5-Linux.deb` (SHA-512 verified), unpacked
  without root. Its `souffle-compile.py` only points include and library paths
  at the unpacked files; compiler flags (`-O3 -fopenmp -std=c++17` and the
  package's definitions) are unchanged.

### Source verification

`flowlog-runtime` {meta['flowlog_runtime_version']} is not yet on crates.io; its
publish is pending
[flowlog-rs/flowlog#648](https://github.com/flowlog-rs/flowlog/pull/648). The
pinned runtime source was compared with the published 0.7.0 crate (built from
commit `{source['crate_git_commit'][:7]}`): the
{len(source['differing_rust_source_files'])} differing Rust files, listed in
`metadata.json`, are exactly those changed between that commit and the release
commit. Each generated program's Cargo metadata was verified to resolve
`flowlog-runtime` from the pinned source, and the Soufflé binary was verified
to link OpenMP.

All 20 DOOP input archives were SHA256 verified against the pinned HuggingFace
dataset revision. No engine source, harness script, or Datalog program was
modified.

## Data and plot reproduction

- [All 20 case outcomes](all_results.csv): the source of both the table and plots.
- [All {len(rows) * 6} execution measurements](attempts.csv): portable timing/RSS data, without local filesystem paths.
- [Aggregate statistics](summary.json).
- [Machine-readable provenance](metadata.json).
- [Render script](render.py): reproduces the figures and this document, without rerunning benchmarks.

With Python, Matplotlib, NumPy, and the Ubuntu font installed, run from the
repository root. On Ubuntu the font package is `fonts-ubuntu`.
SVG text is saved as outlines so the typography is preserved on other systems.
These figures were rendered with Ubuntu 22.04's packaged Matplotlib 3.5.1,
NumPy 1.21.5, and FreeType 2.11.1, which also reproduce the 2026-09-24 figures
byte for byte; other builds can differ slightly in antialiasing.

```bash
python3 docs/benchmarks/{day.isoformat()}/render.py
```

These plots use whole-process wall time for **both** engines. The harness's
`Compiler_Total` column instead reports FlowLog's internal dataflow time; it is
preserved as `flowlog_dataflow_s` in the CSV but is **not** the plotted
baseline.
"""
    (HERE / "README.md").write_text(report, encoding="utf-8")


def main():
    rows = load_results()
    for metric in ("time", "memory"):
        render([("DOOP default analysis", rows)], f"doop-{metric}", metric)
    write_report(rows)
    print(f"Rendered {len(rows)} DOOP comparisons in two PNG/SVG figures and the table.")


if __name__ == "__main__":
    main()
