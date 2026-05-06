# scripts/lib & scripts/engines

Top-level scripts (`bench_one.sh`, `cross_engine.sh`, `regression.sh`,
`ldbc.sh`) `source` files from these two directories.

## scripts/lib/ — engine-neutral helpers

| File | What |
| --- | --- |
| `common.sh` | ANSI colors, `trim`, `flowlog_truthy`, dataset cache-safety guard (`cleanup_dataset_should_clean`, with the `CACHE_PATCH_v2` marker). `log`/`die` are intentionally **not** here — each runner owns its own branded prefix. |
| `measure.sh` | `time_wrap` (GNU `/usr/bin/time -v` + `timeout`), log/sidecar extractors (`extract_total_seconds`, `extract_load_seconds`, `extract_peak_rss_kb`, `extract_elapsed_ms`), median/avg helpers, `kib_to_mib`, `speedup_ratio`, `pick_median_entry`, `write_engine_sidecars`. |
| `datasets.sh` | `dataset_ensure_zip` / `dataset_ensure_tar_zst` (download to `/dev/shm`, extract into `$FACT_DIR`); `dataset_cleanup` (calls the `common.sh` safety guard). |
| `run_info.sh` | `write_run_info` / `verify_run_info` — reproducibility manifest (AGENTS.md principle 6). Identity body is byte-stable across runs; do **not** edit `_run_info_render_identity` without a deliberate plan to invalidate every existing `results/*/run_info.txt`. |
| `runner.sh` | Library-mode runner crate synthesis (Cargo.toml + build.rs + main.rs). Used by `bench_one.sh` and `engines/libmode.sh`. |
| `synth_common.sh` | Tiny stateless `.dl` parsing helpers (`pascal_case`, `dl_to_rust_type`, `input_filename_for`, `find_csv_case_insensitive`). Vendored from flowlog. |

## scripts/engines/ — one file per comparison engine

Each file owns the per-attempt timing loop for one external tool (so
the differences — Soufflé times via `date`, the lib runner needs a
per-pair Cargo build, etc. — stay visible rather than hidden behind
a shared template). Each exposes:

* `engine_<name>_setup` (optional, for one-time install/clone/warm-up)
* `engine_<name>_run "$prog_name" "$dataset_name"` — runs `NUM_RUNS`
  attempts, picks the median, writes the standard sidecars
  (`<best_log>.median_rss_kb`, `<best_log>.n_runs_succeeded`, plus
  `<best_log>.median_total_s` for Soufflé and `<best_log>.sizes`
  for compiler / Soufflé cross-validation). Returns `1` if every
  attempt failed.

| File | Notes |
| --- | --- |
| `compiler.sh` | `flowlog-compiler -> binary -w N`. Timing from the `Dataflow executed` log line. |
| `lib.sh` | Per-pair Cargo build via `lib/runner.sh`, then runs `flowlog_bench_lib`. |
| `interpreter.sh` | Downloads the vldb26-artifact `.dl` program; runs the cloned interpreter. |
| `souffle.sh` | Compile-once-per-program (cache keyed by `WORKERS` + `.dl` mtime, `libgomp` linkage check). Timing via `date +%s.%N` (Souffle has no built-in dataflow log line). |

## How a new engine slots in

1. Add `scripts/engines/<name>.sh` with the two functions above.
2. Source it from `cross_engine.sh`'s setup section.
3. Add columns to `CSV_HEADER` and `append_csv_row` in `cross_engine.sh`.
4. Update `plotting/plot_speedup.py` if you want the new column charted.

That's it — no other files need to change.
