#!/usr/bin/env bash
# egglog 3.x adapter. A pair is runnable when programs/oracle/egglog/<stem>.egg
# exists; absent translations are reported as unsupported by the orchestrator.

[[ -n "${FLOWLOG_BENCH_ENGINE_EGGLOG_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_ENGINE_EGGLOG_LOADED=1

engine_egglog_setup() {
    [[ -x "$EGGLOG_BIN" ]] || die "egglog not found at $EGGLOG_BIN — install with: cargo install egglog --version 3.0.0 --locked --root '$EGGLOG_ROOT'"
    local got
    got="$($EGGLOG_BIN --version | awk '{print $2}')"
    [[ "$got" == "${EGGLOG_VERSION}_"* || "$got" == "$EGGLOG_VERSION" ]] \
        || die "egglog version mismatch: wanted $EGGLOG_VERSION, got $got"
    local supported
    supported="$(find "$EGGLOG_PROG_DIR" -maxdepth 1 -type f -name '*.egg' -printf '%f\n' \
        | sed 's/\.egg$//' | LC_ALL=C sort | paste -sd, -)"
    log "$BLUE" "SETUP" "egglog: $EGGLOG_BIN (v$EGGLOG_VERSION, -j $WORKERS)"
    log "$BLUE" "SUPPORT" "egglog translations: ${supported:-none}"
}

engine_egglog_has_program() {
    local stem
    stem="$(basename "$1" .dl)"
    [[ -f "$EGGLOG_PROG_DIR/$stem.egg" ]]
}

engine_egglog_run() {
    local prog_name="$1" dataset="$2" stem program data_dir best_log entries=""
    stem="$(basename "$prog_name" .dl)"
    program="$EGGLOG_PROG_DIR/$stem.egg"
    data_dir="$LOG_DIR/.egglog-facts/${stem}_${dataset}"
    best_log="$LOG_DIR/${stem}_${dataset}_egglog.log"
    mkdir -p "$data_dir"

    # egglog's input command requires TSV. Preserve every row and do the
    # mechanical conversion once, outside timed samples.
    local csv base
    while IFS= read -r -d '' csv; do
        base="$(basename "$csv" .csv)"
        tr ',' '\t' < "$csv" > "$data_dir/$base.tsv"
    done < <(find "$FACT_DIR/$dataset" -maxdepth 1 -type f -name '*.csv' -print0)

    local -a rss_values=()
    local run run_log rss_log ms sec rss rc
    log "$BLUE" "RUN" "egglog:   $(basename "$program") + $dataset (w=$WORKERS, runs=$NUM_RUNS)"
    for run in $(seq 1 "$NUM_RUNS"); do
        run_log="$LOG_DIR/${stem}_${dataset}_egglog_run${run}.log"
        rss_log="${run_log}.rss"
        rc=0
        time_wrap "$rss_log" "$run_log" "$FLOWLOG_RUN_TIMEOUT" -- \
            "$EGGLOG_BIN" -j "$WORKERS" -F "$data_dir" "$program" || rc=$?
        (( rc == 0 )) || { log "$YELLOW" "WARN" "egglog run $run failed (see $run_log)"; continue; }
        ms="$(extract_elapsed_ms "$rss_log")"
        rss="$(extract_peak_rss_kb "$rss_log")"
        [[ "$ms" =~ ^[0-9]+$ ]] || continue
        sec="$(awk -v ms="$ms" 'BEGIN {printf "%.6f", ms/1000}')"
        entries="${entries:+$entries$'\n'}${sec}:${run_log}"
        [[ "$rss" =~ ^[0-9]+$ ]] && rss_values+=("$rss")
        log "$YELLOW" "TIME" "  egglog run $run: ${sec}s, peak ${rss} KiB"
    done
    [[ -n "$entries" ]] || return 1

    local median_entry median_time median_log median_rss n
    median_entry="$(pick_median_entry "$entries")"
    median_time="${median_entry%%:*}"; median_log="${median_entry#*:}"
    median_rss="$(median_int "${rss_values[@]}")"
    n="$(printf '%s\n' "$entries" | wc -l)"
    write_engine_sidecars "$best_log" "$median_log" "$median_rss" "$n" "$median_time"

    local relation_file size_file
    relation_file="${best_log}.relations.tmp"; size_file="${best_log}.values.tmp"
    sed -n 's/^; @printsize //p' "$program" > "$relation_file"
    awk '/^[0-9]+$/ {print}' "$best_log" > "$size_file"
    [[ "$(wc -l < "$relation_file")" == "$(wc -l < "$size_file")" ]] || {
        rm -f "$relation_file" "$size_file"
        log "$RED" "FAIL" "egglog print-size count does not match @printsize metadata: $program"
        return 1
    }
    paste "$relation_file" "$size_file" > "${best_log}.sizes"
    rm -f "$relation_file" "$size_file"
}
