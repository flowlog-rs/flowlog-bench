#!/usr/bin/env python3
"""Same-join-order deep dive: on the apps where FlowLog trails as-shipped, the gap
is mostly Soufflé's .plan, not the engine. Per app: FlowLog (default order) vs
Soufflé (default order, .plan stripped) vs Soufflé (its tuned .plan). At equal
order biojava/kafka/graphchi tie; .plan then re-opens a lead only Soufflé can use.
Reads ../sameorder.csv, writes ../sameorder.{png,svg}."""
import csv, pathlib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
SNAP = HERE.parent
FL = "#1F6FEB"; SF_DEF = "#F0B866"; SF_PLAN = "#D97706"
TEXT = "#1F2328"; MUT = "#57606A"; GRID = "#D0D7DE"
plt.rcParams.update({"axes.edgecolor": GRID, "axes.linewidth": 0.8, "axes.labelcolor": TEXT,
    "xtick.color": MUT, "ytick.color": MUT, "axes.spines.top": False, "axes.spines.right": False,
    "savefig.facecolor": "white", "figure.facecolor": "white"})

rows = list(csv.DictReader(open(SNAP / "sameorder.csv")))
labels = [r["app"] for r in rows]
fl = [float(r["flowlog_default_s"]) for r in rows]
sd = [float(r["souffle_default_noplan_s"]) for r in rows]
sp = [float(r["souffle_plan_s"]) for r in rows]
x = np.arange(len(labels)); w = 0.26

fig, ax = plt.subplots(figsize=(11, 5.4))
ax.bar(x - w, fl, w, label="FlowLog — default order", color=FL, zorder=3)
ax.bar(x, sd, w, label="Soufflé — default order (no .plan)", color=SF_DEF, zorder=3)
ax.bar(x + w, sp, w, label="Soufflé — its tuned .plan", color=SF_PLAN, zorder=3)
ax.set_yscale("log"); ax.set_ylabel("solve time (s, log)", fontsize=11)
ax.set_title("Same join order ⇒ the mid-app gaps vanish (ties); Soufflé's .plan then re-opens a lead\n"
             "only Soufflé can use. Real engine gap remains on xalan (1.16×) and h2o (1.88×). 32 threads.",
             loc="left", color=TEXT, fontsize=11, fontweight="600", pad=14)
ax.grid(True, axis="y", color=GRID, linewidth=0.8, zorder=0); ax.set_axisbelow(True)
ax.legend(loc="upper left", frameon=False, fontsize=9.5)
ax.set_xticks(x); ax.set_xticklabels(labels, fontsize=10)
for i in range(len(labels)):
    r = fl[i] / sd[i]
    tag = f"{r:.2f}×" + (" (tie)" if 0.97 <= r <= 1.05 else "")
    ax.annotate(tag, (x[i] - w / 2, max(fl[i], sd[i])), textcoords="offset points", xytext=(0, 5),
                ha="center", fontsize=9, color=(TEXT if r > 1.05 else "#1A7F37"), fontweight="700")
fig.tight_layout()
for ext in ("png", "svg"):
    fig.savefig(SNAP / f"sameorder.{ext}", bbox_inches="tight", dpi=150)
print("wrote sameorder.*")
