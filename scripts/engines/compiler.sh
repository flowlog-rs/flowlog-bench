#!/usr/bin/env bash
# scripts/engines/compiler.sh — flowlog-compiler timing adapter.
#
# Caller contract (set by cross_engine.sh / cross_flowlog_version.sh before sourcing):
#   COMPILER_BIN          flowlog-compiler binary
#   PROG_DIR              programs/oracle/flowlog/
#   FACT_DIR              datasets root
#   LOG_DIR               where to write run + median logs
#   WORKERS               -w value
#   NUM_RUNS              attempts per pair
#   FLOWLOG_RUN_TIMEOUT   per-attempt SIGTERM cap
#
# Caller log helpers (`log <colour> <tag> <msg>`, `die`) must already exist.

[[ -n "${FLOWLOG_BENCH_ENGINE_COMPILER_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_ENGINE_COMPILER_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/measure.sh"

# Run flowlog-compiler N times on (prog, dataset). Median log + sidecars
# written to $LOG_DIR/<stem>_<dataset>_compiler.log. Returns 1 if all
# runs failed.
engine_compiler_run() {
    local prog_name="$1" dataset_name="$2"
    local prog_file stem prog_path dataset_path binary best_log
    prog_file="$(basename "$prog_name")"
    stem="${prog_file%.*}"
    # Programs live under <stem>/<variant>.dl after the join-order layout
    # migration. A config entry like `andersen.dl=medium` is shorthand for
    # `andersen/default.dl=medium`; an entry that already names a folder
    # (`andersen/sample_0042.dl=medium`) is taken as-is.
    if [[ "$prog_name" == */* ]]; then
        prog_path="${PROG_DIR}/${prog_name}"
    else
        prog_path="${PROG_DIR}/${stem}/default.dl"
    fi
    [[ -f "$prog_path" ]] || die "Compiler program not found: $prog_path"

    dataset_path="$(realpath "${FACT_DIR}/${dataset_name}")"
    binary="${LOG_DIR}/.bin/${stem}_${dataset_name}"
    best_log="${LOG_DIR}/${stem}_${dataset_name}_compiler.log"

    log "$BLUE" "RUN" "Compiler:  $prog_file + $dataset_name (batch, w=$WORKERS, runs=$NUM_RUNS)"
    mkdir -p "$LOG_DIR" "$(dirname "$binary")"

    # Compile .dl -> standalone executable (once per pair).
    local compile_log="${LOG_DIR}/${stem}_${dataset_name}_compiler_build.log"
    rm -f "$binary"
    "$COMPILER_BIN" "$prog_path" \
        -F "$dataset_path" \
        -o "$binary" \
        --mode datalog-batch \
        > "$compile_log" 2>&1 \
        || die "Compilation failed for $prog_file (see $compile_log)"
    [[ -x "$binary" ]] || die "Binary not found: $binary"

    # Run NUM_RUNS times.
    local entries=""
    local -a rss_values=()
    local run rc t r
    for run in $(seq 1 "$NUM_RUNS"); do
        local run_log="${LOG_DIR}/${stem}_${dataset_name}_compiler_run${run}.log"
        local rss_log="${run_log}.rss"

        log "$YELLOW" "RUN" "  Compiler attempt $run/$NUM_RUNS"
        rc=0
        time_wrap "$rss_log" "$run_log" "$FLOWLOG_RUN_TIMEOUT" -- \
            "$binary" -w "$WORKERS" || rc=$?

        if (( rc != 0 )); then
            if (( rc == 124 )); then
                log "$YELLOW" "TIMEOUT" "Compiler run $run hit ${FLOWLOG_RUN_TIMEOUT}s on $prog_file + $dataset_name (see $run_log)"
            else
                log "$YELLOW" "WARN" "Compiler run $run failed for $prog_file + $dataset_name (see $run_log)"
            fi
            continue
        fi

        t=$(extract_total_seconds "$run_log")
        r=$(extract_peak_rss_kb   "$rss_log")
        log "$YELLOW" "TIME" "  Run $run: ${t}s, peak ${r} KiB"
        [[ "$t" =~ ^[0-9] ]] && entries="${entries:+$entries$'\n'}${t}:${run_log}"
        [[ "$r" =~ ^[0-9] ]] && rss_values+=("$r")
    done

    rm -f "$binary"

    if [[ -z "$entries" ]]; then
        log "$RED" "FAIL" "Compiler: all $NUM_RUNS runs failed for $prog_file + $dataset_name"
        rm -f "${best_log}.n_runs_succeeded" "${best_log}.sizes"
        return 1
    fi

    local median_entry median_time median_log median_rss n_succeeded
    median_entry=$(pick_median_entry "$entries")
    median_time="${median_entry%%:*}"
    median_log="${median_entry#*:}"
    median_rss=$(median_int "${rss_values[@]}")
    n_succeeded=$(echo "$entries" | wc -w)

    write_engine_sidecars "$best_log" "$median_log" "$median_rss" "$n_succeeded"

    # Cheap cross-validation: per-relation sizes from "[size][rel] t=() size=N"
    # log lines. cross_engine.sh diffs this against souffle's .sizes.
    grep -oE '\[size\]\[[^]]+\] t=\(\) size=[0-9]+' "$median_log" 2>/dev/null \
        | sed -E 's/^\[size\]\[([^]]+)\] t=\(\) size=([0-9]+)$/\1\t\2/' \
        > "${best_log}.sizes" 2>/dev/null

    if (( n_succeeded < NUM_RUNS )); then
        log "$YELLOW" "PARTIAL" "Compiler: only $n_succeeded/$NUM_RUNS runs succeeded for $prog_file + $dataset_name (median over $n_succeeded)"
    fi
    log "$GREEN" "DONE" "Compiler:  $prog_file + $dataset_name (median: ${median_time}s, peak ${median_rss} KiB, runs=${n_succeeded}/${NUM_RUNS})"
}
