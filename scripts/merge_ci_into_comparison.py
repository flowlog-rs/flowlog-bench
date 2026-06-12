#!/usr/bin/env python3
"""Merge DOOP context-insensitive results into the cross_engine comparison CSV.

context_insensitive (DOOP points-to) is benchmarked by
scripts/context_insensitive_compare.sh (it needs the missing-input fact overlay
and a real output dir, since it uses `.output` rather than `.printsize`). This
script lifts each app's per-dataset logs into the SAME 25-column schema +
SAME metric that scripts/cross_engine.sh emits, so a single comparison CSV can
drive one unified FlowLog-vs-Souffle bar chart.

Metric parity with cross_engine.sh / scripts/lib/measure.sh:
  * FlowLog Compiler_Total = the "<dur>: Dataflow executed" stamp (solve end).
  * FlowLog Compiler_Load  = last "Data loaded for ..." stamp.
  * FlowLog Compiler_Exec  = max(Total - Load, 0).   <- the column the plot uses
  * Souffle_Total          = "Elapsed (wall clock)" from /usr/bin/time -v.
  * *_PeakRss_MB           = "Maximum resident set size (kbytes)" / 1024.

Idempotent: skips an app already present as a `context_insensitive,<app>` row.

Usage:
  scripts/merge_ci_into_comparison.py [--ci-dir results/context_insensitive] \
                                      [--csv results/benchmark/comparison_results.csv]
"""

import argparse
import csv
import os
import pathlib
import re
import sys

HEADER = ("Program,Dataset,Interp_Load,Compiler_Load,Load_Speedup,Interp_Exec,"
          "Compiler_Exec,Exec_Speedup,Interp_Total,Compiler_Total,Total_Speedup,"
          "Interp_PeakRss_MB,Compiler_PeakRss_MB,Souffle_Total,Souffle_PeakRss_MB,"
          "Souffle_vs_Compiler_Total,Crosscheck_Souffle,Interp_RunsSucceeded,"
          "Compiler_RunsSucceeded,Souffle_RunsSucceeded,Ddlog_Total,Ddlog_PeakRss_MB,"
          "Ddlog_vs_Compiler_Total,Crosscheck_Ddlog,Ddlog_RunsSucceeded").split(",")

_DUR = re.compile(r"([0-9]+\.?[0-9]*)\s*(µs|ms|s)")


def _dur_to_s(text):
    m = _DUR.search(text)
    if not m:
        return None
    v, unit = float(m.group(1)), m.group(2)
    return v / 1e6 if unit == "µs" else v / 1e3 if unit == "ms" else v


def _last(path, needle):
    """Last line containing `needle`, parsed to seconds."""
    if not path.is_file():
        return None
    hit = None
    for line in path.read_text(errors="replace").splitlines():
        if needle in line:
            hit = line
    return _dur_to_s(hit) if hit else None


def _peak_rss_mb(time_txt):
    if not time_txt.is_file():
        return None
    for line in time_txt.read_text(errors="replace").splitlines():
        if "Maximum resident set size" in line:
            kb = re.search(r"(\d+)", line.split(":")[-1])
            if kb:
                return int(kb.group(1)) / 1024.0
    return None


def _elapsed_wall_s(time_txt):
    if not time_txt.is_file():
        return None
    for line in time_txt.read_text(errors="replace").splitlines():
        if "Elapsed (wall clock)" in line:
            # Label contains colons ("... (h:mm:ss or m:ss):"); the value is the
            # last whitespace token, e.g. "0:31.99" or "1:02:03" (mirror measure.sh $NF).
            field = line.split()[-1]
            try:
                s = 0.0
                for p in field.split(":"):
                    s = s * 60 + float(p)
                return s
            except ValueError:
                return None
    return None


def _souffle_ok(time_txt):
    """True only if the souffle run recorded Exit status 0."""
    if not time_txt.is_file():
        return False
    for line in time_txt.read_text(errors="replace").splitlines():
        if "Exit status" in line:
            return line.strip().endswith("0")
    return False


def _ratio(n, d):
    return f"{n / d:.6f}" if (n is not None and d not in (None, 0)) else "N/A"


def load_existing(csv_path):
    have = set()
    if csv_path.is_file():
        with csv_path.open() as fh:
            for row in csv.reader(fh):
                if len(row) >= 2:
                    have.add((row[0], row[1]))
    return have


def verdict_for(ci_dir, app, summary):
    row = summary.get(app)
    if row:
        v = row.get("verdict", "")
        rc = row.get("nonHR_rowcounts_equal") or row.get("rowcounts_equal") or ""
        if v == "MATCH":
            return f"match({rc})" if rc else "match"
        if v:
            return v
    return "n/a"


def load_summary(ci_dir):
    s = {}
    f = ci_dir / "summary.csv"
    if f.is_file():
        with f.open() as fh:
            for row in csv.DictReader(fh):
                s[row["dataset"]] = row
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ci-dir", default="results/context_insensitive")
    ap.add_argument("--csv", default="results/benchmark/comparison_results.csv")
    ap.add_argument("--program", default="context_insensitive",
                    help="Program label written in column 1")
    args = ap.parse_args()

    ci_dir = pathlib.Path(args.ci_dir)
    csv_path = pathlib.Path(args.csv)
    if not ci_dir.is_dir():
        print(f"ci-dir not found: {ci_dir}", file=sys.stderr)
        return 1

    summary = load_summary(ci_dir)
    apps = sorted(d.name for d in ci_dir.iterdir()
                  if d.is_dir() and (d / "flowlog_run.log").is_file())
    if not apps:
        print(f"no per-app logs under {ci_dir}", file=sys.stderr)
        return 1

    csv_path.parent.mkdir(parents=True, exist_ok=True)
    if not csv_path.is_file() or csv_path.stat().st_size == 0:
        csv_path.write_text(",".join(HEADER) + "\n")
    have = load_existing(csv_path)

    appended, skipped = 0, []
    with csv_path.open("a", newline="") as out:
        w = csv.writer(out)
        for app in apps:
            if (args.program, app) in have:
                skipped.append(f"{app}(exists)")
                continue
            d = ci_dir / app
            fl_run, fl_time = d / "flowlog_run.log", d / "flowlog_time.txt"
            sf_time = d / "souffle_time.txt"

            c_total = _last(fl_run, "Dataflow executed")
            c_load = _last(fl_run, "Data loaded for")
            c_exec = max(c_total - c_load, 0.0) if (c_total and c_load is not None) else c_total
            c_rss = _peak_rss_mb(fl_time)

            sf_total = _elapsed_wall_s(sf_time) if _souffle_ok(sf_time) else None
            sf_rss = _peak_rss_mb(sf_time) if sf_total is not None else None

            if c_total is None or c_rss is None:
                skipped.append(f"{app}(no-flowlog)")
                continue

            row = ["N/A"] * len(HEADER)
            row[0], row[1] = args.program, app
            row[3] = f"{c_load:.9f}" if c_load is not None else "N/A"   # Compiler_Load
            row[6] = f"{c_exec:.9f}" if c_exec is not None else "N/A"   # Compiler_Exec
            row[9] = f"{c_total:.9f}"                                   # Compiler_Total
            row[12] = f"{c_rss:.2f}"                                    # Compiler_PeakRss_MB
            row[13] = f"{sf_total:.9f}" if sf_total is not None else "N/A"  # Souffle_Total
            row[14] = f"{sf_rss:.2f}" if sf_rss is not None else "N/A"      # Souffle_PeakRss_MB
            row[15] = _ratio(sf_total, c_total)                        # Souffle_vs_Compiler_Total
            row[16] = verdict_for(ci_dir, app, summary)                # Crosscheck_Souffle
            row[18] = "1"                                              # Compiler_RunsSucceeded
            row[19] = "1" if sf_total is not None else "N/A"           # Souffle_RunsSucceeded
            row[23] = "n/a"                                            # Crosscheck_Ddlog
            w.writerow(row)
            appended += 1

    print(f"merged {appended} context_insensitive row(s) into {csv_path}")
    if skipped:
        print("skipped: " + ", ".join(skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
