# flowlog-bench

Performance benchmarks for the [FlowLog](https://github.com/flowlog-rs/flowlog)
Datalog engine. Sibling to the main repo, which is correctness-only;
this one carries the heavy deps (Soufflé, DuckDB, GNU time) and the
dataset cache.

## Quickstart

```bash
make env                                     # one-time host bootstrap
make cross-engine                            # FlowLog vs. Soufflé on the micro suite
make bench-one PROG=program_analysis/cspa.dl DATASET=cspa-httpd  # smallest signal

FLOWLOG_REF=v0.5.0 make cross-engine                              # bench a specific commit
FLOWLOG_BASE=v0.5.0 FLOWLOG_HEAD=main make regression             # A/B between commits
make ldbc                                                         # LDBC SNB sweep
make plot                                                         # render speedup chart
```

`flowlog/<short_sha>/`, `facts/`, and `results/` are gitignored.
`tools/get_flowlog.sh` populates the build cache lazily; re-running with
the same ref is a no-op.

## Architecture

Three layers; each `make` target invokes one orchestrator.

```
scripts/
├── bench_one.sh        ─┐  orchestrators
├── cross_engine.sh      │   - own argv parsing, the config-file loop,
├── regression.sh        │     CSV writing, and resume-safety;
├── ldbc.sh             ─┘   - source from engines/ + lib/ for the work.
│
├── engines/            ──── one file per comparison engine
│   ├── compiler.sh           (flowlog-compiler → standalone binary)
│   ├── libmode.sh            (flowlog embedded library API)
│   ├── interpreter.sh        (vldb26-artifact interpreter)
│   └── souffle.sh            (Soufflé compiled C++)
│   Each exposes engine_<name>_run "$prog" "$dataset", owns its own
│   N-runs loop, and writes the standard sidecar files.
│
└── lib/                ──── engine-neutral helpers
    ├── measure.sh            time_wrap, extractors, median_int, speedup_ratio
    ├── datasets.sh           download/extract/cleanup the dataset cache
    ├── runner.sh             FlowLog lib-mode runner crate synthesis
    ├── run_info.sh           reproducibility manifest (resume-safety)
    ├── common.sh             colors, trim, cache-safety guard
    └── synth_common.sh       DL-syntax helpers (vendored from FlowLog)
```

**Adding a new comparison engine** = drop a new file in `scripts/engines/`,
source it from `cross_engine.sh`, and add columns to `CSV_HEADER` /
`append_csv_row`. See [`scripts/lib/README.md`](./scripts/lib/README.md).

**Resume-safety.** Every CSV ships with a `run_info.txt` manifest. Re-running
with the same parameters skips already-benched pairs; re-running with
different parameters hard-fails with a diff. Pass `--fresh` to
`cross_engine.sh` (or `make clean`) to start over.

## Repo layout

| Path | What | In git? |
| --- | --- | --- |
| `Makefile` | one target per task | ✓ |
| `scripts/` | orchestrators + engines/ + lib/ (above) | ✓ |
| `programs/` | rule corpus, dialect-split (`flowlog/`, `souffle/`, `duckdb/`) | ✓ |
| `config/` | `<prog>=<dataset>` lists | ✓ |
| `plotting/` | speedup chart + historical renderers | ✓ |
| `tools/` | `get_flowlog.sh` + env bootstrap | ✓ |
| `docs/historical/` | frozen perf snapshots from before the split | ✓ |
| `flowlog/<short_sha>/` | per-ref FlowLog builds | ✗ |
| `facts/` | dataset cache (external data handler) | ✗ |
| `results/` | CSVs, plots, raw timing | ✗ |

## Requirements

- Linux or macOS (`tools/env/env.sh`); Windows via WSL2.
- Rust toolchain (rustup installs on a fresh box).
- ~50 GB free for the FlowLog build cache + dataset cache.
- A shared dataset mount can be symlinked to `facts/`; the runners'
  cache-safety guard refuses to delete through a symlink unless
  `FLOWLOG_FORCE_CLEANUP=1`.

## Further reading

- [`AGENTS.md`](./AGENTS.md) — design principles, repo split rationale,
  agent contract, file-by-file lineage from `flowlog@pre-bench-split`.
- [`scripts/lib/README.md`](./scripts/lib/README.md) — what each helper
  in `lib/` and `engines/` owns.

## License

MIT. See `LICENSE` (TBD — track upstream `flowlog-rs/flowlog`).
