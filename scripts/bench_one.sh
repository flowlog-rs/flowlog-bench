#!/usr/bin/env bash
# scripts/bench_one.sh — single (program, dataset) lib-mode benchmark.
#
# Used by the agentic perf gate and by regression.sh. Builds the lib
# runner crate for the given pair, runs it NUM_RUNS times, prints two
# stable contract lines on stdout (only):
#
#     elapsed_seconds <median> <min> <max> <runs> <workers>
#     peak_rss_kb     <median> <min> <max> <runs> <workers>
#
# Time is in seconds with 9 decimal digits; memory is in kibibytes
# from /usr/bin/time -v's "Maximum resident set size".
#
# *Fail-closed*: any single run failure aborts the whole call. A perf
# gate that quietly drops failed runs and reports the median of the
# survivors masks flakiness exactly when the regression detector is
# needed most. Use cross_engine.sh if partial-success semantics are
# desired.
#
# All log/build output is on stderr so stdout stays clean for extractors.
#
# Usage:
#   bash scripts/bench_one.sh <prog_rel> <dataset_name>
#
# <prog_rel> is resolved against PROG_DIR (default
# programs/micro/flowlog/). Leading `programs/micro/flowlog/` or `example/`
# prefixes are stripped if present.
#
# Environment overrides:
#   WORKERS         worker thread count (default: 1)
#   NUM_RUNS        timed runs per call (default: 3)
#   QUIET           if 1, suppress per-run progress lines on stderr
#   PROG_DIR        directory holding the .dl programs
#                   (default: ROOT_DIR/programs/micro/flowlog)
#   FLOWLOG_SRC_DIR flowlog source tree for the lib runner's Cargo
#                   path-dep on crates/flowlog-build
#                   (default: ROOT_DIR/flowlog/main/src)
#   TIME_BIN        GNU /usr/bin/time location (default: /usr/bin/time)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Branded logging (matches engines/* expectations) ---------------------
source "${ROOT_DIR}/scripts/lib/common.sh"
log() {
    [[ "${QUIET:-0}" = "1" ]] && return 0
    local _c="${1:-}" tag="${2:-LOG}"
    shift 2 || true
    printf '[%s] %s\n' "$tag" "$*" >&2
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- Paths + knobs --------------------------------------------------------
PROG_DIR="${PROG_DIR:-${ROOT_DIR}/programs/micro/flowlog}"
FACT_DIR="${ROOT_DIR}/facts"
FLOWLOG_SRC_DIR="${FLOWLOG_SRC_DIR:-${ROOT_DIR}/flowlog/main/src}"
export FLOWLOG_SRC_DIR

LIB_BENCH_RUNNER_DIR="${ROOT_DIR}/results/bench-lib/runner"
LIB_BENCH_BIN="${LIB_BENCH_RUNNER_DIR}/target/release/flowlog_bench_lib"
LIB_BENCH_SIP=0
LIB_BENCH_STR_INTERN=0

WORKERS="${WORKERS:-1}"
NUM_RUNS="${NUM_RUNS:-3}"

# /usr/bin/time -v is required (peak RSS); bash builtin doesn't support -v.
TIME_BIN="${TIME_BIN:-/usr/bin/time}"
[[ -x "$TIME_BIN" ]] || die "GNU /usr/bin/time not found (apt install time); set TIME_BIN=<path>"

# --- Args -----------------------------------------------------------------
[[ $# -eq 2 ]] || die "usage: $0 <prog.dl> <dataset>"
PROG_REL="${1#programs/micro/flowlog/}"; PROG_REL="${PROG_REL#example/}"
DATASET_NAME="${2#facts/}"

PROG_PATH="${PROG_DIR}/${PROG_REL}"
DATASET_PATH="${FACT_DIR}/${DATASET_NAME}"
[[ -f "$PROG_PATH" ]]    || die "program not found: $PROG_PATH"
[[ -d "$DATASET_PATH" ]] || die "dataset dir not found: $DATASET_PATH"

PROG_FILE="$(basename "$PROG_PATH")"
log "" "BENCH" "${PROG_FILE} + ${DATASET_NAME} (workers=${WORKERS}, runs=${NUM_RUNS})"

# --- Build the lib runner crate for this pair ----------------------------
source "${ROOT_DIR}/scripts/lib/runner.sh"
mkdir -p "$LIB_BENCH_RUNNER_DIR"
bench_lib_ensure_crate

PAIRS_RAW="$(bench_lib_discover_csvs "$PROG_PATH" "$(realpath "$DATASET_PATH")")"
[[ -n "$PAIRS_RAW" ]] || die "no CSVs discovered for $PROG_FILE under $DATASET_PATH"

cp "$PROG_PATH" "${LIB_BENCH_RUNNER_DIR}/program.dl"
bench_lib_write_build_rs
bench_lib_write_main_rs "${LIB_BENCH_RUNNER_DIR}/program.dl" \
    "$(printf '%s' "$PAIRS_RAW" | tr '\n' ' ')" \
    || die "main.rs synthesis failed for $PROG_FILE"

log "" "BUILD" "cargo build --release --quiet"
(cd "$LIB_BENCH_RUNNER_DIR" && cargo build --release --quiet >&2) \
    || die "cargo build failed for $PROG_FILE"
[[ -x "$LIB_BENCH_BIN" ]] || die "lib bench binary not found: $LIB_BENCH_BIN"

# --- Build env-var array: FLOWLOG_CSV_<REL>=<abspath> --------------------
declare -a CSV_ENVS=()
while IFS= read -r LINE; do
    [[ -n "$LINE" ]] || continue
    REL="${LINE%%=*}"
    CSV_ENVS+=("FLOWLOG_CSV_${REL^^}=${LINE#*=}")
done <<< "$PAIRS_RAW"

# --- Run NUM_RUNS times, fail-closed -------------------------------------
source "${ROOT_DIR}/scripts/lib/measure.sh"

RUN_LOG_DIR="${LIB_BENCH_RUNNER_DIR}/.bench-logs"
mkdir -p "$RUN_LOG_DIR"

TIMES=()
RSS_KB=()
for run in $(seq 1 "$NUM_RUNS"); do
    RUN_LOG="${RUN_LOG_DIR}/run${run}.log"
    RSS_LOG="${RUN_LOG_DIR}/run${run}.rss"

    # NOTE: time_wrap doesn't take a timeout because bench_one is the
    # smallest-possible signal — the caller (regression.sh) decides how
    # long to wait. We pass an absurdly large value so timeout is a no-op.
    if ! time_wrap "$RSS_LOG" "$RUN_LOG" 86400 -- \
            env "${CSV_ENVS[@]}" "WORKERS=$WORKERS" "$LIB_BENCH_BIN"; then
        die "run $run failed (see $RUN_LOG); failing closed"
    fi

    SEC=$(extract_total_seconds "$RUN_LOG")
    RSS=$(extract_peak_rss_kb   "$RSS_LOG")
    [[ "$SEC" =~ ^[0-9] ]] || { log "" "WARN" "run $run: no timing line"; continue; }

    TIMES+=("$SEC")
    if [[ "$RSS" =~ ^[0-9]+$ ]]; then
        RSS_KB+=("$RSS")
        log "" "RUN" "  run $run: ${SEC}s, peak ${RSS} KiB"
    else
        log "" "RUN" "  run $run: ${SEC}s (rss N/A)"
    fi
done

[[ ${#TIMES[@]} -gt 0 ]] || die "all $NUM_RUNS runs failed"

# --- Emit the two stable contract lines on stdout ------------------------
python3 - "${TIMES[@]}" "--rss" "${RSS_KB[@]}" "--workers" "$WORKERS" <<'PY'
import sys
argv = sys.argv[1:]
sep_rss = argv.index("--rss")
sep_w   = argv.index("--workers")
times   = sorted(float(x) for x in argv[:sep_rss])
rss     = sorted(int(x)   for x in argv[sep_rss + 1 : sep_w])
workers = argv[sep_w + 1]

def med(xs):
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

n_t = len(times)
print(f"elapsed_seconds {med(times):.9f} {times[0]:.9f} {times[-1]:.9f} {n_t} {workers}")

if rss:
    n_r = len(rss)
    print(f"peak_rss_kb {int(round(med(rss)))} {rss[0]} {rss[-1]} {n_r} {workers}")
else:
    print(f"peak_rss_kb N/A N/A N/A 0 {workers}")
PY
