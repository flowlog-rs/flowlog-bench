#!/usr/bin/env python3
"""Compare FlowLog aggregation pipelines inside one executable.

All modes live in one binary, so code-layout effects cancel. Each sample runs
every mode of one (scenario, aggregation) back to back, in an order rotated
per sample; ratios are paired within a sample.
"""

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

SCENARIOS = {
    "small-groups": {"groups": 1_000_000, "values": 4, "duplicates": 1, "touched": 1_000},
    "large-groups": {"groups": 1_000, "values": 4_000, "duplicates": 1, "touched": 10},
    "small-groups-dup4": {"groups": 250_000, "values": 4, "duplicates": 4, "touched": 1_000},
    "large-groups-dup4": {"groups": 1_000, "values": 1_000, "duplicates": 4, "touched": 10},
}
EXTREMA = ("batch", "batch-nodedup", "batch-fused", "inc", "inc-fused")
ADDITIVE = ("batch", "batch-fused", "inc", "inc-fused", "inc-weight")
MODES = {"min": EXTREMA, "max": EXTREMA, "sum": ADDITIVE, "count": ADDITIVE}
FIELDS = [
    "scenario", "kind", "mode", "workers", "sample", "position",
    "load_s", "updates_s", "peak_rss_kib", "verified", "checked_updates",
]


def paired(rows, baseline, mode, metric):
    """Per-sample `baseline / mode` ratios; above 1 means `mode` is faster."""
    by_sample = {}
    for row in rows:
        if row["mode"] in (baseline, mode):
            by_sample.setdefault(row["sample"], {})[row["mode"]] = row[metric]
    ratios = [s[baseline] / s[mode] for s in by_sample.values() if baseline in s and mode in s]
    if not ratios:
        return None
    low, high = extrema.interval(ratios)
    return {"median": statistics.median(ratios), "ci95_low": low, "ci95_high": high}


def scaled(scenario, scale):
    return SCENARIOS[scenario] | {"groups": SCENARIOS[scenario]["groups"] * scale}


def summarize(rows, scenario, kind, workers, shape):
    measured = [
        row for row in rows
        if row["scenario"] == scenario and row["kind"] == kind
        and row["workers"] == workers and row["sample"] >= 0
    ]
    result = []
    for mode in MODES[kind]:
        own = [row for row in measured if row["mode"] == mode]
        if not own:
            continue
        entry = {
            "scenario": scenario,
            "kind": kind,
            "mode": mode,
            "workers": workers,
            "samples": len(own),
            **shape,
            "source_rows": shape["groups"] * shape["values"] * shape["duplicates"],
            "load_median_s": statistics.median(row["load_s"] for row in own),
            "peak_rss_median_kib": statistics.median(row["peak_rss_kib"] for row in own),
            "load_speedup_vs_inc": paired(measured, "inc", mode, "load_s"),
            "load_speedup_vs_batch": paired(measured, "batch", mode, "load_s"),
        }
        if mode.startswith("inc"):
            entry["updates_median_s"] = statistics.median(row["updates_s"] for row in own)
            entry["updates_speedup_vs_inc"] = paired(measured, "inc", mode, "updates_s")
        result.append(entry)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--warmup-rounds", type=int, default=2)
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--scale", type=int, default=1, help="multiply every scenario's groups")
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=list(SCENARIOS))
    parser.add_argument("--kinds", nargs="+", choices=MODES, default=list(MODES))
    parser.add_argument("--modes", nargs="+", help="run only these modes")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    extrema.PROGRAM = ROOT / "programs/aggregation_modes/main.rs"
    binary = extrema.build(args.source.resolve(), args.output / "build")
    node, cpus = extrema.physical_cpus()
    if args.workers > len(cpus):
        raise RuntimeError(f"only {len(cpus)} physical CPUs on node {node}")
    pinned = ",".join(map(str, sorted(cpus)[-args.workers:]))
    rows, summary = [], []
    with (args.output / "attempts.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=FIELDS)
        writer.writeheader()
        for scenario in args.scenarios:
            shape = scaled(scenario, args.scale)
            for kind in args.kinds:
                modes = [m for m in MODES[kind] if not args.modes or m in args.modes]
                for sample in range(-1, args.runs):
                    shift = sample % len(modes)
                    for position, mode in enumerate(modes[shift:] + modes[:shift]):
                        stem = args.output / f"{scenario}-{kind}-{mode}-w{args.workers}-{sample}"
                        command = [
                            "/usr/bin/time", "-f", "%M", "-o", f"{stem}.rss",
                            "numactl", f"--physcpubind={pinned}", f"--membind={node}",
                            str(binary), mode, kind, str(args.workers), str(shape["groups"]),
                            str(shape["values"]), str(shape["duplicates"]),
                            str(args.warmup_rounds), str(args.rounds), str(shape["touched"]),
                        ]
                        result = subprocess.run(command, text=True, capture_output=True)
                        Path(f"{stem}.stdout").write_text(result.stdout)
                        Path(f"{stem}.stderr").write_text(result.stderr)
                        if result.returncode:
                            raise RuntimeError(f"{' '.join(command)}\n{result.stderr}")
                        metrics = json.loads(result.stdout)
                        if not metrics["verified"]:
                            raise RuntimeError(f"unverified output: {stem}")
                        row = {
                            "scenario": scenario,
                            "kind": kind,
                            "mode": mode,
                            "workers": args.workers,
                            "sample": sample,
                            "position": position,
                            "peak_rss_kib": int(Path(f"{stem}.rss").read_text()),
                            **metrics,
                        }
                        writer.writerow(row)
                        file.flush()
                        rows.append(row)
                entries = summarize(rows, scenario, kind, args.workers, shape)
                summary.extend(entries)
                cells = []
                for entry in entries:
                    cell = f"{entry['mode']}={entry['load_median_s']:.3f}s"
                    if "updates_median_s" in entry:
                        cell += f"/{entry['updates_median_s']:.4f}s"
                    cells.append(cell)
                print(f"{scenario} {kind}: " + " ".join(cells), flush=True)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (args.output / "metadata.json").write_text(json.dumps({
        "source": extrema.source_info(args.source.resolve()),
        "binary": {"path": str(binary), "sha256": extrema.digest(binary)},
        "pinned_cpus": pinned,
        "numa_node": node,
        "parameters": vars(args) | {"source": str(args.source), "output": str(args.output)},
        "scenarios": {name: scaled(name, args.scale) for name in args.scenarios},
        "all_outputs_verified": True,
        "semantics": (
            "source rows (group, 2*value, witness) project to (group, value); witnesses are "
            "duplicate derivations. Every run verifies its full output update stream."
        ),
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
