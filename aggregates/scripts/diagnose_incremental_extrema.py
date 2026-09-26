#!/usr/bin/env python3
"""Interleave explicitly selected aggregation binaries for causal comparisons."""

import argparse
import csv
import datetime
import json
from pathlib import Path
import statistics
import subprocess

from incremental_extrema import digest, physical_cpus


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", action="append", required=True, help="NAME=BINARY")
    parser.add_argument("--mode", action="append", default=[], help="NAME:runtime|scan|endpoint")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--rounds", type=int, default=64)
    parser.add_argument("--groups", type=int, default=128)
    parser.add_argument("--values", type=int, default=4096)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--kinds", nargs="+", choices=["min", "max", "sum"], default=["min", "max", "sum"])
    args = parser.parse_args()
    variants = {name: Path(binary).resolve() for name, binary in
                (value.split("=", 1) for value in args.variant)}
    modes = {}
    for value in args.mode:
        name, mode = value.split(":", 1)
        if name not in variants or mode not in ("runtime", "scan", "endpoint"):
            parser.error("invalid variant mode")
        modes[name] = mode
    node, cpus = physical_cpus()
    cpus.sort()
    if min(args.runs, args.rounds, args.groups, args.workers) < 1 or args.values < 3:
        parser.error("invalid workload dimensions")
    if args.workers > len(cpus):
        parser.error("not enough physical cores on one NUMA node")
    args.output.mkdir(parents=True, exist_ok=False)
    metadata = {
        "started": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "parameters": vars(args) | {"output": str(args.output)},
        "variants": {name: {"path": str(path), "sha256": digest(path), "mode": modes.get(name)}
                     for name, path in variants.items()},
        "cpus": cpus[:args.workers],
        "numa_node": node,
    }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    rows = []
    with (args.output / "attempts.csv").open("w", newline="") as file:
        writer = None
        names = list(variants)
        for kind in args.kinds:
            for sample in range(-1, args.runs):
                shift = (sample + 1) % len(names)
                order = names[shift:] + names[:shift]
                seen = set()
                for position, name in enumerate(order):
                    stem = args.output / f"{kind}-{sample}-{name}"
                    invocation = [
                        "timeout", "--kill-after=5s", "120s",
                        "/usr/bin/time", "-f", "%M", "-o", str(stem) + ".rss",
                        "numactl", f"--physcpubind={','.join(map(str, cpus[:args.workers]))}",
                        f"--membind={node}", str(variants[name]),
                        kind, "winner", str(args.workers), str(args.groups), str(args.values),
                        "8", str(args.rounds),
                    ]
                    if name in modes:
                        invocation.append(modes[name])
                    result = subprocess.run(invocation, text=True, capture_output=True)
                    Path(str(stem) + ".stdout").write_text(result.stdout)
                    Path(str(stem) + ".stderr").write_text(result.stderr)
                    if result.returncode:
                        raise RuntimeError(f"{name} failed: {result.returncode}: {result.stderr}")
                    metrics = json.loads(result.stdout)
                    if not metrics["verified"]:
                        raise RuntimeError("unverified output")
                    seen.add(metrics["digest"])
                    row = dict(kind=kind, variant=name, sample=sample, position=position,
                               peak_rss_kib=int(Path(str(stem) + ".rss").read_text()), **metrics)
                    if writer is None:
                        writer = csv.DictWriter(file, fieldnames=row)
                        writer.writeheader()
                    writer.writerow(row)
                    file.flush()
                    rows.append(row)
                if len(seen) != 1:
                    raise RuntimeError("variant output mismatch")
            print(kind, {name: round(statistics.median(
                r["updates_s"] for r in rows
                if r["kind"] == kind and r["variant"] == name and r["sample"] >= 0
            ), 6) for name in names}, flush=True)
    metadata["completed"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    metadata["all_outputs_verified"] = True
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
