#!/usr/bin/env python3
"""Regression deep dive: transplanting Soufflé's 16 .plan join orders into FlowLog
does NOT close the gap (±2% vs FlowLog default; correctness preserved) — the gap is
arrangement maintenance, not query planning. Per app: FlowLog default vs FlowLog +
Soufflé .plan vs Soufflé (as shipped). Reads ../regression.csv, writes
../regression.{png,svg}."""
import csv, pathlib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
SNAP = HERE.parent
FL = "#1F6FEB"; FL_PLAN = "#79B8FF"; SF = "#D97706"
TEXT = "#1F2328"; MUT = "#57606A"; GRID = "#D0D7DE"
plt.rcParams.update({"axes.edgecolor": GRID, "axes.linewidth": 0.8, "axes.labelcolor": TEXT,
    "xtick.color": MUT, "ytick.color": MUT, "axes.spines.top": False, "axes.spines.right": False,
    "savefig.facecolor": "white", "figure.facecolor": "white"})

rows = list(csv.DictReader(open(SNAP / "regression.csv")))
labels = [r["app"] for r in rows]
fl = [float(r["flowlog_default_s"]) for r in rows]
flp = [float(r["flowlog_plus_souffle_plan_s"]) for r in rows]
sf = [float(r["souffle_asshipped_s"]) for r in rows]
x = np.arange(len(labels)); w = 0.27

fig, ax = plt.subplots(figsize=(11, 5.2))
ax.bar(x - w, fl, w, label="FlowLog (default plan)", color=FL, zorder=3)
ax.bar(x, flp, w, label="FlowLog (+ Soufflé .plan)", color=FL_PLAN, zorder=3)
ax.bar(x + w, sf, w, label="Soufflé", color=SF, zorder=3)
ax.set_yscale("log"); ax.set_ylabel("solve time (s, log scale)", fontsize=11)
ax.set_title("Regression deep-dive — transplanting Soufflé's join orders into FlowLog "
             "does not close the gap\n(±2% vs default; correctness preserved). 32 threads, --str-intern.",
             loc="left", color=TEXT, fontsize=11.5, fontweight="600", pad=14)
ax.grid(True, axis="y", color=GRID, linewidth=0.8, zorder=0); ax.set_axisbelow(True)
ax.legend(loc="upper left", frameon=False, fontsize=10)
ax.set_xticks(x); ax.set_xticklabels(labels, fontsize=10)
for i in range(len(labels)):
    r = fl[i] / sf[i]
    ax.annotate(f"{r:.2f}× slower", (x[i], max(fl[i], sf[i])), textcoords="offset points",
                xytext=(0, 6), ha="center", fontsize=9, color=FL, fontweight="600")
fig.tight_layout()
for ext in ("png", "svg"):
    fig.savefig(SNAP / f"regression.{ext}", bbox_inches="tight", dpi=150)
print("wrote regression.*")
