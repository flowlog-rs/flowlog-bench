#!/usr/bin/env python3
"""Paired, CPU-pinned measurements with raw records and independent medians."""

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import random
import statistics
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
METHODS = ("cross", "cross-shadow", "nested", "range1", "range", "seek", "back", "auto")
METRICS = ("secs", "load_secs", "update_secs", "per_txn_ms")
ANSWER_FIELDS = ("left_rows", "right_rows", "out", "fingerprint")


def cases(quick):
    n = 3_000 if quick else 30_000
    return [
        ("band-selective", "band", {"n": n}),
        ("band-empty", "band", {"n": n, "width": 1}),
        ("band-dense", "band", {"n": 800, "width": 16_000}),
        ("keyed-tiny-groups", "keyed", {"n": 3_000, "keys": 3_000}),
        ("keyed-selective", "keyed", {"n": n if quick else 100_000}),
        ("keyed-skew", "keyed", {"n": n, "keys": 100, "skew": 3}),
        ("interval-variable", "interval", {"n": n}),
        ("interval-few-probes", "interval", {"n": n, "m": 30}),
        ("object-conflict", "objects", {"n": n}),
        ("recursive-hop", "hop", {"n": 1_000 if quick else 10_000}),
        *[(f"txn-{side}", "txn", {"n": n, "side": side}) for side in ("l", "r", "lr")],
    ]


def options(overrides, workers, seed):
    result = dict(n=10_000, gap=10, width=100, keys=1_000, skew=1,
                  rounds=20, delta=10, side="l", w=workers, seed=seed)
    result.update(overrides)
    result.setdefault("m", result["n"])
    return result


def choose_cpus(topology, allowed, workers):
    """Choose distinct physical cores, preferring the fewest NUMA nodes."""
    nodes, seen = {}, set()
    for line in topology.splitlines():
        if not line or line.startswith("#"):
            continue
        cpu, core, socket, node = map(int, line.split(","))
        if cpu in allowed and (socket, core) not in seen:
            seen.add((socket, core))
            nodes.setdefault(node, []).append(cpu)
    cpus = []
    for node in sorted(nodes, key=lambda node: (-len(nodes[node]), node)):
        cpus.extend(nodes[node])
        if len(cpus) >= workers:
            return cpus[:workers]
    raise ValueError(f"{workers} workers requested, but only {len(cpus)} allowed physical cores")


def parse_result(stdout, workload, method, requested):
    lines = stdout.strip().splitlines()
    if len(lines) != 1:
        raise ValueError(f"expected one result line, got {stdout!r}")
    prefix = lines[0].split()
    if prefix[:2] != [workload, method]:
        raise ValueError(f"unexpected workload/method: {lines[0]}")
    fields = {}
    for field in prefix[2:]:
        name, value = field.split("=", 1)
        if name in fields:
            raise ValueError(f"duplicate result field: {name}")
        fields[name] = value
    if fields.get("check") != "ok":
        raise ValueError(f"result was not oracle-checked: {lines[0]}")
    for name, value in requested.items():
        if name not in fields:
            raise ValueError(f"missing requested field: {name}")
        actual = fields[name]
        if isinstance(value, int):
            actual = int(actual)
        elif isinstance(value, float):
            actual = float(actual)
        if actual != value:
            raise ValueError(f"requested {name}={value}, got {fields.get(name)!r}")
    for name in ("left_rows", "right_rows", "out"):
        fields[name] = int(fields[name])
        if fields[name] < 0:
            raise ValueError(f"negative {name}")
    if len(fields["fingerprint"]) != 16:
        raise ValueError("expected a 64-bit fingerprint")
    int(fields["fingerprint"], 16)
    metrics = METRICS if workload == "txn" else ("secs",)
    for name in metrics:
        fields[name] = float(fields[name])
        if not math.isfinite(fields[name]) or fields[name] <= 0:
            raise ValueError(f"invalid measurement {name}={fields[name]}")
    return fields


def summarize(case, workload, method, samples):
    metric = "per_txn_ms" if workload == "txn" else "secs"
    values = [sample[metric] for sample in samples]
    result = dict(case=case, workload=workload, method=method, runs=len(samples),
                  metric=metric, median=statistics.median(values), minimum=min(values), maximum=max(values))
    for name in METRICS:
        result[f"{name}_median"] = statistics.median([s[name] for s in samples]) if name in samples[0] else ""
    result.update({name: samples[0][name] for name in ANSWER_FIELDS})
    return result


def capture(command):
    return subprocess.run(command, cwd=ROOT, check=True, text=True, capture_output=True, timeout=60).stdout.strip()


def manifest(args, cpus, topology):
    sources = [ROOT / name for name in ("Cargo.toml", "Cargo.lock", "bench.sh", "bench.py")]
    sources += sorted((ROOT / "src").glob("*.rs"))
    dependency_tree = capture(["cargo", "tree", "--locked", "--offline", "--depth=1", "--prefix=none"])
    dependencies = {}
    for line in dependency_tree.splitlines()[1:]:
        name, version, *_ = line.split()
        dependencies[name] = version.removeprefix("v")
    if set(dependencies) != {"timely", "differential-dataflow", "flowlog-runtime", "mimalloc"}:
        raise ValueError(f"unexpected direct dependencies: {dependencies}")
    return dict(
        recorded_at=datetime.now(timezone.utc).isoformat(),
        git_commit=capture(["git", "rev-parse", "HEAD"]),
        git_status=capture(["git", "status", "--short", "--", "."]),
        source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        rustc=capture(["rustc", "-vV"]), cargo=capture(["cargo", "--version"]),
        dependencies=dependencies, host=os.uname().nodename, platform=os.uname().release,
        cpu_model=capture(["lscpu"]), topology=topology, cpus=cpus,
        inherited_cpus=sorted(os.sched_getaffinity(0)), memory_policy="inherited; no NUMA binding",
        options={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
        complete=False,
        timing="secs: worker startup through shutdown, including arrangements and fingerprint sink; excludes data generation/oracle/build",
        transaction_timing="latest post-sink preload completion to latest post-sink final completion, divided by rounds",
    )


def run(args):
    args.binary = args.binary.resolve(strict=True)
    topology = capture(["lscpu", "-p=CPU,CORE,SOCKET,NODE"])
    cpus = choose_cpus(topology, os.sched_getaffinity(0), args.workers)
    selected = cases(args.mode == "quick")
    if args.case:
        unknown = set(args.case) - {name for name, _, _ in selected}
        if unknown:
            raise ValueError(f"unknown cases: {sorted(unknown)}")
        selected = [case for case in selected if case[0] in args.case]
    methods = args.methods.split(",")
    if not methods or len(set(methods)) != len(methods) or set(methods) - set(METHODS):
        raise ValueError(f"methods must be a nonempty, duplicate-free subset of {METHODS}")
    info = manifest(args, cpus, topology)
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "manifest.json").write_text(json.dumps(info, indent=2) + "\n")
    print(f"cpus={','.join(map(str, cpus))} workers={args.workers} runs={args.runs} warmups={args.warmups}")
    print(f"results={args.output.resolve()}", flush=True)
    rng = random.Random(args.seed)
    with (args.output / "raw.jsonl").open("w") as raw, (args.output / "summary.csv").open("w", newline="") as summary:
        writer = None
        for name, workload, overrides in selected:
            eligible = [m for m in methods if not (m == "back" and workload in ("interval", "objects"))]
            if not eligible:
                raise ValueError(f"no requested method supports {name}")
            requested = options(overrides, args.workers, args.seed)
            samples = {method: [] for method in eligible}
            expected = None
            for repetition in range(-args.warmups, args.runs):
                order = eligible.copy()
                rng.shuffle(order)
                for method in order:
                    command = ["taskset", "--cpu-list", ",".join(map(str, cpus)),
                               str(args.binary), workload, method,
                               *(f"{k}={v}" for k, v in requested.items()), "check=1"]
                    completed = subprocess.run(command, cwd=ROOT, check=True, text=True,
                                               capture_output=True, timeout=args.timeout)
                    fields = parse_result(completed.stdout, workload, method, requested)
                    answer = tuple(fields[field] for field in ANSWER_FIELDS)
                    if expected is not None and answer != expected:
                        raise ValueError(f"{name}/{method}: answers or generated input sizes differ between runs")
                    expected = answer
                    raw.write(json.dumps(dict(case=name, method=method, repetition=repetition,
                                              warmup=repetition < 0, command=command, result=fields,
                                              stdout=completed.stdout, stderr=completed.stderr)) + "\n")
                    raw.flush()
                    if repetition >= 0:
                        samples[method].append(fields)
            for method in eligible:
                row = summarize(name, workload, method, samples[method])
                if writer is None:
                    writer = csv.DictWriter(summary, fieldnames=list(row))
                    writer.writeheader()
                writer.writerow(row)
                summary.flush()
                print(f"{name:22} {method:12} {row['metric']}={row['median']:.6f} "
                      f"min={row['minimum']:.6f} max={row['maximum']:.6f} out={row['out']}", flush=True)
    info["complete"] = True
    (args.output / "manifest.json").write_text(json.dumps(info, indent=2) + "\n")


def positive(text):
    value = int(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def nonnegative(text):
    value = int(text)
    if value < 0:
        raise argparse.ArgumentTypeError("must be nonnegative")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("quick", "full"), default="full", nargs="?")
    parser.add_argument("--binary", type=Path, default=ROOT / "target/release/rangejoin-toy")
    parser.add_argument("--workers", type=positive, default=1)
    parser.add_argument("--runs", type=positive, default=3)
    parser.add_argument("--warmups", type=nonnegative, default=1)
    parser.add_argument("--timeout", type=positive, default=120, help="seconds per process; failure aborts the matrix")
    parser.add_argument("--seed", type=nonnegative, default=7)
    parser.add_argument("--methods", default=",".join(METHODS))
    parser.add_argument("--case", action="append", help="run only the named case (repeatable)")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "results" / f"{datetime.now(timezone.utc):%Y%m%dT%H%M%S}-{os.getpid()}")
    args = parser.parse_args()
    try:
        run(args)
    except subprocess.CalledProcessError as error:
        print(f"error: command failed ({error.returncode}): {error.cmd}\n{error.stdout}\n{error.stderr}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
