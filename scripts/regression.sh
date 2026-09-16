#!/usr/bin/env bash
# Compare two FlowLog refs using the same programs, datasets and worker count.
#
# Usage:
#   scripts/regression.sh [--keep-datasets] [--fresh] BASE HEAD CONFIG
#   FLOWLOG_BASE=BASE FLOWLOG_HEAD=HEAD make regression
#
# Refs accept tags, branches, commit SHAs and explicit remote refs.
# Both compilers build with their own Cargo.lock. Generated programs use the
# matching runtime, verified through Cargo metadata before measurement.
#
# Each invocation measures every pair again. --fresh removes previous results;
# otherwise run_info.txt must match before any measurements are overwritten.
# Generated sources, Cargo.lock and metadata are retained under base/generated/
# and head/generated/. Their target/ directories are removed after compilation.
#
# Metrics: median FlowLog "Dataflow executed" time and median peak RSS.
# These are independent medians; the time metric is not process wall time.
#   PERF_COMPARE_TIME_PCT    time regression threshold (default 10)
#   PERF_COMPARE_RSS_PCT     peak RSS threshold (default 20)
#   PERF_COMPARE_NUM_RUNS    successful attempts required per ref (default 5)
#   PERF_COMPARE_WORKERS     physical cores (default up to 32)
#   FLOWLOG_RUN_TIMEOUT      seconds per attempt (default 86400)
#
# Physical cores and NUMA memory are pinned by default; BENCH_NO_PIN=1 opts out.
# Datasets are removed after each pair unless --keep-datasets / KEEP_DATASETS=1.
# Output: results/regression/<base>_vs_<head>/summary.tsv and per-run logs.
# Exit: 0 pass, 1 measured regression, 2 invalid input, 3 build/measurement error.

set -euo pipefail
ORIGINAL_ARGS=("$@")

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    awk '/^set -euo pipefail/ { exit }
         NR > 1 { sub(/^# ?/, ""); print }' "$0"
    exit 0
fi

# ----------------------------------------------------------------------
# Argument parsing.
# ----------------------------------------------------------------------
KEEP_DATASETS="${KEEP_DATASETS:-0}"
FRESH=0
POSITIONAL=()
while (( $# )); do
    case "$1" in
        --keep-datasets) KEEP_DATASETS=1; shift ;;
        --fresh)         FRESH=1; shift ;;
        --)              shift; POSITIONAL+=("$@"); break ;;
        -*)              echo "ERROR: unknown flag '$1' (try --help)" >&2; exit 2 ;;
        *)               POSITIONAL+=("$1"); shift ;;
    esac
done
if [[ ${#POSITIONAL[@]} -ne 3 ]]; then
    echo "usage: $0 [--keep-datasets] [--fresh] <base_ref> <head_ref> <config_file>" >&2
    echo "       $0 --help" >&2
    exit 2
fi
BASE_SHA="${POSITIONAL[0]}"
HEAD_SHA="${POSITIONAL[1]}"
CONFIG_FILE="${POSITIONAL[2]}"
export KEEP_DATASETS

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config file not found: $CONFIG_FILE" >&2; exit 2; }
CONFIG_FILE="$(realpath "$CONFIG_FILE")"
ORIGINAL_ARGS=()
[[ "$KEEP_DATASETS" == 1 ]] && ORIGINAL_ARGS+=(--keep-datasets)
(( FRESH )) && ORIGINAL_ARGS+=(--fresh)
ORIGINAL_ARGS+=(-- "$BASE_SHA" "$HEAD_SHA" "$CONFIG_FILE")

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Shared helpers (ANSI colors, cleanup_dataset_should_clean, time_wrap +
# extractors + median helpers, engine_compiler_run).
source "${ROOT_DIR}/scripts/lib/common.sh"
source "${ROOT_DIR}/scripts/lib/affinity.sh"
source "${ROOT_DIR}/scripts/lib/datasets.sh"
source "${ROOT_DIR}/scripts/lib/measure.sh"
bench_affinity_reexec PERF_COMPARE_WORKERS "${ORIGINAL_ARGS[@]}"

PROG_DIR="${PROG_DIR:-${ROOT_DIR}/programs/oracle/flowlog}"
FACT_DIR="${FACT_DIR:-${ROOT_DIR}/facts}"
PROG_DIR="$(realpath "$PROG_DIR")"
# Preserve symlinks so the dataset cleanup safety check can still detect them.
FACT_DIR="$(realpath -m -s "$FACT_DIR")"
DATASET_URL="https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/resolve/main/dataset/csv"
TIME_BIN="${TIME_BIN:-/usr/bin/time}"
FLOWLOG_RUN_TIMEOUT="${FLOWLOG_RUN_TIMEOUT:-86400}"
export FACT_DIR TIME_BIN

TIME_PCT="${PERF_COMPARE_TIME_PCT:-10}"
RSS_PCT="${PERF_COMPARE_RSS_PCT:-20}"
NUM_RUNS="${PERF_COMPARE_NUM_RUNS:-5}"
WORKERS="${PERF_COMPARE_WORKERS:-32}"

for var in TIME_PCT RSS_PCT NUM_RUNS WORKERS; do
    val="${!var}"
    [[ "$val" =~ ^[0-9]+$ ]] \
        || { echo "ERROR: PERF_COMPARE_$var must be a non-negative integer (got: $val)" >&2; exit 2; }
done
(( NUM_RUNS > 0 && WORKERS > 0 )) || { echo "ERROR: runs and workers must be positive" >&2; exit 2; }
export LC_ALL=C

# log accepts either form so engine_compiler_run (3-arg) and our own
# 1-arg [perf-compare] callers can share the function:
#   log "<msg>"                       → [perf-compare] <msg>
#   log "<colour>" "<tag>" "<msg>..." → <colour>[<tag>]<NC> <msg>
log() {
    if (( $# >= 3 )); then
        local c="$1" t="$2"; shift 2
        printf '%s[%s]%s %s\n' "${c}" "${t}" "${NC}" "$*" >&2
    else
        printf '%s[perf-compare]%s %s\n' "${BLUE}" "${NC}" "$*" >&2
    fi
}
die() { printf '%s[ERROR]%s %s\n' "${RED}" "${NC}" "$*" >&2; exit 3; }

[[ -x "$TIME_BIN" ]] || die "GNU /usr/bin/time not found at $TIME_BIN; apt install time"

# engine_compiler_run reuses the same compile+run primitive cross_engine.sh
# uses — DRY: there's exactly one place that knows how to compile + run +
# pick a median for the flowlog compiler.
source "${ROOT_DIR}/scripts/engines/compiler.sh"

# Environment refs take precedence over positional refs for Make callers.
BASE_REF="${FLOWLOG_BASE:-$BASE_SHA}"
HEAD_REF="${FLOWLOG_HEAD:-$HEAD_SHA}"

# ----------------------------------------------------------------------
# Parse the config: one `<prog>=<dataset>` per line, blanks/comments
# skipped, trailing `[tag]` markers (a cross_engine.sh feature) stripped so
# the same files can be reused across both tools.
# ----------------------------------------------------------------------
PAIRS=()
PROGRAM_HASHES=()
declare -A ARTIFACT_KEYS=()
while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    while [[ "$line" =~ ^(.*[^[:space:]])[[:space:]]+(\[[^][]+\])[[:space:]]*$ ]]; do
        line="${BASH_REMATCH[1]}"
    done
    [[ "$line" == *=* ]] || { echo "ERROR: malformed pair (expected '<prog>=<dataset>'): $raw" >&2; exit 2; }
    prog="${line%%=*}"; ds="${line#*=}"
    [[ "$prog" =~ ^[a-zA-Z0-9_/-]+\.dl$ && "$prog" != /* && "$ds" =~ ^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$ ]] \
        || { echo "ERROR: invalid program/dataset: $line" >&2; exit 2; }
    if [[ "$prog" == */* ]]; then prog_path="$PROG_DIR/$prog"; else prog_path="$PROG_DIR/${prog%.dl}/default.dl"; fi
    [[ -f "$prog_path" ]] || { echo "ERROR: program missing: $prog_path" >&2; exit 2; }
    artifact_key="${prog%.dl}_${ds}"; artifact_key="${artifact_key//\//%}"
    [[ -z "${ARTIFACT_KEYS[$artifact_key]:-}" ]] \
        || { echo "ERROR: pairs share an artifact name: $line and ${ARTIFACT_KEYS[$artifact_key]}" >&2; exit 2; }
    ARTIFACT_KEYS[$artifact_key]="$line"
    PROGRAM_HASHES+=("$(sha256sum "$prog_path")")
    PAIRS+=("$line")
done < "$CONFIG_FILE"

(( ${#PAIRS[@]} > 0 )) || { echo "ERROR: config has no pairs: $CONFIG_FILE" >&2; exit 2; }

# Capture the command's exit status directly. Process substitution + tail used
# to mask fetch/build failures and could continue with empty or stale paths.
for side in BASE HEAD; do
    ref_var="${side}_REF"
    log "fetching + building $side: ${!ref_var}"
    resolved=$(FLOWLOG_REF="${!ref_var}" bash "${ROOT_DIR}/scripts/get_flowlog.sh") || {
        rc=$?
        [[ "$rc" == 2 ]] && exit 2
        die "get_flowlog.sh failed for $side=${!ref_var}"
    }
    IFS=$'\t' read -r full short tree <<< "$resolved"
    [[ "$full" =~ ^[0-9a-f]{40,64}$ && "$short" == "${full:0:12}" && -x "$tree/target/release/flowlog-compiler" ]] \
        || die "invalid build returned for $side"
    printf -v "${side}_FULL" '%s' "$full"
    printf -v "${side}_SHORT" '%s' "$short"
    printf -v "${side}_TREE" '%s' "$tree"
    printf -v "${side}_COMPILER_SHA256" '%s' "$(sha256sum "$tree/target/release/flowlog-compiler" | cut -d ' ' -f1)"
    toolchain=""
    if command -v rustup >/dev/null; then
        toolchain=$(cd "$tree/src" && rustup show active-toolchain) || die "cannot select toolchain"
        toolchain="${toolchain%% *}"
    fi
    printf -v "${side}_RUSTUP_TOOLCHAIN" '%s' "$toolchain"
    printf -v "${side}_TOOL_VERSIONS" '%s' "$(cd "$tree/src" && cargo --version && rustc -vV)"
done
# Prevent another job from rebuilding these cached binaries under different
# flags/toolchains while this run measures them.
exec 7>"$(dirname "$BASE_TREE")/.fetch.lock"
flock -s 7
for side in BASE HEAD; do
    tree_var="${side}_TREE"; hash_var="${side}_COMPILER_SHA256"
    [[ "$(sha256sum "${!tree_var}/target/release/flowlog-compiler" | cut -d ' ' -f1)" == "${!hash_var}" ]] \
        || die "compiler changed during preparation; use a job-specific FLOWLOG_CACHE_DIR"
done
if [[ "$BASE_FULL" == "$HEAD_FULL" ]]; then
    echo "ERROR: BASE and HEAD resolve to the same sha ($BASE_FULL); nothing to compare" >&2
    exit 2
fi

# ----------------------------------------------------------------------
# BASE and HEAD trees are populated by scripts/get_flowlog.sh above.
# Each lives at flowlog/<short_sha>/target/release/flowlog-compiler.
# ----------------------------------------------------------------------
log "config             : $CONFIG_FILE  (${#PAIRS[@]} pair(s))"
log "base sha           : $BASE_FULL  ($BASE_TREE)"
log "head sha           : $HEAD_FULL  ($HEAD_TREE)"
log "tolerances         : time +${TIME_PCT}%, peak RSS +${RSS_PCT}%"
log "bench knobs        : NUM_RUNS=$NUM_RUNS, WORKERS=$WORKERS"

# Guard the result directory before replacing any measurements.
OUT_DIR="${ROOT_DIR}/results/regression/${BASE_SHORT}_vs_${HEAD_SHORT}"
mkdir -p "$OUT_DIR"
# Keep the lock outside OUT_DIR so --fresh cannot remove a held lock.
exec 8>"${OUT_DIR}.lock"
flock -n 8 || die "another regression run is using $OUT_DIR"
SUMMARY_TSV="${OUT_DIR}/summary.tsv"

# Record the resolved commits and measurement parameters.
RUN_INFO_BENCH_ROOT="$ROOT_DIR"
RUN_INFO_RUNNER="regression.sh"
RUN_INFO_CONFIG_PATH="$CONFIG_FILE"
# The regression runner resolves two SHAs via get_flowlog.sh; record both
# explicitly. The single FLOWLOG_RESOLVED_SHA slot in run_info.sh
# becomes "n/a (see base_sha + head_sha)".
FLOWLOG_RESOLVED_SHA="n/a (A/B run — see base_sha + head_sha)"
FLOWLOG_BIN="(varies — base + head trees benched separately)"
FLOWLOG_REF="(see base_ref + head_ref)"
export RUN_INFO_BENCH_ROOT RUN_INFO_RUNNER RUN_INFO_CONFIG_PATH \
       FLOWLOG_RESOLVED_SHA FLOWLOG_BIN FLOWLOG_REF WORKERS NUM_RUNS
source "${ROOT_DIR}/scripts/lib/run_info.sh"

if (( FRESH )); then
    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"
fi
# base_short / head_short are derivable from the full SHAs (kept only
# in $OUT_DIR's path encoding), so they're excluded from the identity.
guard_run_info "$OUT_DIR" \
        "base_ref=${BASE_REF}" \
        "base_sha=${BASE_FULL}" \
        "head_ref=${HEAD_REF}" \
        "head_sha=${HEAD_FULL}" \
        "build_mode=compiler-build-dir-runtime-check" \
        "base_compiler_sha256=${BASE_COMPILER_SHA256}" \
        "head_compiler_sha256=${HEAD_COMPILER_SHA256}" \
        "base_tools_sha256=$(printf '%s' "$BASE_TOOL_VERSIONS" | sha256sum | cut -d ' ' -f1)" \
        "head_tools_sha256=$(printf '%s' "$HEAD_TOOL_VERSIONS" | sha256sum | cut -d ' ' -f1)" \
        "rustflags=${CARGO_ENCODED_RUSTFLAGS-${RUSTFLAGS:-}}" \
        "extra_fl_flags=${EXTRA_FL_FLAGS:-}" \
        "str_intern=$([[ "${FL_NO_STR_INTERN:-0}" == 1 ]] && echo off || echo on)" \
        "run_timeout=${FLOWLOG_RUN_TIMEOUT}" \
        "programs_sha256=$(printf '%s\n' "${PROGRAM_HASHES[@]}" | sha256sum | cut -d ' ' -f1)" \
        "fact_dir=${FACT_DIR}" \
        "time_pct=${TIME_PCT}" \
        "rss_pct=${RSS_PCT}" \
    || die "run parameters changed — use --fresh to replace previous results."
log "output dir         : $OUT_DIR"
# A failed new attempt must not leave a previous passing summary in place.
rm -f "$SUMMARY_TSV"
for side in base head; do
    tree_var="${side^^}_TREE"; tools_var="${side^^}_TOOL_VERSIONS"
    mkdir -p "$OUT_DIR/$side"
    cp "${!tree_var}/src/Cargo.lock" "$OUT_DIR/$side/compiler.Cargo.lock"
    printf '%s\n' "${!tools_var}" > "$OUT_DIR/$side/toolchain.txt"
done

# Run one revision; return "<median seconds> <median RSS KiB>".
bench_pair() {
    local tree="$1" prog="$2" ds="$3" sublabel="$4"
    COMPILER_BIN="${tree}/target/release/flowlog-compiler"
    # Generated crates must use the runtime from the same revision as the
    # compiler. Branch tips can contain runtime APIs that are not published
    # to crates.io yet, and mixing those versions makes codegen fail.
    FLOWLOG_RUNTIME_PATH="${tree}/src/flowlog-runtime"
    export FLOWLOG_RUNTIME_PATH
    export FLOWLOG_VERIFY_RUNTIME=1 FLOWLOG_STRICT_RUNS=1
    # Select the same toolchain in Cargo's generated-project working directory.
    local toolchain_var="${sublabel^^}_RUSTUP_TOOLCHAIN"
    if [[ -n "${!toolchain_var}" ]]; then export RUSTUP_TOOLCHAIN="${!toolchain_var}"; fi
    # Old compilers assume target/ is inside their scratch directory. Neither
    # revision may inherit an unrelated shared target directory from CI.
    unset CARGO_TARGET_DIR CARGO_BUILD_TARGET_DIR
    LOG_DIR="${OUT_DIR}/${sublabel}"
    mkdir -p "$LOG_DIR"

    [[ -x "$COMPILER_BIN" ]] \
        || { log "$RED" "FAIL" "compiler not found: $COMPILER_BIN"; return 1; }

    engine_compiler_run "$prog" "$ds" || return 1

    # Read back the medians from engine_compiler_run's sidecar layout.
    local stem; stem="$(engine_compiler_stem "$prog")"
    local best_log="${LOG_DIR}/${stem}_${ds}_compiler.log"
    local sec rss
    sec=$(extract_total_seconds "$best_log")
    rss=$(cat "${best_log}.median_rss_kb" 2>/dev/null || echo "N/A")
    [[ "$sec" =~ ^[0-9]+\.[0-9]+$ && "$rss" =~ ^[0-9]+$ ]] || return 1
    awk -v t="$sec" -v r="$rss" 'BEGIN { exit !(t > 0 && r > 0) }' || return 1
    printf '%s %s\n' "$sec" "${rss:-N/A}"
}

# ----------------------------------------------------------------------
# Iterate the pair list, collecting per-pair (b_sec, h_sec, b_kb, h_kb).
# ----------------------------------------------------------------------
declare -A B_SEC B_KB H_SEC H_KB

for pair in "${PAIRS[@]}"; do
    prog="${pair%%=*}"
    ds="${pair#*=}"
    log "pair: $pair"

    # Ensure dataset is on disk before either bench runs.
    if [[ ! -d "${FACT_DIR}/${ds}" ]]; then
        log "  fetching dataset ${ds} ..."
        dataset_ensure_zip "$ds" "${DATASET_URL}/${ds}.zip" \
            || die "dataset download/extract failed: ${ds}"
    fi

    log "  base@${BASE_SHORT} ..."
    if out=$(bench_pair "$BASE_TREE" "$prog" "$ds" base); then
        B_SEC[$pair]="${out% *}"; B_KB[$pair]="${out##* }"
    else
        log "  ${YELLOW}WARN${NC}: base bench failed for $pair"
    fi

    log "  head@${HEAD_SHORT} ..."
    if out=$(bench_pair "$HEAD_TREE" "$prog" "$ds" head); then
        H_SEC[$pair]="${out% *}"; H_KB[$pair]="${out##* }"
    else
        log "  ${YELLOW}WARN${NC}: head bench failed for $pair"
    fi

    # Cleanup after both refs have been measured (gated by --keep-datasets;
    # dies if FACT_DIR is a symlink and --keep-datasets wasn't passed).
    if dataset_cleanup "$ds"; then
        log "  cleaned ${ds}"
    else
        log "  kept ${ds} (${CLEANUP_SKIP_REASON})"
    fi
done

# ----------------------------------------------------------------------
# Summary table — verdict per pair. Successes → stdout; failures →
# stderr so extractors keyed on stdout don't pick up regression rows.
# ----------------------------------------------------------------------
ROWS=()
FAILED=0
MEASURE_FAILED=0

for pair in "${PAIRS[@]}"; do
    b_sec="${B_SEC[$pair]:-}"; h_sec="${H_SEC[$pair]:-}"
    b_kb="${B_KB[$pair]:-}";   h_kb="${H_KB[$pair]:-}"

    if [[ -z "$b_sec" || -z "$h_sec" ]]; then
        ROWS+=("${pair}|${b_sec:-N/A}|${h_sec:-N/A}|N/A|${b_kb:-N/A}|${h_kb:-N/A}|N/A|MEASURE_FAIL")
        MEASURE_FAILED=1
        continue
    fi

    # % deltas + verdict in python (avoids bashism for floats).
    eval "$(python3 - "$b_sec" "$h_sec" "$b_kb" "$h_kb" "$TIME_PCT" "$RSS_PCT" <<'PY'
import sys
b_sec, h_sec, b_kb, h_kb, tol_t, tol_r = sys.argv[1:]
b_sec_f, h_sec_f = float(b_sec), float(h_sec)
time_pct = (h_sec_f - b_sec_f) / b_sec_f * 100.0 if b_sec_f > 0 else 0.0
fail = 1 if time_pct > float(tol_t) else 0
if b_kb in ("N/A", "") or h_kb in ("N/A", ""):
    rss_pct_str = "NA"
else:
    b_kb_i, h_kb_i = int(b_kb), int(h_kb)
    rss_pct = (h_kb_i - b_kb_i) / b_kb_i * 100.0 if b_kb_i > 0 else 0.0
    rss_pct_str = f"{rss_pct:+.2f}"
    if rss_pct > float(tol_r):
        fail = 1
print(f'TIME_PCT_VAL="{time_pct:+.2f}"')
print(f'RSS_PCT_VAL="{rss_pct_str}"')
print(f'FAIL_FLAG="{fail}"')
PY
)"

    VERDICT="OK"
    if [[ "$FAIL_FLAG" = "1" ]]; then
        VERDICT="FAIL"
        FAILED=1
    fi
    ROWS+=("${pair}|${b_sec}|${h_sec}|${TIME_PCT_VAL}|${b_kb}|${h_kb}|${RSS_PCT_VAL}|${VERDICT}")
done

SINK=1
(( FAILED || MEASURE_FAILED )) && SINK=2

# Persist the verdict beside the logs and run parameters.
{
    printf 'pair\tbase_sec\thead_sec\ttime_pct\tbase_kb\thead_kb\trss_pct\tverdict\n'
    for row in "${ROWS[@]}"; do
        IFS='|' read -r pair bs hs tp bk hk rp v <<< "$row"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$pair" "$bs" "$hs" "$tp" "$bk" "$hk" "$rp" "$v"
    done
} > "$SUMMARY_TSV"

{
    printf '\n=== perf-compare: base=%s head=%s ===\n' "${BASE_FULL:0:12}" "${HEAD_FULL:0:12}"
    printf '    workers=%s  runs/sha=%s  thresholds: time +%s%%  rss +%s%%\n' \
        "$WORKERS" "$NUM_RUNS" "$TIME_PCT" "$RSS_PCT"
    printf '    artifacts: %s\n\n' "$OUT_DIR"
    printf '%-46s %12s %12s %9s %12s %12s %9s  %s\n' \
        pair base_time head_time time% base_rss head_rss rss% verdict
    printf '%-46s %12s %12s %9s %12s %12s %9s  %s\n' \
        ---- --------- --------- ----- -------- -------- ---- -------
    for row in "${ROWS[@]}"; do
        IFS='|' read -r pair bs hs tp bk hk rp v <<< "$row"
        color="$GREEN"; [[ "$v" != "OK" ]] && color="$RED"
        printf '%-46s %12s %12s %9s %12s %12s %9s  %s%s%s\n' \
            "$pair" "$bs" "$hs" "$tp" "$bk" "$hk" "$rp" "$color" "$v" "$NC"
    done
    printf '\n'
    if (( MEASURE_FAILED )); then
        printf '%sMEASUREMENT FAILED%s — incomplete or invalid measurements; no passing verdict\n' "$RED" "$NC"
    elif (( FAILED )); then
        printf '%sREGRESSION%s — at least one pair exceeded a tolerance\n' "$RED" "$NC"
    else
        printf '%sALL OK%s — every pair within tolerances\n' "$GREEN" "$NC"
    fi
    printf '\n'
} >&$SINK

(( MEASURE_FAILED )) && exit 3
exit $FAILED
