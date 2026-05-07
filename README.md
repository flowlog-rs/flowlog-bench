# flowlog-bench

Performance benchmarks for the [FlowLog](https://github.com/flowlog-rs/flowlog) Datalog engine. Compares FlowLog against other engines (Soufflé, flowlog interpreter) on a shared (program × dataset) corpus and emits results as CSV.

## Setup

Ubuntu only. ~50 GB free for the FlowLog build cache + dataset cache.

```bash
bash env.sh                    # basic deps + rustup only
bash env.sh --all              # + every comparison engine
bash env.sh souffle duckdb     # only the engines you need
bash env.sh --list             # see what's available
```

## Usage

Every workflow goes through `make`:

```bash
make cross-engine                          # FlowLog vs. comparison engines on the oracle suite
make cross-engine ENGINES=souffle,interpreter

FLOWLOG_REF=v0.5.0 make cross-engine       # bench a specific FlowLog commit
FLOWLOG_BASE=v0.5.0 FLOWLOG_HEAD=main \
    make cross-flowlog-version             # A/B between two FlowLog commits

make ldbc                                  # LDBC SNB timing / scaling
make plot                                  # render time + peak-RSS chart
make clean                                 # wipe results/ (keeps caches)
make help                                  # full target list
```

### Knobs

| Variable | Default | Effect |
| --- | --- | --- |
| `FLOWLOG_REF` | `main` | FlowLog branch / tag / SHA to fetch + build |
| `ENGINES` | `souffle` | comma list: `souffle`, `interpreter`, `none` |
| `CONFIG` | `config/default.txt` | which `<prog>=<dataset>` list to run |
| `LDBC_CONFIG` | `config/ldbc.txt` | config slot used by `make ldbc` |
| `WORKERS` | `min(64, nproc)` | thread count, applied identically to every engine |
| `NUM_RUNS` | `3` | timed runs per pair (median is kept) |
| `FLOWLOG_RUN_TIMEOUT` | `1800` | seconds before SIGTERM on one attempt |
| `KEEP_DATASETS` | `0` | delete each dataset after its pair runs (saves disk); set `1` to keep them across pairs (faster on resume) |

> **If `facts/` lives on a shared / remote filesystem, always set `KEEP_DATASETS=1`** — otherwise each dataset is deleted after its pair runs. (When `facts/` is a symlink the script refuses to `rm -rf` through it as a safety net, but a bind-mounted or NFS-mounted real directory has no such guard.)

Per-pair tags in the config file:

- `[interp:skip]` — skip the interpreter on this pair
- `[souffle:skip]` — skip Soufflé on this pair

### Output

Cross-engine writes to `results/benchmark/`:

- `comparison_results.csv` — per-engine timing, peak RSS, and speedups
  vs FlowLog; plus a FlowLog↔Soufflé correctness cross-check
- `<prog>_<dataset>_<engine>.log` — raw timing logs per pair
- `run_info.txt` — reproducibility manifest (resume key)

Console summary at end of run:

```
| Program-Dataset    | Engine      |     Total (s) | Peak RSS (MB) | vs Compiler |
| tc_G5K-0.001       | compiler    |      1.486636 |       1400.82 |       1.00x |
|                    | interpreter |      1.435592 |       2524.06 |       0.97x |
|                    | souffle     |      6.133969 |       1123.93 |       4.13x |
```

`make plot` renders `comparison_results.{pdf,svg}` next to the CSV.

### Resume vs. fresh

Re-running with the **same** parameters skips pairs already in the CSV.
Re-running with **different** parameters (different `ENGINES`,
`FLOWLOG_REF`, `WORKERS`, …) hard-fails with a diff. To start over:

```bash
bash scripts/cross_engine.sh --fresh    # wipes results/benchmark/
make clean                              # wipes all of results/
```
