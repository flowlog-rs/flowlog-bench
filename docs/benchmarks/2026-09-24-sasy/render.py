#!/usr/bin/env python3

import csv
import os
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
from matplotlib import font_manager
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, LogLocator, NullLocator
import numpy as np


ROOT = Path(__file__).resolve().parent
FLOWLOG = "#0087B9"
SOUFFLE = "#F5A623"
ACCENT_BROWN = "#5F2D12"
INK = "#2A2F36"
MUTED = "#555F6C"
GRID = "#E8EEF2"


def configure_style() -> None:
    font_paths = font_manager.findSystemFonts()
    extra = os.environ.get("FLOWLOG_BENCH_FONT_DIR")
    if extra:
        font_paths.extend(font_manager.findSystemFonts(fontpaths=[extra]))
    for font in sorted(font_paths):
        if Path(font).stem in {
            "Ubuntu-R",
            "Ubuntu-B",
            "Ubuntu-Regular",
            "Ubuntu-Bold",
        }:
            font_manager.fontManager.addfont(font)
    try:
        font_manager.findfont("Ubuntu", fallback_to_default=False)
    except ValueError as error:
        raise RuntimeError(
            "Rendering requires the Ubuntu font. Install the Ubuntu package "
            "fonts-ubuntu, or set FLOWLOG_BENCH_FONT_DIR to an extracted copy."
        ) from error

    plt.rcParams.update(
        {
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
            "svg.hashsalt": "flowlog-sasy-2026-09-24",
        }
    )


def rows(name: str) -> list[dict[str, str]]:
    with (ROOT / name).open(newline="") as handle:
        return list(csv.DictReader(handle))


def finish(fig: plt.Figure, stem: str) -> None:
    fig.tight_layout()
    fig.savefig(ROOT / f"{stem}.png", dpi=160, bbox_inches="tight")
    svg = ROOT / f"{stem}.svg"
    fig.savefig(svg, bbox_inches="tight", metadata={"Date": None})
    svg.write_text(
        "\n".join(line.rstrip() for line in svg.read_text().splitlines()) + "\n"
    )
    plt.close(fig)


def style_axis(ax: plt.Axes) -> None:
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    ax.tick_params(axis="x", length=0, pad=6, labelsize=10)
    ax.tick_params(axis="y", length=0, pad=6, labelsize=10)


def policy_census() -> None:
    data = rows("policy-census.csv")
    fig, axes = plt.subplots(1, 2, figsize=(15.5, 8.2), sharex=True)
    for ax, shape in zip(axes, ("linear", "fan-in"), strict=True):
        selected = [row for row in data if row["shape"] == shape]
        labels = [row["workload"] for row in selected]
        souffle = np.array([float(row["souffle_us"]) for row in selected])
        flowlog = np.array([float(row["flowlog_us"]) for row in selected])
        y = np.arange(len(selected))
        height = 0.36
        ax.barh(y - height / 2, flowlog, height, color=FLOWLOG, label="FlowLog main")
        ax.barh(y + height / 2, souffle, height, color=SOUFFLE, label="Souffle")
        ax.set_yticks(y, labels)
        ax.invert_yaxis()
        ax.set_xscale("log")
        ax.xaxis.set_major_locator(LogLocator(base=10))
        ax.xaxis.set_minor_locator(NullLocator())
        ax.xaxis.set_major_formatter(
            FuncFormatter(lambda value, _: f"{value:,.0f}")
        )
        ax.set_title(
            f"{shape.capitalize()} graph",
            loc="left",
            fontsize=12,
            fontweight=700,
            pad=14,
        )
        ax.set_xlabel("p95 compute per action (microseconds, log)")
        style_axis(ax)
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(
        handles,
        labels,
        loc="upper right",
        ncol=2,
        frameon=False,
        bbox_to_anchor=(0.98, 0.97),
        handlelength=1.4,
        columnspacing=1.6,
    )
    fig.suptitle(
        "Agent-policy census: actual p95 compute time at 256 turns",
        x=0.07,
        ha="left",
        fontsize=15,
        fontweight=700,
        color=INK,
    )
    finish(fig, "policy-census-time")


def sasty_selected() -> None:
    data = rows("sasty-selected.csv")
    labels = [row["case"] for row in data]
    souffle = np.array([float(row["compiled_souffle_s"]) for row in data])
    old_sip = np.array([float(row["old_sip_s"]) for row in data])
    newfix = np.array([float(row["newfix_s"]) for row in data])
    x = np.arange(len(data))
    width = 0.25

    fig, ax = plt.subplots(figsize=(13.5, 6.4))
    ax.bar(x - width, souffle, width, color=SOUFFLE, label="Compiled Souffle")
    old_bars = ax.bar(
        x,
        old_sip,
        width,
        color=ACCENT_BROWN,
        label="Shipped old-SIP",
    )
    new_bars = ax.bar(x + width, newfix, width, color=FLOWLOG, label="FlowLog main + guard")

    for index, row in enumerate(data):
        if row["old_sip_status"] != "complete":
            old_bars[index].set_facecolor("white")
            old_bars[index].set_edgecolor(ACCENT_BROWN)
            old_bars[index].set_hatch("//")
            ax.text(
                x[index],
                old_sip[index] * 1.08,
                "DNF",
                ha="center",
                va="bottom",
                color=INK,
                fontsize=9,
                fontweight=700,
            )
        if row["newfix_status"] != "complete":
            new_bars[index].set_facecolor("white")
            new_bars[index].set_edgecolor(FLOWLOG)
            new_bars[index].set_hatch("//")
            ax.text(
                x[index] + width,
                newfix[index] * 1.15,
                "ALLOC",
                ha="center",
                va="bottom",
                color=INK,
                fontsize=9,
                fontweight=700,
            )

    ax.set_yscale("log")
    ax.set_ylim(6, 15000)
    ax.yaxis.set_major_locator(LogLocator(base=10))
    ax.yaxis.set_minor_locator(NullLocator())
    ax.yaxis.set_major_formatter(
        FuncFormatter(lambda value, _: f"{value:,.0f}")
    )
    ax.set_xticks(x, labels, rotation=20, ha="right")
    ax.set_ylabel("Engine wall time (seconds, log)")
    ax.set_title(
        "Sasty: actual engine time and SIP trade-offs",
        loc="left",
        fontsize=15,
        fontweight=700,
        color=INK,
        pad=18,
    )
    ax.text(
        0.01,
        -0.25,
        "Hatched bars are incomplete runs: DNF is the 7,200 s timeout; "
        "ALLOC is the observed 122 s allocator abort, not completion time.",
        transform=ax.transAxes,
        color=MUTED,
        fontsize=9,
    )
    ax.grid(axis="y", color=GRID, linewidth=0.7)
    ax.tick_params(axis="x", length=0, pad=8, labelsize=10)
    ax.tick_params(axis="y", length=0, pad=6, labelsize=10)
    ax.legend(
        frameon=False,
        ncol=3,
        loc="upper right",
        handlelength=1.4,
        columnspacing=1.6,
        fontsize=10.5,
    )
    finish(fig, "sasty-selected-time")


def incremental_sast() -> None:
    data = rows("incremental-sast.csv")
    labels = [row["step"] for row in data]
    flowlog = np.array([float(row["flowlog_main_s"]) for row in data])
    compiled = np.array([float(row["souffle_compiled_s"]) for row in data])
    interpreted = np.array([float(row["souffle_interpreted_s"]) for row in data])
    x = np.arange(len(data))
    width = 0.25

    fig, ax = plt.subplots(figsize=(12.5, 5.6))
    ax.bar(x - width, flowlog, width, color=FLOWLOG, label="FlowLog main")
    ax.bar(x, compiled, width, color=SOUFFLE, label="Compiled Souffle")
    ax.bar(
        x + width,
        interpreted,
        width,
        color=ACCENT_BROWN,
        label="Interpreted Souffle",
    )
    ax.set_xticks(x, labels)
    ax.set_ylabel("Wall time (seconds)")
    ax.set_title(
        "SAST incremental replay: actual time per step",
        loc="left",
        fontsize=15,
        fontweight=700,
        color=INK,
        pad=18,
    )
    ax.grid(axis="y", color=GRID, linewidth=0.7)
    ax.tick_params(axis="x", length=0, pad=8, labelsize=10)
    ax.tick_params(axis="y", length=0, pad=6, labelsize=10)
    ax.legend(
        frameon=False,
        ncol=3,
        loc="upper right",
        handlelength=1.4,
        columnspacing=1.6,
        fontsize=10.5,
    )
    finish(fig, "incremental-sast-time")


def main() -> None:
    configure_style()
    policy_census()
    sasty_selected()
    incremental_sast()


if __name__ == "__main__":
    main()
