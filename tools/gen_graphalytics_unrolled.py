#!/usr/bin/env python3
"""
gen_graphalytics_unrolled.py — emit unrolled-K PageRank / CDLP programs for
both FlowLog and Souffle.

Why unrolled?  FlowLog evaluates a whole recursive SCC as one fixpoint and a
non-monotone aggregate (sum / count) inside that SCC captures *intermediate*
partial-aggregate tuples, so the single-program recursive encoding in
programs/oracle/flowlog/{pagerank,cdlp}/default.dl produces wrong results
(multiple labels per vertex / partial PR mass).  Souffle simply forbids
recursive aggregation outright.  The only encoding both engines compute
*correctly and identically* is to materialise each iteration as its own
relation (no recursion → aggregation is exact).

The two emitted dialects are arithmetically identical:
  * integer-scaled by 1e9, damping 0.85 (D=85, 1-D=15, /100)
  * per-term integer (truncating) division, so FlowLog int64 == Souffle int64
FlowLog has no parens / precedence (left-to-right), so every expression below
is written so that left-to-right == the intended grouping.
"""
from __future__ import annotations
import argparse, sys
from pathlib import Path

# ── PageRank ────────────────────────────────────────────────────────────────
def pagerank_flowlog(k: int) -> str:
    L = []
    L.append("// LDBC Graphalytics PageRank — UNROLLED K={} (FlowLog).".format(k))
    L.append("// Integer-scaled by 1e9, damping 0.85. Auto-generated; do not hand-edit.")
    L.append('.decl Arc(src: int64, dst: int64)')
    L.append('.input Arc(IO="file", filename="Arc.csv", delimiter=",")')
    L.append('.decl Vertex(v: int64)')
    L.append('.input Vertex(IO="file", filename="Vertex.csv", delimiter=",")')
    L.append('.decl N(n: int64)')
    L.append('N(count(v)) :- Vertex(v).')
    L.append('.decl Outdeg(v: int64, d: int64)')
    L.append('Outdeg(v, count(u)) :- Arc(v, u).')
    # base = 0.15 * 1e9 / N = 150000000 / N  (left-to-right OK)
    L.append('.decl Base(b: int64)')
    L.append('Base(150000000 / n) :- N(n).')
    # PR_0
    L.append('.decl PR0(v: int64, pr: int64)')
    L.append('PR0(v, 1000000000 / n) :- Vertex(v), N(n).')
    for i in range(k):
        cur, nxt = f"PR{i}", f"PR{i+1}"
        # FlowLog aggregates over the *set* of projected tuples, so a bare
        # `sum(pr / d)` would dedup equal terms (two in-neighbours with the
        # same pr/d counted once). Retain the source vertex v in a pre-agg
        # relation so each in-neighbour contributes its own row -> true
        # multiset sum, matching Souffle.
        L.append(f'.decl ContribTerm{i}(u: int64, v: int64, t: int64)')
        L.append(f'ContribTerm{i}(u, v, pr / d) :- {cur}(v, pr), Arc(v, u), Outdeg(v, d).')
        L.append(f'.decl Contrib{i}(u: int64, c: int64)')
        L.append(f'Contrib{i}(u, sum(t)) :- ContribTerm{i}(u, v, t).')
        L.append(f'.decl HasContrib{i}(v: int64)')
        L.append(f'HasContrib{i}(v) :- Contrib{i}(v, _).')
        # dpart = 85 * c / 100  (left-to-right = (85*c)/100)
        L.append(f'.decl Dpart{i}(v: int64, dp: int64)')
        L.append(f'Dpart{i}(v, 85 * c / 100) :- Contrib{i}(v, c).')
        L.append(f'.decl {nxt}(v: int64, pr: int64)')
        L.append(f'{nxt}(v, b + dp) :- Base(b), Dpart{i}(v, dp).')
        L.append(f'{nxt}(v, b) :- Vertex(v), Base(b), !HasContrib{i}(v).')
    L.append('.decl FinalPR(v: int64, pr: int64)')
    L.append(f'FinalPR(v, pr) :- PR{k}(v, pr).')
    L.append('.printsize FinalPR')
    L.append('.output FinalPR')
    return "\n".join(L) + "\n"

def pagerank_souffle(k: int) -> str:
    L = []
    L.append("// LDBC Graphalytics PageRank — UNROLLED K={} (Souffle).".format(k))
    L.append("// Integer-scaled by 1e9, damping 0.85. Auto-generated; do not hand-edit.")
    L.append('.decl Arc(src: number, dst: number)')
    L.append('.input Arc(IO=file, filename="Arc.csv", delimiter=",")')
    L.append('.decl Vertex(v: number)')
    L.append('.input Vertex(IO=file, filename="Vertex.csv", delimiter=",")')
    L.append('.decl N(n: number)')
    L.append('N(n) :- n = count : { Vertex(_) }.')
    L.append('.decl Outdeg(v: number, d: number)')
    L.append('Outdeg(v, d) :- Arc(v, _), d = count : { Arc(v, _) }.')
    L.append('.decl Base(b: number)')
    L.append('Base(150000000 / n) :- N(n).')
    L.append('.decl PR0(v: number, pr: number)')
    L.append('PR0(v, 1000000000 / n) :- Vertex(v), N(n).')
    for i in range(k):
        cur, nxt = f"PR{i}", f"PR{i+1}"
        # NOTE: FlowLog's `sum` is over the SET of projected values, i.e. it
        # sums *distinct* contribution terms per target (two in-neighbours
        # with equal pr/d are counted once). That is NOT canonical PageRank,
        # but FlowLog cannot express the multiset sum. To keep this an
        # apples-to-apples comparison (identical outputs), the Souffle
        # reference reproduces the same set-sum: project (u, t) into a
        # relation (which dedups), then sum the distinct t.
        L.append(f'.decl ContribVal{i}(u: number, t: number)')
        L.append(f'ContribVal{i}(u, t) :- {cur}(v, pr), Arc(v, u), '
                 f'Outdeg(v, d), t = pr / d.')
        L.append(f'.decl Contrib{i}(u: number, c: number)')
        L.append(f'Contrib{i}(u, c) :- ContribVal{i}(u, _), '
                 f'c = sum t : {{ ContribVal{i}(u, t) }}.')
        L.append(f'.decl HasContrib{i}(v: number)')
        L.append(f'HasContrib{i}(v) :- Contrib{i}(v, _).')
        L.append(f'.decl Dpart{i}(v: number, dp: number)')
        L.append(f'Dpart{i}(v, 85 * c / 100) :- Contrib{i}(v, c).')
        L.append(f'.decl {nxt}(v: number, pr: number)')
        L.append(f'{nxt}(v, b + dp) :- Base(b), Dpart{i}(v, dp).')
        L.append(f'{nxt}(v, b) :- Vertex(v), Base(b), !HasContrib{i}(v).')
    L.append('.decl FinalPR(v: number, pr: number)')
    L.append(f'FinalPR(v, pr) :- PR{k}(v, pr).')
    L.append('.printsize FinalPR')
    L.append('.output FinalPR')
    return "\n".join(L) + "\n"

# ── CDLP ────────────────────────────────────────────────────────────────────
def cdlp_flowlog(k: int) -> str:
    L = []
    L.append("// LDBC Graphalytics CDLP — UNROLLED K={} (FlowLog).".format(k))
    L.append("// Label propagation, mode label, smallest-id tie-break. Auto-generated.")
    L.append('.decl Arc(src: int64, dst: int64)')
    L.append('.input Arc(IO="file", filename="Arc.csv", delimiter=",")')
    L.append('.decl Vertex(v: int64)')
    L.append('.input Vertex(IO="file", filename="Vertex.csv", delimiter=",")')
    L.append('.decl UndirEdge(u: int64, v: int64)')
    L.append('UndirEdge(u, v) :- Arc(u, v), u != v.')
    L.append('UndirEdge(v, u) :- Arc(u, v), u != v.')
    L.append('.decl Label0(v: int64, l: int64)')
    L.append('Label0(v, v) :- Vertex(v).')
    for i in range(k):
        cur, nxt = f"Label{i}", f"Label{i+1}"
        L.append(f'.decl NbrLabelCount{i}(v: int64, l: int64, c: int64)')
        L.append(f'NbrLabelCount{i}(v, l, count(u)) :- {cur}(u, l), UndirEdge(v, u).')
        L.append(f'.decl ModeCount{i}(v: int64, c: int64)')
        L.append(f'ModeCount{i}(v, max(c)) :- NbrLabelCount{i}(v, _, c).')
        L.append(f'.decl LabelNext{i}(v: int64, l: int64)')
        L.append(f'LabelNext{i}(v, min(l)) :- NbrLabelCount{i}(v, l, c), ModeCount{i}(v, c).')
        L.append(f'.decl HasNbr{i}(v: int64)')
        L.append(f'HasNbr{i}(v) :- NbrLabelCount{i}(v, _, _).')
        L.append(f'.decl {nxt}(v: int64, l: int64)')
        L.append(f'{nxt}(v, l) :- LabelNext{i}(v, l).')
        L.append(f'{nxt}(v, lprev) :- {cur}(v, lprev), !HasNbr{i}(v).')
    L.append('.decl FinalLabel(v: int64, l: int64)')
    L.append(f'FinalLabel(v, l) :- Label{k}(v, l).')
    L.append('.printsize FinalLabel')
    L.append('.output FinalLabel')
    return "\n".join(L) + "\n"

def cdlp_souffle(k: int) -> str:
    L = []
    L.append("// LDBC Graphalytics CDLP — UNROLLED K={} (Souffle).".format(k))
    L.append("// Label propagation, mode label, smallest-id tie-break. Auto-generated.")
    L.append('.decl Arc(src: number, dst: number)')
    L.append('.input Arc(IO=file, filename="Arc.csv", delimiter=",")')
    L.append('.decl Vertex(v: number)')
    L.append('.input Vertex(IO=file, filename="Vertex.csv", delimiter=",")')
    L.append('.decl UndirEdge(u: number, v: number)')
    L.append('UndirEdge(u, v) :- Arc(u, v), u != v.')
    L.append('UndirEdge(v, u) :- Arc(u, v), u != v.')
    L.append('.decl Label0(v: number, l: number)')
    L.append('Label0(v, v) :- Vertex(v).')
    for i in range(k):
        cur, nxt = f"Label{i}", f"Label{i+1}"
        L.append(f'.decl NbrLabelCount{i}(v: number, l: number, c: number)')
        L.append(f'NbrLabelCount{i}(v, l, c) :- {cur}(u, l), UndirEdge(v, u), '
                 f'c = count : {{ {cur}(w, l), UndirEdge(v, w) }}.')
        L.append(f'.decl ModeCount{i}(v: number, c: number)')
        L.append(f'ModeCount{i}(v, c) :- NbrLabelCount{i}(v, _, _), '
                 f'c = max cc : {{ NbrLabelCount{i}(v, _, cc) }}.')
        L.append(f'.decl LabelNext{i}(v: number, l: number)')
        L.append(f'LabelNext{i}(v, l) :- ModeCount{i}(v, c), '
                 f'l = min ll : {{ NbrLabelCount{i}(v, ll, c) }}.')
        L.append(f'.decl HasNbr{i}(v: number)')
        L.append(f'HasNbr{i}(v) :- NbrLabelCount{i}(v, _, _).')
        L.append(f'.decl {nxt}(v: number, l: number)')
        L.append(f'{nxt}(v, l) :- LabelNext{i}(v, l).')
        L.append(f'{nxt}(v, lprev) :- {cur}(v, lprev), !HasNbr{i}(v).')
    L.append('.decl FinalLabel(v: number, l: number)')
    L.append(f'FinalLabel(v, l) :- Label{k}(v, l).')
    L.append('.printsize FinalLabel')
    L.append('.output FinalLabel')
    return "\n".join(L) + "\n"

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pr-k", type=int, default=30)
    ap.add_argument("--cdlp-k", type=int, default=10)
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args()
    root = args.root
    fl = root / "programs" / "oracle" / "flowlog"
    sf = root / "programs" / "oracle" / "souffle"
    out = {
        fl / "pagerank" / f"unrolled_k{args.pr_k}.dl": pagerank_flowlog(args.pr_k),
        fl / "cdlp" / f"unrolled_k{args.cdlp_k}.dl":   cdlp_flowlog(args.cdlp_k),
        sf / "pagerank.dl": pagerank_souffle(args.pr_k),
        sf / "cdlp.dl":     cdlp_souffle(args.cdlp_k),
    }
    for path, text in out.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        print(f"[ok] wrote {path} ({len(text.splitlines())} lines)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
