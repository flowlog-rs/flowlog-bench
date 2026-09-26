#!/usr/bin/env python3
"""Interleave batch aggregate designs across several harness builds.

Build the harness once per FlowLog checkout with
`aggregate_designs.py --source <checkout> --build <dir> --build-only`
(it prints the binary path), then name each binary with `--binary`.
Each sample runs every variant of one cell back to back, in an order
rotated per sample, so ratios are paired within a sample and drift between
builds cancels. Sample -1 is a discarded warmup.

Example: PR runtime vs a patched runtime, both against main's design.
  interleave_builds.py --binary pr=<pr build> --binary patch=<patch build> \\
      --variants pr/b-main pr/b-weights patch/b-weights \\
      --ratios patch/b-weights,pr/b-main,vs-main patch/b-weights,pr/b-weights,vs-pr \\
      --kinds min max --output <dir>
"""

import argparse
import csv
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess

RUNNER = Path(__file__).resolve().parent / "aggregate_designs.py"
spec = importlib.util.spec_from_file_location("designs", RUNNER)
designs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(designs)

FIELDS = ["shape", "kind", "placement", "variant", "sample", "position", "load_s", "rss_kib"]


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", action="append", required=True, help="NAME=PATH")
    parser.add_argument("--variants", nargs="+", required=True, help="NAME/DESIGN ...")
    parser.add_argument("--ratios", nargs="+", required=True,
                        help="TOP,BOTTOM,LABEL ...: paired time and memory ratios")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=9)
    parser.add_argument("--workers", type=int, default=32)
    parser.add_argument("--scale", type=int, default=8,
                        help="multiply groups (values for global shapes)")
    parser.add_argument("--shapes", nargs="+", default=list(designs.SHAPES),
                        choices=list(designs.SHAPES))
    parser.add_argument("--kinds", nargs="+", default=["min", "max"],
                        choices=["min", "max", "sum", "count"])
    parser.add_argument("--placements", nargs="+", default=["local"], choices=["local", "spread"])
    args = parser.parse_args()
    binaries = dict(entry.split("=", 1) for entry in args.binary)
    variants = [tuple(v.split("/", 1)) for v in args.variants]
    ratios = [tuple(r.split(",", 2)) for r in args.ratios]
    names = {f"{b}/{m}" for b, m in variants}
    for top, bottom, _ in ratios:
        if not {top, bottom} <= names:
            parser.error(f"ratio {top},{bottom} names a variant that is not run")
    for name, _ in variants:
        if name not in binaries:
            parser.error(f"variant {name}/... has no --binary {name}=...")

    args.output.mkdir(parents=True, exist_ok=False)
    node, cpus = designs.extrema.physical_cpus()
    pinned = ",".join(map(str, sorted(cpus)[-args.workers:]))
    summary = []
    with (args.output / "attempts.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=FIELDS)
        writer.writeheader()
        for shape_name in args.shapes:
            scaled = "values" if shape_name in designs.GLOBAL else "groups"
            base = designs.SHAPES[shape_name]
            shape = base | {scaled: base[scaled] * args.scale}
            for kind in args.kinds:
                for placement in args.placements:
                    runs = {f"{b}/{m}": {} for b, m in variants}
                    for sample in range(-1, args.runs):
                        shift = sample % len(variants)
                        order = variants[shift:] + variants[:shift]
                        for position, (name, mode) in enumerate(order):
                            stem = args.output / f"{shape_name}-{kind}-{placement}-{name}-{mode}-{sample}"
                            command = [
                                "/usr/bin/time", "-f", "%M", "-o", f"{stem}.rss",
                                "numactl", f"--physcpubind={pinned}", f"--membind={node}",
                                binaries[name], mode, kind, str(args.workers),
                                str(shape["groups"]), str(shape["values"]),
                                str(shape["duplicates"]), placement, "0", "0", "0", "0", "0",
                            ]
                            result = subprocess.run(command, text=True, capture_output=True)
                            if result.returncode:
                                raise RuntimeError(f"{' '.join(command)}\n{result.stderr}")
                            metrics = json.loads(result.stdout)
                            if not metrics["verified"]:
                                raise RuntimeError(f"unverified output: {stem}")
                            rss = int(Path(f"{stem}.rss").read_text().split()[-1])
                            row = {
                                "shape": shape_name, "kind": kind, "placement": placement,
                                "variant": f"{name}/{mode}", "sample": sample,
                                "position": position, "load_s": metrics["load_s"],
                                "rss_kib": rss,
                            }
                            writer.writerow(row)
                            file.flush()
                            if sample >= 0:
                                runs[row["variant"]][sample] = (metrics["load_s"], rss)
                    entry = {
                        "shape": shape_name, "kind": kind, "placement": placement,
                        "workers": args.workers, "scale": args.scale,
                        "load_s": {v: statistics.median(t for t, _ in s.values())
                                   for v, s in runs.items()},
                        "rss_kib": {v: statistics.median(r for _, r in s.values())
                                    for v, s in runs.items()},
                        "ratios": {},
                    }
                    for top, bottom, label in ratios:
                        speed = [runs[top][s][0] / runs[bottom][s][0] for s in runs[top]]
                        memory = [runs[top][s][1] / runs[bottom][s][1] for s in runs[top]]
                        entry["ratios"][label] = {
                            "time": statistics.median(speed), "time_lo": min(speed),
                            "time_hi": max(speed), "rss": statistics.median(memory),
                        }
                    summary.append(entry)
                    text = " ".join(f"{label}: t={r['time']:.2f} rss={r['rss']:.2f}"
                                    for label, r in entry["ratios"].items())
                    print(f"{shape_name} {kind} {placement}: {text}", flush=True)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (args.output / "metadata.json").write_text(json.dumps({
        "binaries": {
            name: {"path": path, "sha256": designs.extrema.digest(Path(path))}
            for name, path in binaries.items()
        },
        "pinned_cpus": pinned, "numa_node": node,
        "parameters": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
