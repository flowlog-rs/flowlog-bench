#!/usr/bin/env bash
# =============================================================================
# scripts/lib/measure.sh — timing + memory + median + sidecar helpers.
# =============================================================================
#
# Pure helpers (no globals, no logging) for parsing /usr/bin/time -v
# sidecars + engine logs and computing medians, ratios, MiB.
#
# Usage:
#     source "${ROOT_DIR}/scripts/lib/measure.sh"
#     time_wrap rss.log run.log 60 -- ./prog       # run + capture
#     rss=$(extract_peak_rss_kb rss.log)            # KiB | "N/A"
#     sec=$(extract_total_seconds run.log)          # float | "N/A"
#     med=$(median_int "${times[@]}")
# =============================================================================

[[ -n "${FLOWLOG_BENCH_MEASURE_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_MEASURE_LOADED=1

# /usr/bin/time -v required for peak RSS; override via TIME_BIN=<path>.
TIME_BIN="${TIME_BIN:-/usr/bin/time}"

# =============================================================================
# Command wrapping
# =============================================================================

# Run <cmd> under time -v + timeout. RSS to <rss_log>, output to <run_log>.
# Usage:    time_wrap <rss_log> <run_log> <timeout_secs> [--] <cmd...>
# Returns:  0 ok | 124 timeout | other = command failure.
time_wrap() {
    local rss_log="$1" run_log="$2" timeout_s="$3"
    shift 3
    [[ "${1:-}" == "--" ]] && shift
    "$TIME_BIN" -v -o "$rss_log" \
        timeout "$timeout_s" "$@" \
        > "$run_log" 2>&1
}

# =============================================================================
# Sidecar / log extractors. All return "N/A" on missing/unparseable.
# =============================================================================

# Peak RSS (KiB) from a time -v sidecar.
extract_peak_rss_kb() {
    local f="$1" v
    [[ -f "$f" ]] || { echo "N/A"; return; }
    v=$(awk '/Maximum resident set size/ { print $NF; exit }' "$f" 2>/dev/null) || true
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "N/A"
}

# Wall-clock time (ms) from a time -v sidecar; parses h:mm:ss or m:ss[.cc].
extract_elapsed_ms() {
    local f="$1" v
    [[ -f "$f" ]] || { echo "N/A"; return; }
    v=$(awk '/Elapsed \(wall clock\) time/ {
        n = split($NF, a, ":")
        s = 0
        for (i = 1; i <= n; i++) s = s * 60 + a[i]
        printf "%d", int(s * 1000 + 0.5)
        exit
    }' "$f" 2>/dev/null) || true
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "N/A"
}

# Last line matching <pattern>: convert trailing "<num>(s|ms|µs)" to
# seconds (9 decimals). Python because µs is multi-byte (locale-stable).
_extract_seconds_for_pattern() {
    local log_file="$1" pattern="$2" line
    [[ -f "$log_file" ]] || { echo "N/A"; return; }
    line=$(grep "$pattern" "$log_file" 2>/dev/null | tail -1) || true
    [[ -z "$line" ]] && { echo "N/A"; return; }
    python3 - "$line" <<'PY' 2>/dev/null || echo "N/A"
import re, sys
m = re.search(r"([0-9]+\.?[0-9]*)(µs|ms|s)", sys.argv[1])
if not m:
    sys.exit(1)
v, unit = float(m.group(1)), m.group(2)
if   unit == "ms": v /= 1_000.0
elif unit == "µs": v /= 1_000_000.0
print(f"{v:.9f}")
PY
}

# Engines emit "Dataflow executed in <Dur>" once and "Data loaded for
# <name>: <Dur>" per input (last wins). <Dur> is "<num>(s|ms|µs)".
extract_total_seconds() { _extract_seconds_for_pattern "$1" "Dataflow executed"; }
extract_load_seconds()  { _extract_seconds_for_pattern "$1" "Data loaded for"; }

# =============================================================================
# Arithmetic / formatting
# =============================================================================

# exec = max(total - load, 0), in seconds. "N/A" if either input is missing.
compute_exec_seconds() {
    local t="$1" l="$2"
    [[ "$t" =~ ^[0-9] && "$l" =~ ^[0-9] ]] \
        || { echo "N/A"; return; }
    awk -v t="$t" -v l="$l" 'BEGIN {
        d = t - l; if (d < 0) d = 0; printf "%.9f", d
    }'
}

# Ratio n/d (6 decimals). "" on bad input or d=0; caller adds "x" suffix.
speedup_ratio() {
    local n="$1" d="$2"
    [[ "$n" =~ ^[0-9] && "$d" =~ ^[0-9] ]] \
        || { echo ""; return; }
    awk -v n="$n" -v d="$d" 'BEGIN {
        if (d > 0) printf "%.6f", n / d
    }'
}

# KiB -> MiB (2 decimals); "N/A" on non-integer input.
kib_to_mib() {
    local kb="$1"
    [[ "$kb" =~ ^[0-9]+$ ]] \
        || { echo "N/A"; return; }
    awk -v kb="$kb" 'BEGIN { printf "%.2f", kb / 1024 }'
}

# =============================================================================
# Statistics
# =============================================================================

# Median of integer args (variadic). "" on empty input.
# Usage:  median_int 1 2 3 4 5
#         median_int "${arr[@]}"
median_int() {
    (( $# > 0 )) || { echo ""; return; }
    printf '%s\n' "$@" | sort -n | awk '
        { a[NR] = $1 }
        END {
            if      (NR == 0)     { exit }
            else if (NR % 2)      { print a[(NR + 1) / 2] }
            else                  { printf "%d", int((a[NR/2] + a[NR/2 + 1]) / 2) }
        }'
}

# Mean of integer args (truncating, variadic). "" on empty input.
avg_int() {
    (( $# > 0 )) || { echo ""; return; }
    local sum=0 x
    for x in "$@"; do sum=$(( sum + x )); done
    echo $(( sum / $# ))
}

# Pick the median "<seconds>:<logpath>" record (newline-separated).
# Even N returns upper-middle so the kept logfile is a real run on disk.
pick_median_entry() {
    local entries="$1"
    printf '%s\n' "$entries" | python3 -c "
import sys
pairs = [line.strip() for line in sys.stdin if line.strip()]
pairs.sort(key=lambda x: float(x.split(':', 1)[0]))
print(pairs[len(pairs) // 2])
" 2>/dev/null
}

# =============================================================================
# Sidecar writer
# =============================================================================

# Copy <median_log> to <best_log> and write the sidecars consumers read:
#   .median_rss_kb        peak RSS for the median run
#   .n_runs_succeeded     samples kept out of N attempts
#   .median_total_s       souffle only (date-bracketed timing)
# Usage:  write_engine_sidecars <best_log> <median_log> <rss_kb> <n_ok> [total_s]
write_engine_sidecars() {
    local best_log="$1" median_log="$2" median_rss="$3" n_succeeded="$4"
    local extra_total_s="${5:-}"

    cp "$median_log" "$best_log"
    cp "${median_log}.rss" "${best_log}.rss" 2>/dev/null || true
    echo "$median_rss"  > "${best_log}.median_rss_kb"
    echo "$n_succeeded" > "${best_log}.n_runs_succeeded"
    if [[ -n "$extra_total_s" ]]; then
        echo "$extra_total_s" > "${best_log}.median_total_s"
    fi
}
