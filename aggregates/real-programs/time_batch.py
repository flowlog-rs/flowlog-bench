#!/usr/bin/env python3
"""Time batch programs built by build.sh, with the variants interleaved.

For each PROGRAM:FACTS_DIR case: one discarded warmup run (rep 0, first
variant), then --reps rounds that run every variant once, in an order rotated
per round. Each run appends one CSV row: FlowLog's own "Dataflow executed"
time, whole-process wall time and peak RSS (from GNU time), and the
.printsize result size.

Example:
  time_batch.py --variant main=<main bins> --variant pr=<pr bins> \\
      --output batch.csv cc:<facts>/livejournal sssp:<facts>/livejournal-sssp
"""

import argparse
import csv
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

FIELDS = ["variant", "program", "dataset", "workers", "rep", "wall_s", "dataflow_s",
          "peak_rss_kib", "result_size"]
UNITS = {"ns": 1e-9, "µs": 1e-6, "us": 1e-6, "ms": 1e-3, "s": 1.0}


def seconds(text):
    """Seconds in a Rust `Duration` debug string such as `4.55s` or `850.2ms`."""
    number, unit = re.fullmatch(r"([0-9.]+)(ns|µs|us|ms|s)", text).groups()
    return float(number) * UNITS[unit]


def gnu_time(path):
    """Wall seconds and peak RSS (KiB) from a `/usr/bin/time -v` report."""
    report = {}
    for line in path.read_text().splitlines():
        key, _, value = line.strip().rpartition(": ")
        report[key] = value
    wall = report["Elapsed (wall clock) time (h:mm:ss or m:ss)"].split(":")
    return (sum(float(part) * 60 ** i for i, part in enumerate(reversed(wall))),
            int(report["Maximum resident set size (kbytes)"]))


def rotated(items, by):
    shift = by % len(items)
    return items[shift:] + items[:shift]


def run(binary, arguments, scratch, stdin=None, cwd=None):
    """Run under GNU time; return the program's output and its (wall, RSS)."""
    log, timing = scratch / "run.log", scratch / "time.log"
    command = ["/usr/bin/time", "-v", "-o", str(timing), str(binary), *arguments]
    with log.open("w") as output:
        result = subprocess.run(command, stdin=stdin, stdout=output,
                                stderr=subprocess.STDOUT, cwd=cwd)
    if result.returncode:
        raise SystemExit(f"failed ({result.returncode}): {' '.join(command)}\n"
                         + log.read_text()[-2000:])
    return log.read_text(), gnu_time(timing)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--variant", action="append", required=True, metavar="NAME=BIN_DIR",
                        help="a build.sh output directory; give one per variant")
    parser.add_argument("--output", type=Path, required=True, help="CSV file, appended to")
    parser.add_argument("--reps", type=int, default=7)
    parser.add_argument("--workers", type=int, default=32)
    parser.add_argument("cases", nargs="+", metavar="PROGRAM:FACTS_DIR")
    args = parser.parse_args()
    variants = [(name, Path(path)) for name, _, path in (v.partition("=") for v in args.variant)]
    new = not args.output.exists()
    with args.output.open("a", newline="") as handle, tempfile.TemporaryDirectory() as tmp:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        if new:
            writer.writeheader()
        scratch = Path(tmp)
        for case in args.cases:
            program, _, facts = case.partition(":")
            facts = Path(facts).resolve()
            if not facts.is_dir():  # FlowLog reads missing inputs as empty
                raise SystemExit(f"no such facts directory: {facts}")
            plan = [(0, variants[0])] + [
                (rep, variant) for rep in range(1, args.reps + 1)
                for variant in rotated(variants, rep)
            ]
            for rep, (name, bins) in plan:
                out = scratch / "out"
                shutil.rmtree(out, ignore_errors=True)
                out.mkdir()
                text, (wall, rss) = run(bins / "batch" / program, [
                    "-w", str(args.workers), "-F", str(facts), "-D", str(out)], scratch)
                dataflow = re.search(r"^(\S+):\s+Dataflow executed", text, re.M).group(1)
                row = {
                    "variant": name, "program": program, "dataset": facts.name,
                    "workers": args.workers, "rep": rep, "wall_s": f"{wall:.2f}",
                    "dataflow_s": f"{seconds(dataflow):.3f}", "peak_rss_kib": rss,
                    "result_size": "+".join(re.findall(r"size=(\d+)", text)),
                }
                writer.writerow(row)
                handle.flush()
                print(",".join(str(row[field]) for field in FIELDS), flush=True)


if __name__ == "__main__":
    main()
