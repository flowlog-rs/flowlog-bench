#!/usr/bin/env bash
# scripts/engines/libmode.sh — flowlog library-mode timing adapter.
#
# Builds a tiny driver crate (via lib/runner.sh) that links the
# generated DatalogBatchEngine, loads CSVs, and times only run().
# Each pair gets a fresh main.rs (loaders) + cargo build, then the
# driver binary is invoked NUM_RUNS times.
#
# Caller contract:
#   FLOWLOG_SRC_DIR        flowlog source for build-deps path
#   PROG_DIR, FACT_DIR
#   LIB_BENCH_RUNNER_DIR   crate build dir (scratch under results/)
#   LIB_BENCH_BIN          built driver binary path
#   LOG_DIR, WORKERS, NUM_RUNS, FLOWLOG_RUN_TIMEOUT
#   LIB_BENCH_SIP, LIB_BENCH_STR_INTERN  (compile-time codegen knobs)
# Caller log helpers (log/die) must already exist.

[[ -n "${FLOWLOG_BENCH_ENGINE_LIBMODE_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_ENGINE_LIBMODE_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/measure.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/runner.sh"

# Build the runner crate once with a trivial program so the cargo
# cache is hot before we start swapping in real per-pair codegen.
engine_libmode_setup() {
    log "$BLUE" "SETUP" "Setting up lib runner crate at $LIB_BENCH_RUNNER_DIR"
    bench_lib_ensure_crate

    cat > "${LIB_BENCH_RUNNER_DIR}/program.dl" <<'EOF'
.decl Edge(x: int32, y: int32)
.input Edge()
.decl Reach(x: int32, y: int32)
Reach(x, y) :- Edge(x, y).
Reach(x, y) :- Reach(x, z), Edge(z, y).
.output Reach
EOF
    LIB_BENCH_SIP=0 LIB_BENCH_STR_INTERN=0 bench_lib_write_build_rs
    cat > "${LIB_BENCH_RUNNER_DIR}/src/main.rs" <<'EOF'
pub mod prog { include!(concat!(env!("OUT_DIR"), "/program.rs")); }
fn main() {}
EOF
    log "$YELLOW" "BUILD" "Warming lib runner crate (release)"
    (cd "$LIB_BENCH_RUNNER_DIR" && cargo build --release --quiet 2>&1 | tail -5) \
        || die "Lib runner warm-up failed"
    log "$GREEN" "OK" "Lib runner ready"
}

# Run lib path NUM_RUNS times. Returns 1 if all runs failed.
engine_libmode_run() {
    local prog_name="$1" dataset_name="$2"
    local prog_file stem prog_path dataset_path best_log
    prog_file="$(basename "$prog_name")"
    stem="${prog_file%.*}"
    prog_path="${PROG_DIR}/${prog_name}"
    [[ -f "$prog_path" ]] || die "Lib program not found: $prog_path"

    dataset_path="$(realpath "${FACT_DIR}/${dataset_name}")"
    best_log="${LOG_DIR}/${stem}_${dataset_name}_lib.log"

    log "$BLUE" "RUN" "Lib:       $prog_file + $dataset_name (batch, w=$WORKERS, runs=$NUM_RUNS)"
    mkdir -p "$LOG_DIR"

    # Discover input-relation -> CSV mapping (case-insensitive).
    local pairs
    pairs=$(bench_lib_discover_csvs "$prog_path" "$dataset_path")
    [[ -n "$pairs" ]] || die "No CSVs discovered for $prog_file under $dataset_path"

    local -a csv_envs=()
    local line rel csv_abs
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        rel="${line%%=*}"
        csv_abs="${line#*=}"
        csv_envs+=("FLOWLOG_CSV_${rel^^}=${csv_abs}")
    done <<< "$pairs"

    # Stage program.dl unchanged (no .printsize -> .output rewrite — would
    # force materializing output Vecs and skew the timing vs the compiler).
    local prepared_dl="${LIB_BENCH_RUNNER_DIR}/program.dl"
    cp "$prog_path" "$prepared_dl"

    LIB_BENCH_SIP=0 LIB_BENCH_STR_INTERN=0 bench_lib_write_build_rs

    local pairs_space
    pairs_space="$(echo "$pairs" | tr '\n' ' ')"
    bench_lib_write_main_rs "$prepared_dl" "$pairs_space" \
        || die "main.rs synthesis failed for $prog_file"

    log "$YELLOW" "BUILD" "  Lib: cargo build --release"
    (cd "$LIB_BENCH_RUNNER_DIR" && cargo build --release --quiet) \
        || die "Lib build failed for $prog_file"
    [[ -x "$LIB_BENCH_BIN" ]] || die "Lib bench binary not found: $LIB_BENCH_BIN"

    local entries=""
    local -a rss_values=()
    local run rc t r
    for run in $(seq 1 "$NUM_RUNS"); do
        local run_log="${LOG_DIR}/${stem}_${dataset_name}_lib_run${run}.log"
        local rss_log="${run_log}.rss"
        log "$YELLOW" "RUN" "  Lib attempt $run/$NUM_RUNS"
        rc=0
        # csv_envs[]/WORKERS must be exported to the binary; bash-function
        # prefix-assignments are NOT exported to children, so use `env`.
        time_wrap "$rss_log" "$run_log" "$FLOWLOG_RUN_TIMEOUT" -- \
            env "${csv_envs[@]}" "WORKERS=$WORKERS" \
            "$LIB_BENCH_BIN" || rc=$?

        if (( rc != 0 )); then
            if (( rc == 124 )); then
                log "$YELLOW" "TIMEOUT" "Lib run $run hit ${FLOWLOG_RUN_TIMEOUT}s (see $run_log)"
            else
                log "$YELLOW" "WARN" "Lib run $run failed (see $run_log)"
            fi
            continue
        fi
        t=$(extract_total_seconds "$run_log")
        r=$(extract_peak_rss_kb   "$rss_log")
        log "$YELLOW" "TIME" "  Run $run: ${t}s, peak ${r} KiB"
        [[ "$t" =~ ^[0-9] ]] && entries="${entries:+$entries$'\n'}${t}:${run_log}"
        [[ "$r" =~ ^[0-9] ]] && rss_values+=("$r")
    done

    if [[ -z "$entries" ]]; then
        log "$RED" "FAIL" "Lib: all $NUM_RUNS runs failed for $prog_file + $dataset_name"
        rm -f "${best_log}.n_runs_succeeded"
        return 1
    fi

    local median_entry median_time median_log median_rss n_succeeded
    median_entry=$(pick_median_entry "$entries")
    median_time="${median_entry%%:*}"
    median_log="${median_entry#*:}"
    median_rss=$(median_int "${rss_values[@]}")
    n_succeeded=$(echo "$entries" | wc -w)
    write_engine_sidecars "$best_log" "$median_log" "$median_rss" "$n_succeeded"

    if (( n_succeeded < NUM_RUNS )); then
        log "$YELLOW" "PARTIAL" "Lib: only $n_succeeded/$NUM_RUNS succeeded for $prog_file + $dataset_name"
    fi
    log "$GREEN" "DONE" "Lib:       $prog_file + $dataset_name (median: ${median_time}s, peak ${median_rss} KiB, runs=${n_succeeded}/${NUM_RUNS})"
}
