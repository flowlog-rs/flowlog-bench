# flowlog-bench

Performance + cross-engine benchmarks for the [FlowLog](https://github.com/flowlog-rs/flowlog)
Datalog compiler/engine.

> **Why this is a separate repo.** [`flowlog-rs/flowlog`](https://github.com/flowlog-rs/flowlog)
> is correctness-only — its `make test` is fast, has minimal deps, and runs on
> every PR. This repo is the heavy side: Soufflé + DuckDB + GNU time, large
> dataset cache, A/B regression bisects, and full LDBC sweeps.
> See [`AGENTS.md`](./AGENTS.md) for the full split rationale.

---

## Quickstart

```bash
# 1. One-time host bootstrap (rust + souffle + duckdb + …)
make env

# 2. Bench `main` against Soufflé on the micro suite
make cross-engine

# 3. Bench a specific commit instead
FLOWLOG_REF=v0.5.0 make cross-engine

# 4. A/B perf+memory between two commits
FLOWLOG_BASE=v0.5.0 FLOWLOG_HEAD=main make regression

# 5. Single program (smallest possible signal)
make bench-one PROG=program_analysis/cspa.dl DATASET=cspa-httpd

# 6. LDBC SNB timing
make ldbc

# 7. Render the speedup chart
make plot
```

`flowlog/<short_sha>/` is gitignored and is populated lazily by
`tools/get_flowlog.sh` (idempotent: re-running with the same ref is free).
`facts/` and `results/` are gitignored too.

### Re-running and cleanup

`cross_engine.sh` and `regression.sh` write a `run_info.txt` provenance
manifest next to every output CSV. On re-run, they verify that the
identity-defining parameters (workers, num-runs, baselines, flowlog SHA,
config file) match — same params **resume cleanly** (already-benched
pairs are skipped); changed params **hard-fail** with a diff of what
moved, so a single CSV never ends up with rows produced under different
settings. Pass `--fresh` to `cross_engine.sh` (or wipe `results/` with
`make clean`) to start over. See [`AGENTS.md`](./AGENTS.md) §Design
principle 6 for the full contract.

```bash
make clean        # wipe results/ (keeps flowlog/ build cache + facts/)
make distclean    # also wipe flowlog/<short_sha>/ build trees
```

---

## Layout (high-level)

| Path             | What                                    | In git? |
| ---------------- | --------------------------------------- | ------- |
| `Makefile`       | one target per task                     | ✓       |
| `scripts/`       | bash runners (bench_one, cross_engine, regression, ldbc) | ✓ |
| `programs/`      | rule corpus, dialect-split              | ✓       |
| `config/`        | `<prog>=<dataset>` lists                | ✓       |
| `plotting/`      | speedup chart + historical renderers    | ✓       |
| `tools/`         | `get_flowlog.sh` + env bootstrap        | ✓       |
| `docs/historical/` | frozen perf snapshots from before the split | ✓ |
| `flowlog/`       | per-ref engine builds (cached)          | ✗       |
| `facts/`         | dataset cache (external data handler)   | ✗       |
| `results/`       | CSVs, plots, raw timing                 | ✗       |

See [`AGENTS.md`](./AGENTS.md) for the full design and the file-by-file
lineage from `flowlog@pre-bench-split`.

---

## Standard environment

- Linux or macOS (Windows users: run from WSL2; `tools/env/env.ps1` is a
  best-effort starter for native PowerShell, but Soufflé has no Windows build).
- Rust toolchain (rustup will install on a fresh box).
- ~50 GB free for `flowlog/` build caches + `facts/` dataset cache (depending
  on suite).
- Optional: a shared dataset mount; symlink `facts/` to it and the safety
  guard in the runners will refuse to delete through the symlink.

---

## License

MIT. See `LICENSE` (TBD — track upstream `flowlog-rs/flowlog`'s license).
