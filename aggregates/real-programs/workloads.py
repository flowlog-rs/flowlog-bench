#!/usr/bin/env python3
"""Make the incremental workloads: one bulk load, then ten transactions.

Each transaction inserts 1,000 held-out edges and deletes 1,000 loaded ones,
so the graph keeps about the same size. Workloads:

  cc-roadnet, sssp-roadnet   roadNet-CA
  cc-lj250k, sssp-lj250k     LiveJournal edges whose two ids are both < 250,000
  cc-lj250k-shuf             cc-lj250k with node ids randomly renamed, so the
                             smallest label is not a hub

SSSP edge weights are (lo * 31 + hi) % 10 + 1, where lo and hi are the edge's
smaller and larger ids; the source is node 0. Each workload directory holds
its edge files and commands.txt, which time_incremental.py feeds to the
binary on stdin. commands.txt names files by absolute path.
"""

import argparse
from pathlib import Path

import numpy as np

TXNS, BATCH, SEED, SHUFFLE_SEED, LJ_LIMIT = 10, 1000, 7, 11, 250_000


def read_edges(path, limit=None):
    """Edges of a two-column CSV; with `limit`, only those with both ids below it."""
    edges = []
    with open(path) as handle:
        for line in handle:
            a, b = line.split(",")[:2]
            a, b = int(a), int(b)
            if limit is None or (a < limit and b < limit):
                edges.append((a, b))
    return np.array(edges, dtype=np.int64).reshape(-1, 2)


def write_edges(path, edges):
    np.savetxt(path, edges, fmt="%d", delimiter=",")


def build(name, edges, weighted, out, source=None):
    rng = np.random.default_rng(SEED)
    edges = np.unique(edges, axis=0)
    if weighted:
        lo = np.minimum(edges[:, 0], edges[:, 1])
        hi = np.maximum(edges[:, 0], edges[:, 1])
        edges = np.column_stack([edges, (lo * 31 + hi) % 10 + 1])
    order = rng.permutation(len(edges))
    held, loaded = order[: TXNS * BATCH], order[TXNS * BATCH :]
    deletes = rng.choice(loaded, size=TXNS * BATCH, replace=False)

    root = out / name
    root.mkdir(parents=True, exist_ok=True)
    write_edges(root / "load.csv", edges[np.sort(loaded)])
    lines = ["begin", f"file arc {root}/load.csv +1"]
    if source is not None:
        lines.append(f"file id {source} +1")
    lines.append("commit")
    for t in range(1, TXNS + 1):
        write_edges(root / f"ins_{t}.csv", edges[held[(t - 1) * BATCH : t * BATCH]])
        write_edges(root / f"del_{t}.csv", edges[deletes[(t - 1) * BATCH : t * BATCH]])
        lines += ["begin", f"file arc {root}/ins_{t}.csv +1",
                  f"file arc {root}/del_{t}.csv -1", "commit"]
    lines.append("quit")
    (root / "commands.txt").write_text("\n".join(lines) + "\n")
    print(f"{name}: {len(loaded)} edges loaded, {TXNS} transactions of "
          f"{BATCH} inserts + {BATCH} deletes")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--facts", type=Path, required=True,
                        help="dataset directory holding roadNet-CA/ and livejournal/")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = out / "source0.csv"
    source.write_text("0\n")

    road = read_edges(args.facts / "roadNet-CA/Arc.csv")
    build("cc-roadnet", road, False, out)
    build("sssp-roadnet", road, True, out, source)
    lj = read_edges(args.facts / "livejournal/Arc.csv", LJ_LIMIT)
    build("cc-lj250k", lj, False, out)
    build("sssp-lj250k", lj, True, out, source)
    rename = np.random.default_rng(SHUFFLE_SEED).permutation(int(lj.max()) + 1)
    build("cc-lj250k-shuf", rename[lj], False, out)


if __name__ == "__main__":
    main()
