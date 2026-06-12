#!/usr/bin/env python3
"""Render results/benchmark/comparison_results.csv as markdown tables:
  1. wall time  — per engine Total (slowdown vs FlowLog) + Load/Exec split
  2. peak RSS   — per engine, GiB
  3. crosscheck — souffle/ddlog/ascent size verdicts vs FlowLog
FlowLog (compiler) is the baseline engine throughout."""
import csv
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
path = sys.argv[1] if len(sys.argv) > 1 else str(
    REPO_ROOT / "results" / "benchmark" / "comparison_results.csv")

def f(cell):
    try:
        return float(cell)
    except (TypeError, ValueError):
        return None

def total_cell(t, base):
    if t is None:
        return "—"
    s = f"{t:,.1f}"
    if base:
        s += f" ({t / base:.1f}×)"
    return s

def num(v):
    return f"{v:,.1f}" if v is not None else "?"

def split_cell(load, exc):
    if load is None and exc is None:
        return "—"
    return f"{num(load)}+{num(exc)}"

def mem_cell(cell):
    v = f(cell)
    return f"{v / 1024:.1f}" if v is not None else "—"

def xc(cell):
    cell = (cell or "").strip()
    if cell.startswith("match"):
        return "ok"
    if cell in ("", "n/a"):
        return "—"
    return cell  # MISMATCH/PARTIAL surfaced verbatim

with open(path) as fh:
    rows = list(csv.DictReader(fh))
rows.sort(key=lambda r: (r["Program"], r["Dataset"]))

print("## Wall time (seconds, median of runs; slowdown vs FlowLog; load+exec split)\n")
print("| Program/Dataset | FlowLog | FL load+exec | Soufflé | Sf load+exec "
      "| DDlog | DD load+exec | Ascent | As load+exec |")
print("|---|---|---|---|---|---|---|---|---|")
for r in rows:
    fl = f(r.get("Compiler_Total"))
    print(f"| {r['Program']}/{r['Dataset']} "
          f"| {total_cell(fl, None)} "
          f"| {split_cell(f(r.get('Compiler_Load')), f(r.get('Compiler_Exec')))} "
          f"| {total_cell(f(r.get('Souffle_Total')), fl)} "
          f"| {split_cell(f(r.get('Souffle_Load')), f(r.get('Souffle_Exec')))} "
          f"| {total_cell(f(r.get('Ddlog_Total')), fl)} "
          f"| {split_cell(f(r.get('Ddlog_Load')), f(r.get('Ddlog_Exec')))} "
          f"| {total_cell(f(r.get('Ascent_Total')), fl)} "
          f"| {split_cell(f(r.get('Ascent_Load')), f(r.get('Ascent_Exec')))} |")

print("\n## Peak RSS (GiB)\n")
print("| Program/Dataset | FlowLog | Soufflé | DDlog | Ascent |")
print("|---|---|---|---|---|")
for r in rows:
    print(f"| {r['Program']}/{r['Dataset']} "
          f"| {mem_cell(r.get('Compiler_PeakRss_MB'))} "
          f"| {mem_cell(r.get('Souffle_PeakRss_MB'))} "
          f"| {mem_cell(r.get('Ddlog_PeakRss_MB'))} "
          f"| {mem_cell(r.get('Ascent_PeakRss_MB'))} |")

print("\n## Crosscheck (relation sizes vs FlowLog) + runs succeeded\n")
print("| Program/Dataset | Soufflé | DDlog | Ascent | runs FL/Sf/DD/As |")
print("|---|---|---|---|---|")
for r in rows:
    runs = "/".join((r.get(k) or "—").strip() or "—" for k in
                    ("Compiler_RunsSucceeded", "Souffle_RunsSucceeded",
                     "Ddlog_RunsSucceeded", "Ascent_RunsSucceeded"))
    print(f"| {r['Program']}/{r['Dataset']} "
          f"| {xc(r.get('Crosscheck_Souffle'))} | {xc(r.get('Crosscheck_Ddlog'))} "
          f"| {xc(r.get('Crosscheck_Ascent'))} | {runs} |")
