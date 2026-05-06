#!/usr/bin/env bash
# scripts/engines/souffle.sh — Souffle (compiled C++) timing adapter.
#
# Souffle has two execution modes:
#   1. Interpreted  (souffle prog.dl -F facts -D out)  — `-j N` accepted
#                    but does NOT enable runtime parallelism.
#   2. Compiled     (souffle -o bin -j N -F facts prog.dl; bin -j N …)
#                    — `-j N` at compile-time wires up the `pfor` macro
#                    against libgomp; only this mode is fairly comparable
#                    to FlowLog's parallel runtime.
#
# We use mode 2. Three load-bearing details:
#
#   - `-o <bin>` (NOT `-c`). `-c` compiles AND runs in one shot and does
#     not produce a reusable binary; `-o` emits standalone C++.
#   - `-j N` at compile time. Souffle gates pfor expansion on this —
#     without it, pfor degrades to a serial `for` and the binary won't
#     be linked against libgomp regardless of the runtime `-j N`.
#   - `-F <facts>` at compile time too: Souffle validates `.input`
#     directives against the dataset during codegen.
#
# Compile is cached at $LOG_DIR/sf-bin/<stem>-w<workers>; cache key
# includes WORKERS because of the `pfor` gating; cache is invalidated
# on .dl mtime newer than the binary.
#
# Timing source: `date +%s.%N` brackets — Souffle does NOT emit a
# "Dataflow executed" log line. RSS still comes from /usr/bin/time -v.
#
# Caller contract:
#   SOUFFLE_BIN, SOUFFLE_PROG_DIR
#   FACT_DIR, LOG_DIR, WORKERS, NUM_RUNS, FLOWLOG_RUN_TIMEOUT

[[ -n "${FLOWLOG_BENCH_ENGINE_SOUFFLE_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_ENGINE_SOUFFLE_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/measure.sh"

engine_souffle_setup() {
    [[ -x "$SOUFFLE_BIN" ]] || die "Souffle binary not found at $SOUFFLE_BIN (apt install souffle, or set SOUFFLE_BIN)"
    [[ -d "$SOUFFLE_PROG_DIR" ]] || die "Souffle program dir not found: $SOUFFLE_PROG_DIR"
    log "$BLUE" "SETUP" "Souffle: $($SOUFFLE_BIN --version 2>&1 | head -1)"
    mkdir -p "${LOG_DIR}/sf-bin"
}

# Compile (or reuse cached) the C++ binary for this program.
# Returns the binary path on stdout, non-zero exit on failure.
_souffle_compile() {
    local stem="$1" sf_src="$2" fact_path="$3"
    local sf_bin="${LOG_DIR}/sf-bin/${stem}-w${WORKERS}"

    if [[ ! -x "$sf_bin" || "$sf_src" -nt "$sf_bin" ]]; then
        log "$BLUE" "BUILD" "Souffle: compiling $stem with -j $WORKERS (one-off)"
        mkdir -p "$(dirname "$sf_bin")"
        if ! "$SOUFFLE_BIN" -o "$sf_bin" -p /dev/null -j "$WORKERS" \
                -F "$fact_path" "$sf_src" \
                > "${sf_bin}.compile.log" 2>&1; then
            log "$YELLOW" "WARN" "Souffle: -o compile failed for $stem (see ${sf_bin}.compile.log)"
            return 1
        fi
        if ldd "$sf_bin" 2>/dev/null | grep -q "libgomp"; then
            log "$BLUE" "BUILD" "Souffle: ${sf_bin} linked against libgomp (parallel-ready)"
        else
            log "$YELLOW" "WARN" "Souffle: $stem NOT linked against libgomp — runtime will be effectively single-threaded"
        fi
    fi

    echo "$sf_bin"
}

# Record per-relation row counts to ${best_log}.sizes from a successful
# souffle output dir. .printsize relations don't write a .csv — we pick
# them up from "Relation\tN" lines in the run log.
_souffle_record_sizes() {
    local sizes_sidecar="$1" out_dir="$2" run_log="$3"
    [[ -s "$sizes_sidecar" ]] && return 0   # already populated

    local csv rel rows
    for csv in "$out_dir"/*.csv; do
        [[ -f "$csv" ]] || continue
        rel=$(basename "$csv" .csv)
        rows=$(wc -l < "$csv")
        printf '%s\t%s\n' "${rel,,}" "$rows" >> "$sizes_sidecar"
    done
    grep -E '^[A-Za-z][A-Za-z0-9_]*\s+[0-9]+$' "$run_log" 2>/dev/null \
        | awk -v IGNORECASE=1 '{ printf "%s\t%s\n", tolower($1), $2 }' \
        >> "$sizes_sidecar"
    sort -u -k1,1 -o "$sizes_sidecar" "$sizes_sidecar" 2>/dev/null || true
}

# Run souffle NUM_RUNS times. Returns 1 if all runs failed or program
# is missing.
engine_souffle_run() {
    local prog_name="$1" dataset_name="$2"
    local prog_file stem sf_src fact_path best_log sf_bin
    prog_file="$(basename "$prog_name")"
    stem="${prog_file%.*}"
    sf_src="${SOUFFLE_PROG_DIR}/${stem}.dl"
    fact_path="${FACT_DIR}/${dataset_name}"
    best_log="${LOG_DIR}/${stem}_${dataset_name}_souffle.log"

    if [[ ! -f "$sf_src" ]]; then
        log "$YELLOW" "WARN" "Souffle: no canonical .dl for $stem at $sf_src — recording N/A"
        rm -f "${best_log}.median_rss_kb" "${best_log}.median_total_s"
        : > "$best_log"
        return 1
    fi

    sf_bin=$(_souffle_compile "$stem" "$sf_src" "$fact_path") || {
        rm -f "${best_log}.median_rss_kb" "${best_log}.median_total_s"
        : > "$best_log"
        return 1
    }

    log "$BLUE" "RUN" "Souffle:   $prog_file + $dataset_name (compiled, w=$WORKERS, runs=$NUM_RUNS)"
    mkdir -p "$LOG_DIR"

    local sizes_sidecar="${best_log}.sizes"
    : > "$sizes_sidecar"

    local entries=""
    local -a rss_values=()
    local run rc t r out_dir t_start t_end
    for run in $(seq 1 "$NUM_RUNS"); do
        local run_log="${LOG_DIR}/${stem}_${dataset_name}_souffle_run${run}.log"
        local rss_log="${run_log}.rss"
        out_dir="${LOG_DIR}/sf_${stem}_${dataset_name}_run${run}"
        mkdir -p "$out_dir"

        log "$YELLOW" "RUN" "  Souffle attempt $run/$NUM_RUNS"
        t_start=$(date +%s.%N)
        rc=0
        time_wrap "$rss_log" "$run_log" "$FLOWLOG_RUN_TIMEOUT" -- \
            "$sf_bin" -F "$fact_path" -D "$out_dir" -j "$WORKERS" || rc=$?
        t_end=$(date +%s.%N)

        if (( rc != 0 )); then
            if (( rc == 124 )); then
                log "$YELLOW" "TIMEOUT" "Souffle run $run hit ${FLOWLOG_RUN_TIMEOUT}s (see $run_log)"
            else
                log "$YELLOW" "WARN" "Souffle run $run failed (see $run_log)"
            fi
            rm -rf "$out_dir"
            continue
        fi

        _souffle_record_sizes "$sizes_sidecar" "$out_dir" "$run_log"
        rm -rf "$out_dir"

        t=$(python3 -c "print(f'{${t_end}-${t_start}:.9f}')")
        r=$(extract_peak_rss_kb "$rss_log")
        log "$YELLOW" "TIME" "  Run $run: ${t}s, peak ${r} KiB"
        [[ "$t" =~ ^[0-9] ]] && entries="${entries:+$entries$'\n'}${t}:${run_log}"
        [[ "$r" =~ ^[0-9] ]] && rss_values+=("$r")
    done

    if [[ -z "$entries" ]]; then
        log "$RED" "FAIL" "Souffle: all $NUM_RUNS runs failed for $prog_file + $dataset_name"
        rm -f "${best_log}.median_rss_kb" "${best_log}.median_total_s" "${best_log}.n_runs_succeeded"
        : > "$best_log"
        return 1
    fi

    local median_entry median_time median_log median_rss n_succeeded
    median_entry=$(pick_median_entry "$entries")
    median_time="${median_entry%%:*}"
    median_log="${median_entry#*:}"
    median_rss=$(median_int "${rss_values[@]}")
    n_succeeded=$(echo "$entries" | wc -w)
    write_engine_sidecars "$best_log" "$median_log" "$median_rss" "$n_succeeded" "$median_time"

    if (( n_succeeded < NUM_RUNS )); then
        log "$YELLOW" "PARTIAL" "Souffle: only $n_succeeded/$NUM_RUNS succeeded for $prog_file + $dataset_name"
    fi
    log "$GREEN" "DONE" "Souffle:   $prog_file + $dataset_name (median: ${median_time}s, peak ${median_rss} KiB, runs=${n_succeeded}/${NUM_RUNS})"
}
