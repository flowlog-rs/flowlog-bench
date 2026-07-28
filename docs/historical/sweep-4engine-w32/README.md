# 4-engine sweep — final data (FlowLog vs Soufflé vs DDlog vs Ascent)

One CSV, 54 (program × dataset) pairs across the full oracle suite:
FlowLog compiler vs Soufflé 2.5 (compiled), DDlog 1.2.3, Ascent 0.8.
All engines at **WORKERS=32, NUM_RUNS=3 (median), 1800 s timeout/attempt**;
schema is `CSV_HEADER` in `scripts/cross_engine.sh` (times s, RSS MiB,
`*_vs_Compiler_Total` = engine_total / flowlog_total).

Provenance (two measurement dates merged):

- **Engine columns + non-doop/polonius FlowLog rows** — 2026-06-11 sweep
  (64-core / 503 GiB hosts; FlowLog `3b1387e18460`, doop block `a40ecbc60cda`).
- **FlowLog columns on the 24 doop + polonius_int rows** — re-measured
  2026-07-28 with released FlowLog `6c111b729e4b` (compiler 0.5.0: dd 0.25.1 /
  timely 0.31, opt-level 2 + panic=abort codegen) on CloudLab 2× EPYC 7543;
  `*_vs_Compiler_Total` recomputed against the new totals. The release was
  perf-neutral vs the sweep snapshots (geomean −2.4 % time, −3.8 % RSS;
  jython RSS −16 %), so old and new FlowLog rows are directly comparable.

Reading the gaps: `N/A` conflates cannot-run and timeout — DDlog has no
recursive-min, so `cc`/`sssp` are inexpressible, and it timed out on
`reach/arabic`, `bipartite/mag`, `doop/jython`. Correctness: at sweep time
every engine's output relation sizes were diffed against FlowLog — all
runnable pairs matched on all engines.

The full figures, per-phase configs, and the independent west2
reproduction (all 52 runnable pairs re-validated end-to-end) were trimmed
from the tree; they live in git history at commits `c594bdc`/`90a3563`.
