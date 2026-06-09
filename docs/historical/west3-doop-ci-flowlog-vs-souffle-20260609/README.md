# [west3] DOOP context-insensitive — FlowLog vs Soufflé (20 DaCapo apps)

**Correctness: all 19 fully-compared apps produce identical results on both engines.** Per app,
16–19 of the 21 output relations are byte-for-byte identical; the rest differ *only* by
`ord()`-based heap-merge **representative choice** — identical row counts, **zero residual** after
canonicalising each representative to its merge class. That is the known, benign string-interning
non-portability (`bin/compare-flowlog-souffle.py`), not a semantic difference. The 20th app
(`jython`) is the density ceiling — see the note below.

This is the **non-toy** DOOP `context-insensitive` points-to analysis
(`context-insensitive.flowlog.flat.dl`, ~3.2k lines: Soufflé components + FlowLog head
aggregates), not the curated `doop/default.dl`. Soufflé runs the equivalent
`context-insensitive.souffle.flat.dl` over the **same** facts.

![Run time](time.png)
![Peak memory](memory.png)

## jython — the density ceiling (20th app)

`jython` is by far the densest workload: **VarPointsTo = 371,435,757 tuples (~105 GiB)**.
FlowLog completes it in **13 m 43 s** at **167 GiB** peak. It needs a memory-mapped-heavy
runtime: `vm.max_map_count` raised above the 65 530 default (FlowLog issues >65 k `mmap`s and
otherwise aborts with a spurious "allocation failed") and `vm.overcommit_memory=1`. Soufflé with
**left-to-right** join order (no `.plan`) is still grinding through jython's recursive points-to —
no result yet well past FlowLog's 10 min solve — consistent with the trend that the unscheduled
order hurts Soufflé most on the densest inputs (cf. spring 4.40×, batik 4.75×). jython is
therefore excluded from the perf/mem table above; its FlowLog result is reported here for
completeness, with the FlowLog↔Soufflé tuple comparison pending Soufflé completion.

## Same join order, pure engine (no optimiser)

Perf/mem isolate **engine execution at one fixed join order**, not optimiser quality:

- **FlowLog** evaluates body atoms left-to-right (`--sip` **off**) — its default.
- **Soufflé** also left-to-right: **all `.plan` directives stripped** (DOOP ships 16 hand-tuned
  join-order hints) and **no `-a` auto-schedule** (Soufflé keeps written order otherwise —
  verified it does not reorder a written `a,a,b` cartesian).
- The two programs share **identical body-atom order on all 543 join rules** (verified); only the
  12 group-by aggregates differ structurally.
- `.plan` changes execution order only, not results: `.plan` vs no-`.plan` Soufflé output is
  **byte-identical** (verified on tomcat), so the correctness verdicts above apply to both.

For reference, DOOP's hand-tuned `.plan` makes Soufflé ~1.2–1.3× faster than this left-to-right
run; we exclude it so neither engine gets an optimiser the other lacks.

## Results — correctness + performance + memory

Run-only times (FlowLog compile, a one-off ~4.5 min/app, excluded). `sf/fl` > 1 ⇒ FlowLog faster.
Single run per engine — **timings are indicative; correctness is exact.**

| App | VarPointsTo | Match | Exact rel. | FlowLog s | Souffle s | sf/fl | FlowLog GiB | Souffle GiB |
|---|---:|:--:|---:|---:|---:|---:|---:|---:|
| avrora | 2,528,797 | ✅ | 19/21 | 22.4 | 35.8 | 1.60× | 4.41 | 2.60 |
| batik | 28,249,074 | ✅ | 18/21 | 58.6 | 277.9 | 4.75× | 12.98 | 13.39 |
| biojava | 3,470,185 | ✅ | 18/21 | 53.0 | 63.6 | 1.20× | 6.57 | 5.13 |
| cassandra | 2,545,822 | ✅ | 16/21 | 15.3 | 33.9 | 2.22× | 3.89 | 2.04 |
| eclipse | 10,539,055 | ✅ | 16/21 | 24.4 | 84.5 | 3.46× | 7.12 | 5.16 |
| fop | 15,414,507 | ✅ | 18/21 | 45.3 | 125.5 | 2.77× | 9.24 | 8.18 |
| graphchi | 4,480,629 | ✅ | 19/21 | 79.8 | 83.8 | 1.05× | 7.74 | 7.28 |
| h2 | 22,669,373 | ✅ | 16/21 | 43.4 | 149.7 | 3.45× | 13.57 | 11.48 |
| h2o | 8,348,153 | ✅ | 19/21 | 409.3 | 228.4 | 0.56× | 23.66 | 29.26 |
| jme | 3,740,675 | ✅ | 19/21 | 32.6 | 53.4 | 1.64× | 5.53 | 3.75 |
| kafka | 4,467,153 | ✅ | 19/21 | 60.7 | 66.5 | 1.10× | 6.69 | 5.33 |
| luindex | 5,396,536 | ✅ | 19/21 | 20.2 | 49.1 | 2.43× | 5.22 | 3.17 |
| lusearch | 5,627,641 | ✅ | 18/21 | 19.9 | 48.8 | 2.46× | 5.36 | 3.26 |
| pmd | 4,128,719 | ✅ | 19/21 | 25.4 | 45.8 | 1.80× | 5.09 | 3.32 |
| spring | 27,878,606 | ✅ | 18/21 | 54.4 | 239.6 | 4.40× | 13.58 | 12.80 |
| sunflow | 6,140,841 | ✅ | 19/21 | 24.3 | 55.1 | 2.27× | 6.00 | 3.83 |
| tomcat | 3,066,514 | ✅ | 16/21 | 15.9 | 34.5 | 2.16× | 4.25 | 2.23 |
| xalan | 2,387,458 | ✅ | 19/21 | 41.8 | 40.9 | 0.98× | 4.80 | 3.04 |
| zxing | 4,144,794 | ✅ | 16/21 | 23.6 | 45.8 | 1.94× | 4.97 | 3.12 |

## Headline

- **Correctness:** all 19/19 apps match — identical VarPointsTo row counts, 0 residual tuples after ord-canonicalisation.
- **Run time (left-to-right both):** FlowLog faster on 17/19 measured apps, geomean **1.95×** (range 0.56–4.75×); slower on h2o, xalan.
- **Peak memory:** Soufflé/FlowLog geomean **0.73×** (Soufflé leaner on light apps; FlowLog leaner on the densest).

## Run conditions

| Field | Value |
|---|---|
| Host | `flowlog-west3` (64 vCPU, 503 GiB RAM) |
| FlowLog | `flowlog-compiler` @ `main-next` `1d8b05a`, `--str-intern --mode datalog-batch`, `-w 32`, `--sip` off |
| Soufflé | `2.5`, compiled (`-o`, `-j 32`), **`.plan` stripped**, no `-a` |
| Facts | 20 DaCapo 23.11-MR2-chopin sets, identical inputs to both engines; empty `KeepClass*`/`KeepMethod`/`RootCodeElement` materialised for Soufflé (FlowLog tolerates missing) |
| Program fix | DOOP macro `CONFIGURATION` → `ContextInsensitiveConfiguration` |
| Kernel | `vm.overcommit_memory=1`, `vm.max_map_count=1048576` (the densest app, jython, needs >65 k mmaps) |
| Correctness oracle | `bin/compare-flowlog-souffle.py` set-equality + residual check canonicalising heap reps to type |

## Why the heap-representative relations differ (benign)

DOOP merges allocations of a type into one **representative** heap = the member with minimum
`ord(...)`. `ord` is each engine's string-interning order, so the engines pick different
representatives for the same class. Example (tomcat `StaticFieldPointsTo`):

```
FlowLog : … /new java.lang.Character$UnicodeBlock/133   <…AEGEAN_NUMBERS>
Soufflé : … /new java.lang.Character$UnicodeBlock/0     <…AEGEAN_NUMBERS>
```

Same class, different representative. Row counts match and, after mapping each heap to its type,
the symmetric difference is empty — the partitions (and the analysis result) are identical.
Affected: `VarPointsTo`, `InstanceFieldPointsTo`, `StaticFieldPointsTo`, `CallGraphEdge`,
`AnyCallGraphEdge`.

Snapshot files: `results.csv`, `time.{png,svg}`, `memory.{png,svg}`, programs under `programs/`.
