# [west3] DOOP context-insensitive — FlowLog vs Soufflé

Full (non-toy) DOOP **context-insensitive** points-to analysis, run through FlowLog
(`--str-intern`, `-w32`) and Soufflé (`-j32`, compiled) over **all 20 DaCapo
fact sets** that `doop.dl` uses. This is a *results* (correctness) comparison
**plus** a performance/regression study.

Reproduce: `make` n/a — `bash scripts/context_insensitive_compare.sh` (reads
`config/context_insensitive.txt`). Data: `docs/context_insensitive/summary.csv`.

---

## TL;DR

- **Correctness: identical on all 19 cross-checked datasets.** Every output
  relation agrees on cardinality *and* tuples, modulo the documented `ord()`
  heap-representative renaming — and the `HeapRepresentative` **partitions are
  identical** on every one (244 classes on tomcat, …). No genuine divergence.
  (jython is the 20th: too dense to cross-check in budget — see below.)
- **Performance (default settings): 14 wins (up to 2.5×), 5 regressions** —
  **h2o 2.11×**, graphchi / xalan / kafka **1.28×**, biojava **1.24×**. *But the
  default comparison is unfair:* Soufflé runs DOOP's hand-tuned `.plan` join
  orders on the hot recursive rules; FlowLog runs syntactic order (no `.plan`).
- **Pure-engine, SAME join order** (Soufflé `.plan` stripped + strict SIPS;
  FlowLog already syntactic): the moderate regressions **vanish** — xalan is a
  **tie** (FlowLog 39.8 s vs Soufflé 41–45 s). They were Soufflé's *optimizer*,
  not its engine. **h2o is the exception**: a genuine **~1.65× engine gap** even
  at equal order (389 vs 236 s) — the largest/densest workload — though FlowLog
  there uses **less** memory (24.5 vs 29.9 GB).
- **jython** is pathological for *both* engines (~150–180 GB). FlowLog OOMs at
  `-w32` (knife-edge 178 GB) but **completes at `-w16` / `-w8`** (171 GB); the
  matched Soufflé run was still going at 150 GB / 22 min when stopped, so jython
  is **not yet cross-checked** (it is the one dataset without a MATCH verdict).
- **Where FlowLog's time goes** (FlowLog `-P` profile, xalan): **66 %** inside
  the recursive fixpoint — joins + **~21 % rebuilding arrangements** each
  iteration. That overhead is what costs at h2o scale; below it, FlowLog's
  parallel integer-key joins win.
- **Actionable.** `--sip` is **3–4× worse** and `--str-intern` is **mandatory**
  (`ord()` needs it), so neither is the answer. **FlowLog *supports* `.plan`** —
  porting DOOP's join-order hints should close the moderate regressions; the h2o
  engine gap (arrangement churn) is the one real engine target. `-w16` is a free
  win (the `-w32` "fairness" setting is past FlowLog's scaling knee).

---

## Runtime — 14 wins, 5 regressions

![runtime](plots/runtime.png)

![speedup](plots/speedup.png)

FlowLog wins where the solve dominates and its parallel integer-key joins pay off
(batik 0.40×, h2 0.40×, spring 0.41×). It loses on denser fixpoints where
per-iteration arrangement maintenance dominates.

## Pure-engine — the same join order

The runtime chart above is **unfair to FlowLog**: Soufflé runs DOOP's hand-tuned
`.plan` join orders on the hot recursive rules (16 `.plan` directives in the
`.dl`), while FlowLog has none and runs syntactic order. To isolate the *engine*
from the *optimizer*, re-run with the **same join order** on both — Soufflé with
`.plan` stripped + `.pragma "SIPS" "strict"` (syntactic), FlowLog as-is
(syntactic by default). Outputs are byte-identical (VarPointsTo matches).

![same_order](plots/same_order.png)

- **xalan: a tie.** FlowLog 39.8 s vs Soufflé-same-order 41–45 s (Soufflé-tuned
  36.1 s). The 1.28× "regression" was **entirely Soufflé's `.plan` tuning** — at
  equal join order FlowLog's engine is as fast or faster. The other 1.24–1.28×
  regressions (kafka, graphchi, biojava) are the same shape.
- **h2o: a real engine gap.** Even at equal order Soufflé is **1.65× faster**
  (236 vs 389 s) — differential-dataflow's per-iteration re-arrangement genuinely
  costs on the largest, densest workload. FlowLog does use **less** memory here
  (24.5 vs 29.9 GB).

So the regression list is two different things: **mostly the planner** (closeable
— FlowLog *supports* `.plan`, the orders just aren't emitted by the mirror), plus
**one true engine gap at h2o scale**.

## Peak memory — comparable

![memory](plots/memory.png)

Peak RSS is in the same ballpark; FlowLog is higher on small apps (the resident
str-intern table) and comparable-to-lower on the big ones (batik 13.4 vs 15.5 GB).
`jython` is the exception — dense enough to need ~170–180 GB on *both* engines.

## What's actually slow (xalan `-P` profile)

![profile](plots/profile.png)

66 % of operator-active-time is inside the recursive (`Iterative`) scope; within
it, **joins (32 %) + arrangement rebuild (~21 %)** dominate. The two hottest
joins run ~50 fixpoint iterations (16.5 s + 7.1 s). This is the VarPointsTo
propagation — the cost is re-arranging large recursive relations each round.

## Tuning experiments (xalan)

![tuning](plots/tuning.png)

| lever | result |
|-------|--------|
| `--str-intern` off | **impossible** — `ord()` (heap-merge `min(ord(heap))`) requires interning |
| `--sip` | **3–4× worse** (xalan 38 s → 132–153 s); SIP plans backfire here |
| workers | knee ≈ **16**; `-w32` slightly past it; `-w48/64` pathological (1.6×) |
| `-w16` vs `-w32` | xalan 38.2 vs 39.3 s; **h2o 396 vs 432 s** (helps the worst case) |
| **`.plan` join order** | the real lever — see *Pure-engine* above; at equal order the moderate regressions disappear |

**Takeaway:** the 1.24–1.28× regressions are **not** an engine deficit — they are
Soufflé's `.plan` join-order tuning, and they vanish at equal join order. The
actionable fix is to **emit DOOP's `.plan` hints into the FlowLog program**
(FlowLog already supports `.plan`); `--sip` is not it, and `--str-intern` is
mandatory. Two things remain genuinely engine-side: the **h2o-scale ~1.65× gap**
(arrangement churn in the recursive scope) and FlowLog's higher memory on small
apps. `-w16` is a free win (the `-w32` "fairness" setting is past FlowLog's
scaling knee).

---

## Full results

See `summary.csv`. Verdict `MATCH` = all non-`HeapRepresentative` relations equal
cardinality, `HeapRepresentative` partition identical, 0 missing.

| dataset | verdict | FlowLog s | Soufflé s | ratio | FlowLog GB | Soufflé GB |
|---------|---------|-----------|-----------|-------|-----------|-----------|
| h2o | MATCH | 432.0 | 204.5 | **2.11×** | 23.8 | 29.9 |
| graphchi | MATCH | 92.9 | 72.3 | 1.28× | 7.7 | 7.7 |
| xalan | MATCH | 46.3 | 36.1 | 1.28× | 4.7 | 3.2 |
| kafka | MATCH | 72.3 | 56.4 | 1.28× | 6.6 | 5.7 |
| biojava | MATCH | 62.9 | 50.7 | 1.24× | 6.5 | 5.4 |
| jme | MATCH | 39.6 | 42.3 | 0.94× | 5.6 | 4.0 |
| pmd | MATCH | 30.5 | 36.0 | 0.85× | 5.1 | 3.6 |
| avrora | MATCH | 26.4 | 32.0 | 0.82× | 4.3 | 2.8 |
| zxing | MATCH | 27.3 | 35.8 | 0.76× | 5.0 | 3.4 |
| sunflow | MATCH | 27.0 | 42.4 | 0.64× | 6.0 | 4.3 |
| fop | MATCH | 51.0 | 81.9 | 0.62× | 9.3 | 9.4 |
| cassandra | MATCH | 15.6 | 25.6 | 0.61× | 4.0 | 2.2 |
| tomcat | MATCH | 15.8 | 27.0 | 0.59× | 4.2 | 2.5 |
| lusearch | MATCH | 20.2 | 36.7 | 0.55× | 5.3 | 3.7 |
| luindex | MATCH | 19.8 | 36.5 | 0.54× | 5.2 | 3.6 |
| eclipse | MATCH | 26.1 | 53.8 | 0.49× | 7.4 | 5.9 |
| spring | MATCH | 52.0 | 127.4 | 0.41× | 13.2 | 15.3 |
| batik | MATCH | 56.9 | 141.4 | 0.40× | 13.1 | 15.2 |
| h2 | MATCH | 46.6 | 116.6 | 0.40× | 13.6 | 16.5 |
| jython | n/a\* | 171 (`-w16`) | ~180+ (killed) | — | 167 | ~150+ |

\* jython OOMs FlowLog at `-w32` (knife-edge ~178 GB) and **completes at `-w16`**
(171 GB); the Soufflé side was still running (~150 GB, 22 min) when stopped, so
this row is **not a verified MATCH** — it is the one dataset left un-cross-checked.
Single-run timings elsewhere carry run-to-run noise (the `ord()` heap-representative
non-determinism), but the win/loss pattern is stable.

## Methodology

- Programs: `programs/oracle/{flowlog,souffle}/context_insensitive*.dl` — the same
  analysis in two dialects (head vs body aggregates, `?`-vars), `CONFIGURATION`
  bound to `ContextInsensitiveConfiguration`, `+HeapRepresentative` output for the
  partition check.
- Facts: `/datasets/facts/<app>` via a tmpfs overlay (symlinks + empty keep-spec
  defaults Soufflé requires); never written into the shared mount.
- Oracle: `scripts/lib/compare-flowlog-souffle.py` (vendored from
  `flowlog-rs/doop-flowlog`) — tuple-set per relation, `--partition
  HeapRepresentative`.
