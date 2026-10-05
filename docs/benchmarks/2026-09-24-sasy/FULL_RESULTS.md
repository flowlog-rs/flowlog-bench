# FlowLog vs Souffle on SASY/Sasty: full results appendix

Generated 2026-09-24; the Sasty results were rerun on 2026-09-25 with the reordered rule #337
(section 4). Every number was measured on this VM in this session, unless marked otherwise.
Ratios are always **Souffle time  /  FlowLog time**, so **>1 means FlowLog is faster**.

For the concise findings and publication boundary, see [README.md](README.md).

## Setup

| component | version |
|---|---|
| FlowLog **old** | `6c111b7` (Jul 26): flowlog-build 0.4.0 / runtime 0.3.0 / compiler 0.5.0. This is the build Sasty ships. |
| FlowLog **mid** | `fed4211` (Sep 14): 0.5.0 / 0.4.0 / compiler 0.6.0 |
| FlowLog **new** | main `07ffd67` (Sep 24): 0.6.0 / 0.5.0 / compiler 0.7.0, including the CSE work (#373-#377); identical to the crates.io 0.6.0/0.5.0 releases. For Sasty only, "newfix" adds a local planner guard (`c8af77a`, see section 7). |
| Souffle | 2.5. Interpreted is the production engine; a compiled `souffle -o` binary of the same program is the strongest Souffle reference. |
| Harness | Private SASY/Sasty benchmark harness revisions retained with the source run; only aggregate results are published here. |
| Host | Azure VM, AMD EPYC 7763, 32 cores / 64 threads, 4 L3 domains, 503 GB RAM. Every engine runs single-threaded, one job per L3 domain. For Sasty this is the production setting: `runner.py` calls `souffle` without `-j` (default 1) and the FlowLog evaluator with `-w 1`. |

## Headline

| family | what is timed | FlowLog main (0.6/0.5, CSE) vs Souffle | release effect (new vs old FlowLog) |
|---|---|---|---|
| Agent-policy census, 256 turns (section 1) | p95 compute per action | wins 4/22 cells, geomean 0.157x (old 0.131x); forward forms: 6/22, 0.320x | 1.20x geomean; up to 3.14x (DLP Guard fan-in); linear shapes ~1.0x |
| In-budget ladders (section 2) | p95 compute per action | wins 10/77, 0.075x (old 0.068x); forward forms: 12/77, 0.13x | CSE gain grows with fan-in: F32 1.10x, F64 1.19x, F128 1.32x; linear ~1.03x |
| Guard profile (section 3) | p95 compute per action | 0.09-0.35x; no-gate variant 0.14-1.43x | from the ratio columns: linear ~0.9-1.0x, fan-in 1.14-1.25x |
| SAST incremental, 6 real commits (section 6) | per-commit update vs from-scratch | 4.0-5.1x faster than compiled Souffle; 5.2-6.9x faster than interpreted (steps 1-5) | 1.03x |
| SAST end-to-end, production `sasty scan` (section 5) | whole scan | python-off: 1.44x (79.0 s vs 113.9 s); shipped old-sip 1.15x (99.1 s). JS-off (original policy): every engine hits the 900 s stage timeout | shipped old-sip 99.1 s -> newfix 79.0 s (1.25x); main has no SIP |
| SAST batch, engine-only (section 4) | one evaluation | main (SIP off): geomean 3.01x vs interpreted Souffle (wins 19/19); 1.68x vs compiled Souffle (wins 17/20), 1.96x on inputs >= 1 s (wins 15/16, only loss starlette 0.90x). JS-off: 4,894 s vs 6,259 s compiled, >7,200 s interpreted. django: 44.0 s vs 209.8 s compiled. JS-XL: only main finishes (7,129 s) | shipped old-sip -> main: 2.11x geomean, faster on all 19 inputs (1.25-3.80x). With SIP off in both, CSE and the other main changes give 1.07x |

**Policy workloads (census, ladders, guard).** FlowLog wins only where fan-in makes each
Souffle re-run expensive: Airline, Copilot Security and Policy Skill at fan-in. Everywhere
else Souffle's from-scratch run is still cheaper per action. Main's CSE work speeds up
FlowLog mainly on fan-in shapes (0.92-3.14x per t256 cell; 1.20x geomean over all cells) and
leaves linear shapes unchanged. In the shipped-program census it moves no cell across the
break-even line.

**Forward rewrite.** The FlowLog-only rewrite helps linear shapes a lot (Toxic Flow 7-55x,
DLP Guard 3.5-23x, Retail 2.4-16x). It is mixed at fan-in (Retail 0.53-0.62x, LLM Content
0.87-0.91x). Over the in-budget ladders it raises FlowLog from 10 to 12 wins of 77. The
Copilot Security and Policy Skill rewrites also drop work that Souffle skips anyway, so those
forward-form gains are not engine gains. Sasty's
`taint.dl` has no forward form, so the rewrite does not apply to SAST.

**SAST.** Every Sasty engine-only number and the python-off end-to-end scan use Sasty's taint
policy with two atoms of rule #337 swapped, for every engine; as written, that rule starts with
a Cartesian product (section 4). On this
policy, main without SIP beats the production Souffle interpreter on all 19 engine-only inputs
where both finish (3.01x geomean) and compiled Souffle on 17 of 20 (1.68x). On inputs of at
least 1 s it beats compiled Souffle on 15 of 16 (1.96x); starlette is the only loss (0.90x).
Parity is exact on every finished run.

SIP no longer pays on this policy: old-nosip  /  old-sip is 0.505x and mid-nosip  /  mid-sip
0.497x, so SIP is slower on every input. The shipped old-sip -> main upgrade is therefore
2.11x, mostly from dropping SIP. With SIP off in both, CSE and the other main changes give
1.07x (old-nosip  /  newfix). End-to-end on python-off, main is now the fastest engine:
79.0 s, versus 99.1 s for the shipped build and 113.9 s for Souffle.

FlowLog still costs memory: 1.4-4.6x compiled Souffle's peak RSS (2.9x geomean where both
finish), for example 2.4 GiB on python-off where compiled Souffle uses 0.75 GiB, and 125 GiB on
JS-off where it uses 51 GiB.

With the original rule, main was only 1.09x faster than compiled Souffle (10/19), SIP was worth
2.5-3.7x on aiohttp, undici and python-off, and every no-SIP build aborted on django at
mimalloc's 172 GiB ceiling. Those results are kept at the end of section 4.

First-party JavaScript (JS-off) exceeds Sasty's 900 s stage bound with every engine; the
fastest is main at 4,894 s. On JS-XL only main finishes, at 7,129 s, just under the 2 h limit.

The incremental path is where FlowLog clearly wins: each real SASY commit update (steps 1-5)
is 4.0-5.1x faster than a compiled-Souffle rerun (section 6).

## 1. Agent-policy census, 256 turns (11 SASY workloads x 2 shapes)

### Souffle vs FlowLog-inc census, 256 turns, one action per query

Primary metric: p95 engine compute per action, Souffle run() / FlowLog commit(); >1 = FlowLog faster.


#### All shipped programs (both engines)

| workload | shape | 0.4.0/0.3.0 (Jul 26) | 0.5.0/0.4.0 (Sep 14) | 0.6.0/0.5.0 (Sep 24) |
| --- | --- | ---: | ---: | ---: |
| Airline | linear | **1.15x** | **1.20x** | **1.16x** |
| Airline | fanin | **16.36x** | **17.62x** | **18.38x** |
| Copilot Security | linear | 0.82x | 0.84x | 0.82x |
| Copilot Security | fanin | **32.92x** | **33.82x** | **33.42x** |
| DLP Guard | linear | 0.012x | 0.012x | 0.011x |
| DLP Guard | fanin | 0.058x | 0.052x | 0.17x |
| LLM Content | linear | 0.004x | 0.004x | 0.004x |
| LLM Content | fanin | 0.69x | 0.66x | 0.82x |
| MALADE | linear | 0.012x | 0.012x | 0.015x |
| MALADE | fanin | 0.10x | 0.10x | 0.20x |
| MLS | linear | 0.009x | 0.009x | 0.010x |
| MLS | fanin | 0.008x | 0.008x | 0.008x |
| OpenClaw | linear | 0.013x | 0.013x | 0.013x |
| OpenClaw | fanin | 0.011x | 0.010x | 0.011x |
| Policy Skill | linear | 0.67x | 0.68x | 0.66x |
| Policy Skill | fanin | **17.60x** | **17.72x** | **23.62x** |
| Retail | linear | 0.029x | 0.030x | 0.029x |
| Retail | fanin | 0.40x | 0.36x | 0.48x |
| Security | linear | 0.20x | 0.20x | 0.20x |
| Security | fanin | 0.32x | 0.31x | 0.38x |
| Toxic Flow | linear | 0.008x | 0.008x | 0.008x |
| Toxic Flow | fanin | 0.041x | 0.045x | 0.12x |
| **wins** | | 4 / 22 | 4 / 22 | 4 / 22 |
| **geomean** | | 0.131x | 0.131x | 0.157x |

#### FlowLog forward forms as in the published shipped-only census

| workload | shape | 0.4.0/0.3.0 (Jul 26) | 0.5.0/0.4.0 (Sep 14) | 0.6.0/0.5.0 (Sep 24) |
| --- | --- | ---: | ---: | ---: |
| Airline | linear | **1.15x** | **1.20x** | **1.16x** |
| Airline | fanin | **16.36x** | **17.62x** | **18.38x** |
| Copilot Security | linear | **1.61x** [f] | **1.61x** [f] | **1.53x** [f] |
| Copilot Security | fanin | **35.27x** [f] | **34.38x** [f] | **34.40x** [f] |
| DLP Guard | linear | 0.14x [f] | 0.14x [f] | 0.14x [f] |
| DLP Guard | fanin | 0.78x [f] | 0.75x [f] | 0.59x [f] |
| LLM Content | linear | 0.030x [f] | 0.030x [f] | 0.038x [f] |
| LLM Content | fanin | 0.49x [f] | 0.49x [f] | 0.62x [f] |
| MALADE | linear | 0.015x [f] | 0.015x [f] | 0.016x [f] |
| MALADE | fanin | **2.07x** [f] | **2.04x** [f] | **2.05x** [f] |
| MLS | linear | 0.009x | 0.009x | 0.010x |
| MLS | fanin | 0.008x | 0.008x | 0.008x |
| OpenClaw | linear | 0.013x | 0.013x | 0.013x |
| OpenClaw | fanin | 0.011x | 0.010x | 0.011x |
| Policy Skill | linear | 0.67x | 0.68x | 0.66x |
| Policy Skill | fanin | **17.60x** | **17.72x** | **23.62x** |
| Retail | linear | 0.22x [f] | 0.23x [f] | 0.24x [f] |
| Retail | fanin | 0.40x | 0.36x | 0.48x |
| Security | linear | 0.20x | 0.20x | 0.20x |
| Security | fanin | 0.32x | 0.31x | 0.38x |
| Toxic Flow | linear | 0.23x [f] | 0.23x [f] | 0.22x [f] |
| Toxic Flow | fanin | 0.55x [f] | 0.55x [f] | 0.59x [f] |
| **wins** | | 6 / 22 | 6 / 22 | 6 / 22 |
| **geomean** | | 0.307x | 0.303x | 0.320x |

#### Best FlowLog form per cell (selected on outcome; optimistic)

| workload | shape | 0.4.0/0.3.0 (Jul 26) | 0.5.0/0.4.0 (Sep 14) | 0.6.0/0.5.0 (Sep 24) |
| --- | --- | ---: | ---: | ---: |
| Airline | linear | **1.15x** | **1.20x** | **1.16x** |
| Airline | fanin | **16.36x** | **17.62x** | **18.38x** |
| Copilot Security | linear | **1.61x** [f] | **1.61x** [f] | **1.53x** [f] |
| Copilot Security | fanin | **35.27x** [f] | **34.38x** [f] | **34.40x** [f] |
| DLP Guard | linear | 0.14x [f] | 0.14x [f] | 0.14x [f] |
| DLP Guard | fanin | 0.78x [f] | 0.75x [f] | 0.59x [f] |
| LLM Content | linear | 0.030x [f] | 0.030x [f] | 0.038x [f] |
| LLM Content | fanin | 0.69x | 0.66x | 0.82x |
| MALADE | linear | 0.015x [f] | 0.015x [f] | 0.016x [f] |
| MALADE | fanin | **2.07x** [f] | **2.04x** [f] | **2.05x** [f] |
| MLS | linear | 0.009x | 0.009x | 0.010x |
| MLS | fanin | 0.008x | 0.008x | 0.008x |
| OpenClaw | linear | 0.013x | 0.013x | 0.013x |
| OpenClaw | fanin | 0.011x | 0.010x | 0.011x |
| Policy Skill | linear | 0.90x [f] | 0.91x [f] | **1.21x** [f] |
| Policy Skill | fanin | **17.60x** | **17.72x** | **28.35x** [f] |
| Retail | linear | 0.22x [f] | 0.23x [f] | 0.24x [f] |
| Retail | fanin | 0.40x | 0.36x | 0.48x |
| Security | linear | 0.20x | 0.20x | 0.20x |
| Security | fanin | 0.32x | 0.31x | 0.38x |
| Toxic Flow | linear | 0.23x [f] | 0.23x [f] | 0.22x [f] |
| Toxic Flow | fanin | 0.55x [f] | 0.55x [f] | 0.59x [f] |
| **wins** | | 6 / 22 | 6 / 22 | 7 / 22 |
| **geomean** | | 0.316x | 0.312x | 0.336x |

#### FlowLog-only speedup across releases (FlowLog p95 compute, same program)


##### arm `target`

| workload | shape | old FlowLog p95 us | mid FlowLog p95 us | new FlowLog p95 us | speedup mid vs old | speedup new vs old |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Airline | linear | 74,917 | 73,124 | 74,460 | 1.02x | 1.01x |
| Airline | fanin | 34,215 | 31,985 | 30,019 | 1.07x | 1.14x |
| Copilot Security | linear | 75,607 | 74,267 | 74,560 | 1.02x | 1.01x |
| Copilot Security | fanin | 39,163 | 38,409 | 38,761 | 1.02x | 1.01x |
| DLP Guard | linear | 18,062 | 17,821 | 17,916 | 1.01x | 1.01x |
| DLP Guard | fanin | 22,485 | 22,454 | 7,160 | 1.00x | 3.14x |
| LLM Content | linear | 17,102 | 17,345 | 17,170 | 0.99x | 1.00x |
| LLM Content | fanin | 1,781 | 1,873 | 1,667 | 0.95x | 1.07x |
| MALADE | linear | 1,176 | 1,170 | 936 | 1.00x | 1.26x |
| MALADE | fanin | 38,797 | 38,163 | 19,159 | 1.02x | 2.02x |
| MLS | linear | 692 | 696 | 693 | 1.00x | 1.00x |
| MLS | fanin | 945 | 1,028 | 1,025 | 0.92x | 0.92x |
| OpenClaw | linear | 549 | 551 | 549 | 1.00x | 1.00x |
| OpenClaw | fanin | 787 | 863 | 856 | 0.91x | 0.92x |
| Policy Skill | linear | 47,626 | 46,091 | 47,225 | 1.03x | 1.01x |
| Policy Skill | fanin | 29,814 | 29,335 | 21,513 | 1.02x | 1.39x |
| Retail | linear | 34,251 | 32,354 | 33,687 | 1.06x | 1.02x |
| Retail | fanin | 4,870 | 4,923 | 3,688 | 0.99x | 1.32x |
| Security | linear | 51,131 | 51,024 | 50,492 | 1.00x | 1.01x |
| Security | fanin | 146,106 | 144,873 | 121,418 | 1.01x | 1.20x |
| Toxic Flow | linear | 37,344 | 38,431 | 37,145 | 0.97x | 1.01x |
| Toxic Flow | fanin | 24,815 | 24,792 | 8,767 | 1.00x | 2.83x |
| **geomean** | | |  |  | 1.00x | 1.20x |

##### arm `fwd`

| workload | shape | old FlowLog p95 us | mid FlowLog p95 us | new FlowLog p95 us | speedup mid vs old | speedup new vs old |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Copilot Security | linear | 38,390 | 38,615 | 39,765 | 0.99x | 0.97x |
| Copilot Security | fanin | 37,370 | 37,664 | 37,619 | 0.99x | 0.99x |
| DLP Guard | linear | 1,550 | 1,507 | 1,510 | 1.03x | 1.03x |
| DLP Guard | fanin | 1,890 | 1,950 | 1,963 | 0.97x | 0.96x |
| LLM Content | linear | 2,485 | 2,481 | 1,922 | 1.00x | 1.29x |
| LLM Content | fanin | 2,448 | 2,509 | 1,911 | 0.98x | 1.28x |
| MALADE | linear | 897 | 887 | 833 | 1.01x | 1.08x |
| MALADE | fanin | 1,826 | 1,890 | 1,838 | 0.97x | 0.99x |
| Policy Skill | linear | 35,196 | 34,793 | 25,850 | 1.01x | 1.36x |
| Policy Skill | fanin | 30,843 | 30,304 | 18,514 | 1.02x | 1.67x |
| Retail | linear | 4,361 | 4,266 | 4,130 | 1.02x | 1.06x |
| Retail | fanin | 6,062 | 6,082 | 5,905 | 1.00x | 1.03x |
| Toxic Flow | linear | 1,360 | 1,367 | 1,361 | 0.99x | 1.00x |
| Toxic Flow | fanin | 1,955 | 2,024 | 2,046 | 0.97x | 0.96x |
| **geomean** | | |  |  | 1.00x | 1.10x |

#### Souffle drift control (identical Souffle program in every campaign)

114 identical-program Souffle p95 comparisons: min 0.787x, p05 0.905x, median 0.999x, p95 1.084x, max 1.257x, geomean 0.998x


#### Secondary accountings for the new release (arm selection as published)

- compute p50: 5 / 22 wins, geomean 0.210x
- compute p95: 6 / 22 wins, geomean 0.320x
- reaction p50: 5 / 22 wins, geomean 0.454x
- reaction p95: 11 / 22 wins, geomean 0.788x

#### Raw p95 compute (us), new release

| workload | shape | Souffle | FlowLog shipped | FlowLog fwd | edges |
| --- | --- | ---: | ---: | ---: | ---: |
| Airline | linear | 86,197 | 74,460 | - | 770 |
| Airline | fanin | 551,833 | 30,019 | - | 99,458 |
| Copilot Security | linear | 61,320 | 74,560 | 39,765 | 701 |
| Copilot Security | fanin | 1,295,549 | 38,761 | 37,619 | 246,051 |
| DLP Guard | linear | 205 | 17,916 | 1,510 | 512 |
| DLP Guard | fanin | 1,231 | 7,160 | 1,963 | 131,328 |
| LLM Content | linear | 74 | 17,170 | 1,922 | 511 |
| LLM Content | fanin | 1,375 | 1,667 | 1,911 | 130,816 |
| MALADE | linear | 14 | 936 | 833 | 799 |
| MALADE | fanin | 3,856 | 19,159 | 1,838 | 102,911 |
| MLS | linear | 7 | 693 | - | 1,023 |
| MLS | fanin | 8 | 1,025 | - | 131,583 |
| OpenClaw | linear | 7 | 549 | - | 512 |
| OpenClaw | fanin | 9 | 856 | - | 131,328 |
| Policy Skill | linear | 31,053 | 47,225 | 25,850 | 516 |
| Policy Skill | fanin | 508,190 | 21,513 | 18,514 | 133,386 |
| Retail | linear | 971 | 33,687 | 4,130 | 772 |
| Retail | fanin | 1,767 | 3,688 | 5,905 | 99,972 |
| Security | linear | 10,026 | 50,492 | - | 653 |
| Security | fanin | 45,891 | 121,418 | - | 213,531 |
| Toxic Flow | linear | 313 | 37,145 | 1,361 | 1,023 |
| Toxic Flow | fanin | 1,030 | 8,767 | 2,046 | 131,583 |

## 2. In-budget size ladders and the forward rewrite

### Souffle vs FlowLog-inc census: size ladder inside the graph budget

Budget: <= 2,048 nodes and <= 65,536 edges per generated graph. Metric: p95 engine compute per action, Souffle / FlowLog (>1 = FlowLog faster). Fan-in 256 is an over-budget reference only.


#### Generated graph sizes (min-max over workloads)

| shape | turns | nodes | edges | edges/node | in budget |
| --- | ---: | ---: | ---: | ---: | :---: |
| linear | 64 | 129-256 | 128-255 | 1-1 | yes |
| linear | 128 | 257-512 | 256-511 | 1-1 | yes |
| linear | 256 | 513-1,024 | 512-1,023 | 1-1 | yes |
| linear | 512 | 1,025-2,048 | 1,024-2,047 | 1-1 | yes |
| fanin | 32 | 65-128 | 1,663-3,655 | 16-42 | yes |
| fanin | 64 | 129-256 | 6,434-15,051 | 32-86 | yes |
| fanin | 128 | 257-512 | 25,154-61,075 | 64-174 | yes |
| fanin | 256 | 513-1,024 | 99,458-246,051 | 128-350 | no |

#### Shipped programs on both engines: FlowLog wins / cells and geomean, per rung

| shape | turns | old 0.4/0.3 | mid 0.5/0.4 | new 0.6/0.5 (CSE) |
| --- | ---: | ---: | ---: | ---: |
| linear | 64 | 0/11, 0.026x | 0/11, 0.026x | 0/11, 0.027x |
| linear | 128 | 0/11, 0.034x | 0/11, 0.035x | 0/11, 0.036x |
| linear | 256 | 1/11, 0.046x | 1/11, 0.047x | 1/11, 0.047x |
| linear | 512 | 3/11, 0.062x | 3/11, 0.063x | 3/11, 0.064x |
| fanin | 32 | 0/11, 0.071x | 0/11, 0.072x | 0/11, 0.080x |
| fanin | 64 | 3/11, 0.14x | 3/11, 0.14x | 3/11, 0.17x |
| fanin | 128 | 3/11, 0.25x | 3/11, 0.25x | 3/11, 0.33x |
| fanin | 256 (over budget) | 3/11, 0.37x | 3/11, 0.36x | 3/11, 0.52x |
| **all in-budget rungs** | | 10/77, 0.068x | 10/77, 0.068x | 10/77, 0.075x |

#### FlowLog forward forms where the published census used them ([f]): FlowLog wins / cells and geomean, per rung

| shape | turns | old 0.4/0.3 | mid 0.5/0.4 | new 0.6/0.5 (CSE) |
| --- | ---: | ---: | ---: | ---: |
| linear | 64 | 0/11, 0.045x | 0/11, 0.045x | 0/11, 0.046x |
| linear | 128 | 0/11, 0.073x | 0/11, 0.074x | 0/11, 0.075x |
| linear | 256 | 2/11, 0.12x | 2/11, 0.12x | 2/11, 0.13x |
| linear | 512 | 3/11, 0.21x | 3/11, 0.21x | 3/11, 0.22x |
| fanin | 32 | 1/11, 0.076x | 1/11, 0.077x | 1/11, 0.080x |
| fanin | 64 | 3/11, 0.17x | 3/11, 0.18x | 3/11, 0.18x |
| fanin | 128 | 3/11, 0.39x | 3/11, 0.38x | 3/11, 0.41x |
| fanin | 256 (over budget) | 4/11, 0.77x | 4/11, 0.75x | 4/11, 0.81x |
| **all in-budget rungs** | | 12/77, 0.12x | 12/77, 0.12x | 12/77, 0.13x |

#### Best FlowLog form per cell (optimistic, chosen on outcome): FlowLog wins / cells and geomean, per rung

| shape | turns | old 0.4/0.3 | mid 0.5/0.4 | new 0.6/0.5 (CSE) |
| --- | ---: | ---: | ---: | ---: |
| linear | 64 | 0/11, 0.047x | 0/11, 0.047x | 0/11, 0.048x |
| linear | 128 | 0/11, 0.077x | 0/11, 0.077x | 0/11, 0.079x |
| linear | 256 | 2/11, 0.13x | 2/11, 0.13x | 3/11, 0.13x |
| linear | 512 | 3/11, 0.21x | 3/11, 0.21x | 3/11, 0.23x |
| fanin | 32 | 1/11, 0.078x | 1/11, 0.078x | 1/11, 0.082x |
| fanin | 64 | 3/11, 0.18x | 3/11, 0.18x | 3/11, 0.19x |
| fanin | 128 | 3/11, 0.40x | 3/11, 0.39x | 3/11, 0.43x |
| fanin | 256 (over budget) | 4/11, 0.79x | 4/11, 0.77x | 4/11, 0.85x |
| **all in-budget rungs** | | 12/77, 0.13x | 12/77, 0.13x | 13/77, 0.13x |

#### Per-workload ladder, FlowLog new 0.6/0.5 (CSE) (published selection; [f] = forward form)

| workload | L64 | L128 | L256 | L512 | F32 | F64 | F128 | F256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Airline | 0.21x | 0.47x | **1.16x** | **2.67x** | 0.51x | **2.09x** | **6.94x** | **18.38x** |
| Copilot Security | 0.32x [f] | 0.71x [f] | **1.53x** [f] | **3.55x** [f] | **1.05x** [f] | **4.27x** [f] | **13.44x** [f] | **34.40x** [f] |
| DLP Guard | 0.034x [f] | 0.065x [f] | 0.14x [f] | 0.29x [f] | 0.038x [f] | 0.089x [f] | 0.23x [f] | 0.59x [f] |
| LLM Content | 0.012x [f] | 0.020x [f] | 0.038x [f] | 0.086x [f] | 0.031x [f] | 0.076x [f] | 0.22x [f] | 0.62x [f] |
| MALADE | 0.011x [f] | 0.013x [f] | 0.016x [f] | 0.025x [f] | 0.066x [f] | 0.20x [f] | 0.69x [f] | **2.05x** [f] |
| MLS | 0.011x | 0.010x | 0.010x | 0.009x | 0.011x | 0.010x | 0.010x | 0.008x |
| OpenClaw | 0.013x | 0.013x | 0.013x | 0.013x | 0.013x | 0.013x | 0.012x | 0.011x |
| Policy Skill | 0.13x | 0.30x | 0.66x | **1.41x** | 0.47x | **2.05x** | **8.11x** | **23.62x** |
| Retail | 0.064x [f] | 0.12x [f] | 0.24x [f] | 0.48x [f] | 0.073x | 0.13x | 0.24x | 0.48x |
| Security | 0.094x | 0.14x | 0.20x | 0.26x | 0.11x | 0.22x | 0.34x | 0.38x |
| Toxic Flow | 0.053x [f] | 0.11x [f] | 0.22x [f] | 0.44x [f] | 0.039x [f] | 0.090x [f] | 0.23x [f] | 0.59x [f] |

L = linear, F = fanin; F256 is over budget.

#### Per-workload ladder, FlowLog old 0.4/0.3 (published selection; [f] = forward form)

| workload | L64 | L128 | L256 | L512 | F32 | F64 | F128 | F256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Airline | 0.22x | 0.49x | **1.15x** | **2.77x** | 0.50x | **1.92x** | **6.20x** | **16.36x** |
| Copilot Security | 0.32x [f] | 0.71x [f] | **1.61x** [f] | **3.57x** [f] | **1.04x** [f] | **4.29x** [f] | **13.61x** [f] | **35.27x** [f] |
| DLP Guard | 0.035x [f] | 0.067x [f] | 0.14x [f] | 0.28x [f] | 0.041x [f] | 0.10x [f] | 0.27x [f] | 0.78x [f] |
| LLM Content | 0.011x [f] | 0.018x [f] | 0.030x [f] | 0.055x [f] | 0.027x [f] | 0.069x [f] | 0.18x [f] | 0.49x [f] |
| MALADE | 0.010x [f] | 0.012x [f] | 0.015x [f] | 0.023x [f] | 0.061x [f] | 0.18x [f] | 0.66x [f] | **2.07x** [f] |
| MLS | 0.010x | 0.010x | 0.009x | 0.010x | 0.010x | 0.010x | 0.011x | 0.008x |
| OpenClaw | 0.013x | 0.013x | 0.013x | 0.013x | 0.013x | 0.013x | 0.013x | 0.011x |
| Policy Skill | 0.13x | 0.30x | 0.67x | **1.42x** | 0.42x | **1.74x** | **6.38x** | **17.60x** |
| Retail | 0.061x [f] | 0.12x [f] | 0.22x [f] | 0.47x [f] | 0.065x | 0.11x | 0.20x | 0.40x |
| Security | 0.093x | 0.14x | 0.20x | 0.26x | 0.10x | 0.19x | 0.27x | 0.32x |
| Toxic Flow | 0.056x [f] | 0.11x [f] | 0.23x [f] | 0.44x [f] | 0.043x [f] | 0.088x [f] | 0.22x [f] | 0.55x [f] |

L = linear, F = fanin; F256 is over budget.

#### FlowLog-only speedup across releases (FlowLog p95, same program), geomean over workloads

| arm | shape | turns | mid vs old | new vs old | new vs mid | min new vs old (cell) | max new vs old (cell) |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| target | linear | 64 | 1.01x | 1.03x | 1.02x | 0.96x (Airline) | 1.19x (MALADE) |
| target | linear | 128 | 1.01x | 1.02x | 1.02x | 0.95x (Airline) | 1.20x (MALADE) |
| target | linear | 256 | 1.01x | 1.03x | 1.02x | 1.00x (LLM Content) | 1.26x (MALADE) |
| target | linear | 512 | 1.01x | 1.03x | 1.03x | 0.97x (Airline) | 1.42x (MALADE) |
| target | fanin | 32 | 1.00x | 1.10x | 1.09x | 0.97x (OpenClaw) | 1.34x (MALADE) |
| target | fanin | 64 | 1.00x | 1.19x | 1.19x | 0.95x (OpenClaw) | 1.60x (DLP Guard) |
| target | fanin | 128 | 0.99x | 1.32x | 1.33x | 0.94x (OpenClaw) | 2.29x (DLP Guard) |
| target | fanin | 256 (over) | 0.99x | 1.40x | 1.42x | 0.92x (OpenClaw) | 3.14x (DLP Guard) |
| fwd | linear | 64 | 1.01x | 1.04x | 1.04x | 0.98x (Toxic Flow) | 1.09x (Policy Skill) |
| fwd | linear | 128 | 1.01x | 1.06x | 1.06x | 0.99x (Toxic Flow) | 1.16x (LLM Content) |
| fwd | linear | 256 | 1.01x | 1.10x | 1.09x | 0.97x (Copilot Security) | 1.36x (Policy Skill) |
| fwd | linear | 512 | 1.01x | 1.20x | 1.19x | 0.99x (Toxic Flow) | 1.92x (Policy Skill) |
| fwd | fanin | 32 | 1.00x | 1.04x | 1.04x | 0.97x (Toxic Flow) | 1.12x (Policy Skill) |
| fwd | fanin | 64 | 1.00x | 1.06x | 1.06x | 0.99x (Toxic Flow) | 1.23x (Policy Skill) |
| fwd | fanin | 128 | 0.99x | 1.08x | 1.09x | 0.96x (Toxic Flow) | 1.45x (Policy Skill) |
| fwd | fanin | 256 (over) | 0.98x | 1.10x | 1.12x | 0.96x (Toxic Flow) | 1.67x (Policy Skill) |

#### Forward-rewrite effect (FlowLog only): shipped p95 / forward p95, same release - new (old)

<1 = the forward form is slower. The Copilot Security and Policy Skill rewrites also remove work that Souffle would skip, so their forward-form wins are not engine wins.

| workload | L64 | L128 | L256 | L512 | F32 | F64 | F128 | F256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Copilot Security | 1.91x (1.90x) | 1.96x (1.93x) | 1.88x (1.97x) | 1.94x (1.92x) | 1.14x (1.11x) | 1.08x (1.07x) | 1.04x (1.06x) | 1.03x (1.05x) |
| DLP Guard | 3.47x (3.42x) | 6.24x (6.12x) | 11.87x (11.65x) | 22.72x (21.67x) | 0.98x (1.20x) | 1.22x (1.91x) | 1.86x (4.29x) | 3.65x (11.90x) |
| LLM Content | 2.56x (2.44x) | 4.61x (4.03x) | 8.93x (6.88x) | 17.16x (11.37x) | 0.91x (0.89x) | 0.90x (0.85x) | 0.87x (0.78x) | 0.87x (0.73x) |
| MALADE | 1.13x (1.25x) | 1.14x (1.26x) | 1.12x (1.31x) | 1.14x (1.49x) | 1.25x (1.54x) | 1.85x (2.71x) | 4.03x (7.41x) | 10.43x (21.25x) |
| Policy Skill | 1.68x (1.61x) | 1.82x (1.61x) | 1.83x (1.35x) | 1.83x (0.95x) | 1.07x (1.08x) | 1.09x (1.05x) | 1.15x (1.02x) | 1.16x (0.97x) |
| Retail | 2.37x (2.40x) | 4.28x (4.32x) | 8.16x (7.85x) | 15.51x (14.84x) | 0.53x (0.58x) | 0.54x (0.65x) | 0.57x (0.71x) | 0.62x (0.80x) |
| Toxic Flow | 7.16x (7.36x) | 13.57x (14.40x) | 27.29x (27.47x) | 55.07x (56.61x) | 0.88x (1.09x) | 1.12x (1.77x) | 1.88x (4.36x) | 4.29x (12.70x) |

L = linear, F = fanin; F256 is over budget.

#### Souffle drift control (identical Souffle program, different FlowLog campaigns)

288 comparisons: min 0.787x, p05 0.944x, median 1.000x, p95 1.065x, max 1.136x


## 3. Guard security profile ladder

### Guard security profile ladder (4 reps, alternating order, parity 0)

Souffle/FlowLog per-action compute; p95 (mean). >1 = FlowLog faster.

| cell | nodes | edges | new | nogate | old | mid | push-toggle share new -> nogate | Souffle drift nogate/new |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| linear 64 | 177 | 176 | 0.09x (0.09x) | 0.14x (0.10x) | 0.10x (0.08x) | 0.08x (0.08x) | 37% -> 23% | 0.990x |
| linear 128 | 353 | 352 | 0.14x (0.13x) | 0.28x (0.20x) | 0.15x (0.15x) | 0.15x (0.16x) | 47% -> 22% | 0.989x |
| linear 256 | 706 | 705 | 0.19x (0.22x) | 0.57x (0.45x) | 0.19x (0.22x) | 0.19x (0.22x) | 68% -> 22% | 0.999x |
| linear 512 | 1,413 | 1,412 | 0.21x (0.24x) | **1.18x** (0.94x) | 0.23x (0.26x) | 0.23x (0.25x) | 82% -> 24% | 0.991x |
| fanin 32 | 88 | 3,828 | 0.14x (0.08x) | 0.17x (0.09x) | 0.12x (0.08x) | 0.12x (0.08x) | 27% -> 24% | 1.005x |
| fanin 64 | 177 | 15,576 | 0.24x (0.16x) | 0.50x (0.20x) | 0.21x (0.15x) | 0.21x (0.16x) | 36% -> 25% | 1.024x |
| fanin 128 | 353 | 62,128 | 0.35x (0.32x) | **1.43x** (0.44x) | 0.28x (0.24x) | 0.27x (0.24x) | 62% -> 26% | 0.991x |
| fanin 256 (over budget) | 706 | 248,865 | 0.35x (0.38x) | - | 0.29x (0.34x) | 0.32x (0.35x) | - | - |

#### Absolute per-action compute, us (FlowLog new / nogate vs Souffle)

| cell | Souffle p50 | Souffle mean | Souffle p95 | new p50 | new mean | new p95 | nogate p50 | nogate mean | nogate p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| linear 64 | 498 | 554 | 1,405 | 4,540 | 6,240 | 14,809 | 4,619 | 5,353 | 10,195 |
| linear 128 | 973 | 1,234 | 4,124 | 5,363 | 9,305 | 29,807 | 4,699 | 6,119 | 14,810 |
| linear 256 | 1,918 | 3,021 | 13,456 | 3,447 | 13,697 | 71,683 | 3,961 | 6,729 | 23,704 |
| linear 512 | 3,936 | 8,888 | 50,912 | 4,180 | 36,286 | 237,975 | 3,351 | 9,339 | 42,800 |
| fanin 32 | 275 | 304 | 762 | 3,313 | 3,680 | 5,536 | 3,244 | 3,476 | 4,384 |
| fanin 64 | 546 | 716 | 2,358 | 3,453 | 4,373 | 9,759 | 3,299 | 3,596 | 4,777 |
| fanin 128 | 1,193 | 2,339 | 11,748 | 3,397 | 7,329 | 33,553 | 4,884 | 5,212 | 7,927 |
| fanin 256 | 2,837 | 10,591 | 68,050 | 3,686 | 28,048 | 194,271 | - | - | - |

## 4. SAST batch: Sasty's taint policy, engine-only

**Workload.** Sasty's production taint policy (`taint.dl`, 851 rules) with one join
reordered (see below), evaluated on byte-identical fact directories captured from real
`sasty scan` runs (section 8 lists the capture settings).

The corpora are:
- the 18 pinned public differential corpora (10 Python, 8 JavaScript);
- SASY's own Python and JavaScript sources (`sasy-*-off`, dependencies off);
- `sasy-javascript-reachable-xl`, SASY's JavaScript together with its reachable
  `node_modules` closure. Its limits were raised past production defaults, because the
  production scan refuses it (see section 5).

**Policy change: rule #337.** The body of rule #337 lists a call atom that shares no
variable with the atoms before it, ahead of the atom that connects it to the rest of the
body. Evaluated in written order, the rule therefore starts with a Cartesian product.
- FlowLog plans each rule left-deep in written order and materialized the product: up to
  168 million tuples, and 83-84% of FlowLog's compute on aiohttp and undici (18-70% on
  requests, starlette, uvicorn and werkzeug).
- Souffle runs the same order as a streaming nested loop, 3.8-4.5x cheaper per tuple, but
  the rule still took 9.3 s of Souffle's 32 s on aiohttp.
- SIP semijoin-reduces both sides of the product (1,504 x 3,129 = 4.7 million tuples on
  aiohttp, 0.85 s instead of 35.5 s). That is why SIP helped on the original policy. SIP
  also adds pairwise semijoins to every rule with three or more atoms, which costs time
  elsewhere, for example 17.5 s instead of 6.0 s in starlette's recursive `CallableCtx`
  stratum.

Every engine below evaluates the policy with those two atoms swapped. The Souffle-to-FlowLog
adapter keeps the body atom order, and no `.plan` directives are used. FlowLog joins in
written order; with default settings, `souffle --show=transformed-ram` shows no loop nest
that differs from strict written order (`-P RamSIPS:strict`); 86 `IF` lines in 60 rule
versions differ only in conjunct order. Check-only atoms run early in both engines (hoisted
existence checks in Souffle, semijoins folded into a covering atom in FlowLog), and their
exact placement can differ. All seven public relations are unchanged on every corpus where a
reference finished, and on the end-to-end Python scan (section 5). The original-policy
results are kept at the end of this section.

Timing protocol:
- three measured runs per (case, engine), no warm-up, in rep-major order (every cell's first
  run before any second run, longest corpora first); a single run on the two JavaScript
  scans;
- timeout 7,200 s; per-run RSS guards of 100-200 GB, none reached;
- one job per L3 domain, except the two interpreted-Souffle JavaScript runs, which shared
  one domain; timing runs shared the host with evaluator builds and the end-to-end scans on
  the other domains;
- every evaluator was rebuilt from the reordered policy (FlowLog builds took 596-658 s
  without SIP and 2,162-2,231 s with SIP);
- old and mid FlowLog were not rerun on the two JavaScript scans, which take hours per run.
  The swap changes FlowLog's JavaScript times by only about 7%.

Parity compares Sasty's seven `PUBLIC_RELATIONS` (sorted lines, SHA-256) against
interpreted Souffle: the six public result relations plus the `Stat` diagnostics.

**Not measured:** `sasy-python-reachable-xl`, the reachable Python closure. Its capture
exceeded 4 GiB of *dependency facts* (more than 5x JS-XL) after 20 min. FlowLog already needed
140 GiB on the 0.8 GiB JS-XL input, so this case is infeasible on a 503 GB host.

**JS-XL.** Only newfix finishes, in 7,129 s, just under the limit. No reference finished, but
the two relations that compiled and interpreted Souffle wrote before their timeouts
(`SourceFound`, 523 rows, and the empty `PatternFinding`) match newfix exactly, as do
interpreted Souffle's partial JS-off outputs.

### Engine-only Sasty benchmark (reordered rule #337)

Median wall seconds of 3 runs per cell (n = finished runs; n=0 means a single run was the measurement, as on the two JavaScript corpora). Every engine evaluates the same policy with the rule-#337 atom swap. Souffle = production interpreter; Souffle-c = compiled `souffle -o` binary of the same taint.dl. * = longer than Sasty's default 900 s stage timeout (the production scan would fail closed); DNF = killed by the 7,200 s timeout.

| case | fact rows | MiB | souffle | souffle-c | old-sip | old-nosip | mid-sip | mid-nosip | newfix | n |
|---|---|---|---|---|---|---|---|---|---|---|
| sasy-python-off | 2,730,964 | 227 | 69.65 | 42.55 | 55.13 | 36.88 | 54.99 | 36.69 | 36.38 | 3/3/3/3/3/3/3 |
| sasy-javascript-off | 6,681,913 | 524 | DNF>7206s | 6259.00 * | - | - | - | - | 4894.00 * | -/0/-/-/-/-/0 |
| starlette | 503,832 | 35 | 14.42 | 8.12 | 20.79 | 8.61 | 20.73 | 8.58 | 9.06 | 3/3/3/3/3/3/3 |
| werkzeug | 579,462 | 38 | 6.82 | 4.26 | 4.60 | 2.40 | 4.49 | 2.32 | 2.28 | 3/3/3/3/3/3/3 |
| itsdangerous | 264,222 | 24 | 1.32 | 0.37 | 1.18 | 0.56 | 1.14 | 0.52 | 0.51 | 3/3/3/3/3/3/3 |
| httpx | 419,796 | 30 | 4.66 | 2.82 | 3.00 | 1.46 | 2.94 | 1.41 | 1.34 | 3/3/3/3/3/3/3 |
| fastapi | 1,181,935 | 81 | 22.18 | 12.61 | 9.42 | 7.63 | 9.33 | 7.58 | 7.53 | 3/3/3/3/3/3/3 |
| aiohttp | 1,368,261 | 78 | 30.33 | 22.81 | 11.24 | 8.01 | 11.22 | 7.85 | 7.68 | 3/3/3/3/3/3/3 |
| flask | 398,762 | 29 | 2.71 | 1.44 | 2.25 | 1.08 | 2.23 | 1.02 | 0.98 | 3/3/3/3/3/3/3 |
| django | 6,166,453 | 366 | 301.62 | 209.79 | 58.21 | 45.93 | 58.26 | 45.21 | 44.00 | 3/3/3/3/3/3/3 |
| requests | 359,385 | 28 | 2.27 | 1.10 | 2.36 | 1.08 | 2.34 | 1.04 | 1.00 | 3/3/3/3/3/3/3 |
| uvicorn | 447,845 | 33 | 3.75 | 2.32 | 2.58 | 1.61 | 2.59 | 1.55 | 1.51 | 3/3/3/3/3/3/3 |
| execa | 867,857 | 51 | 4.54 | 3.31 | 3.54 | 1.91 | 3.46 | 1.85 | 1.67 | 3/3/3/3/3/3/3 |
| body-parser | 302,255 | 25 | 1.47 | 0.51 | 1.38 | 0.55 | 1.36 | 0.54 | 0.50 | 3/3/3/3/3/3/3 |
| cookie-parser | 254,952 | 23 | 1.23 | 0.29 | 1.13 | 0.44 | 1.11 | 0.42 | 0.45 | 3/3/3/3/3/3/3 |
| koa | 336,090 | 27 | 1.70 | 0.77 | 1.51 | 0.62 | 1.49 | 0.60 | 0.58 | 3/3/3/3/3/3/3 |
| fastify | 1,188,147 | 66 | 27.92 | 20.97 | 29.04 | 8.27 | 29.22 | 8.33 | 7.64 | 3/3/3/3/3/3/3 |
| axios | 674,500 | 46 | 5.35 | 4.72 | 3.23 | 1.45 | 3.18 | 1.41 | 1.28 | 3/3/3/3/3/3/3 |
| express | 504,320 | 34 | 2.40 | 1.47 | 1.99 | 0.90 | 1.96 | 0.88 | 0.80 | 3/3/3/3/3/3/3 |
| undici | 1,797,035 | 95 | 21.93 | 21.71 | 10.37 | 5.76 | 10.32 | 5.67 | 5.20 | 3/3/3/3/3/3/3 |
| sasy-javascript-reachable-xl | 10,028,546 | 821 | DNF>7206s | DNF>7204s | - | - | - | - | 7129.00 * | -/-/-/-/-/-/0 |

#### Speedup of each FlowLog evaluator (Souffle time  /  FlowLog time; >1 = FlowLog faster)

| evaluator | vs Souffle interpreted: geomean | wins | range | vs Souffle compiled: geomean | wins | range |
|---|---|---|---|---|---|---|
| old-sip | 1.426x | 16/19 | 0.694-5.182x | 0.804x | 5/19 | 0.257-3.604x |
| old-nosip | 2.825x | 19/19 | 1.675-6.567x | 1.593x | 15/19 | 0.659-4.568x |
| mid-sip | 1.442x | 16/19 | 0.696-5.177x | 0.813x | 5/19 | 0.261-3.601x |
| mid-nosip | 2.902x | 19/19 | 1.681-6.672x | 1.637x | 15/19 | 0.690-4.640x |
| newfix | 3.013x | 19/19 | 1.592-6.855x | 1.675x | 17/20 | 0.644-4.768x |

Runs that did not finish: killed by the timeout or the memory guard, or aborted by an allocation failure (not in the geomeans):

- sasy-javascript-off souffle: Souffle interpreted killed (DNF>7206s)
- sasy-javascript-off newfix: Souffle interpreted killed (DNF>7206s) -> speedup > 1.472x
- sasy-javascript-reachable-xl souffle: Souffle interpreted killed (DNF>7206s)
- sasy-javascript-reachable-xl souffle-c: Souffle compiled killed (DNF>7204s)
- sasy-javascript-reachable-xl newfix: Souffle interpreted killed (DNF>7206s) -> speedup > 1.011x
- sasy-javascript-reachable-xl newfix: Souffle compiled killed (DNF>7204s) -> speedup > 1.011x

Souffle compiled vs interpreted: geomean 1.773x faster (19 cases).

#### FlowLog vs FlowLog on the same facts (time of A  /  time of B; >1 = B faster)

| case | old-nosip  /  newfix | mid-nosip  /  newfix | old-nosip  /  mid-nosip | old-nosip  /  old-sip | mid-nosip  /  mid-sip | old-sip  /  newfix |
|---|---|---|---|---|---|---|
| sasy-python-off | 1.014x | 1.009x | 1.005x | 0.669x | 0.667x | 1.515x |
| sasy-javascript-off | - | - | - | - | - | - |
| starlette | 0.950x | 0.947x | 1.003x | 0.414x | 0.414x | 2.295x |
| werkzeug | 1.053x | 1.018x | 1.034x | 0.522x | 0.517x | 2.018x |
| itsdangerous | 1.098x | 1.020x | 1.077x | 0.475x | 0.456x | 2.314x |
| httpx | 1.090x | 1.052x | 1.035x | 0.487x | 0.480x | 2.239x |
| fastapi | 1.013x | 1.007x | 1.007x | 0.810x | 0.812x | 1.251x |
| aiohttp | 1.043x | 1.022x | 1.020x | 0.713x | 0.700x | 1.464x |
| flask | 1.102x | 1.041x | 1.059x | 0.480x | 0.457x | 2.296x |
| django | 1.044x | 1.028x | 1.016x | 0.789x | 0.776x | 1.323x |
| requests | 1.080x | 1.040x | 1.038x | 0.458x | 0.444x | 2.360x |
| uvicorn | 1.066x | 1.026x | 1.039x | 0.624x | 0.598x | 1.709x |
| execa | 1.144x | 1.108x | 1.032x | 0.540x | 0.535x | 2.120x |
| body-parser | 1.100x | 1.080x | 1.019x | 0.399x | 0.397x | 2.760x |
| cookie-parser | 0.978x | 0.933x | 1.048x | 0.389x | 0.378x | 2.511x |
| koa | 1.069x | 1.034x | 1.033x | 0.411x | 0.403x | 2.603x |
| fastify | 1.082x | 1.090x | 0.993x | 0.285x | 0.285x | 3.801x |
| axios | 1.133x | 1.102x | 1.028x | 0.449x | 0.443x | 2.523x |
| express | 1.125x | 1.100x | 1.023x | 0.452x | 0.449x | 2.487x |
| undici | 1.108x | 1.090x | 1.016x | 0.555x | 0.549x | 1.994x |
| sasy-javascript-reachable-xl | - | - | - | - | - | - |
| **geomean (both finished)** | **1.067x** (19) | **1.038x** (19) | **1.028x** (19) | **0.505x** (19) | **0.497x** (19) | **2.113x** (19) |

- old-nosip  /  newfix: CSE and other main changes, SIP off in both
- mid-nosip  /  newfix: mid -> main, SIP off in both
- old-nosip  /  mid-nosip: old -> mid, SIP off in both
- old-nosip  /  old-sip: SIP on the old release
- mid-nosip  /  mid-sip: SIP on the mid release
- old-sip  /  newfix: upgrade: Sasty's shipped build -> main (SIP removed)

#### Parity of the seven public relations vs Souffle interpreted (sorted lines, SHA-256)

Where interpreted Souffle did not finish, the cell names the reference used instead.

| case | souffle-c | old-sip | old-nosip | mid-sip | mid-nosip | newfix |
|---|---|---|---|---|---|---|
| sasy-python-off | exact | exact | exact | exact | exact | exact |
| sasy-javascript-off | exact vs newfix | n/a | n/a | n/a | n/a | exact vs souffle-c |
| starlette | exact | exact | exact | exact | exact | exact |
| werkzeug | exact | exact | exact | exact | exact | exact |
| itsdangerous | exact | exact | exact | exact | exact | exact |
| httpx | exact | exact | exact | exact | exact | exact |
| fastapi | exact | exact | exact | exact | exact | exact |
| aiohttp | exact | exact | exact | exact | exact | exact |
| flask | exact | exact | exact | exact | exact | exact |
| django | exact | exact | exact | exact | exact | exact |
| requests | exact | exact | exact | exact | exact | exact |
| uvicorn | exact | exact | exact | exact | exact | exact |
| execa | exact | exact | exact | exact | exact | exact |
| body-parser | exact | exact | exact | exact | exact | exact |
| cookie-parser | exact | exact | exact | exact | exact | exact |
| koa | exact | exact | exact | exact | exact | exact |
| fastify | exact | exact | exact | exact | exact | exact |
| axios | exact | exact | exact | exact | exact | exact |
| express | exact | exact | exact | exact | exact | exact |
| undici | exact | exact | exact | exact | exact | exact |
| sasy-javascript-reachable-xl | n/a | n/a | n/a | n/a | n/a | no reference finished |

#### Peak RSS (MiB, median) and CPU utilisation ((user+sys)/wall)

| case | souffle RSS | souffle-c RSS | old-sip RSS | old-nosip RSS | mid-sip RSS | mid-nosip RSS | newfix RSS | souffle cpu | souffle-c cpu | old-sip cpu | old-nosip cpu | mid-sip cpu | mid-nosip cpu | newfix cpu |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| sasy-python-off | 1490 | 766 | 3594 | 2471 | 3602 | 2482 | 2466 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| sasy-javascript-off | >=81609 | 51800 | - | - | - | - | 127757 | - | 1.00 | - | - | - | - | 1.00 |
| starlette | 576 | 421 | 1829 | 1248 | 1774 | 1268 | 1236 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| werkzeug | 126 | 106 | 495 | 286 | 484 | 291 | 270 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| itsdangerous | 84 | 57 | 462 | 256 | 453 | 249 | 236 | 1.00 | 0.97 | 1.01 | 1.00 | 1.00 | 1.00 | 1.00 |
| httpx | 106 | 83 | 487 | 278 | 479 | 273 | 258 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 0.99 | 1.00 |
| fastapi | 210 | 183 | 713 | 848 | 715 | 853 | 844 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| aiohttp | 253 | 232 | 707 | 499 | 707 | 493 | 485 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| flask | 96 | 74 | 488 | 270 | 471 | 269 | 252 | 1.00 | 0.99 | 1.00 | 1.00 | 1.00 | 1.00 | 1.01 |
| django | 1402 | 1334 | 2599 | 4405 | 2582 | 4231 | 3815 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| requests | 91 | 68 | 481 | 262 | 468 | 285 | 246 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| uvicorn | 107 | 85 | 486 | 276 | 475 | 282 | 260 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| execa | 178 | 154 | 537 | 315 | 536 | 309 | 288 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| body-parser | 79 | 53 | 415 | 210 | 412 | 208 | 200 | 0.99 | 0.98 | 1.00 | 1.00 | 1.00 | 1.00 | 1.02 |
| cookie-parser | 75 | 47 | 407 | 202 | 404 | 202 | 192 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 0.98 | 1.00 |
| koa | 81 | 56 | 418 | 215 | 416 | 215 | 204 | 1.00 | 0.99 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| fastify | 577 | 503 | 2036 | 1118 | 2028 | 1109 | 1108 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| axios | 128 | 107 | 507 | 290 | 511 | 287 | 268 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| express | 106 | 82 | 459 | 246 | 456 | 252 | 228 | 1.00 | 0.99 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| undici | 455 | 434 | 902 | 665 | 916 | 670 | 602 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| sasy-javascript-reachable-xl | >=74835 | >=55051 | - | - | - | - | 143330 | - | - | - | - | - | - | 1.00 |

FlowLog runs with any stderr output (would fail Sasty's reject_stderr path): none

### Original policy (superseded)

<details>
<summary><strong>Engine-only results with Sasty's unmodified rule #337</strong></summary>

These were the first published results. They used the campaign protocol: one warm-up plus
5/3/1/0 measured runs depending on the warm-up wall time, and a 250 GB RSS cap.

Median wall seconds of the measured reps (n = measured reps after one warm-up; n=0 means the warm-up alone was the measurement). Souffle = production interpreter; Souffle-c = compiled `souffle -o` binary of the same taint.dl. * = longer than Sasty's default 900 s stage timeout (the production scan would fail closed); DNF/MEM = killed by the 7,200 s timeout or the 250 GB RSS cap; ALLOC = the evaluator aborted with `memory allocation of ... failed` (peak RSS@time).

| case | fact rows | MiB | souffle | souffle-c | old-sip | old-nosip | mid-sip | mid-nosip | newfix | n |
|---|---|---|---|---|---|---|---|---|---|---|
| sasy-python-off | 2,730,964 | 227 | 102.00 | 64.71 | 55.48 | 141.69 | 55.11 | 139.08 | 137.49 | 3/3/5/3/5/3/3 |
| sasy-javascript-off | 6,681,913 | 524 | DNF>7201s | 6271.00 * | DNF>7200s | 5271.00 * | DNF>7200s | 5272.00 * | 5245.00 * | -/0/-/0/-/0/0 |
| starlette | 503,832 | 35 | 15.15 | 8.61 | 20.90 | 10.82 | 20.93 | 10.55 | 10.92 | 5/5/5/5/5/5/5 |
| werkzeug | 579,462 | 38 | 8.46 | 5.37 | 4.66 | 6.97 | 4.58 | 6.77 | 6.68 | 5/5/5/5/5/5/5 |
| itsdangerous | 264,222 | 24 | 1.33 | 0.38 | 1.22 | 0.56 | 1.16 | 0.53 | 0.50 | 5/5/5/5/5/5/5 |
| httpx | 419,796 | 30 | 4.94 | 3.02 | 3.09 | 2.17 | 3.02 | 2.11 | 2.03 | 5/5/5/5/5/5/5 |
| fastapi | 1,181,935 | 81 | 22.99 | 12.96 | 9.47 | 9.55 | 9.35 | 9.42 | 9.23 | 5/5/5/5/5/5/5 |
| aiohttp | 1,368,261 | 78 | 43.61 | 32.19 | 12.15 | 44.59 | 12.00 | 43.34 | 43.22 | 5/5/5/5/5/5/5 |
| flask | 398,762 | 29 | 2.88 | 1.57 | 2.33 | 1.50 | 2.25 | 1.44 | 1.39 | 5/5/5/5/5/5/5 |
| django | 6,166,453 | 366 | 2096.92 * | 1653.10 * | 61.79 | ALLOC 172G@125s | 62.03 | ALLOC 172G@123s | ALLOC 172G@122s | 0/0/3/-/3/-/- |
| requests | 359,385 | 28 | 2.41 | 1.14 | 2.41 | 1.33 | 2.36 | 1.28 | 1.23 | 5/5/5/5/5/5/5 |
| uvicorn | 447,845 | 33 | 4.82 | 3.05 | 2.65 | 4.59 | 2.59 | 4.46 | 4.41 | 5/5/5/5/5/5/5 |
| execa | 867,857 | 51 | 4.55 | 3.32 | 3.54 | 1.90 | 3.49 | 1.86 | 1.65 | 5/5/5/5/5/5/5 |
| body-parser | 302,255 | 25 | 1.48 | 0.51 | 1.43 | 0.56 | 1.39 | 0.53 | 0.50 | 5/5/5/5/5/5/5 |
| cookie-parser | 254,952 | 23 | 1.25 | 0.31 | 1.17 | 0.45 | 1.13 | 0.43 | 0.40 | 5/5/5/5/5/5/5 |
| koa | 336,090 | 27 | 1.73 | 0.78 | 1.55 | 0.71 | 1.52 | 0.69 | 0.64 | 5/5/5/5/5/5/5 |
| fastify | 1,188,147 | 66 | 28.37 | 21.17 | 29.31 | 8.77 | 29.23 | 8.72 | 8.18 | 5/5/5/5/5/5/5 |
| axios | 674,500 | 46 | 5.92 | 5.10 | 3.22 | 2.88 | 3.18 | 2.80 | 2.67 | 5/5/5/5/5/5/5 |
| express | 504,320 | 34 | 2.42 | 1.47 | 2.03 | 0.90 | 2.27 | 0.88 | 0.80 | 5/5/5/5/5/5/5 |
| undici | 1,797,035 | 95 | 30.88 | 27.53 | 10.49 | 30.81 | 10.36 | 29.99 | 29.65 | 5/5/5/5/5/5/5 |
| sasy-javascript-reachable-xl | 10,028,546 | 821 | DNF>7201s | DNF>7200s | - | - | - | - | DNF>7200s | -/-/-/-/-/-/- |

| evaluator | vs Souffle interpreted: geomean | wins | range | vs Souffle compiled: geomean | wins | range |
|---|---|---|---|---|---|---|
| old-sip | 1.713x | 16/19 | 0.725-33.936x | 0.972x | 8/19 | 0.265-26.754x |
| old-nosip | 1.810x | 16/18 | 0.720-3.235x | 1.017x | 9/19 | 0.457-2.414x |
| mid-sip | 1.732x | 17/19 | 0.724-33.805x | 0.983x | 8/19 | 0.274-26.650x |
| mid-nosip | 1.866x | 17/18 | 0.733-3.253x | 1.046x | 9/19 | 0.465-2.428x |
| newfix | 1.944x | 17/18 | 0.742-3.468x | 1.088x | 10/19 | 0.471-2.588x |

- django without SIP: old-nosip, mid-nosip and newfix each aborted at about 122 s with an
  identical 172 GiB peak while 242 GiB was still available. The cause is an allocator ceiling
  in mimalloc v3.3.2 (section 7 item 7); even with that ceiling removed, the no-SIP plan needed
  more than 240 GiB.
- SIP builds on JS-off: old-sip and mid-sip both hit the 7,200 s timeout at a 158 GiB peak,
  while the no-SIP builds finished in about 5,270 s.
- Older releases on JS-XL: old-nosip reached 152 GiB after 23 min and was stopped by hand, so
  only Souffle, Souffle-c and newfix ran on JS-XL. All three hit the 7,200 s timeout.
- newfix peak RSS: 20.1 GiB on python-off, 9.0 GiB on aiohttp and 6.8 GiB on undici, where
  compiled Souffle used 0.75, 0.23 and 0.42 GiB.
- Parity was exact on every finished run.

</details>

## 5. SAST end-to-end (Sasty's standard protocol)

Sasty's standard protocol, `sasty scan` with production limits and the default 900 s
stage timeout. Each run includes fact extraction and model loading, and each engine's
public CSVs are byte-compared with Souffle's from the same iteration. Iterations are one
warm-up plus five for `sasy-python-off`, and a single iteration elsewhere.

With both reachable-dependency modes, the production scan **fails closed before any engine
runs**, whichever engine is selected:
- Python: the dependency source exceeds `--dependency-byte-limit-mib=64`;
- JavaScript: `typescript.js` is larger than the hard-coded 4 MiB import-planning limit.

The engine is therefore irrelevant for those scans today.

**Policy.** The `sasy-python-off` rows use the reordered rule #337 (section 4), with every
evaluator rebuilt from that policy. Their public CSVs are byte-identical to the
original-policy scan's. With the original policy, python-off took 145.0 s with Souffle, 97.2 s
with old-sip and 179.7 s with newfix (20 GiB). The JS-off and reachable rows were measured with
the original policy and not rerun: the reachable scans fail before any engine runs, and JS-off's
engine-only time with the reordered rule (at least 4,894 s) still far exceeds the 900 s stage
bound. The python-off rerun shared the host with engine-only timing jobs on the other three L3
domains.

**JS-off (first-party JavaScript only) hits the 900 s stage timeout with every engine.**
Souffle, old-sip and newfix all exit with rc=124 after about 923 s (23 s of extraction plus
900 s of analysis). At the kill their RSS was 20, 32 and 60 GB. Section 4 shows how long the engines
actually need without a bound. One committed generated file,
`packages/sasty/src/sasty/resources/extract_js.bundle.js` (Sasty's own 3.5 MiB minified bun
bundle), supplies half of JS-off's expression facts (638K of 1.26M `SrcExpr` rows, across 646
files). It also supplies 64% of `SrcFlow` and 68% of `SrcAlias`. That file sits just under
the 4 MiB per-file limit that stops JS-reachable.
These e2e runs shared the host with the engine-only JS-XL jobs on the other three L3 domains.

Sasty's benchmark README positions FlowLog as the fallback "for a corpus where Souffle does
not complete within the reviewed stage bound". The * marks in section 4 show which inputs exceed
that 900 s bound.

| case | engine | runs ok | median wall s (reps) | min-max s | peak RSS MiB | Souffle  /  engine (>1 = faster) | public tables vs Souffle | failure |
|---|---|---|---|---|---|---|---|---|
| sasy-javascript-off | souffle | 0/1 | failed (rc=[124]) | - | 20437 | - | - | Souffle analysis timed out after 900s |
| sasy-javascript-off | old-sip | 0/1 | failed (rc=[124]) | - | 31920 | - | - | Flowlog analysis timed out after 900s |
| sasy-javascript-off | newfix | 0/1 | failed (rc=[124]) | - | 59423 | - | - | Flowlog analysis timed out after 900s |
| sasy-javascript-reachable | souffle | 0/1 | failed (rc=[2]) | - | 2576 | - | - | dependency discovery failed: JavaScript dependency import planning refuses a source file larger than 4 MiB: .../typescript.js |
| sasy-javascript-reachable | old-sip | 0/1 | failed (rc=[2]) | - | 1331 | - | - | dependency discovery failed: JavaScript dependency import planning refuses a source file larger than 4 MiB: .../typescript.js |
| sasy-javascript-reachable | newfix | 0/1 | failed (rc=[2]) | - | 2048 | - | - | dependency discovery failed: JavaScript dependency import planning refuses a source file larger than 4 MiB: .../typescript.js |
| sasy-python-off | souffle | 6/6 | 113.9 (5) | 112.7-115.6 | 1489 | - | reference | - |
| sasy-python-off | old-sip | 6/6 | 99.1 (5) | 98.7-102.0 | 3635 | 1.150x | exact | - |
| sasy-python-off | newfix | 6/6 | 79.0 (5) | 78.2-79.3 | 2469 | 1.442x | exact | - |
| sasy-python-reachable | souffle | 0/1 | failed (rc=[2]) | - | 164 | - | - | dependency discovery failed: dependency source exceeds --dependency-byte-limit-mib=64 (64.0 MiB selected) |
| sasy-python-reachable | old-sip | 0/1 | failed (rc=[2]) | - | 164 | - | - | dependency discovery failed: dependency source exceeds --dependency-byte-limit-mib=64 (64.0 MiB selected) |
| sasy-python-reachable | newfix | 0/1 | failed (rc=[2]) | - | 164 | - | - | dependency discovery failed: dependency source exceeds --dependency-byte-limit-mib=64 (64.0 MiB selected) |

## 6. SAST incremental: six real SASY commits

#### sast-commits: six real SASY commits (638 Python files), incremental replay

FlowLog columns: median commit seconds over 5 replays (single worker). Souffle columns: median from-scratch seconds over 5 runs after a warm-up, on the same step's facts (interpreted = the shipping runner's command).

| step | unique facts | inserted | removed | FlowLog old | FlowLog mid | FlowLog newfix | Souffle interp | Souffle compiled | interp  /  newfix | compiled  /  newfix | findings |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 1,157,603 | 1,135,219 | 0 | 5.360 | 5.383 | 5.167 | 8.49 | 6.29 | 1.6x | 1.2x | 203 |
| 1 | 1,159,755 | 23,845 | 21,736 | 1.339 | 1.325 | 1.304 | 8.42 | 6.34 | 6.5x | 4.9x | 205 |
| 2 | 1,171,372 | 60,980 | 49,586 | 1.677 | 1.678 | 1.619 | 8.44 | 6.52 | 5.2x | 4.0x | 212 |
| 3 | 1,177,683 | 47,476 | 41,239 | 1.421 | 1.416 | 1.398 | 8.65 | 6.39 | 6.2x | 4.6x | 232 |
| 4 | 1,185,826 | 63,717 | 55,700 | 1.619 | 1.611 | 1.561 | 8.59 | 6.41 | 5.5x | 4.1x | 239 |
| 5 | 1,185,862 | 24,404 | 24,369 | 1.299 | 1.292 | 1.261 | 8.64 | 6.41 | 6.9x | 5.1x | 239 |

| engine | process wall (median) | peak RSS MiB (median) | parity |
|---|---|---|---|
| FlowLog 6c111b7 (build 0.4.0 / runtime 0.3.0) | 21.13s for all 6 steps incl. fact loading | 1760 | 5/5 outputs exact at 6/6 steps |
| FlowLog fed4211 (build 0.5.0 / runtime 0.4.0) | 21.03s for all 6 steps incl. fact loading | 1765 | 5/5 outputs exact at 6/6 steps |
| FlowLog main 07ffd67 + fuse guard (build 0.6.0 / runtime 0.5.0) | 20.63s for all 6 steps incl. fact loading | 1710 | 5/5 outputs exact at 6/6 steps |
| Souffle interpreted | 8.42-8.65s per step (from scratch) | 209 | 36/36 runs match the runner's CSVs |
| Souffle compiled | 6.29-6.52s per step (from scratch) | 200 | 36/36 runs match the runner's CSVs |

Steady-state commit (steps 1-5, mean of medians): old 1.471s, mid 1.464s, newfix 1.429s
newfix vs old: 1.030x (steps 1-5); step 0 1.037x

## 7. FlowLog build and compatibility findings (Sasty and the SASY harnesses)

1. **Planner ICE on Sasty's policy with main.** The error is
   `update_const_eq_and_var_eq_constraints: only applicable to unary (KVToKV) transformations`,
   from `fuse.rs`.
   - Bisected to FlowLog **#368** (`643ac37`, "fold semijoins once and push original filters
     down the plan", Sep 20). The CSE commits #373-#377 are not the cause.
   - The local guard `c8af77a` skips fusion of a map that has const/var-eq predicates and a
     non-KVToKV producer. It changes **exactly 1 map** in the policy, and all outputs stay exact.
   - This needs an upstream fix.
2. **Reserved words.** FlowLog #361 (Sep 16) reserves bare `as`, `fn`, `overridable`, `True`
   and `False`.
   - Sasty's `taint.dl` has 122 `fn` occurrences, and SASY's copilot-security, security and
     policy-skill policies (and their `_fwd` forms) plus `taint_flowlog.dl` also use `fn`.
   - None of these parse on main without an alpha-rename.
3. **SIP was removed on main** (#365, `691eb0d`).
   - Sasty's default FlowLog build arguments include `--sip`, so Sasty cannot build its engine
     against main unchanged.
   - The new release is therefore always measured without SIP. Section 4 shows the SIP effect
     separately (`old-nosip  /  old-sip`, `mid-nosip  /  mid-sip`). With the reordered rule
     #337, SIP is slower on every input (no-SIP time is 0.50x SIP time, geomean); with the
     original rule it was worth 2.5-3.7x on aiohttp, undici and python-off.
4. **API renames** (`DatalogInc` -> `Inc`, `IncrementalEngine`) required harness edits on mid
   and new.
5. **Evaluator build cost** (Sasty, single policy):

   | build | time | binary size |
   |---|---|---|
   | noSIP | 503-585 s | 304-353 MB |
   | SIP | 2,229-2,573 s | 769-855 MB |

   One old-SIP build attempt died when the disk filled (ENOSPC); that was the host, not FlowLog.
   The rebuilds from the reordered policy took 596-658 s (noSIP) and 2,162-2,231 s (SIP), with
   the same binary sizes.
6. **Silent bad input.** Upstream FlowLog loads missing or malformed fact files as empty,
   printing a stderr diagnostic. Sasty's build smoke test therefore cannot pass on these
   builds, so it ran in report-only mode (`SASTY_BENCH_SMOKE_REPORT_ONLY=1`). At scan time,
   Sasty's `reject_stderr` path still rejects any FlowLog stderr output.
7. **Allocator ceiling at about 172 GiB (all three releases, original policy).** The generated
   evaluators use `mimalloc = "0.1"` as the global allocator. The newest crates (mimalloc 0.1.52,
   libmimalloc-sys 0.1.49, May 22) bundle **mimalloc v3.3.2** by default.
   - Diagnosis (newfix on django, `MIMALLOC_VERBOSE=1`, `diag_maps.py`):
     - v3.3.2 reserved 8 arenas each of 1, 2, 4 and 8 GiB.
     - Every 16 GiB reservation was then rejected: "too large with respect to the maximum
       object size (meta-info slices 521 > 512)". It fell back to 97 x 128 MiB and
       28 x 1 GiB arenas, for 157 arenas and about 160 GiB. At that point `mi_arena_reserve`
       stops for good (`arena_count > MI_MAX_ARENAS - 4`, where `MI_MAX_ARENAS` = 160).
     - After that, every allocation mapped OS memory directly. The mapping count was below
       200 up to 102 s (159 GiB RSS), then reached the host's `vm.max_map_count` (65,530)
       at 109 s.
     - The process aborted at 122 s: "memory allocation of 8192 bytes failed", SIGABRT
       (rc=134), 172 GiB peak RSS, with **242 GiB still available**.
   - This is upstream mimalloc issue **#1309**. It is fixed by `566fbc1f` (Jun 18), with the
     follow-up #1326 for pages >= 4 GiB. Both fixes are in mimalloc v3.4.0 and later, but no
     Rust crate release ships them yet.
   - Workarounds:
     - **Tested here:** `MIMALLOC_ARENA_RESERVE=1792MiB` capped arenas at 14 GiB. The
       mapping count stayed at or below 180 through 240 GiB.
     - **Not tested here:**
       - the crate's `v2` feature, which bundles mimalloc 2.3.2 (the upstream report says
         2.3.2 is unaffected);
       - raising `vm.max_map_count` (this is a shared host).
   - The workaround does not rescue django without SIP. Its memory kept growing at about
     1.65 GiB/s, and the run was stopped at a 240 GiB diagnostic cap after 147 s. With SIP,
     the same input needs 2.5 GiB and finishes in 62 s.
   - On JS-off, old-sip and mid-sip were at 158 GiB when the timeout killed them. That is
     within about 2 GiB of the RSS at which django's runs fell back to per-page mappings.
   - With the reordered rule #337, newfix finishes django in 44 s at 3.7 GiB. Its largest
     peaks, 125 GiB on JS-off and 140 GiB on JS-XL, stay below the point where arena
     reservation stops (about 160 GiB).

## 8. Deviations, substitutions and blockers

- **Sasty policy.** Rule #337 of `taint.dl` has two body atoms swapped, for every engine, in
  all Sasty engine-only results and the python-off end-to-end rows (sections 4 and 5).
  Outputs are unchanged. The incremental replay's policy (section 6) has no such rule and is
  unmodified. The first published version of this report used the unmodified rule; its
  engine-only results are kept at the end of section 4.
- **Corpus pins.** `differential-corpora.yml` lists **18** corpora, not 20. Three pins do
  not exist on GitHub (HTTP 422), so each was replaced by the default-branch commit that
  shares its prefix at the YAML's commit time:

  | corpus | substitute commit |
  |---|---|
  | flask | `d318b683471` |
  | express | `023767fe987` |
  | django | `5babd2e21ac` |
- **Unparseable files allowed.**
  - undici: `--allow-unparseable 1`.
  - django: `--allow-unparseable 6`. Five files use Python 3.12 `type X =` under the 3.11
    extractor; the sixth is a deliberate syntax-error test.
- **JS-XL limits**, all beyond production:
  - dependency file limit 100,000;
  - dependency bytes 1,024 MiB;
  - dependency facts 4,096 MiB;
  - facts 8,192 MiB;
  - JS import limits 64 / 1,024 / 1,024 MiB.
- **Python-XL:** infeasible (more than 4 GiB of dependency facts); not measured.
- **Environment.**
  - SASY `uv sync` ran without `--frozen`, because the root `uv.lock` is absent.
  - Sasty ran from a Python 3.11 venv (`pip install -e packages/sasty`) with env-gated local
    patches: build-args override, report-only smoke test, and the `fn` rename.
- **Model sources** (the original revisions are not recorded):
  - codeql `ccaf9104f873`, pyre-check `d5614e0a75f5`, bandit `68ebe11ef792`;
  - Model.facts has 5,114 rows; the Pysa (4,210) and Bandit (95) counts match Sasty's README.
- **Forward rewrite** (FlowLog-only `*_fwd.dl` forms): these exist for 7 census workloads
  (section 1-2). Sasty's `taint.dl` has none, so the rewrite does not apply to SAST.
- **Census context.** The published census ran on a different VM of the same SKU, and its
  headline used a Souffle-forward arm that no longer exists; section 1 reproduces its shipped-only
  selection instead. Traces are generated, because real Claude traces are not in the repo.
- **Blocked:** Nils's private "Long SAST session" trace (FlowLog 3.17x p50) is not committed,
  so it could not be reproduced.
- **Publication boundary.** This appendix publishes aggregate measurements and findings only. Private source, extracted facts, generated evaluators, and multi-gigabyte run directories are not included.
