#!/usr/bin/env bash
# scripts/engines/compiler.sh — flowlog-compiler timing adapter.
#
# Caller contract (set by cross_engine.sh / regression.sh before sourcing):
#   COMPILER_BIN          flowlog-compiler binary
#   PROG_DIR              programs/oracle/flowlog/
#   FACT_DIR              datasets root
#   LOG_DIR               where to write run + median logs
#   WORKERS               -w value
#   NUM_RUNS              attempts per pair
#   FLOWLOG_RUN_TIMEOUT   per-attempt SIGTERM cap
#   FLOWLOG_VERIFY_RUNTIME=1  retain generated sources and verify FLOWLOG_RUNTIME_PATH
#   FLOWLOG_STRICT_RUNS=1      require every attempt to produce valid time + RSS
#
# Caller log helpers (`log <colour> <tag> <msg>`, `die`) must already exist.

[[ -n "${FLOWLOG_BENCH_ENGINE_COMPILER_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_ENGINE_COMPILER_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/measure.sh"

# Include program directories in artifact names so a/default.dl and
# b/default.dl cannot overwrite each other's logs and dependency locks.
engine_compiler_stem() {
    local name="${1%.dl}"
    if [[ "${FLOWLOG_VERIFY_RUNTIME:-0}" == 1 ]]; then
        printf '%s\n' "${name//\//%}"
    else
        basename "$name"
    fi
}

# Run flowlog-compiler N times on (prog, dataset). Median log + sidecars
# written to $LOG_DIR/<stem>_<dataset>_compiler.log. Returns 1 if all
# runs failed.
engine_compiler_run() {
    local prog_name="$1" dataset_name="$2"
    local prog_file stem prog_path dataset_path binary best_log
    prog_file="$(basename "$prog_name")"
    stem="$(engine_compiler_stem "$prog_name")"
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

    # Compile .dl -> standalone executable (once per pair). Pass `-D -`
    # so `.printsize` directives surface on the binary's stdout (which
    # the per-run logger captures) — without this, programs that use
    # .printsize (e.g. doop, polonius) fail with "output_dir is unset".
    #
    # Enable string interning by default; FL_NO_STR_INTERN=1 opts out.
    local fl_intern_flag="--str-intern"
    [[ "${FL_NO_STR_INTERN:-0}" == "1" ]] && fl_intern_flag=""
    local compile_log="${LOG_DIR}/${stem}_${dataset_name}_compiler_build.log"
    local build_dir="${LOG_DIR}/generated/${stem}_${dataset_name}"
    local -a build_flags=()
    rm -f "$binary" "$best_log" "${best_log}.median_rss_kb" \
        "${best_log}.median_wall_s" "${best_log}.n_runs_succeeded" "${best_log}.sizes"
    if [[ "${FLOWLOG_VERIFY_RUNTIME:-0}" == 1 ]]; then
        build_flags=(-B "$build_dir")
    fi
    # Compile once per pair. The regression gate measures execution time;
    # build duration and binary size are separate diagnostic sidecars.
    local compile_t0 compile_t1
    compile_t0=$(date +%s.%N)
    "$COMPILER_BIN" "$prog_path" \
        -F "$dataset_path" \
        -D - \
        -o "$binary" \
        ${fl_intern_flag} \
        ${EXTRA_FL_FLAGS:-} \
        "${build_flags[@]}" \
        > "$compile_log" 2>&1 \
        || die "Compilation failed for $prog_file (see $compile_log)"
    compile_t1=$(date +%s.%N)
    [[ -x "$binary" ]] || die "Binary not found: $binary"
    if [[ "${FLOWLOG_VERIFY_RUNTIME:-0}" == 1 ]]; then
        # Let the selected compiler generate and build its own manifest. Check
        # what Cargo actually resolved before timing the resulting executable.
        (
            cd "$build_dir" || exit 1
            cargo metadata --locked --format-version=1 > metadata.json
        ) 2>> "$compile_log" || die "Cargo metadata failed (see $compile_log)"
        python3 "${ROOT_DIR}/scripts/lib/verify_runtime.py" \
            "$build_dir/metadata.json" "$FLOWLOG_RUNTIME_PATH" \
            2>> "$compile_log" || die "Runtime mismatch (see $compile_log)"
        # Keep the generated sources and Cargo.lock without accumulating a
        # full target directory for every pair in a large suite.
        rm -rf -- "$build_dir/target"
    fi
    awk -v a="$compile_t0" -v b="$compile_t1" 'BEGIN { printf "%.2f\n", b - a }' \
        > "${compile_log%.log}.seconds"
    stat -c %s "$binary" > "${compile_log%.log}.binsize" 2>/dev/null || true
    log "$YELLOW" "TIME" "  Compile: $(cat "${compile_log%.log}.seconds")s, binary $(cat "${compile_log%.log}.binsize" 2>/dev/null || echo '?') bytes"

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
        if [[ "${FLOWLOG_STRICT_RUNS:-0}" == 1 ]]; then
            [[ "$t" =~ ^[0-9]+\.[0-9]+$ && "$r" =~ ^[0-9]+$ ]] || continue
            awk -v t="$t" -v r="$r" 'BEGIN { exit !(t > 0 && r > 0) }' || continue
        fi
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
    if [[ "${FLOWLOG_STRICT_RUNS:-0}" == 1 ]] && (( n_succeeded != NUM_RUNS )); then
        log "$RED" "FAIL" "Compiler: only $n_succeeded/$NUM_RUNS valid measurements"
        return 1
    fi

    write_engine_sidecars "$best_log" "$median_log" "$median_rss" "$n_succeeded"
    # Process wall time of the runtime-median sample. Despite the historical
    # sidecar name, this is not the median of all process wall times.
    local median_wall_ms
    median_wall_ms=$(extract_elapsed_ms "${median_log}.rss")
    if [[ "$median_wall_ms" =~ ^[0-9]+$ ]]; then
        awk -v ms="$median_wall_ms" 'BEGIN {printf "%.6f\n", ms/1000}' > "${best_log}.median_wall_s"
    fi

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
