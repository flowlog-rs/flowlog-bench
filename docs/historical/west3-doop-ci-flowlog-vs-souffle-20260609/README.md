# [west3] DOOP context-insensitive — FlowLog vs Soufflé

The full **non-toy** DOOP `context-insensitive` points-to analysis
(`context-insensitive.flowlog.flat.dl`, ~3.2k lines: Soufflé components + FlowLog head
aggregates) on **20 DaCapo 23.11-MR2-chopin** apps — same facts, **same left-to-right join
order**, both engines.

|  |  |
|---|---|
| ✅ **Correct** | every comparable app gives identical results (modulo a benign `ord()` heap-representative renaming) |
| ⚡ **Faster** | at one fixed join order, FlowLog wins **17/19** on run time — geomean **1.95×** (0.56–4.75×) |
| 🧠 **Memory** | peak RSS audited for both engines: Soufflé lighter on small apps (geomean Soufflé/FlowLog **0.73×**), FlowLog lighter on the densest |
| 📈 **Scales** | FlowLog solves jython (**371 M** points-to tuples) in 10 min / 167 GiB; Soufflé doesn't finish in an hour |

![Run time](time.png)
![Peak memory](memory.png)

## Results

Run-only wall time and peak RSS — compile excluded, `-w/-j 32`, single run. `sf/fl > 1` ⇒ FlowLog
faster. Sorted by speedup.

| App | VarPointsTo | Match | FlowLog s | Soufflé s | sf/fl | FlowLog GiB | Soufflé GiB |
|---|---:|:--:|---:|---:|---:|---:|---:|
| batik | 28,249,074 | ✅ | 58.6 | 277.9 | **4.75×** | 12.98 | 13.39 |
| spring | 27,878,606 | ✅ | 54.4 | 239.6 | **4.40×** | 13.58 | 12.80 |
| eclipse | 10,539,055 | ✅ | 24.4 | 84.5 | 3.46× | 7.12 | 5.16 |
| h2 | 22,669,373 | ✅ | 43.4 | 149.7 | 3.45× | 13.57 | 11.48 |
| fop | 15,414,507 | ✅ | 45.3 | 125.5 | 2.77× | 9.24 | 8.18 |
| lusearch | 5,627,641 | ✅ | 19.9 | 48.8 | 2.46× | 5.36 | 3.26 |
| luindex | 5,396,536 | ✅ | 20.2 | 49.1 | 2.43× | 5.22 | 3.17 |
| sunflow | 6,140,841 | ✅ | 24.3 | 55.1 | 2.27× | 6.00 | 3.83 |
| cassandra | 2,545,822 | ✅ | 15.3 | 33.9 | 2.22× | 3.89 | 2.04 |
| tomcat | 3,066,514 | ✅ | 15.9 | 34.5 | 2.16× | 4.25 | 2.23 |
| zxing | 4,144,794 | ✅ | 23.6 | 45.8 | 1.94× | 4.97 | 3.12 |
| pmd | 4,128,719 | ✅ | 25.4 | 45.8 | 1.80× | 5.09 | 3.32 |
| jme | 3,740,675 | ✅ | 32.6 | 53.4 | 1.64× | 5.53 | 3.75 |
| avrora | 2,528,797 | ✅ | 22.4 | 35.8 | 1.60× | 4.41 | 2.60 |
| biojava | 3,470,185 | ✅ | 53.0 | 63.6 | 1.20× | 6.57 | 5.13 |
| kafka | 4,467,153 | ✅ | 60.7 | 66.5 | 1.10× | 6.69 | 5.33 |
| graphchi | 4,480,629 | ✅ | 79.8 | 83.8 | 1.05× | 7.74 | 7.28 |
| xalan | 2,387,458 | ✅ | 41.8 | 40.9 | 0.98× | 4.80 | 3.04 |
| h2o | 8,348,153 | ✅ | 409.3 | 228.4 | 0.56× | 23.66 | 29.26 |
| **jython** | **371,435,757** | —† | **823** | **DNF** † | — | **166.7** | —† |
| | | | | | geomean **1.95×** | | geomean **0.73×** |

**Memory.** Soufflé is the lighter engine on the small/medium apps (≈0.5–0.7× FlowLog's peak);
FlowLog pulls ahead on the two densest — h2o (23.7 vs 29.3 GiB) and jython (167 GiB, completed,
vs Soufflé still climbing past 98 GiB when capped). Across the 19 measured apps the geomean peak
ratio Soufflé/FlowLog is **0.73×**.

**† jython.** Soufflé (left-to-right, no `.plan`) produced **no output within a 1 h cap** — its RSS
was already past 98 GiB and still rising — so the tuple comparison could not run. FlowLog solves
it in **606 s** (13 m 43 s including writing the 105 GiB result), **167 GiB** peak. Its mmap-heavy
run needs `vm.max_map_count` raised (>65 k mmaps) and `vm.overcommit_memory=1`.

## Correctness — identical modulo `ord()`

For each comparable app, 16–19 of the 21 output relations are **byte-for-byte identical**. The rest
(`VarPointsTo`, `Instance`/`StaticFieldPointsTo`, `Call`/`AnyCallGraphEdge`) differ *only* in which
member of a merged heap class is its **representative**: DOOP picks the minimum-`ord(...)` member,
and `ord` is each engine's string-interning order, so the choice is engine-specific. Row counts
match exactly and, after mapping every representative to its type, the symmetric difference is
**empty** — the heap partitions, and the analysis, are identical. Checked with
`bin/compare-flowlog-souffle.py`.

```
FlowLog : … /new java.lang.Character$UnicodeBlock/133   <…AEGEAN_NUMBERS>
Soufflé : … /new java.lang.Character$UnicodeBlock/0     <…AEGEAN_NUMBERS>
```

## Fair by construction — one join order, no optimiser

Perf/mem isolate **engine execution at one fixed join order**, not query planning:

- **FlowLog** evaluates body atoms left-to-right (`--sip` off — its default).
- **Soufflé** runs left-to-right too: the **16 DOOP `.plan` hints stripped** and **no `-a`
  auto-schedule** (Soufflé keeps written order otherwise — verified it won't reorder even a written
  `a,a,b` cartesian).
- The two programs share **identical body-atom order on all 543 join rules**; only the 12 group-by
  aggregates differ in form.
- `.plan` is order-only, not results: with vs without it Soufflé's output is **byte-identical**, so
  the correctness above holds for both. (For reference, `.plan` buys Soufflé ~1.2–1.3×, excluded
  here so neither engine gets an optimiser the other lacks.)

## Run conditions

`flowlog-west3` · 64 vCPU / 503 GiB. **FlowLog** `flowlog-compiler` @ `main-next 1d8b05a`,
`--str-intern --mode datalog-batch -w 32`. **Soufflé** `2.5` compiled (`-o -j 32`), `.plan`
stripped, no `-a`. Same DaCapo chopin facts to both; empty `KeepClass*`/`KeepMethod`/
`RootCodeElement` materialised for Soufflé (FlowLog tolerates missing); DOOP macro
`CONFIGURATION` → `ContextInsensitiveConfiguration`. Kernel: `vm.overcommit_memory=1`,
`vm.max_map_count=1048576`.

## Files

`results.csv` · `time.{png,svg}` · `memory.{png,svg}` · `programs/` — the FlowLog program, the
Soufflé program (as provided, with `.plan`), and the `.plan`-stripped Soufflé used for the timings.
