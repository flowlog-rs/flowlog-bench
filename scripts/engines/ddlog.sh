#!/usr/bin/env bash
# scripts/engines/ddlog.sh — DDlog (Differential Datalog, compiled) timing adapter.
#
# DDlog is a COMPILER: `ddlog -i prog.dl` emits a Rust crate, built once with
# `cargo +<DDLOG_RUST> build --release` into a standalone <stem>_cli binary.
# The binary is driven by a stdin command stream (start; insert …; commit;
# dump RelationSizes;) generated from the dataset by ddlog_gen_dat.py
# (schema-aware: quotes string/istring columns, leaves integers bare).
#
# Two load-bearing details:
#   - Generated crates need rustc <DDLOG_RUST> (1.76). A modern stable
#     toolchain rejects the vendored differential_datalog lib, so we build
#     with `cargo +1.76`. env.sh installs both ddlog and the 1.76 toolchain.
#   - `.printsize` has no DDlog equivalent; each program reports relation
#     sizes via a RelationSizes output relation, which we `dump` and parse.
#
# Compile is cached at $DDLOG_BUILD_DIR/<stem>_ddlog; invalidated when the
# .dl is newer than the binary.
#
# Timing source: `date +%s.%N` brackets (DDlog emits no "Dataflow executed"
# line). RSS from /usr/bin/time -v. Sizes from RelationSizes dump lines.
#
# Caller contract (set by cross_engine.sh):
#   DDLOG_HOME, DDLOG_PROG_DIR, DDLOG_RUST, DDLOG_BUILD_DIR
#   FACT_DIR, LOG_DIR, WORKERS, NUM_RUNS, FLOWLOG_RUN_TIMEOUT, TIME_BIN
# Caller log helpers (log/die) must already exist.

[[ -n "${FLOWLOG_BENCH_ENGINE_DDLOG_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_ENGINE_DDLOG_LOADED=1

_DDLOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "${_DDLOG_DIR}/../lib" && pwd)/measure.sh"

engine_ddlog_setup() {
    [[ -x "${DDLOG_HOME}/bin/ddlog" ]] \
        || die "ddlog not found at ${DDLOG_HOME}/bin/ddlog (run: bash env.sh ddlog)"
    [[ -d "$DDLOG_PROG_DIR" ]] || die "DDlog program dir not found: $DDLOG_PROG_DIR"
    command -v cargo >/dev/null 2>&1 || die "cargo not on PATH — needed to build DDlog crates"
    rustup toolchain list 2>/dev/null | grep -q "^${DDLOG_RUST}" \
        || die "rust ${DDLOG_RUST} toolchain missing (run: rustup toolchain install ${DDLOG_RUST}) — DDlog crates don't build on modern stable"
    log "$BLUE" "SETUP" "DDlog: $("${DDLOG_HOME}/bin/ddlog" --version 2>&1 | head -1) (crates built with cargo +${DDLOG_RUST})"
    mkdir -p "${DDLOG_BUILD_DIR}"
}

# Compile (or reuse cached) the DDlog CLI binary. Echoes the binary path on
# stdout; non-zero exit on failure.
_ddlog_compile() {
    local stem="$1" dl_src="$2"
    local crate="${DDLOG_BUILD_DIR}/${stem}_ddlog"
    local bin="${crate}/target/release/${stem}_cli"

    if [[ ! -x "$bin" || "$dl_src" -nt "$bin" ]]; then
        log "$BLUE" "BUILD" "DDlog: compiling $stem (ddlog -i + cargo +${DDLOG_RUST}, one-off)"
        rm -rf "$crate"
        cp "$dl_src" "${DDLOG_BUILD_DIR}/${stem}.dl"
        if ! ( cd "$DDLOG_BUILD_DIR" \
                && "${DDLOG_HOME}/bin/ddlog" -i "${stem}.dl" -L "${DDLOG_HOME}/lib" ) \
                > "${crate}.ddlog.log" 2>&1; then
            log "$YELLOW" "WARN" "DDlog: ddlog -i failed for $stem (see ${crate}.ddlog.log)"
            return 1
        fi
        if ! ( cd "$crate" && cargo "+${DDLOG_RUST}" build --release ) \
                > "${crate}.build.log" 2>&1; then
            log "$YELLOW" "WARN" "DDlog: cargo +${DDLOG_RUST} build failed for $stem (see ${crate}.build.log)"
            return 1
        fi
    fi
    [[ -x "$bin" ]] || return 1
    echo "$bin"
}

# Record per-relation sizes to <sizes_sidecar> as "relation\tN" (lowercased,
# matching the souffle/compiler crosscheck). DDlog's RelationSizes dump omits
# 0-size relations (a group_by over an empty relation yields no row), so we
# seed every relation named in a RelationSizes rule at 0 and overlay the
# dumped values — declared-but-empty relations then appear as <rel>\t0, like
# souffle, so the compiler crosscheck stays honest.
_ddlog_record_sizes() {
    local sizes_sidecar="$1" run_log="$2" dl_src="$3"
    [[ -s "$sizes_sidecar" ]] && return 0
    {
        grep -oE 'RelationSizes\("[^"]+"' "$dl_src" 2>/dev/null \
            | sed -E 's/.*"([^"]+)".*/\1\t0/'
        grep -oE 'rel = "[^"]+", \.size = [0-9]+' "$run_log" 2>/dev/null \
            | sed -E 's/rel = "([^"]+)", \.size = ([0-9]+)/\1\t\2/'
    } | awk -F'\t' '{ v[tolower($1)] = $2 } END { for (k in v) printf "%s\t%s\n", k, v[k] }' \
      | sort -k1,1 > "$sizes_sidecar"
}

# Run ddlog NUM_RUNS times. Returns 1 if all runs failed or program missing.
engine_ddlog_run() {
    local prog_name="$1" dataset_name="$2"
    local prog_file stem dl_src fact_path best_log bin dat
    prog_file="$(basename "$prog_name")"
    stem="${prog_file%.*}"
    dl_src="${DDLOG_PROG_DIR}/${stem}.dl"
    fact_path="${FACT_DIR}/${dataset_name}"
    best_log="${LOG_DIR}/${stem}_${dataset_name}_ddlog.log"

    if [[ ! -f "$dl_src" ]]; then
        log "$YELLOW" "WARN" "DDlog: no .dl for $stem at $dl_src — recording N/A"
        rm -f "${best_log}.median_rss_kb" "${best_log}.median_total_s"; : > "$best_log"
        return 1
    fi

    bin=$(_ddlog_compile "$stem" "$dl_src") || {
        rm -f "${best_log}.median_rss_kb" "${best_log}.median_total_s"; : > "$best_log"
        return 1
    }

    # Translate the dataset to a command stream ONCE and cache it. Reuse the
    # cached .dat whenever it exists: the published datasets are immutable by
    # name, so a re-downloaded dataset (fresh mtime) doesn't change the stream
    # — only the program or the generator changing does. So a repeat run skips
    # the (slow, multi-million-row) translate, and never needs the raw dataset
    # at all once cached (with --keep-datasets it also skips the re-download).
    dat="${DDLOG_BUILD_DIR}/${stem}_${dataset_name}.dat"
    if [[ ! -s "$dat" || "$dl_src" -nt "$dat" \
            || "${_DDLOG_DIR}/ddlog_gen_dat.py" -nt "$dat" ]]; then
        if [[ ! -d "$fact_path" ]]; then
            log "$YELLOW" "WARN" "DDlog: no cached .dat for $stem + $dataset_name and dataset $fact_path is absent — cannot translate"
            rm -f "${best_log}.median_rss_kb" "${best_log}.median_total_s"; : > "$best_log"
            return 1
        fi
        log "$CYAN" "DAT" "DDlog: translating $dataset_name -> command stream (one-off; cached at $dat)"
        if ! python3 "${_DDLOG_DIR}/ddlog_gen_dat.py" "$dl_src" "$fact_path" \
                > "$dat" 2> "${dat}.gen.log"; then
            log "$YELLOW" "WARN" "DDlog: command-stream generation failed for $stem + $dataset_name (see ${dat}.gen.log)"
            rm -f "${best_log}.median_rss_kb" "${best_log}.median_total_s"; : > "$best_log"
            return 1
        fi
    else
        log "$GREEN" "DAT" "DDlog: reusing cached command stream ($dat)"
    fi

    log "$BLUE" "RUN" "DDlog:     $prog_file + $dataset_name (compiled, w=$WORKERS, runs=$NUM_RUNS)"
    mkdir -p "$LOG_DIR"

    local sizes_sidecar="${best_log}.sizes"
    : > "$sizes_sidecar"

    local entries=""
    local -a rss_values=()
    local run rc t r t_start t_end
    for run in $(seq 1 "$NUM_RUNS"); do
        local run_log="${LOG_DIR}/${stem}_${dataset_name}_ddlog_run${run}.log"
        local rss_log="${run_log}.rss"

        log "$YELLOW" "RUN" "  DDlog attempt $run/$NUM_RUNS"
        t_start=$(date +%s.%N)
        rc=0
        # exec inside bash -c so /usr/bin/time -v measures the CLI (not bash)
        # while still redirecting the command stream into its stdin.
        time_wrap "$rss_log" "$run_log" "$FLOWLOG_RUN_TIMEOUT" -- \
            bash -c 'exec "$1" -w "$2" < "$3"' _ "$bin" "$WORKERS" "$dat" || rc=$?
        t_end=$(date +%s.%N)

        if (( rc != 0 )); then
            if (( rc == 124 )); then
                log "$YELLOW" "TIMEOUT" "DDlog run $run hit ${FLOWLOG_RUN_TIMEOUT}s (see $run_log)"
            else
                log "$YELLOW" "WARN" "DDlog run $run failed (see $run_log)"
            fi
            continue
        fi

        _ddlog_record_sizes "$sizes_sidecar" "$run_log" "$dl_src"

        t=$(python3 -c "print(f'{${t_end}-${t_start}:.9f}')")
        r=$(extract_peak_rss_kb "$rss_log")
        log "$YELLOW" "TIME" "  Run $run: ${t}s, peak ${r} KiB"
        [[ "$t" =~ ^[0-9] ]] && entries="${entries:+$entries$'\n'}${t}:${run_log}"
        [[ "$r" =~ ^[0-9] ]] && rss_values+=("$r")
    done

    if [[ -z "$entries" ]]; then
        log "$RED" "FAIL" "DDlog: all $NUM_RUNS runs failed for $prog_file + $dataset_name"
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
        log "$YELLOW" "PARTIAL" "DDlog: only $n_succeeded/$NUM_RUNS succeeded for $prog_file + $dataset_name"
    fi
    log "$GREEN" "DONE" "DDlog:     $prog_file + $dataset_name (median: ${median_time}s, peak ${median_rss} KiB, runs=${n_succeeded}/${NUM_RUNS})"
}
