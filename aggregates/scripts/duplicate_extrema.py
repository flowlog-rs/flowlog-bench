#!/usr/bin/env python3
"""Measure scan versus endpoint after duplicate derivations are set-normalized."""

import argparse
import csv
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("extrema", ROOT / "scripts/incremental_extrema.py")
extrema = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extrema)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--rounds", type=int, default=128)
    parser.add_argument("--groups", type=int, default=4)
    parser.add_argument("--values", type=int, default=4096)
    parser.add_argument("--duplicates", type=int, nargs="+", default=[1, 8, 32])
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    extrema.PROGRAM = ROOT / "programs/incremental_extrema/duplicates.rs"
    binary = extrema.build(args.source.resolve(), args.output / "build")
    node, cpus = extrema.physical_cpus()
    cpu = min(cpus)
    rows = []
    fields = [
        "kind", "duplicates", "implementation", "sample", "position",
        "updates_s", "peak_rss_kib", "verified", "checked_updates",
    ]
    with (args.output / "attempts.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for duplicates in args.duplicates:
            for kind in ("min", "max"):
                for sample in range(-1, args.runs):
                    order = ("scan", "endpoint") if sample % 2 == 0 else ("endpoint", "scan")
                    checked = set()
                    for position, implementation in enumerate(order):
                        stem = args.output / f"{kind}-d{duplicates}-{sample}-{implementation}"
                        command = [
                            "/usr/bin/time", "-f", "%M", "-o", str(stem) + ".rss",
                            "numactl", f"--physcpubind={cpu}", f"--membind={node}",
                            str(binary), kind, implementation, "1", str(args.groups),
                            str(args.values), str(duplicates), "8", str(args.rounds),
                        ]
                        result = subprocess.run(command, text=True, capture_output=True)
                        Path(str(stem) + ".stdout").write_text(result.stdout)
                        Path(str(stem) + ".stderr").write_text(result.stderr)
                        if result.returncode:
                            raise RuntimeError(result.stderr)
                        metrics = json.loads(result.stdout)
                        if not metrics["verified"]:
                            raise RuntimeError("unverified result")
                        checked.add(metrics["checked_updates"])
                        row = {
                            "kind": kind,
                            "duplicates": duplicates,
                            "implementation": implementation,
                            "sample": sample,
                            "position": position,
                            "peak_rss_kib": int(Path(str(stem) + ".rss").read_text()),
                            **metrics,
                        }
                        writer.writerow(row)
                        file.flush()
                        rows.append(row)
                    if len(checked) != 1:
                        raise RuntimeError("output mismatch")
                selected = [
                    row for row in rows
                    if row["kind"] == kind and row["duplicates"] == duplicates
                    and row["sample"] >= 0
                ]
                medians = {
                    implementation: statistics.median(
                        row["updates_s"] for row in selected
                        if row["implementation"] == implementation
                    )
                    for implementation in ("scan", "endpoint")
                }
                print(
                    f"{kind} duplicates={duplicates}: "
                    f"{medians['scan']:.6f}s -> {medians['endpoint']:.6f}s "
                    f"({medians['scan'] / medians['endpoint']:.3f}x)",
                    flush=True,
                )
    summary = []
    for duplicates in args.duplicates:
        for kind in ("min", "max"):
            selected = [
                row for row in rows
                if row["kind"] == kind and row["duplicates"] == duplicates
                and row["sample"] >= 0
            ]
            samples = {
                implementation: sorted(
                    (row for row in selected if row["implementation"] == implementation),
                    key=lambda row: row["sample"],
                )
                for implementation in ("scan", "endpoint")
            }
            ratios = [
                scan["updates_s"] / endpoint["updates_s"]
                for scan, endpoint in zip(samples["scan"], samples["endpoint"])
            ]
            scan = statistics.median(row["updates_s"] for row in samples["scan"])
            endpoint = statistics.median(row["updates_s"] for row in samples["endpoint"])
            low, high = extrema.interval(ratios)
            summary.append({
                "kind": kind,
                "duplicates": duplicates,
                "groups": args.groups,
                "unique_values_per_group": args.values,
                "source_rows": args.groups * args.values * duplicates,
                "scan_median_s": scan,
                "endpoint_median_s": endpoint,
                "median_speedup": scan / endpoint,
                "paired_speedup_95pct_bootstrap_low": low,
                "paired_speedup_95pct_bootstrap_high": high,
            })
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (args.output / "metadata.json").write_text(json.dumps({
        "source": extrema.source_info(args.source.resolve()),
        "binary": {"path": str(binary), "sha256": extrema.digest(binary)},
        "parameters": vars(args) | {"source": str(args.source), "output": str(args.output)},
        "all_outputs_verified": True,
        "semantics": "source rows differ by duplicate id, map to identical (group,value), then flowlog_dedup before reduce",
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
