# FlowLog vs Souffle on SASY and Sasty

September 24-25, 2026 | single-threaded | AMD EPYC 7763 | 503 GiB RAM

This campaign compares three FlowLog releases with Souffle 2.5 across:

- 11 agent-policy workloads;
- bounded linear and fan-in graph ladders;
- a guard-policy ablation;
- Sasty's 851-rule static taint analysis on 18 public repositories;
- Sasty scans of the SASY source tree; and
- six real incremental SASY commits.

Speedup always means **Souffle time / FlowLog time**. Values above 1 favor
FlowLog.

The Sasty engine-only results and the completed end-to-end scan use Sasty's
taint policy with one join reordered in rule #337, for every engine. Outputs
are unchanged; see [Sasty policy change](#sasty-policy-change). The
incremental replay's older policy has no such rule.

## Key findings

1. **FlowLog is strongest when it avoids expensive recomputation.**
   Steady-state SAST updates are 4.0x to 5.1x faster than compiled Souffle.
   High-fan-in agent policies reach 18x to 34x speedups.

2. **Souffle remains much faster on many small policy workloads.**
   Latest FlowLog wins 4 of 22 cells in the 256-turn census and 10 of 77
   in-budget ladder cells.

3. **Recent common-subexpression work helps fan-in more than linear graphs.**
   Latest FlowLog is 1.20x faster than the old release across the census.
   The gain rises from 1.10x at fan-in 32 to 1.32x at fan-in 128, while
   linear shapes remain near 1.03x.

4. **Latest FlowLog is faster on one-shot SAST, at a memory cost.**
   It beats compiled Souffle on 15 of the 16 corpora of at least 1 second
   where both finish (1.96x geomean) and interpreted Souffle on every corpus
   (3.01x). Its peak memory is 1.4x to 4.6x compiled Souffle's (2.9x
   geomean).

5. **One rule explained the earlier SAST gap and SIP's benefit.**
   Written left to right, Sasty's rule #337 starts with a Cartesian product.
   FlowLog materialized it, up to 168 million tuples on aiohttp, and SIP only
   shrank it. With two atoms swapped for every engine, SIP slows the old and
   mid releases on all 19 corpora, by 2x geomean.

6. **The latest FlowLog result required a local planner guard.**
   Unmodified main crashes while compiling Sasty's policy. The measured
   `newfix` build is FlowLog `07ffd67` plus a one-map fusion guard. The
   CSE commits are not the cause of the crash.

## Results at a glance

> **Agent policies** · 4/22 wins at 256 turns · strongest at high fan-in,
> slower on most small relations

> **One-shot SAST** · 1.96x vs compiled Souffle on corpora >= 1 s · faster
> on 15 of 16, with more memory

> **Incremental SAST** · 4.0x to 5.1x vs compiled Souffle · the clearest
> steady-state advantage

## FlowLog versions

- **Old** `6c111b7` · build/runtime/compiler `0.4.0 / 0.3.0 / 0.5.0`
  · measured with and without SIP.
- **Mid** `fed4211` · `0.5.0 / 0.4.0 / 0.6.0` · measured with and
  without SIP.
- **Latest** `07ffd67` plus guard `c8af77a` · `0.6.0 / 0.5.0 / 0.7.0`
  · SIP removed upstream.

Sasty ships the old FlowLog release with `--sip --str-intern`. Comparing
`old-sip` directly with `newfix` therefore combines release improvements with
SIP removal. With SIP disabled on both sides, latest is **1.067x** faster than
old and **1.038x** faster than mid; mid is **1.028x** faster than old. The
mixed old-SIP-to-latest comparison is **2.11x**, mostly from dropping SIP.

## Agent-policy results

<p align="center">
  <img src="policy-census-time.png" alt="Actual p95 compute time for all 22 policy cells" width="820"/>
</p>

[Vector version](policy-census-time.svg). The log scale is necessary because
the measured cells span more than five orders of magnitude.

At 256 turns, latest FlowLog wins:

- Airline linear and fan-in;
- Copilot Security fan-in; and
- Policy Skill fan-in.

The largest latest-FlowLog speedups are **33.42x** on Copilot Security fan-in,
**23.62x** on Policy Skill fan-in, and **18.38x** on Airline fan-in. Airline
linear is the only linear win at **1.16x**.

The 18 losing cells range down to 0.004x. These are cases where the fixed
incremental-engine overhead exceeds the cost of a small Souffle rerun.

The full 22-cell release table, raw p95 times, forward-form results, and
cross-release comparisons are in [FULL_RESULTS.md](FULL_RESULTS.md).

## Forward rewriting

The FlowLog-only forward forms are not a universal optimization:

- Toxic Flow linear improves by 7.2x to 55.1x.
- DLP Guard linear improves by 3.5x to 22.7x.
- Retail linear improves by 2.4x to 15.5x.
- Retail fan-in slows to 0.53x to 0.62x.
- LLM Content fan-in slows to 0.87x to 0.91x.

Sasty's taint policy has no forward form, so this rewrite does not affect the
SAST results.

## Sasty engine-only results

<p align="center">
  <img src="sasty-selected-time.png" alt="Sasty engine time for FlowLog main and Souffle on the largest corpora" width="820"/>
</p>

[Vector version](sasty-selected-time.svg). Hatched bars are incomplete runs,
not successful completion times.

Times are median seconds of three runs; the two JavaScript scans ran once.
`DNF` means the run exceeded the 7,200-second limit. The old and mid builds
were not rerun on the JavaScript scans, which take hours per run.

<details>
<summary><strong>Exact engine times for all 21 corpora</strong></summary>

| Corpus | Souffle | Souffle-c | old-SIP | old-noSIP | mid-SIP | mid-noSIP | newfix |
|---|---:|---:|---:|---:|---:|---:|---:|
| SASY Python | 69.65 | 42.55 | 55.13 | 36.88 | 54.99 | 36.69 | 36.38 |
| SASY JavaScript | DNF | 6,259 | not run | not run | not run | not run | 4,894 |
| starlette | 14.42 | 8.12 | 20.79 | 8.61 | 20.73 | 8.58 | 9.06 |
| werkzeug | 6.82 | 4.26 | 4.60 | 2.40 | 4.49 | 2.32 | 2.28 |
| itsdangerous | 1.32 | 0.37 | 1.18 | 0.56 | 1.14 | 0.52 | 0.51 |
| httpx | 4.66 | 2.82 | 3.00 | 1.46 | 2.94 | 1.41 | 1.34 |
| fastapi | 22.18 | 12.61 | 9.42 | 7.63 | 9.33 | 7.58 | 7.53 |
| aiohttp | 30.33 | 22.81 | 11.24 | 8.01 | 11.22 | 7.85 | 7.68 |
| flask | 2.71 | 1.44 | 2.25 | 1.08 | 2.23 | 1.02 | 0.98 |
| django | 301.62 | 209.79 | 58.21 | 45.93 | 58.26 | 45.21 | 44.00 |
| requests | 2.27 | 1.10 | 2.36 | 1.08 | 2.34 | 1.04 | 1.00 |
| uvicorn | 3.75 | 2.32 | 2.58 | 1.61 | 2.59 | 1.55 | 1.51 |
| execa | 4.54 | 3.31 | 3.54 | 1.91 | 3.46 | 1.85 | 1.67 |
| body-parser | 1.47 | 0.51 | 1.38 | 0.55 | 1.36 | 0.54 | 0.50 |
| cookie-parser | 1.23 | 0.29 | 1.13 | 0.44 | 1.11 | 0.42 | 0.45 |
| koa | 1.70 | 0.77 | 1.51 | 0.62 | 1.49 | 0.60 | 0.58 |
| fastify | 27.92 | 20.97 | 29.04 | 8.27 | 29.22 | 8.33 | 7.64 |
| axios | 5.35 | 4.72 | 3.23 | 1.45 | 3.18 | 1.41 | 1.28 |
| express | 2.40 | 1.47 | 1.99 | 0.90 | 1.96 | 0.88 | 0.80 |
| undici | 21.93 | 21.71 | 10.37 | 5.76 | 10.32 | 5.67 | 5.20 |
| JavaScript reachable XL | DNF | DNF | not run | not run | not run | not run | 7,129 |

</details>

Parity is exact wherever a reference finished, and no completed FlowLog
execution emitted stderr. Only latest FlowLog finishes JavaScript reachable
XL, in 7,129 seconds, just under the limit. The two relations both Souffle
engines wrote before timing out match FlowLog's.

Machine-readable table: [sast-engine.csv](sast-engine.csv).

## Sasty policy change

Rule #337 of Sasty's policy lists a call atom before the atom that connects it
to the rest of the rule body. Evaluated left to right, the body therefore
starts with a Cartesian product.

FlowLog plans joins in written order and materialized that product: up to
168 million tuples, and 83% to 84% of FlowLog's compute on aiohttp and undici.
Souffle runs the same order as a nested loop, which is cheaper per tuple, but
the rule still took 9.3 of Souffle's 32 seconds on aiohttp.

This report swaps the two atoms in the policy given to every engine. Both
engines follow the written join order: with default settings, no Souffle loop
nest differs from its strict written-order mode (`-P RamSIPS:strict`). All
outputs are unchanged, and the swap speeds up both engines.

| Measure | Original rule | Reordered rule |
|---|---:|---:|
| newfix vs compiled Souffle, corpora >= 1 s | 1.14x, 8 of 15 wins | 1.96x, 15 of 16 wins |
| SASY Python: newfix / compiled Souffle | 137.49 / 64.71 s | 36.38 / 42.55 s |
| aiohttp: newfix / compiled Souffle | 43.22 / 32.19 s | 7.68 / 22.81 s |
| django: newfix / compiled Souffle | ALLOC / 1,653 s | 44.00 / 209.79 s |
| SASY Python: newfix peak memory | 20.1 GiB | 2.4 GiB |

The original-policy results are kept in [FULL_RESULTS.md](FULL_RESULTS.md).

## SIP effect

With the reordered rule, SIP no longer pays off. Disabling it makes the old
and mid releases 2x faster (geomean over 19 corpora), from 1.2x on fastapi to
3.5x on fastify. No corpus is faster with SIP.

With the original rule, SIP helped because its semijoins shrank the rule-#337
product: it sped up aiohttp 3.67x, undici 2.94x, and SASY Python 2.55x, and it
was the only FlowLog configuration that finished django.

## Incremental SAST

<p align="center">
  <img src="incremental-sast-time.png" alt="Actual wall time for the six incremental SAST steps" width="820"/>
</p>

[Vector version](incremental-sast-time.svg).

The six-commit replay covers 638 Python files and about 1.16 million unique
facts. FlowLog applies inserts and removals; Souffle reruns from scratch.

> **Initial load** · 1.2x faster than compiled Souffle  
> **Steady state** · 4.0x to 5.1x faster across the next five commits

<details>
<summary><strong>Exact timing for each incremental step</strong></summary>

| Step | Main FlowLog | Souffle | Compiled Souffle | Compiled speedup |
|---|---:|---:|---:|---:|
| Initial load | 5.167 s | 8.49 s | 6.29 s | 1.2x |
| Commit 1 | 1.304 s | 8.42 s | 6.34 s | 4.9x |
| Commit 2 | 1.619 s | 8.44 s | 6.52 s | 4.0x |
| Commit 3 | 1.398 s | 8.65 s | 6.39 s | 4.6x |
| Commit 4 | 1.561 s | 8.59 s | 6.41 s | 4.1x |
| Commit 5 | 1.261 s | 8.64 s | 6.41 s | 5.1x |

</details>

Main improves steady-state FlowLog commit time by 1.03x over the old release.

## Memory

Latest FlowLog trades memory for time. Its peak memory is 1.4x to 4.6x
compiled Souffle's, 2.9x geomean where both finish.

<details>
<summary><strong>Representative peak-memory measurements</strong></summary>

| Corpus | Souffle | Compiled Souffle | old-SIP | newfix |
|---|---:|---:|---:|---:|
| SASY Python | 1.46 GiB | 0.75 GiB | 3.51 GiB | 2.41 GiB |
| SASY JavaScript | >=79.7 GiB | 50.6 GiB | not run | 124.8 GiB |
| aiohttp | 0.25 GiB | 0.23 GiB | 0.69 GiB | 0.47 GiB |
| django | 1.37 GiB | 1.30 GiB | 2.54 GiB | 3.73 GiB |
| undici | 0.44 GiB | 0.42 GiB | 0.88 GiB | 0.59 GiB |

</details>

With the original rule, the no-SIP django runs exposed a mimalloc v3.3.2
arena-growth defect: they aborted near 172 GiB after exhausting
`vm.max_map_count`. With the reordered rule, newfix finishes django in
44 seconds at 3.7 GiB. The allocator analysis remains in
[FULL_RESULTS.md](FULL_RESULTS.md).

## End-to-end Sasty scans

Latest FlowLog is fastest on the completed Python scan: **79.0 seconds**,
versus **99.1 seconds** for the shipped old-SIP build and **113.9 seconds**
for Souffle.

<details>
<summary><strong>Exact end-to-end outcomes</strong></summary>

| Case | Souffle | old-SIP | newfix |
|---|---:|---:|---:|
| SASY Python, dependencies off | 113.9 s | 99.1 s | 79.0 s |
| SASY JavaScript, dependencies off | timeout | timeout | timeout |
| Python reachable dependencies | rejected before engine | same | same |
| JavaScript reachable dependencies | rejected before engine | same | same |

</details>

The last three rows were measured with the original rule. The reachable scans
fail in dependency discovery before either Datalog engine runs. The JavaScript
first-party scan exceeds Sasty's 900-second production stage bound with every
engine; with the reordered rule, its engine-only time is still at least
4,894 seconds.

## Correctness and limitations

- The SAST comparison hashes sorted rows from all seven public relations.
- Every completed result is exact where a reference finished. JavaScript
  reachable XL has only the partial outputs both Souffle engines wrote before
  timing out.
- The SAST geometric means cover corpora where both engines finish; timeouts
  are excluded.
- Engine-only Sasty results use the reordered rule #337 for every engine. The
  old and mid builds were not rerun on the JavaScript scans.
- Policy traces are generated because real assistant traces are not in the
  benchmark repository.
- Three unavailable public-corpus pins were replaced by same-era public
  commits; the exact substitutions are listed in the appendix.
- Python reachable XL was not measured because capture exceeded 4 GiB of
  dependency facts.
- Only aggregate measurements are published here. Private source, extracted
  facts, generated evaluator binaries, and multi-gigabyte run directories are
  intentionally excluded.
- The latest result is `newfix`, not pristine main: main requires the local
  planner guard, removal of Sasty's `--sip` argument, and a mechanical rename
  of the newly reserved `fn` identifier.

## Full disclosure

[FULL_RESULTS.md](FULL_RESULTS.md) contains:

- all 22 census cells across old, mid, and latest FlowLog;
- bounded ladder results and per-workload forward-rewrite effects;
- guard ablation measurements;
- every Sasty engine-only timing and peak-RSS result;
- the rule-#337 profile and the original-policy Sasty results;
- parity tables and all incomplete-run bounds;
- end-to-end scan results;
- incremental commit replay results;
- build and compatibility findings; and
- corpus substitutions, blocked cases, and other deviations.

Machine-readable run settings and the publication boundary are recorded in
[metadata.json](metadata.json).

The figures are generated from [policy-census.csv](policy-census.csv),
[sasty-selected.csv](sasty-selected.csv), and
[incremental-sast.csv](incremental-sast.csv):

```bash
python3 docs/benchmarks/2026-09-24-sasy/render.py
```

Rendering uses FlowLog's Ubuntu typography and website blue/brown accents.
On Ubuntu, install `fonts-ubuntu`; an extracted font directory can instead
be supplied through `FLOWLOG_BENCH_FONT_DIR`.
