#!/usr/bin/env bash
# scripts/engines/ascent.sh — Ascent (Rust embedded Datalog) timing adapter.
#
# Ascent (github.com/s-arash/ascent) is a proc-macro: each oracle program is
# a hand-translated bin crate in programs/oracle/ascent/<stem>/, sharing a
# `harness` lib that owns all fact loading (Ascent itself has no I/O).
# See programs/oracle/ascent/README.md for translation conventions.
#
# Compile: `cargo build --release -p <stem>` in the workspace. Cargo's own
# fingerprinting is the compile cache (a warm no-op build is ~0.1s), so —
# unlike ddlog.sh — there is no mtime check here, and the cache lives in
# the workspace target/ dir, surviving a --fresh LOG_DIR wipe.
#
# Run: `target/release/<stem> <fact_dir>` with WORKERS in the environment
# (the harness builds the rayon pool from it — same knob as every engine).
#
# Timing source: the harness mirrors FlowLog's log lines exactly —
#   "Data loaded for ...: <secs>s"   and   "Dataflow executed in <secs>s"
# (total = load + compute) — so extract_total_seconds works unchanged and
# the Total is FlowLog-comparable. RSS from /usr/bin/time -v. Sizes come
# from the "<relation>\t<count>" lines (already lowercased) each program
# prints for its .printsize relations.
#
# Caller contract (set by cross_engine.sh):
#   ASCENT_PROG_DIR
#   FACT_DIR, LOG_DIR, WORKERS, NUM_RUNS, FLOWLOG_RUN_TIMEOUT, TIME_BIN
# Caller log helpers (log/die) must already exist.

[[ -n "${FLOWLOG_BENCH_ENGINE_ASCENT_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_ENGINE_ASCENT_LOADED=1

_ASCENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "${_ASCENT_DIR}/../lib" && pwd)/measure.sh"

engine_ascent_setup() {
    command -v cargo >/dev/null 2>&1 || die "cargo not on PATH — needed to build Ascent crates"
    [[ -d "$ASCENT_PROG_DIR" ]] || die "Ascent program dir not found: $ASCENT_PROG_DIR"
    [[ -f "${ASCENT_PROG_DIR}/Cargo.toml" ]] \
        || die "Ascent workspace manifest missing: ${ASCENT_PROG_DIR}/Cargo.toml"
    log "$BLUE" "SETUP" "Ascent: $(cargo --version 2>&1 | head -1) (workspace at $ASCENT_PROG_DIR)"
}

# Compile (or no-op reuse via cargo's fingerprinting) the program crate.
# Echoes the binary path on stdout; non-zero exit on failure.
_ascent_compile() {
    local stem="$1"
    local bin="${ASCENT_PROG_DIR}/target/release/${stem}"
    local build_log="${LOG_DIR}/ascent-${stem}.build.log"

    mkdir -p "$LOG_DIR"
    if ! ( cd "$ASCENT_PROG_DIR" && cargo build --release -p "$stem" ) \
            > "$build_log" 2>&1; then
        log "$YELLOW" "WARN" "Ascent: cargo build failed for $stem (see $build_log)"
        return 1
    fi
    [[ -x "$bin" ]] || return 1
    echo "$bin"
}

# Clear stale sidecars + truncate the best-log so the CSV row reads N/A.
_ascent_record_na() {
    local best_log="$1"
    rm -f "${best_log}.median_rss_kb" "${best_log}.median_total_s"
    : > "$best_log"
}

# Record per-relation sizes to <sizes_sidecar>: the program prints
# "<relation>\t<count>" (lowercased) for every .printsize relation, so this
# is a straight filter — no seeding needed (0-size relations are printed).
_ascent_record_sizes() {
    local sizes_sidecar="$1" run_log="$2"
    [[ -s "$sizes_sidecar" ]] && return 0
    grep -E $'^[A-Za-z_][A-Za-z0-9_]*\t[0-9]+$' "$run_log" 2>/dev/null \
        | sort -k1,1 > "$sizes_sidecar"
}

# Run ascent NUM_RUNS times. Returns 1 if all runs failed or program missing.
engine_ascent_run() {
    local prog_name="$1" dataset_name="$2"
    local prog_file stem fact_path best_log bin
    prog_file="$(basename "$prog_name")"
    stem="${prog_file%.*}"
    fact_path="${FACT_DIR}/${dataset_name}"
    best_log="${LOG_DIR}/${stem}_${dataset_name}_ascent.log"

    if [[ ! -d "${ASCENT_PROG_DIR}/${stem}" ]]; then
        log "$YELLOW" "WARN" "Ascent: no crate for $stem at ${ASCENT_PROG_DIR}/${stem} — recording N/A"
        _ascent_record_na "$best_log"; return 1
    fi

    bin=$(_ascent_compile "$stem") || { _ascent_record_na "$best_log"; return 1; }

    if [[ ! -d "$fact_path" ]]; then
        log "$YELLOW" "WARN" "Ascent: dataset $fact_path is absent — cannot run"
        _ascent_record_na "$best_log"; return 1
    fi

    log "$BLUE" "RUN" "Ascent:    $prog_file + $dataset_name (compiled, w=$WORKERS, runs=$NUM_RUNS)"
    mkdir -p "$LOG_DIR"

    local sizes_sidecar="${best_log}.sizes"
    : > "$sizes_sidecar"

    local entries=""
    local -a rss_values=()
    local run rc t r
    for run in $(seq 1 "$NUM_RUNS"); do
        local run_log="${LOG_DIR}/${stem}_${dataset_name}_ascent_run${run}.log"
        local rss_log="${run_log}.rss"

        log "$YELLOW" "RUN" "  Ascent attempt $run/$NUM_RUNS"
        rc=0
        WORKERS="$WORKERS" time_wrap "$rss_log" "$run_log" "$FLOWLOG_RUN_TIMEOUT" -- \
            "$bin" "$fact_path" || rc=$?

        if (( rc != 0 )); then
            if (( rc == 124 )); then
                log "$YELLOW" "TIMEOUT" "Ascent run $run hit ${FLOWLOG_RUN_TIMEOUT}s (see $run_log)"
            else
                log "$YELLOW" "WARN" "Ascent run $run failed (see $run_log)"
            fi
            continue
        fi

        _ascent_record_sizes "$sizes_sidecar" "$run_log"

        # Harness emits FlowLog-style "Dataflow executed in <secs>s"
        # (= load + compute), so the same extractor the compiler uses works.
        t=$(extract_total_seconds "$run_log")
        r=$(extract_peak_rss_kb "$rss_log")
        log "$YELLOW" "TIME" "  Run $run: ${t}s, peak ${r} KiB"
        [[ "$t" =~ ^[0-9] ]] && entries="${entries:+$entries$'\n'}${t}:${run_log}"
        [[ "$r" =~ ^[0-9] ]] && rss_values+=("$r")
    done

    if [[ -z "$entries" ]]; then
        log "$RED" "FAIL" "Ascent: all $NUM_RUNS runs failed for $prog_file + $dataset_name"
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
        log "$YELLOW" "PARTIAL" "Ascent: only $n_succeeded/$NUM_RUNS succeeded for $prog_file + $dataset_name"
    fi
    log "$GREEN" "DONE" "Ascent:    $prog_file + $dataset_name (median: ${median_time}s, peak ${median_rss} KiB, runs=${n_succeeded}/${NUM_RUNS})"
}
