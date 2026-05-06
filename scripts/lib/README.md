# scripts/lib & scripts/engines

The top-level orchestrators (`bench_one.sh`, `cross_engine.sh`,
`regression.sh`, `ldbc.sh`) stay thin — they parse argv, walk the
config file, and write CSVs. The actual work lives here:

- **`scripts/lib/`** — shared helpers any engine can use.
- **`scripts/engines/`** — one file per comparison engine; each uses
  the helpers.

Keeping these two layers separate is what keeps `cross_engine.sh` small.

---

## scripts/lib/

### `measure.sh` — timing & memory

The single source of truth for everything an engine adapter needs to
measure one run.

- `time_wrap <rss_log> <run_log> <timeout_s> -- <cmd…>` — runs `<cmd>`
  inside `/usr/bin/time -v` + `timeout`. Returns the command's exit
  code (124 = timeout).
- **Sidecar extractors** (parse a `time -v` file): `extract_peak_rss_kb`,
  `extract_elapsed_ms`.
- **Log-line extractors** (parse FlowLog stdout):
  `extract_total_seconds`, `extract_load_seconds`.
- **Stats**: `median_int`, `avg_int`, `pick_median_entry`.
- **Conversions**: `kib_to_mib`, `speedup_ratio`, `compute_exec_seconds`.
- `write_engine_sidecars <best_log> <median_log> <rss_kb> <n_succeeded> [total_s]`
  — copies the median run log to `<best_log>` and writes the
  `.median_rss_kb` / `.n_runs_succeeded` / (optional) `.median_total_s`
  files every engine adapter is expected to leave behind.

### `datasets.sh` — dataset cache

- `dataset_ensure_zip <name> <url>` and `dataset_ensure_tar_zst <name> <url>`
  — idempotent: download to `/dev/shm`, extract into `$FACT_DIR`.
- `dataset_cleanup <name>` — `rm -rf` of the extracted dir, gated by
  the safety guard from `common.sh` (refuses to delete through a
  symlinked `$FACT_DIR` unless `FLOWLOG_FORCE_CLEANUP=1`).

### `common.sh` — small utilities

- ANSI color constants, `trim`, `flowlog_truthy`.
- `cleanup_dataset_should_clean` — the safety guard above. Carries
  the `CACHE_PATCH_v2` marker that external tooling greps for; do
  not rename it.

> **Why no `log`/`die` here?** Each runner owns its own branded prefix
> (`[BENCH]`, `[CHECK]`, `[perf-compare]`, …) so transcripts stay
> legible. A unified `log` would force every script through the same
> shape and lose that.

### `runner.sh` — FlowLog lib-mode crate synthesis

Builds a tiny per-pair Cargo crate (`Cargo.toml` + `build.rs` + `main.rs`)
that links the FlowLog runtime, loads CSVs, and times only
`engine.run()`. Used by `bench_one.sh` and `engines/libmode.sh`.

### `run_info.sh` — reproducibility manifest

- `write_run_info <outdir> [key=value …]` — writes `run_info.txt` with
  the flowlog SHA, corpus SHA, host, workers, num-runs, config sha256,
  and any extra knobs the runner passes through.
- `verify_run_info <outdir> [key=value …]` — on resume, hard-fails if
  the identity body has drifted from the on-disk manifest.

> **Do not** edit `_run_info_render_identity` without a deliberate plan
> to invalidate every existing `results/*/run_info.txt`. The verify is a
> byte-equal comparison.

### `synth_common.sh` — `.dl` syntax helpers

Stateless leaves: `pascal_case`, `dl_to_rust_type`, `input_filename_for`,
`find_csv_case_insensitive`. Vendored from FlowLog so the bench is not
pinned to the engine's evolving `tests/` layout.

---

## scripts/engines/

Each file owns the per-attempt timing loop for one external tool.
Engine-specific knowledge stays *next to* the engine that needs it,
rather than hidden behind a shared template — Soufflé times via
`date`, lib mode needs a per-pair Cargo build, etc.

**Each file exposes two functions:**

```bash
engine_<name>_setup                       # optional: one-time install/clone/warm-up
engine_<name>_run "$prog" "$dataset"      # runs NUM_RUNS attempts → picks median →
                                          # writes the standard sidecars
                                          # returns 1 iff every attempt failed
```

The standard sidecars `engine_<name>_run` is expected to produce:

| File | Always | Notes |
| --- | --- | --- |
| `<best_log>` | yes | the median run's stdout/stderr |
| `<best_log>.rss` | yes | the median run's `time -v` output |
| `<best_log>.median_rss_kb` | yes | one integer (kibibytes) |
| `<best_log>.n_runs_succeeded` | yes | one integer (≤ `NUM_RUNS`) |
| `<best_log>.median_total_s` | Soufflé only | one float (seconds) — Soufflé has no log-line timing |
| `<best_log>.sizes` | compiler & Soufflé | one `<rel>\t<count>` row per output relation, used by the compiler-vs-Soufflé cross-check |

**The four engines:**

| File | What it does |
| --- | --- |
| `compiler.sh` | `flowlog-compiler` → standalone binary. Times the `Dataflow executed in …` log line. Emits `.sizes` from `[size][rel] size=N` log lines. |
| `libmode.sh` | Per-pair Cargo build via `lib/runner.sh`, then runs `flowlog_bench_lib`. Same log-line timing as `compiler.sh`. |
| `interpreter.sh` | Downloads the vldb26-artifact `.dl` program if missing; runs the cloned interpreter. |
| `souffle.sh` | Compile-once-per-program (cache keyed by `WORKERS` + `.dl` mtime; `libgomp` linkage check). Times via `date +%s.%N` brackets. |

---

## Adding a new comparison engine

1. Create `scripts/engines/<name>.sh` exposing the two functions above.
2. `source` it from `scripts/cross_engine.sh` next to the other
   `source "${ROOT_DIR}/scripts/engines/*.sh"` lines.
3. Add columns to `CSV_HEADER` and the `append_csv_row` writer in
   `cross_engine.sh`.
4. *Optional:* update `plotting/plot_speedup.py` if the new column
   should be charted.

No other files need to change — that's the whole point of the
`engines/` + `lib/` split.
