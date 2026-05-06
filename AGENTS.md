# AGENTS.md — flowlog-bench

> Sibling spec to [`flowlog-rs/flowlog/AGENTS.md`](https://github.com/flowlog-rs/flowlog/blob/main/AGENTS.md).
> The flowlog repo is **correctness-only**; this repo is **performance + cross-engine**.

This file is the agent contract for `flowlog-rs/flowlog-bench`. Read it before
making any change. Section anchors mirror the parent spec.

---

## Why two repos?

The parent spec ([`flowlog/AGENTS.md`](https://github.com/flowlog-rs/flowlog/blob/main/AGENTS.md))
split the project so that correctness signals are cheap to run on every
PR and perf signals can take as long as they need with their own deps
and dataset cache.

| Stage           | Repo             | Output                                    |
| --------------- | ---------------- | ----------------------------------------- |
| Build + correct | `flowlog`        | binary + `make test` green                |
| Perf measure    | `flowlog-bench`  | timing CSVs, speedup plots, regressions   |

A change is shippable when **flowlog**'s tests pass. Perf signoff is a separate
gate owned by **this repo**.

---

## Design principles (mirrors [`flowlog/AGENTS.md`](https://github.com/flowlog-rs/flowlog/blob/main/AGENTS.md))

1. **Flowlog is a fetched input, not a fork.** This repo never patches engine
   code; if it needs an engine change, that's a PR against `flowlog-rs/flowlog`
   first. We pull flowlog source via `tools/get_flowlog.sh` and build it.
2. **Any commit is benchable, by design.** Every script accepts a flowlog
   ref (env var or flag). No bench-repo commit is required to switch which
   flowlog version you're measuring. Default is `main`; explicit refs win.
3. **Programs / facts / scripts / outputs are physically separated.**
   - `programs/` — rule corpus (in git, dialect-split: `flowlog/`, `souffle/`, `duckdb/`)
   - `facts/`   — dataset cache (gitignored, populated by external data handler)
   - `scripts/` — code (bash + python helpers)
   - `results/` — gitignored output (CSVs, plots, raw timing)

   They never overlap; scripts only read from `programs/` + `facts/` and only
   write to `results/`.
4. **One Make target per task, no full-sweep orchestrator.** `make bench-one
   PROG=…`, `make cross-engine`, `make regression`, `make ldbc`, `make plot`.
   Each script already iterates over its (program × dataset) pairs internally.
5. **Comparisons are pluggable.** Adding another engine (DuckDB beyond LDBC,
   etc.) is a new file under `scripts/`, not a rewrite of `cross_engine.sh`.
6. **Reproducibility over cleverness.** Every per-run output directory under
   `results/` ships a `run_info.txt` sidecar via `scripts/lib/run_info.sh`.
   The manifest records the flowlog commit (resolved to a full SHA via the
   fallback chain `FLOWLOG_RESOLVED_SHA` → `git rev-parse` of `FLOWLOG_SRC_DIR`
   → `flowlog/<short>/…` cache-path match → `unknown`), the bench-repo corpus
   sha + dirty flag, config file path + sha256, host, OS, worker count,
   num-runs, runner-specific knobs (baselines, target filter, tolerances, A/B
   refs, …), and a UTC timestamp. The CSV/TSV is the data; the sidecar is the
   provenance.

   **Resume safety is enforced.** Before `cross_engine.sh` re-uses an existing
   `results/benchmark/` dir, it rebuilds the would-be-current manifest, diffs
   it against the on-disk one, and hard-fails on any mismatch (different
   workers, baseline list, flowlog SHA, config file, etc.). Mixed-parameter
   rows in a single CSV would otherwise be a silent footgun. Pass `--fresh`
   to start over.
7. **Bench env is heavier than test env, and that's fine.** Soufflé, DuckDB,
   GNU time, larger dataset caches all live with this repo's `tools/env/`.
   The flowlog repo's env stays minimal.
8. **No `env_check.sh`.** If a script needs deps, it fails loudly at the first
   call. Bench scripts are run by humans/CI, not by agents — they don't need
   the doctor pattern that flowlog's correctness loop uses.

---

## Repo layout

```
flowlog-bench/
├── README.md              — purpose, quickstart
├── AGENTS.md              — this file
├── Makefile               — single source of entry points (task targets + housekeeping)
├── tools/
│   ├── get_flowlog.sh     — fetch + build flowlog at FLOWLOG_REF
│   └── env/               — one-time machine bootstrap (env.sh, env.ps1)
├── flowlog/               — gitignored; populated by get_flowlog.sh.
│   ├── .mirror/           — bare clone (resolves any ref cheaply)
│   └── <short_sha>/       — built tree per ref
│       ├── src/           — git worktree at <full_sha>
│       └── target/release/flowlog-compiler
├── scripts/               — how to run one program / one comparison
│   ├── bench_one.sh       — primitive: one program × one dataset × one engine
│   ├── cross_engine.sh    — flowlog vs. {soufflé, interpreter, …} at one ref
│   ├── regression.sh      — flowlog@base vs. flowlog@head (A/B over commits)
│   ├── ldbc.sh            — LDBC timing / scaling
│   ├── engines/           — one comparison-engine adapter per file
│   │   ├── compiler.sh    — flowlog-compiler → standalone C++-equivalent binary
│   │   ├── libmode.sh     — flowlog library mode (per-pair Cargo build)
│   │   ├── interpreter.sh — vldb26-artifact interpreter
│   │   └── souffle.sh     — Soufflé (compile-once cache, libgomp check)
│   └── lib/               — engine-neutral shared helpers
│       ├── common.sh      — colors, trim, flowlog_truthy, cache-safety guard
│       ├── measure.sh     — /usr/bin/time wrap, extractors, median, sidecar writer
│       ├── datasets.sh    — dataset cache (zip + tar.zst download/extract)
│       ├── run_info.sh    — reproducibility manifest helpers
│       ├── runner.sh      — lib-mode runner crate synthesis
│       └── synth_common.sh — DL-syntax helpers (vendored from flowlog)
├── programs/              — programs only (in git). Grouped by suite, then dialect.
│   ├── micro/             — single-program micro-benchmarks
│   │   ├── flowlog/       — graph_analysis/, knowledge_reasoning/, program_analysis/
│   │   └── souffle/       — Soufflé equivalents (flat by program name)
│   └── ldbc/              — LDBC SNB suite (queries × scale-factors)
│       ├── flowlog/       — interactive-complex-*.dl
│       └── duckdb/        — interactive-complex-*.sql
├── facts/                 — gitignored; populated by data handler (mirrors
│                            programs/ at suite level, dialect-agnostic)
├── plotting/              — plot_speedup.py + render_perf_*.py (history)
├── config/
│   ├── default.txt        — micro suite (program × dataset pairs)
│   └── ldbc.txt           — LDBC suite (query × dataset pairs)
├── docs/historical/       — frozen perf snapshots from before the split
└── results/               — gitignored; per-run dirs, each with run_info.txt + CSV/TSV
    ├── benchmark/         — cross_engine.sh: comparison_results.csv + run_info.txt + per-pair logs
    ├── regression/        — regression.sh: <base_short>_vs_<head_short>/{summary.tsv, run_info.txt}
    └── ldbc/              — ldbc.sh: <UTC_timestamp>-<pid>/{summary.csv, run_info.txt, work/}
```

### Note on the `programs/ldbc/duckdb/` slot

The parent spec ([`flowlog/AGENTS.md`](https://github.com/flowlog-rs/flowlog/blob/main/AGENTS.md))
prescribes
`programs/ldbc/{flowlog,souffle}/`. We use `duckdb/` instead because the
historical LDBC pipeline cross-validates flowlog against DuckDB, not Soufflé.
Per principle 5 (comparisons are pluggable), the slot is "engine of comparison"
— DuckDB fits cleanly. A future Soufflé LDBC corpus would sit alongside as
`programs/ldbc/souffle/`.

---

## Specifying which flowlog commit to bench

This repo treats flowlog as a **fetched, built input**, not a submodule.
A perf repo routinely benches arbitrary commits (regression bisects, A/B over
a feature branch, comparing main against a release tag), and a submodule's
gitlink would force a bench-repo commit per attempt. A fetch script is one
arg.

Standard call shape:

```bash
# Bench main:
make cross-engine

# Bench a specific commit:
FLOWLOG_REF=abc1234 make cross-engine

# A/B over two commits (regression.sh fetches both):
FLOWLOG_BASE=abc1234 FLOWLOG_HEAD=def5678 make regression
```

Each cached build lives at `flowlog/<short_sha>/`, so re-running the same ref
is free. `tools/get_flowlog.sh` is idempotent: if the ref is already built, it
no-ops.

---

## Agent contract (what changes here look like)

1. **Don't patch engine code from this repo.** If you need a flowlog change,
   send a PR to `flowlog-rs/flowlog` first; this repo will pick it up via
   `FLOWLOG_REF` once merged.
2. **Adding a benchmark program** = add the same program in every dialect
   directory under `programs/<suite>/`, then add the `<prog>=<dataset>` line
   to the relevant `config/*.txt`. No script change required.
3. **Adding a benchmark suite** (e.g. tpc-h) = a new sibling under `programs/`
   + a new `scripts/<suite>.sh` runner + a new `config/<suite>.txt` + a new
   Makefile target. Don't fold it into an existing runner.
4. **Adding a comparison engine** = a new file under `scripts/engines/`, not
   a rewrite of `cross_engine.sh`. Each engine exposes
   `engine_<name>_setup` (optional) + `engine_<name>_run "$prog" "$dataset"`,
   uses the shared `lib/measure.sh` helpers for timing / RSS / sidecar
   writes, and is sourced from `cross_engine.sh`. Adding columns to the
   CSV is a separate step in `cross_engine.sh::CSV_HEADER` /
   `append_csv_row`. See `scripts/lib/README.md` for the contract.
5. **Adding a result column** = update both the CSV writer in
   `cross_engine.sh` (or `regression.sh`) and any downstream plot in
   `plotting/`. The reproducibility principle (6) means the column header
   alone doesn't carry meaning — units + provenance must be obvious from the
   header text or from `docs/`.
6. **Don't add a "run everything" wrapper here.** If you need to chain
   targets, do it in your CI / agent / Makefile target on the *consumer*
   side (or a one-off shell loop).

---

## File-by-file lineage from the split

For provenance, each file in this repo was lifted from
`flowlog-rs/flowlog@pre-bench-split` (commit `72e5f4f`, the last commit before
the perf surface was deleted from flowlog). The mapping:

| `flowlog@pre-bench-split` source         | This repo                          |
| ---------------------------------------- | ---------------------------------- |
| `tools/benchmark/bench_one.sh`           | `scripts/bench_one.sh`             |
| `tools/benchmark/compare.sh`             | `scripts/cross_engine.sh`          |
| `tools/benchmark/lib_runner.sh`          | `scripts/lib/runner.sh`            |
| `tools/perf_compare.sh`                  | `scripts/regression.sh`            |
| `tests/ldbc/ldbc.sh`                     | `scripts/ldbc.sh`                  |
| `tools/benchmark/config.txt`             | `config/default.txt`               |
| `tests/ldbc/config.txt`                  | `config/ldbc.txt`                  |
| `tools/benchmark/plot_speedup.py`        | `plotting/plot_speedup.py`         |
| `docs/render_perf_*.py`                  | `plotting/render_perf_*.py`        |
| `tools/benchmark/souffle-programs/*.dl`  | `programs/micro/souffle/*.dl`      |
| `example/{graph,knowledge,program}_*/*`  | `programs/micro/flowlog/<cat>/*`   |
| `example/ldbc_snb/flowlog/*.dl`          | `programs/ldbc/flowlog/*.dl`       |
| `example/ldbc_snb/duckdb/*.sql`          | `programs/ldbc/duckdb/*.sql`       |
| `docs/perf-*.{csv,svg}`                  | `docs/historical/`                 |

Path constants in the lifted scripts were retargeted to the new layout, with
env-var overrides preserved (`FLOWLOG_BIN`, `FLOWLOG_SRC_DIR`, `PROG_DIR`,
`SOUFFLE_PROG_DIR`, `DL_DIR`, `SQL_DIR`, `FACT_DIR`). The biggest behavioural
change: `regression.sh` now fetches both BASE and HEAD via
`tools/get_flowlog.sh` (was: in-tree git worktree of the active flowlog
checkout). This is what makes principle 2 ("any commit is benchable") work
from a perf repo that doesn't carry an engine source tree.

Post-split, the four `run_*` engine functions originally inside
`cross_engine.sh` were extracted into `scripts/engines/{compiler,
interpreter,libmode,souffle}.sh`, and the per-runner duplicated helpers
(RSS / wall-time extractors, median pickers, dataset download/extract)
were consolidated into `scripts/lib/measure.sh` and `scripts/lib/datasets.sh`.
See `scripts/lib/README.md`.
