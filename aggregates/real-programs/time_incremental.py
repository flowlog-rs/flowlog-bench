#!/usr/bin/env python3
"""Time incremental workloads made by workloads.py, with the variants interleaved.

Feeds a workload's commands.txt on stdin to each variant's incremental binary.
For each PROGRAM:WORKLOAD_DIR case: one discarded warmup run (rep 0, first
variant), then --reps rounds that run every variant once, in an order rotated
per round. Each run appends one CSV row: the time of every commit (the first
commit is the initial load; updates_s sums the other ten) and peak RSS from
GNU time.

The outputs of each variant's rep-1 run are compared with the first
variant's, commit by commit, after adding up the +1/-1 rows. Exits 1 if they
differ.

Example:
  time_incremental.py --variant main=<main bins> --variant pr=<pr bins> \\
      --output incremental.csv cc_out:<work>/cc-lj250k sssp_out:<work>/sssp-lj250k
"""

import argparse
import collections
import csv
from pathlib import Path
import re
import shutil
import tempfile

from time_batch import rotated, run, seconds

FIELDS = ["variant", "program", "workload", "workers", "rep", "load_s", "updates_s",
          "peak_rss_kib", "commit_s"]


def net_rows(path):
    counts = collections.Counter()
    with path.open() as handle:
        for line in handle:
            *row, diff = line.rstrip("\n").split("\t")
            counts[tuple(row)] += int(diff)
    return {row: count for row, count in counts.items() if count}


def differing_commits(left, right):
    names = sorted({p.name for d in (left, right) for p in d.glob("*_t*.csv")})
    return [name for name in names
            if (net_rows(left / name) if (left / name).exists() else {})
            != (net_rows(right / name) if (right / name).exists() else {})]


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--variant", action="append", required=True, metavar="NAME=BIN_DIR",
                        help="a build.sh output directory; give one per variant")
    parser.add_argument("--output", type=Path, required=True, help="CSV file, appended to")
    parser.add_argument("--reps", type=int, default=7)
    parser.add_argument("--workers", type=int, default=32)
    parser.add_argument("cases", nargs="+", metavar="PROGRAM:WORKLOAD_DIR")
    args = parser.parse_args()
    variants = [(name, Path(path)) for name, _, path in (v.partition("=") for v in args.variant)]
    new = not args.output.exists()
    failed = []
    with args.output.open("a", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        if new:
            writer.writeheader()
        for case in args.cases:
            program, _, workload = case.partition(":")
            workload = Path(workload).resolve()
            plan = [(0, variants[0])] + [
                (rep, variant) for rep in range(1, args.reps + 1)
                for variant in rotated(variants, rep)
            ]
            with tempfile.TemporaryDirectory() as tmp:
                scratch = Path(tmp)
                for rep, (name, bins) in plan:
                    out = scratch / (f"kept-{name}" if rep == 1 else "out")
                    shutil.rmtree(out, ignore_errors=True)
                    out.mkdir()
                    with (workload / "commands.txt").open() as commands:
                        text, (_, rss) = run(bins / "incremental" / program,
                                             ["-w", str(args.workers), "-D", str(out)],
                                             scratch, stdin=commands, cwd=out)
                    commits = [seconds(t) for t in
                               re.findall(r"^(\S+):\s+Committed & executed", text, re.M)]
                    row = {
                        "variant": name, "program": program, "workload": workload.name,
                        "workers": args.workers, "rep": rep, "load_s": f"{commits[0]:.4f}",
                        "updates_s": f"{sum(commits[1:]):.4f}", "peak_rss_kib": rss,
                        "commit_s": ";".join(f"{c:.4f}" for c in commits),
                    }
                    writer.writerow(row)
                    handle.flush()
                    print(",".join(str(row[field]) for field in FIELDS), flush=True)
                if args.reps:
                    first = variants[0][0]
                    for name, _ in variants[1:]:
                        bad = differing_commits(scratch / f"kept-{first}", scratch / f"kept-{name}")
                        print(f"{case}: {name} vs {first}: "
                              + (f"DIFFERENT in {', '.join(bad)}" if bad else "same outputs"))
                        if bad:
                            failed.append(f"{case} ({name})")
    if failed:
        raise SystemExit(f"outputs differ: {' '.join(failed)}")


if __name__ == "__main__":
    main()
