#!/usr/bin/env python3

import csv
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


ROOT = Path(__file__).resolve().parent
FLOWLOG = "#0087B9"
SOUFFLE = "#F5A623"
OLD_SIP = "#626C78"
GRID = "#D8DEE5"
TEXT = "#1F2933"


def rows(name: str) -> list[dict[str, str]]:
    with (ROOT / name).open(newline="") as handle:
        return list(csv.DictReader(handle))


def finish(fig: plt.Figure, stem: str) -> None:
    fig.tight_layout()
    fig.savefig(ROOT / f"{stem}.png", dpi=180, bbox_inches="tight")
    fig.savefig(ROOT / f"{stem}.svg", bbox_inches="tight")
    plt.close(fig)


def style_axis(ax: plt.Axes) -> None:
    ax.set_axisbelow(True)
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.tick_params(colors=TEXT)


def policy_census() -> None:
    data = rows("policy-census.csv")
    fig, axes = plt.subplots(1, 2, figsize=(13.5, 7.4), sharex=True)
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
        ax.set_title(f"{shape.capitalize()} graph", weight="bold", color=TEXT)
        ax.set_xlabel("p95 compute per action (microseconds, log scale)")
        style_axis(ax)
    axes[0].legend(frameon=False, loc="lower right")
    fig.suptitle(
        "Agent-policy census: actual p95 compute time at 256 turns",
        fontsize=16,
        weight="bold",
        color=TEXT,
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

    fig, ax = plt.subplots(figsize=(12.5, 6.6))
    ax.bar(x - width, souffle, width, color=SOUFFLE, label="Compiled Souffle")
    old_bars = ax.bar(x, old_sip, width, color=OLD_SIP, label="Shipped old-SIP")
    new_bars = ax.bar(x + width, newfix, width, color=FLOWLOG, label="FlowLog main + guard")

    for index, row in enumerate(data):
        if row["old_sip_status"] != "complete":
            old_bars[index].set_facecolor("white")
            old_bars[index].set_edgecolor(OLD_SIP)
            old_bars[index].set_hatch("//")
            ax.text(
                x[index],
                old_sip[index] * 1.15,
                "DNF",
                ha="center",
                va="bottom",
                color=TEXT,
                fontsize=9,
                weight="bold",
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
                color=TEXT,
                fontsize=9,
                weight="bold",
            )

    ax.set_yscale("log")
    ax.set_xticks(x, labels, rotation=20, ha="right")
    ax.set_ylabel("Engine wall time (seconds, log scale)")
    ax.set_title(
        "Sasty: actual engine time and SIP trade-offs",
        fontsize=16,
        weight="bold",
        color=TEXT,
    )
    ax.text(
        0.01,
        -0.25,
        "Hatched bars are incomplete runs: DNF is the 7,200 s timeout; "
        "ALLOC is the observed 122 s allocator abort, not completion time.",
        transform=ax.transAxes,
        color=TEXT,
        fontsize=9,
    )
    ax.set_axisbelow(True)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.legend(frameon=False, ncol=3, loc="upper center")
    finish(fig, "sasty-selected-time")


def incremental_sast() -> None:
    data = rows("incremental-sast.csv")
    labels = [row["step"] for row in data]
    flowlog = np.array([float(row["flowlog_main_s"]) for row in data])
    compiled = np.array([float(row["souffle_compiled_s"]) for row in data])
    interpreted = np.array([float(row["souffle_interpreted_s"]) for row in data])
    x = np.arange(len(data))
    width = 0.25

    fig, ax = plt.subplots(figsize=(10.5, 5.8))
    ax.bar(x - width, flowlog, width, color=FLOWLOG, label="FlowLog main")
    ax.bar(x, compiled, width, color=SOUFFLE, label="Compiled Souffle")
    ax.bar(x + width, interpreted, width, color=OLD_SIP, label="Interpreted Souffle")
    ax.set_xticks(x, labels)
    ax.set_ylabel("Wall time (seconds)")
    ax.set_title(
        "SAST incremental replay: actual time per step",
        fontsize=16,
        weight="bold",
        color=TEXT,
    )
    ax.set_axisbelow(True)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.legend(frameon=False, ncol=3, loc="upper center")
    finish(fig, "incremental-sast-time")


def main() -> None:
    plt.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "font.size": 10,
            "axes.labelcolor": TEXT,
            "text.color": TEXT,
            "svg.fonttype": "path",
        }
    )
    policy_census()
    sasty_selected()
    incremental_sast()


if __name__ == "__main__":
    main()
