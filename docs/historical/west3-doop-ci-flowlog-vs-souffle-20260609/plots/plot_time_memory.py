#!/usr/bin/env python3
"""Time + peak-memory bar charts (as-shipped: FlowLog --str-intern vs Soufflé with
its tuned .plan), 20 DaCapo apps, 32 threads. Reads ../results.csv, writes
../time.{png,svg} and ../memory.{png,svg}. Self-consistent with the committed CSV."""
import csv, pathlib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
SNAP = HERE.parent
FL = "#1F6FEB"; SF = "#E8820C"; TEXT = "#1F2328"; MUT = "#57606A"; GRID = "#D0D7DE"
plt.rcParams.update({"axes.edgecolor": GRID, "axes.linewidth": 0.8, "axes.labelcolor": TEXT,
    "xtick.color": MUT, "ytick.color": MUT, "axes.spines.top": False, "axes.spines.right": False,
    "savefig.facecolor": "white", "figure.facecolor": "white"})

rows = list(csv.DictReader(open(SNAP / "results.csv")))
# speedup = Soufflé / FlowLog, derived from raw wall-clock times (not the rounded column)
for r in rows:
    r["_spd"] = float(r["souffle_run_s"]) / float(r["flowlog_run_s"])
rows.sort(key=lambda r: r["_spd"], reverse=True)
apps = [r["app"] for r in rows]
fl_t = [float(r["flowlog_run_s"]) for r in rows]
sf_t = [float(r["souffle_run_s"]) for r in rows]
fl_m = [float(r["flowlog_peak_gib"]) for r in rows]
sf_m = [float(r["souffle_peak_gib"]) for r in rows]
spd = [r["_spd"] for r in rows]

wins = sum(1 for s in spd if s > 1.0)
geomean = float(np.exp(np.mean(np.log(spd))))
x = np.arange(len(apps)); w = 0.38
xlabels = [f"context-insensitive/{a}" for a in apps]


def base(ax, title):
    ax.set_title(title, loc="left", color=TEXT, fontsize=12.5, fontweight="700", pad=14)
    ax.grid(True, axis="y", color=GRID, linewidth=0.8, zorder=0); ax.set_axisbelow(True)
    ax.set_xticks(x); ax.set_xticklabels(xlabels, rotation=40, ha="right", fontsize=9)
    ax.legend(loc="upper right", frameon=False, fontsize=11)


# --- time (log) ---
fig, ax = plt.subplots(figsize=(15, 6.2))
ax.bar(x - w / 2, fl_t, w, label="FlowLog (compiler)", color=FL, zorder=3)
ax.bar(x + w / 2, sf_t, w, label="Soufflé (compiled)", color=SF, zorder=3)
ax.set_yscale("log"); ax.set_ylabel("Execution time (s, log scale)", fontsize=11)
base(ax, f"FlowLog vs Soufflé — execution time · 20 workloads · FlowLog wins {wins}/20 · "
         f"geomean {geomean:.2f}× · range {min(spd):.2f}× → {max(spd):.2f}×")
for i in range(len(apps)):
    ax.annotate(f"{spd[i]:.1f}×", (x[i], max(fl_t[i], sf_t[i])), textcoords="offset points",
                xytext=(0, 5), ha="center", fontsize=8.5, color=FL, fontweight="700")
fig.tight_layout()
for ext in ("png", "svg"):
    fig.savefig(SNAP / f"time.{ext}", bbox_inches="tight", dpi=150)

# --- memory (linear) ---
fig, ax = plt.subplots(figsize=(15, 6.2))
ax.bar(x - w / 2, fl_m, w, label="FlowLog (compiler)", color=FL, zorder=3)
ax.bar(x + w / 2, sf_m, w, label="Soufflé (compiled)", color=SF, zorder=3)
ax.set_ylabel("Peak RSS (GiB)", fontsize=11)
base(ax, "FlowLog vs Soufflé — peak memory · 20 workloads · lower is better")
fig.tight_layout()
for ext in ("png", "svg"):
    fig.savefig(SNAP / f"memory.{ext}", bbox_inches="tight", dpi=150)

print(f"wrote time.* and memory.*  (wins {wins}/20, geomean {geomean:.2f}x)")
