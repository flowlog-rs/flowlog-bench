#!/usr/bin/env python3
"""Paired, CPU-pinned A/B measurement of the incremental aggregation operator."""

import argparse
import csv
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
PROGRAM = ROOT / "programs/incremental_extrema/main.rs"


def command(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_info(source):
    paths = command(["git", "-C", str(source), "ls-files", "flowlog-runtime"]).splitlines()
    paths += ["Cargo.toml", "Cargo.lock"]
    return {
        "path": str(source),
        "commit": command(["git", "-C", str(source), "rev-parse", "HEAD"]),
        "patch": command(["git", "-C", str(source), "diff", "--binary"]),
        "files": {path: digest(source / path) for path in paths if (source / path).is_file()},
    }


def build(source, directory, lockfile=None):
    directory.mkdir(parents=True, exist_ok=True)
    manifest = (
        '[package]\nname = "incremental-extrema-bench"\nversion = "0.0.0"\nedition = "2024"\n'
        '[workspace]\n[dependencies]\n'
        f'flowlog-runtime = {{ path = {json.dumps(str(source / "flowlog-runtime"))} }}\n'
        '[[bin]]\nname = "incremental-extrema-bench"\n'
        f'path = {json.dumps(str(PROGRAM))}\n'
    )
    (directory / "Cargo.toml").write_text(manifest)
    if lockfile is None:
        subprocess.run(["cargo", "generate-lockfile", "--offline"], cwd=directory, check=True)
    else:
        shutil.copyfile(lockfile, directory / "Cargo.lock")
    environment = dict(os.environ)
    environment.pop("CARGO_TARGET_DIR", None)
    environment["CARGO_BUILD_JOBS"] = "4"
    with (directory / "build.log").open("w") as log:
        result = subprocess.run(
            ["cargo", "build", "--release", "--locked", "--offline"],
            cwd=directory, env=environment, stdout=log, stderr=subprocess.STDOUT,
        )
    if result.returncode:
        raise RuntimeError(f"build failed: {(directory / 'build.log').read_text()}")
    metadata = json.loads(command(
        ["cargo", "metadata", "--locked", "--offline", "--format-version=1"],
        cwd=directory,
    ))
    runtime = next(p for p in metadata["packages"] if p["name"] == "flowlog-runtime")
    if Path(runtime["manifest_path"]).resolve() != source / "flowlog-runtime/Cargo.toml":
        raise RuntimeError("built runtime does not match the selected source")
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return directory / "target/release/incremental-extrema-bench"


def physical_cpus():
    allowed = os.sched_getaffinity(0)
    selected = {}
    for line in command(["lscpu", "-p=CPU,CORE,SOCKET,NODE"]).splitlines():
        if line.startswith("#"):
            continue
        cpu, core, socket, node = map(int, line.split(","))
        if cpu in allowed:
            selected.setdefault((socket, core), (cpu, node))
    nodes = {}
    for cpu, node in selected.values():
        nodes.setdefault(node, []).append(cpu)
    return max(nodes.items(), key=lambda item: len(item[1]))


def interval(ratios):
    rng = random.Random(20260924)
    logs = [math.log(value) for value in ratios]
    samples = sorted(
        math.exp(statistics.mean(rng.choices(logs, k=len(logs)))) for _ in range(10000)
    )
    return samples[250], samples[9749]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-source", type=Path, required=True)
    parser.add_argument("--head-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "results/incremental-min-max")
    parser.add_argument("--tag", default="full")
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--rounds", type=int, default=128)
    parser.add_argument("--warmup-rounds", type=int, default=8)
    parser.add_argument("--process-warmups", type=int, default=1)
    parser.add_argument("--groups", type=int, default=128)
    parser.add_argument("--sizes", type=int, nargs="+", default=[64, 4096])
    parser.add_argument("--workers", type=int, nargs="+", default=[1, 32])
    args = parser.parse_args()
    if min(args.runs, args.rounds, args.groups, *args.workers) <= 0 or min(args.sizes) < 3:
        parser.error("runs, rounds, groups and workers must be positive; sizes must be >= 3")
    if min(args.process_warmups, args.warmup_rounds) < 0:
        parser.error("warmups cannot be negative")
    base, head = args.base_source.resolve(), args.head_source.resolve()
    output = args.output.resolve()
    run_dir = output / args.tag
    run_dir.mkdir(parents=True, exist_ok=False)
    sources = {"base": source_info(base), "candidate": source_info(head)}
    if sources["base"]["patch"]:
        raise RuntimeError("baseline must be a clean checkout")
    binaries = {}
    binaries["base"] = build(base, output / "build/base")
    binaries["candidate"] = build(
        head, output / "build/candidate", output / "build/base/Cargo.lock"
    )
    if digest(output / "build/base/Cargo.lock") != digest(output / "build/candidate/Cargo.lock"):
        raise RuntimeError("dependency lockfiles differ")
    (run_dir / "binaries").mkdir()
    for side, binary in binaries.items():
        archived = run_dir / "binaries" / side
        shutil.copy2(binary, archived)
        binaries[side] = archived
    node, cpus = physical_cpus()
    cpus.sort()
    if max(args.workers) > len(cpus):
        raise RuntimeError("not enough allowed physical cores on one NUMA node")
    metadata = {
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "host": platform.node(),
        "kernel": platform.platform(),
        "cpu_topology": command(["lscpu"]),
        "bench_commit": command(["git", "-C", str(ROOT), "rev-parse", "HEAD"]),
        "sources": sources,
        "program_sha256": digest(PROGRAM),
        "runner_sha256": digest(Path(__file__)),
        "binaries": {side: {"path": str(path), "sha256": digest(path)}
                     for side, path in binaries.items()},
        "rustc": command(["rustc", "-vV"]),
        "cargo": command(["cargo", "--version"]),
        "lock_sha256": digest(output / "build/base/Cargo.lock"),
        "parameters": {key: str(value) if isinstance(value, Path) else value
                       for key, value in vars(args).items()},
        "numa_node": node,
        "physical_cpus": cpus,
        "scope": "runtime operator; excludes Datalog compilation, parsing and file I/O",
        "causal_limit": "separate build paths can change binary layout; small differences require A/A and same-executable controls",
        "timing": "max worker phase end minus min worker phase start; exact output validation afterward",
        "memory": "whole-process peak RSS, including loading and post-timing validation",
    }
    (run_dir / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    cases = []
    for workers in args.workers:
        for kind in ("min", "max"):
            cases.extend((kind, "winner", workers, size) for size in args.sizes)
            cases.append((kind, "interior", workers, max(args.sizes)))
        cases.append(("sum", "winner", workers, max(args.sizes)))
    random.Random(20260924).shuffle(cases)
    rows = []
    fields = ["kind", "pattern", "workers", "groups", "values", "rounds",
              "sample", "phase", "side", "position", "load_s", "updates_s",
              "process_wall_s", "peak_rss_kib", "checked_updates", "digest", "verified"]
    with (run_dir / "attempts.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for case_index, (kind, pattern, workers, values) in enumerate(cases):
            case_id = f"{kind}-{pattern}-w{workers}-n{values}"
            for sample in range(-args.process_warmups, args.runs):
                phase = "warmup" if sample < 0 else "measured"
                order = ("base", "candidate") if (sample + case_index) % 2 == 0 else ("candidate", "base")
                pair = {}
                for position, side in enumerate(order):
                    stem = run_dir / f"{case_id}-{phase}-{sample}-{side}"
                    invocation = [
                        "timeout", "--kill-after=5s", "120s",
                        "/usr/bin/time", "-f", "%M", "-o", str(stem) + ".rss",
                        "numactl", f"--physcpubind={','.join(map(str, cpus[:workers]))}",
                        f"--membind={node}", str(binaries[side]), kind, pattern,
                        str(workers), str(args.groups), str(values),
                        str(args.warmup_rounds), str(args.rounds),
                    ]
                    started = time.perf_counter()
                    result = subprocess.run(invocation, text=True, capture_output=True)
                    wall = time.perf_counter() - started
                    Path(str(stem) + ".stdout").write_text(result.stdout)
                    Path(str(stem) + ".stderr").write_text(result.stderr)
                    if result.returncode:
                        raise RuntimeError(f"{case_id} {side} failed ({result.returncode}): {result.stderr}")
                    metrics = json.loads(result.stdout)
                    if not metrics["verified"] or min(metrics["load_s"], metrics["updates_s"]) <= 0:
                        raise RuntimeError("missing correctness verification or invalid timing")
                    row = dict(kind=kind, pattern=pattern, workers=workers, groups=args.groups,
                               values=values, rounds=args.rounds, sample=sample, phase=phase,
                               side=side, position=position, process_wall_s=wall,
                               peak_rss_kib=int(Path(str(stem) + ".rss").read_text()), **metrics)
                    writer.writerow(row)
                    file.flush()
                    rows.append(row)
                    pair[side] = row
                if pair["base"]["digest"] != pair["candidate"]["digest"]:
                    raise RuntimeError(f"{case_id}: baseline/candidate output parity failed")
            base_median = statistics.median(
                r["updates_s"] for r in rows if r["kind"] == kind and r["pattern"] == pattern
                and r["workers"] == workers and r["values"] == values
                and r["phase"] == "measured" and r["side"] == "base"
            )
            head_median = statistics.median(
                r["updates_s"] for r in rows if r["kind"] == kind and r["pattern"] == pattern
                and r["workers"] == workers and r["values"] == values
                and r["phase"] == "measured" and r["side"] == "candidate"
            )
            print(f"{case_id}: {base_median:.6f}s -> {head_median:.6f}s "
                  f"({base_median / head_median:.3f}x)", flush=True)

    summary = []
    for kind, pattern, workers, values in sorted(cases):
        selected = [r for r in rows if (r["kind"], r["pattern"], r["workers"], r["values"])
                    == (kind, pattern, workers, values) and r["phase"] == "measured"]
        sides = {side: sorted((r for r in selected if r["side"] == side),
                              key=lambda r: r["sample"]) for side in binaries}
        ratios = [a["updates_s"] / b["updates_s"]
                  for a, b in zip(sides["base"], sides["candidate"])]
        item = dict(kind=kind, pattern=pattern, workers=workers, groups=args.groups,
                    values=values, rounds=args.rounds, runs=args.runs)
        for side, samples in sides.items():
            for metric in ("updates_s", "load_s", "process_wall_s", "peak_rss_kib"):
                item[f"{side}_{metric}_median"] = statistics.median(r[metric] for r in samples)
            item[f"{side}_updates_s_min"] = min(r["updates_s"] for r in samples)
            item[f"{side}_updates_s_max"] = max(r["updates_s"] for r in samples)
        item["speedup"] = item["base_updates_s_median"] / item["candidate_updates_s_median"]
        item["paired_geomean_speedup"] = statistics.geometric_mean(ratios)
        item["paired_speedup_95pct_bootstrap_low"], item["paired_speedup_95pct_bootstrap_high"] = interval(ratios)
        summary.append(item)
    with (run_dir / "summary.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=summary[0])
        writer.writeheader()
        writer.writerows(summary)
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if source_info(base) != sources["base"] or source_info(head) != sources["candidate"]:
        raise RuntimeError("engine source changed during the experiment")
    metadata["completed_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    metadata["all_outputs_verified"] = True
    metadata["attempts"] = len(rows)
    (run_dir / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
