#!/usr/bin/env python3
"""
graphalytics_prep.py — derive Graphalytics-shaped EDB files from an Arc.csv.

The FlowLog Graphalytics programs (pagerank, lcc, cdlp) need a few extra
EDB files beyond Arc.csv that the existing dataset cache provides:

  * Vertex.csv  — one int64 vertex id per line. Union of distinct ids that
                  appear as src or dst in Arc.csv. Required by all three.
  * MaxIter.csv — single int line K. Required by pagerank and cdlp.

Usage:

  # default delimiter is comma (matches the existing Arc.csv convention)
  python3 tools/graphalytics_prep.py vertex   /path/to/facts/livejournal
  python3 tools/graphalytics_prep.py maxiter  /path/to/facts/livejournal --k 30

  # one-shot for a whole Graphalytics suite run
  python3 tools/graphalytics_prep.py all      /path/to/facts/livejournal --k 30

Idempotent: refuses to overwrite an existing Vertex.csv/MaxIter.csv unless
--force is passed.
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
from pathlib import Path


def cmd_vertex(facts_dir: Path, delimiter: str, force: bool) -> int:
    arc = facts_dir / "Arc.csv"
    out = facts_dir / "Vertex.csv"
    if not arc.exists():
        print(f"[err] {arc} not found", file=sys.stderr)
        return 2
    if out.exists() and not force:
        print(f"[skip] {out} already exists (use --force to overwrite)")
        return 0

    vertices: set[int] = set()
    with arc.open("r", newline="") as f:
        reader = csv.reader(f, delimiter=delimiter)
        for row in reader:
            if not row:
                continue
            try:
                vertices.add(int(row[0]))
                if len(row) > 1:
                    vertices.add(int(row[1]))
            except ValueError:
                # skip header rows if present
                continue

    with out.open("w") as f:
        for v in sorted(vertices):
            f.write(f"{v}\n")
    print(f"[ok] wrote {len(vertices):,} vertices -> {out}")
    return 0


def cmd_maxiter(facts_dir: Path, k: int, force: bool) -> int:
    out = facts_dir / "MaxIter.csv"
    if out.exists() and not force:
        print(f"[skip] {out} already exists (use --force to overwrite)")
        return 0
    with out.open("w") as f:
        f.write(f"{k}\n")
    print(f"[ok] wrote MaxIter={k} -> {out}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_v = sub.add_parser("vertex", help="derive Vertex.csv from Arc.csv")
    p_v.add_argument("facts_dir", type=Path)
    p_v.add_argument("--delimiter", default=",")
    p_v.add_argument("--force", action="store_true")

    p_m = sub.add_parser("maxiter", help="write MaxIter.csv")
    p_m.add_argument("facts_dir", type=Path)
    p_m.add_argument("--k", type=int, default=30, help="number of iterations (default: 30)")
    p_m.add_argument("--force", action="store_true")

    p_a = sub.add_parser("all", help="vertex + maxiter in one call")
    p_a.add_argument("facts_dir", type=Path)
    p_a.add_argument("--k", type=int, default=30)
    p_a.add_argument("--delimiter", default=",")
    p_a.add_argument("--force", action="store_true")

    args = ap.parse_args()

    facts_dir: Path = args.facts_dir
    if not facts_dir.is_dir():
        print(f"[err] {facts_dir} is not a directory", file=sys.stderr)
        return 2

    if args.cmd == "vertex":
        return cmd_vertex(facts_dir, args.delimiter, args.force)
    if args.cmd == "maxiter":
        return cmd_maxiter(facts_dir, args.k, args.force)
    if args.cmd == "all":
        rc = cmd_vertex(facts_dir, args.delimiter, args.force)
        if rc != 0:
            return rc
        return cmd_maxiter(facts_dir, args.k, args.force)
    ap.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
