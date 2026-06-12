#!/usr/bin/env bash
# scripts/precompile_engines.sh — warm the souffle/ddlog compile caches in
# parallel before a long cross_engine.sh sweep, so the sweep's serial
# per-pair compile step is a cache hit instead of hours of dead wall-clock.
#
# Uses the SAME cache locations and keys the engine adapters use
# ($LOG_DIR/sf-bin/<stem>-w$WORKERS[-prof], $LOG_DIR/ddlog-bin/<stem>_ddlog),
# so cross_engine.sh picks the binaries up via its normal mtime checks.
#
#   WORKERS=32 bash scripts/precompile_engines.sh tc sg reach ...
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/common.sh"
log() { local c="$1" t="$2"; shift 2; echo "[${t}] $*"; }
die() { log "" "ERROR" "$*"; exit 1; }

# Compile-path env only (the run-time knobs NUM_RUNS / FLOWLOG_RUN_TIMEOUT /
# TIME_BIN are never reached by the _*_compile helpers). Defaults mirror
# cross_engine.sh — keep the two in sync if its paths change.
export WORKERS="${WORKERS:?set WORKERS to the sweep worker count}"
FACT_DIR="${ROOT_DIR}/facts"
LOG_DIR="${ROOT_DIR}/results/benchmark"
SOUFFLE_BIN="${SOUFFLE_BIN:-/usr/bin/souffle}"
SOUFFLE_PROG_DIR="${ROOT_DIR}/programs/oracle/souffle"
DDLOG_HOME="${DDLOG_HOME:-$HOME/ddlog}"
DDLOG_PROG_DIR="${ROOT_DIR}/programs/oracle/ddlog"
DDLOG_RUST="${DDLOG_RUST:-1.76}"
DDLOG_BUILD_DIR="${LOG_DIR}/ddlog-bin"

source "${ROOT_DIR}/scripts/engines/souffle.sh"
source "${ROOT_DIR}/scripts/engines/ddlog.sh"
mkdir -p "${LOG_DIR}/sf-bin" "$DDLOG_BUILD_DIR"

STEMS=("$@")
(( ${#STEMS[@]} )) || die "usage: WORKERS=N $0 <stem> [stem ...]"

# DDlog first (the expensive ones: ddlog -i codegen + cargo +1.76 build).
for s in "${STEMS[@]}"; do
    [[ -f "${DDLOG_PROG_DIR}/${s}.dl" ]] || { echo "[skip] ddlog $s (no .dl)"; continue; }
    (
        if _ddlog_compile "$s" "${DDLOG_PROG_DIR}/${s}.dl" > /dev/null; then
            echo "[ok] ddlog $s"
        else
            echo "[FAIL] ddlog $s (see ${DDLOG_BUILD_DIR}/${s}_ddlog.*.log)"
        fi
    ) &
    while (( $(jobs -r | wc -l) >= 5 )); do wait -n; done
done

# Souffle: main + profiled binary per stem (the split pass needs -prof too).
for s in "${STEMS[@]}"; do
    src="${SOUFFLE_PROG_DIR}/${s}.dl"
    [[ -f "$src" ]] || { echo "[skip] souffle $s (no .dl)"; continue; }
    (
        if _souffle_compile "$s" "$src" "$FACT_DIR" > /dev/null; then
            echo "[ok] souffle $s"
        else
            echo "[FAIL] souffle $s"
        fi
        prof_bin="${LOG_DIR}/sf-bin/${s}-w${WORKERS}-prof"
        if [[ ! -x "$prof_bin" || "$src" -nt "$prof_bin" ]]; then
            if "$SOUFFLE_BIN" -o "$prof_bin" -p "${prof_bin}.compile-profile" \
                    -j "$WORKERS" -F "$FACT_DIR" "$src" \
                    > "${prof_bin}.compile.log" 2>&1; then
                echo "[ok] souffle $s (prof)"
            else
                echo "[FAIL] souffle $s (prof)"
            fi
        fi
    ) &
    while (( $(jobs -r | wc -l) >= 8 )); do wait -n; done
done

wait
echo "PRECOMPILE-DONE"
