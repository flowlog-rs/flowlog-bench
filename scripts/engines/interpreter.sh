#!/usr/bin/env bash
# scripts/engines/interpreter.sh — vldb26 interpreter timing adapter.
#
# Caller contract (set by cross_engine.sh):
#   INTERPRETER_BIN, INTERPRETER_PROG_DIR, INTERPRETER_PROG_URL
#   FACT_DIR, LOG_DIR, WORKERS, NUM_RUNS, FLOWLOG_RUN_TIMEOUT
# Caller log helpers (log/die) must already exist.

[[ -n "${FLOWLOG_BENCH_ENGINE_INTERPRETER_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_ENGINE_INTERPRETER_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/measure.sh"

# Clone (if needed) and build the interpreter in release mode.
engine_interpreter_setup() {
    local repo_url="https://github.com/flowlog-rs/vldb26-artifact.git"
    log "$BLUE" "SETUP" "Setting up interpreter (vldb26-artifact)"
    if [[ ! -d "$INTERPRETER_DIR" ]]; then
        log "$CYAN" "CLONE" "Cloning vldb26-artifact"
        git clone --depth 1 "$repo_url" "$INTERPRETER_DIR" \
            || die "Failed to clone vldb26-artifact"
    else
        log "$GREEN" "FOUND" "vldb26-artifact already cloned"
    fi
    pushd "$INTERPRETER_DIR" >/dev/null
    log "$YELLOW" "BUILD" "Building interpreter (release)"
    cargo build --release 2>&1 | tail -5
    popd >/dev/null
    [[ -x "$INTERPRETER_BIN" ]] || die "Interpreter binary not found: $INTERPRETER_BIN"
    log "$GREEN" "OK" "Interpreter ready"
}

# Download an interpreter .dl program file if not already cached.
_interpreter_download_program() {
    local file="$1" path="${INTERPRETER_PROG_DIR}/${file}"
    mkdir -p "$INTERPRETER_PROG_DIR"
    [[ -f "$path" ]] && return 0
    log "$CYAN" "DOWNLOAD" "Interpreter program: $file"
    wget -q -O "$path" "${INTERPRETER_PROG_URL}/${file}" \
        || die "Download failed: $file"
}

# Run interpreter NUM_RUNS times. Returns 1 if all runs failed.
engine_interpreter_run() {
    local prog_name="$1" dataset_name="$2"
    local prog_file stem prog_path fact_path best_log
    prog_file="$(basename "$prog_name")"
    stem="${prog_file%.*}"
    _interpreter_download_program "$prog_file"
    prog_path="${INTERPRETER_PROG_DIR}/${prog_file}"
    fact_path="${FACT_DIR}/${dataset_name}"
    best_log="${LOG_DIR}/${stem}_${dataset_name}_interpreter.log"

    log "$BLUE" "RUN" "Interpreter: $prog_file + $dataset_name (no opt, w=$WORKERS, runs=$NUM_RUNS)"
    mkdir -p "$LOG_DIR"

    local entries=""
    local -a rss_values=()
    local run rc t r
    for run in $(seq 1 "$NUM_RUNS"); do
        local run_log="${LOG_DIR}/${stem}_${dataset_name}_interpreter_run${run}.log"
        local rss_log="${run_log}.rss"
        log "$YELLOW" "RUN" "  Interpreter attempt $run/$NUM_RUNS"
        rc=0
        # `env RUST_LOG=info` so the var is exported to the binary (a
        # bash-function prefix-assignment is NOT exported to children).
        time_wrap "$rss_log" "$run_log" "$FLOWLOG_RUN_TIMEOUT" -- \
            env RUST_LOG=info \
            "$INTERPRETER_BIN" \
                --program "$prog_path" \
                --facts "$fact_path" \
                --workers "$WORKERS" || rc=$?
        if (( rc != 0 )); then
            if (( rc == 124 )); then
                log "$YELLOW" "TIMEOUT" "Interpreter run $run hit ${FLOWLOG_RUN_TIMEOUT}s (see $run_log)"
            else
                log "$YELLOW" "WARN" "Interpreter run $run failed (see $run_log)"
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
        log "$RED" "FAIL" "Interpreter: all $NUM_RUNS runs failed for $prog_file + $dataset_name"
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
        log "$YELLOW" "PARTIAL" "Interpreter: only $n_succeeded/$NUM_RUNS succeeded for $prog_file + $dataset_name"
    fi
    log "$GREEN" "DONE" "Interpreter: $prog_file + $dataset_name (median: ${median_time}s, peak ${median_rss} KiB, runs=${n_succeeded}/${NUM_RUNS})"
}
