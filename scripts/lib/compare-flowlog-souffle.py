#!/usr/bin/env python3
# Vendored from flowlog-rs/doop-flowlog: bin/compare-flowlog-souffle.py
# (the correctness oracle for the Soufflé->FlowLog DOOP port). Kept here so the
# context_insensitive comparison is self-contained. Update from upstream as needed.
"""Compare a FlowLog analysis output directory against a Soufflé reference.

This is the correctness oracle for the Soufflé -> FlowLog port: run the same
DOOP analysis through both engines over the same facts, then check that every
output relation agrees.

Two comparison modes:

* **exact** (default) — a relation passes iff its tuple *set* is identical on
  both sides (order-insensitive, duplicate-insensitive). This is the right
  check for the overwhelming majority of relations.

* **partition** (`--partition REL`) — for DOOP's heap-merging `HeapRepresentative`
  relation (and any other *2-column* `(representative, member)` relation). It
  stores pairs that partition heaps into equivalence classes. The
  *representative* is whichever member has the minimum `ord(...)`, and `ord` is
  each engine's interning order — so the two engines partition the heaps
  identically but legitimately pick *different* representatives within a class.
  Comparing raw tuples reports spurious differences; comparing the induced
  partitions (the sets of members, ignoring which one is the representative) is
  the faithful, engine-independent correctness check.

  This applies to any 2-column representative relation, in either column order:
  `HeapRepresentative` is `(representative, member)` and `TypeToPartition` is
  `(member, representative)` — the partition check uses connected components, so
  orientation does not matter. The 3+ column `*ToRepresentative` maps
  (e.g. `MethodAndTypeToRepresentative`) are not partitions; compare those in the
  default exact mode (partition mode rejects them rather than mis-comparing).
  When reps agree across engines they match exactly; when they diverge it is the
  same `ord` non-portability.

  See docs/STATUS.md / the `min ord(?heap)` discussion: this is a known,
  inherent non-portability of `ord`-based canonical selection, not a bug.

Files are paired across the two directories by case-insensitive stem, so a
FlowLog `VarPointsTo.csv` lines up with a Soufflé `varpointsto.csv`. Both
engines emit tab-separated rows.

Usage:
  bin/compare-flowlog-souffle.py FLOWLOG_DIR SOUFFLE_DIR
  bin/compare-flowlog-souffle.py FL SF --partition HeapRepresentative --sample 5

Exit status is 0 iff every paired relation matches under its mode AND no
relation the reference produced is missing from the FlowLog side (a dropped
output is a correctness failure, not a warning).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def load_tuples(path: Path) -> list[tuple[str, ...]]:
    """Read a relation file as a list of tab-split tuples (one per line)."""
    rows: list[tuple[str, ...]] = []
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line == "":
                continue
            rows.append(tuple(line.split("\t")))
    return rows


def index_dir(d: Path) -> dict[str, Path]:
    """Map case-folded relation stem -> file, for every *.csv/*.facts in `d`."""
    out: dict[str, Path] = {}
    for p in sorted(d.iterdir()):
        if p.is_file() and p.suffix.lower() in (".csv", ".facts"):
            out[p.stem.lower()] = p
    return out


def partitions(rows: list[tuple[str, ...]]) -> set[frozenset[str]]:
    """Collapse a 2-column representative relation into its set of equivalence
    classes (each a frozenset of elements), discarding representative identity.

    Computed as connected components (union-find) over the tuples-as-edges, so
    the check is independent of column order: it works for both the
    `(representative, member)` shape (`HeapRepresentative`) and the
    `(member, representative)` shape (`TypeToPartition`). Two elements land in
    the same class iff a chain of tuples connects them — which, for DOOP's
    star-shaped representative relations (every member linked to its rep, plus
    the `(rep, rep)` self-pair), yields exactly the merge classes.
    """
    parent: dict[str, str] = {}

    def find(x: str) -> str:
        parent.setdefault(x, x)
        root = x
        while parent[root] != root:
            root = parent[root]
        while parent[x] != root:  # path compression
            parent[x], x = root, parent[x]
        return root

    def union(a: str, b: str) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    for row in rows:
        if len(row) != 2:
            raise ValueError(
                f"partition mode expects 2 columns, got {len(row)}: {row!r}"
            )
        union(row[0], row[1])

    classes: dict[str, set[str]] = {}
    for elem in parent:
        classes.setdefault(find(elem), set()).add(elem)
    return {frozenset(members) for members in classes.values()}


def compare_exact(fl: Path, sf: Path, sample: int) -> tuple[bool, str]:
    a, b = set(load_tuples(fl)), set(load_tuples(sf))
    if a == b:
        return True, f"{len(a)} tuples"
    only_fl, only_sf = a - b, b - a
    detail = (
        f"flowlog={len(a)} souffle={len(b)} "
        f"(+{len(only_fl)} fl-only / +{len(only_sf)} sf-only)"
    )
    if sample:
        for label, s in (("fl-only", only_fl), ("sf-only", only_sf)):
            for row in list(sorted(s))[:sample]:
                detail += f"\n      {label}: " + "\t".join(row)
    return False, detail


def compare_partition(fl: Path, sf: Path) -> tuple[bool, str]:
    pa, pb = partitions(load_tuples(fl)), partitions(load_tuples(sf))
    if pa == pb:
        members = sum(len(p) for p in pa)
        return True, f"{len(pa)} classes / {members} members (rep-renaming OK)"
    only_fl, only_sf = pa - pb, pb - pa
    return False, (
        f"flowlog={len(pa)} classes souffle={len(pb)} classes; "
        f"{len(only_fl)} fl-only / {len(only_sf)} sf-only classes "
        f"(partitions genuinely differ — not just representative choice)"
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("flowlog_dir", type=Path)
    ap.add_argument("souffle_dir", type=Path)
    ap.add_argument(
        "--partition",
        action="append",
        default=[],
        metavar="REL",
        help="relation compared modulo representative renaming (repeatable)",
    )
    ap.add_argument(
        "--sample",
        type=int,
        default=3,
        help="number of differing tuples to show per side (exact mode)",
    )
    args = ap.parse_args()

    fl_idx = index_dir(args.flowlog_dir)
    sf_idx = index_dir(args.souffle_dir)
    part = {p.lower() for p in args.partition}

    common = sorted(set(fl_idx) & set(sf_idx))
    fl_only = sorted(set(fl_idx) - set(sf_idx))
    sf_only = sorted(set(sf_idx) - set(fl_idx))

    failures = 0
    print(f"{'relation':<40} {'mode':<10} result")
    print("-" * 78)
    for stem in common:
        mode = "partition" if stem in part else "exact"
        try:
            if mode == "partition":
                ok, detail = compare_partition(fl_idx[stem], sf_idx[stem])
            else:
                ok, detail = compare_exact(fl_idx[stem], sf_idx[stem], args.sample)
        except ValueError as e:
            ok, detail = False, str(e)
        status = "OK  " if ok else "DIFF"
        if not ok:
            failures += 1
        print(f"{fl_idx[stem].stem:<40} {mode:<10} [{status}] {detail}")

    if fl_only:
        print(f"\n[warn] {len(fl_only)} relation(s) only in FlowLog (extra outputs): "
              + ", ".join(fl_only))
    if sf_only:
        # A relation the reference produced but FlowLog did not is a *missing
        # output* — a correctness failure, not a warning. A faithful port must
        # emit every relation the oracle does, so this counts toward the exit
        # status (otherwise "20 compared, 20 matched" could mask a dropped 21st).
        print(f"\n[FAIL] {len(sf_only)} expected relation(s) missing from FlowLog: "
              + ", ".join(sf_only))

    missing = len(sf_only)
    print(
        f"\n{len(common)} compared, {len(common) - failures} matched, "
        f"{failures} differ; {missing} expected relation(s) missing."
    )
    sys.exit(1 if failures or missing else 0)


if __name__ == "__main__":
    main()
