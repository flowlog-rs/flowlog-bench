#!/usr/bin/env bash
# scripts/lib/measure.sh — timing + memory + median helpers.
#
# One source of truth for what was previously duplicated in
# cross_engine.sh, bench_one.sh, regression.sh, and ldbc.sh.
#
# All functions are pure: no globals mutated, no logging.
# The caller passes paths in, and reads strings/numbers out.

[[ -n "${FLOWLOG_BENCH_MEASURE_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_MEASURE_LOADED=1

# /usr/bin/time -v — required everywhere because bash's builtin `time`
# does NOT support `-v` (peak RSS). Override via TIME_BIN=<path>.
TIME_BIN="${TIME_BIN:-/usr/bin/time}"

# ---------------------------------------------------------------------
# time_wrap <rss_log> <run_log> <timeout_secs> -- <cmd...>
#
# Run <cmd...> wrapped by /usr/bin/time -v (peak RSS to <rss_log>) and
# `timeout` (SIGTERM cap). Stdout+stderr go to <run_log>.
#
# Returns:  0 on success
#         124 on timeout
#         <other> on engine failure
# ---------------------------------------------------------------------
time_wrap() {
    local rss_log="$1" run_log="$2" timeout_s="$3"
    shift 3
    [[ "${1:-}" == "--" ]] && shift
    "$TIME_BIN" -v -o "$rss_log" \
        timeout "$timeout_s" "$@" \
        > "$run_log" 2>&1
}

# ---------------------------------------------------------------------
# Sidecar / log extractors. All return "N/A" on missing/unparseable.
# ---------------------------------------------------------------------

# Peak resident-set size in kibibytes from a /usr/bin/time -v sidecar.
extract_peak_rss_kb() {
    local f="$1"
    [[ -f "$f" ]] || { echo "N/A"; return; }
    local v
    v=$(awk '/Maximum resident set size/ { print $NF; exit }' "$f" 2>/dev/null) || true
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "N/A"
}

# "Elapsed (wall clock) time" from /usr/bin/time -v, integer milliseconds.
# Format: h:mm:ss (rare) or m:ss[.cc] (common).
extract_elapsed_ms() {
    local f="$1"
    [[ -f "$f" ]] || { echo "N/A"; return; }
    local v
    v=$(awk '/Elapsed \(wall clock\) time/ {
        n = split($NF, a, ":")
        s = 0
        for (i = 1; i <= n; i++) s = s * 60 + a[i]
        printf "%d", int(s * 1000 + 0.5)
        exit
    }' "$f" 2>/dev/null) || true
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "N/A"
}

# Pull the last log line matching <pattern> and convert its
# "<num><unit>" duration (s / ms / µs) to seconds.
_extract_seconds_for_pattern() {
    local log_file="$1" pattern="$2"
    [[ -f "$log_file" ]] || { echo "N/A"; return; }
    local line
    line=$(grep "$pattern" "$log_file" 2>/dev/null | tail -1) || true
    [[ -z "$line" ]] && { echo "N/A"; return; }
    python3 - "$line" <<'PY' 2>/dev/null || echo "N/A"
import re, sys
m = re.search(r"([0-9]+\.?[0-9]*)(µs|ms|s)", sys.argv[1])
if not m:
    sys.exit(1)
v, unit = float(m.group(1)), m.group(2)
if   unit == "ms":  v /= 1_000.0
elif unit == "µs": v /= 1_000_000.0
print(f"{v:.9f}")
PY
}

# Total (= "Dataflow executed in <Dur>") and load (= last "Data loaded for")
# lines emitted by both compiler-built and lib-mode binaries.
extract_total_seconds() { _extract_seconds_for_pattern "$1" "Dataflow executed"; }
extract_load_seconds()  { _extract_seconds_for_pattern "$1" "Data loaded for"; }

# ---------------------------------------------------------------------
# Arithmetic / formatting helpers.
# ---------------------------------------------------------------------

# exec = total - load (seconds), clamped >= 0. "N/A" if either is missing.
compute_exec_seconds() {
    local total="$1" load="$2"
    if [[ "$total" =~ ^[0-9] && "$load" =~ ^[0-9] ]]; then
        python3 -c "print(f'{max(${total}-${load},0):.9f}')" 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

# Numeric ratio "n/d" as a float (6 decimals). Returns "" if either
# operand isn't a number, or if the denominator is zero. Pure division —
# no "x" suffix; caller adds units / formatting.
speedup_ratio() {
    local n="$1" d="$2"
    if [[ "$n" =~ ^[0-9] && "$d" =~ ^[0-9] ]]; then
        python3 -c "print(f'{${n}/${d}:.6f}') if ${d}>0 else print('')" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# kibibytes -> mebibytes, 2 decimals; "N/A" on non-integer input.
kib_to_mib() {
    local kb="$1"
    if [[ "$kb" =~ ^[0-9]+$ ]]; then
        python3 -c "print(f'{${kb}/1024:.2f}')"
    else
        echo "N/A"
    fi
}

# ---------------------------------------------------------------------
# Median helpers.
# ---------------------------------------------------------------------

# Median over integer values (variadic). Examples:
#   median_int 1 2 3 4 5             # array spread:  median_int "${arr[@]}"
#   median_int $space_separated      # bash word-splitting on a string
# Returns "" on empty input.
median_int() {
    (( $# > 0 )) || { echo ""; return; }
    printf '%s\n' "$@" | sort -n | awk '
        { a[NR] = $1 }
        END {
            if (NR == 0)        { exit }
            else if (NR % 2)    { print a[(NR + 1) / 2] }
            else                { printf "%d", int((a[NR/2] + a[NR/2 + 1]) / 2) }
        }'
}

# Mean over integer values (variadic). Returns "" on empty input.
avg_int() {
    (( $# > 0 )) || { echo ""; return; }
    local sum=0 x
    for x in "$@"; do sum=$(( sum + x )); done
    echo $(( sum / $# ))
}

# Pick the median entry from newline-separated "<seconds>:<logpath>"
# records. With even N we deliberately return the upper-middle so the
# returned logfile is a real file (averaging two times would decouple
# the reported median from the retained log).
pick_median_entry() {
    local entries="$1"
    printf '%s\n' "$entries" | python3 -c "
import sys
pairs = [line.strip() for line in sys.stdin if line.strip()]
pairs.sort(key=lambda x: float(x.split(':', 1)[0]))
print(pairs[len(pairs) // 2])
" 2>/dev/null
}

# ---------------------------------------------------------------------
# Sidecar writer: copies the median run log to <best_log> and writes
# the three sidecar files every cross-engine consumer expects.
#
# Args: <best_log> <median_log> <median_rss_kb> <n_succeeded>
#       [extra_total_seconds]   # only set for souffle (date-bracket timing)
# ---------------------------------------------------------------------
write_engine_sidecars() {
    local best_log="$1" median_log="$2" median_rss="$3" n_succeeded="$4"
    local extra_total_s="${5:-}"

    cp "$median_log" "$best_log"
    cp "${median_log}.rss" "${best_log}.rss" 2>/dev/null || true
    echo "$median_rss"   > "${best_log}.median_rss_kb"
    echo "$n_succeeded"  > "${best_log}.n_runs_succeeded"
    if [[ -n "$extra_total_s" ]]; then
        echo "$extra_total_s" > "${best_log}.median_total_s"
    fi
}
