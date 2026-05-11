#!/usr/bin/env bash
# =============================================================================
# scripts/cross_joinorder.sh — sweep all join-order variants per program.
# =============================================================================
#
# For every (program, dataset) pair listed in the config, iterate every
# variant under programs/oracle/flowlog/<stem>/ (default.dl, ablation_*,
# sample_*, variant_*), run flowlog-compiler NUM_RUNS times per variant,
# and write a CSV of (Variant, Kind, Total_s, PeakRss_MB, vs_Default,
# RunsSucceeded). A semantic-preservation gate flags any variant whose
# per-relation output sizes diverge from default.dl's.
#
# Variants are produced by `scripts/gen_joinorder_variants.py` ahead of
# time; this script doesn't generate them.
#
# Usage:
#   bash scripts/cross_joinorder.sh [FLAGS] [config_file]
#   make cross-joinorder
#
# Flags:
#   --target=<stem:ds>    sweep only the named pair.
#   --fresh               wipe results/joinorder/ first.
#   --keep-datasets       skip dataset cleanup between pairs (required if
#                         FACT_DIR is a symlink).
#   -h, --help            print this header.
#
# Environment knobs (same semantics as cross_engine.sh):
#   WORKERS, NUM_RUNS, FLOWLOG_RUN_TIMEOUT, FLOWLOG_BIN,
#   FLOWLOG_RESOLVED_SHA, TIME_BIN.
# =============================================================================

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

source "${ROOT_DIR}/scripts/lib/common.sh"
log() { local c="$1" t="$2"; shift 2; echo -e "${c}[${t}]${NC} $*" >&2; }
die() { log "$RED" "ERROR" "$*"; exit 1; }

# ---- argv ---------------------------------------------------------------
FRESH=0
TARGET_FILTER=""
KEEP_DATASETS=0
POSITIONAL_ARGS=()
while (( $# )); do
    case "$1" in
        -h|--help)
            awk '/^# =+$/ { sep++; next }
                 sep==1 || sep==2 { sub(/^# ?/, ""); print }
                 sep>=3 { exit }' "$0"
            exit 0 ;;
        --fresh)         FRESH=1; shift ;;
        --target=*)      TARGET_FILTER="${1#--target=}"; shift ;;
        --target)        TARGET_FILTER="$2"; shift 2 ;;
        --keep-datasets) KEEP_DATASETS=1; shift ;;
        --)              shift; POSITIONAL_ARGS+=("$@"); break ;;
        -*)              die "Unknown option: $1 (try --help)" ;;
        *)               POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done
export KEEP_DATASETS

CONFIG_FILE="${POSITIONAL_ARGS[0]:-${ROOT_DIR}/config/default.txt}"
[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

# ---- pre-flight ---------------------------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || die "required command not found: $1${2:+ — $2}"
}
require_cmd python3 "median + summary math"
require_cmd wget    "needed to download datasets if not cached"
require_cmd unzip   "needed to extract dataset zips"

TIME_BIN="${TIME_BIN:-/usr/bin/time}"
[[ -x "$TIME_BIN" ]] || die "GNU /usr/bin/time not found at $TIME_BIN"

_NPROC=$(nproc 2>/dev/null || echo 64)
[[ "$_NPROC" =~ ^[0-9]+$ ]] && (( _NPROC > 0 )) || _NPROC=64
_DEFAULT_WORKERS=$(( _NPROC < 64 ? _NPROC : 64 ))
WORKERS="${WORKERS:-$_DEFAULT_WORKERS}"
[[ "$WORKERS" =~ ^[0-9]+$ ]] && (( WORKERS > 0 )) \
    || die "WORKERS must be a positive integer, got: $WORKERS"

NUM_RUNS="${NUM_RUNS:-3}"
# Tighter than cross_engine.sh's 1800s default: with hundreds of variants
# (galen=27, cvc5/z3=147 each), a stuck variant must not stall the sweep.
# Override on the command line if a slow program needs more head-room.
FLOWLOG_RUN_TIMEOUT="${FLOWLOG_RUN_TIMEOUT:-600}"

# ---- paths --------------------------------------------------------------
PROG_DIR="${PROG_DIR:-${ROOT_DIR}/programs/oracle/flowlog}"
FACT_DIR="${ROOT_DIR}/facts"
LOG_DIR="${ROOT_DIR}/results/joinorder"

COMPILER_BIN="${FLOWLOG_BIN:-${ROOT_DIR}/flowlog/main/target/release/flowlog-compiler}"
FLOWLOG_BIN="$COMPILER_BIN"
DATASET_URL="https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/resolve/main/dataset/csv"

readonly PAIR_CSV_HEADER="Variant,Kind,Signature,Total_s,PeakRss_MB,RunsSucceeded,vs_Default,SemanticPreserve"

export FLOWLOG_BIN PROG_DIR FACT_DIR LOG_DIR COMPILER_BIN \
       WORKERS NUM_RUNS FLOWLOG_RUN_TIMEOUT TIME_BIN

# ---- libs ---------------------------------------------------------------
source "${ROOT_DIR}/scripts/lib/measure.sh"
source "${ROOT_DIR}/scripts/lib/datasets.sh"

# ---- config parsing -----------------------------------------------------
parse_config_line() {
    local raw="$1"
    local line="${raw%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && return 1
    # Strip per-pair tags `[interp:skip]` etc — the joinorder runner
    # ignores them (only the compiler is exercised).
    while [[ "$line" =~ ^(.*[^[:space:]])[[:space:]]+\[[^][]+\][[:space:]]*$ ]]; do
        line="${BASH_REMATCH[1]}"
    done
    IFS='=' read -r PROG_NAME DATASET_NAME <<< "$line"
    PROG_NAME="$(trim "${PROG_NAME:-}")"
    DATASET_NAME="$(trim "${DATASET_NAME:-}")"
    [[ -z "$PROG_NAME" || -z "$DATASET_NAME" ]] && return 1
    [[ "$PROG_NAME" == "test.dl" ]] && return 1
    return 0
}

# ---- dataset cache ------------------------------------------------------
setup_dataset_for_pair() {
    local name="$1"
    if [[ -d "${FACT_DIR}/${name}" ]]; then
        log "$GREEN" "FOUND" "Dataset $name"
        return 0
    fi
    log "$CYAN" "DOWNLOAD" "${name}.zip -> /dev/shm (tmpfs)"
    if ! dataset_ensure_zip "$name" "${DATASET_URL}/${name}.zip"; then
        die "Download/extract failed: $name"
    fi
}
cleanup_dataset_for_pair() {
    local name="$1"
    if dataset_cleanup "$name"; then
        log "$YELLOW" "CLEANUP" "$name"
    fi
}

# ---- per-variant runner -------------------------------------------------
# Compile + run a single variant NUM_RUNS times; emit median total time +
# peak RSS + per-relation sizes sidecar to the LOG_DIR. Returns 0 on
# success, 1 on all-runs-failed.
run_variant() {
    local stem="$1" dataset="$2" variant_path="$3"
    local variant_name; variant_name="$(basename "$variant_path" .dl)"

    local fact_path; fact_path="$(realpath "${FACT_DIR}/${dataset}")"
    local pair_log_dir="${LOG_DIR}/${stem}_${dataset}"
    local bin_dir="${pair_log_dir}/.bin"
    local binary="${bin_dir}/${variant_name}"
    local var_log_dir="${pair_log_dir}/${variant_name}"
    local best_log="${pair_log_dir}/${variant_name}.log"
    mkdir -p "$bin_dir" "$var_log_dir"

    local compile_log="${var_log_dir}/compile.log"
    rm -f "$binary"
    if ! "$COMPILER_BIN" "$variant_path" \
            -F "$fact_path" \
            -o "$binary" \
            --mode datalog-batch \
            > "$compile_log" 2>&1; then
        log "$RED" "FAIL-COMPILE" "$variant_name (see $compile_log)"
        return 1
    fi
    [[ -x "$binary" ]] || { log "$RED" "FAIL-COMPILE" "$variant_name (no binary)"; return 1; }

    # Run NUM_RUNS times. Variants are deterministic, so if the first
    # attempt times out, later attempts will too — short-circuit to avoid
    # burning NUM_RUNS × FLOWLOG_RUN_TIMEOUT on a single bad variant.
    local entries=""
    local -a rss_values=()
    local run rc t r run_log rss_log
    local fatal_timeout=0
    local timeout_rss="N/A"
    for run in $(seq 1 "$NUM_RUNS"); do
        run_log="${var_log_dir}/run${run}.log"
        rss_log="${run_log}.rss"
        rc=0
        time_wrap "$rss_log" "$run_log" "$FLOWLOG_RUN_TIMEOUT" -- \
            "$binary" -w "$WORKERS" || rc=$?
        if (( rc != 0 )); then
            if (( rc == 124 )); then
                # /usr/bin/time -v records peak RSS even when its child is
                # SIGTERM'd by `timeout`, so we still get a useful memory
                # data point on a timed-out variant.
                local r_to; r_to=$(extract_peak_rss_kb "$rss_log")
                [[ "$r_to" =~ ^[0-9]+$ ]] && timeout_rss="$r_to"
                log "$YELLOW" "TIMEOUT" "${variant_name} run $run/$NUM_RUNS (peak ${r_to} KiB) — bailing out (deterministic)"
                fatal_timeout=1
                break
            else
                log "$YELLOW" "WARN" "${variant_name} run $run/$NUM_RUNS failed"
            fi
            continue
        fi
        t=$(extract_total_seconds "$run_log")
        r=$(extract_peak_rss_kb   "$rss_log")
        [[ "$t" =~ ^[0-9] ]] && entries="${entries:+$entries$'\n'}${t}:${run_log}"
        [[ "$r" =~ ^[0-9] ]] && rss_values+=("$r")
    done
    rm -f "$binary"

    if [[ -z "$entries" ]]; then
        if (( fatal_timeout )); then
            log "$RED" "TIMEOUT" "${variant_name}: timed out after ${FLOWLOG_RUN_TIMEOUT}s"
            # Stash the timeout-time RSS so the caller can record it.
            echo "$timeout_rss" > "${best_log}.timeout_rss_kb"
            return 2
        fi
        log "$RED" "FAIL" "${variant_name}: all $NUM_RUNS runs failed"
        return 1
    fi

    local median_entry median_time median_log median_rss n_succeeded
    median_entry=$(pick_median_entry "$entries")
    median_time="${median_entry%%:*}"
    median_log="${median_entry#*:}"
    median_rss=$(median_int "${rss_values[@]}")
    n_succeeded=$(echo "$entries" | wc -w)

    write_engine_sidecars "$best_log" "$median_log" "$median_rss" "$n_succeeded"

    # Per-relation sizes sidecar (used by semantic-preservation gate)
    grep -oE '\[size\]\[[^]]+\] t=\(\) size=[0-9]+' "$median_log" 2>/dev/null \
        | sed -E 's/^\[size\]\[([^]]+)\] t=\(\) size=([0-9]+)$/\1\t\2/' \
        | LC_ALL=C sort -u \
        > "${best_log}.sizes" || true

    log "$GREEN" "DONE" "${variant_name}: median ${median_time}s, peak ${median_rss} KiB, runs=${n_succeeded}/${NUM_RUNS}"
    echo "$median_time $median_rss $n_succeeded" > "${best_log}.summary"
}

# ---- semantic-preservation check ----------------------------------------
sizes_match_default() {
    local default_sizes="$1" variant_sizes="$2"
    [[ -s "$default_sizes" && -s "$variant_sizes" ]] || return 0  # missing = treat as ok
    diff -q "$default_sizes" "$variant_sizes" >/dev/null 2>&1
}

# ---- per-pair driver ----------------------------------------------------
run_pair() {
    local prog_name="$1" dataset="$2"
    local prog_file stem
    prog_file="$(basename "$prog_name")"
    stem="${prog_file%.*}"

    local stem_dir="${PROG_DIR}/${stem}"
    [[ -d "$stem_dir" ]] || die "Program dir not found: $stem_dir"
    [[ -f "$stem_dir/default.dl" ]] || die "Missing default.dl in $stem_dir"

    local manifest="${stem_dir}/manifest.csv"
    [[ -f "$manifest" ]] \
        || die "Missing manifest.csv in $stem_dir — run scripts/gen_joinorder_variants.py first"

    setup_dataset_for_pair "$dataset"

    local pair_log_dir="${LOG_DIR}/${stem}_${dataset}"
    mkdir -p "$pair_log_dir"

    local pair_csv="${LOG_DIR}/${stem}_${dataset}.csv"
    if [[ ! -s "$pair_csv" ]]; then
        echo "$PAIR_CSV_HEADER" > "$pair_csv"
    fi

    # Run default first so we have its sizes for cross-checks.
    local default_total=""
    local default_sizes="${pair_log_dir}/default.log.sizes"

    # Read manifest via Python — csv module handles the quoted-comma
    # signatures correctly where bash IFS=, can't. `default.dl` is
    # hoisted to the front so its size sidecar is on disk before any
    # other variant tries to cross-check against it.
    local manifest_tsv; manifest_tsv=$(python3 - "$manifest" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
default = [r for r in rows if r["variant"] == "default.dl"]
others  = [r for r in rows if r["variant"] != "default.dl"]
for r in default + others:
    print("\t".join((r["variant"], r["kind"], r["rule_perms"])))
PY
)

    local -a order=()
    while IFS=$'\t' read -r variant kind sig; do
        [[ -z "$variant" ]] && continue
        order+=("${variant}|${kind}|${sig}")
    done <<< "$manifest_tsv"
    local total_variants=${#order[@]}
    log "$BLUE" "BENCH" "$stem + $dataset — ${total_variants} variants (workers=$WORKERS, runs=$NUM_RUNS)"

    # Build done-set once for O(1) resume lookup. Grepping the CSV
    # per-variant was O(N²) on the 326-variant doop programs.
    local -A done_variants=()
    if [[ -s "$pair_csv" ]]; then
        while IFS=, read -r v _; do
            [[ -n "$v" && "$v" != "Variant" ]] && done_variants["$v"]=1
        done < "$pair_csv"
    fi

    local idx=0 succ=0 fail=0 mismatch=0
    for entry in "${order[@]}"; do
        idx=$((idx + 1))
        IFS='|' read -r variant kind sig <<< "$entry"
        local variant_name="${variant%.dl}"

        if [[ -n "${done_variants[$variant_name]:-}" ]]; then
            log "$YELLOW" "SKIP" "[$idx/$total_variants] ${variant_name} — already in CSV"
            continue
        fi

        log "$CYAN" "RUN" "[$idx/$total_variants] ${stem}/${variant} (${kind})"
        local rc=0
        run_variant "$stem" "$dataset" "${stem_dir}/${variant}" || rc=$?
        if (( rc == 2 )); then
            fail=$((fail + 1))
            local to_rss_kb to_rss_mb
            to_rss_kb=$(cat "${pair_log_dir}/${variant_name}.log.timeout_rss_kb" 2>/dev/null || echo "N/A")
            to_rss_mb=$(kib_to_mib "$to_rss_kb")
            echo "${variant_name},${kind},\"${sig}\",TIMEOUT,${to_rss_mb},0,N/A,TIMEOUT" >> "$pair_csv"
            continue
        elif (( rc != 0 )); then
            fail=$((fail + 1))
            echo "${variant_name},${kind},\"${sig}\",N/A,N/A,0,N/A,FAIL" >> "$pair_csv"
            continue
        fi
        succ=$((succ + 1))

        local var_summary="${pair_log_dir}/${variant_name}.log.summary"
        local total rss n_ok rss_mb
        read -r total rss n_ok < "$var_summary"
        rss_mb=$(kib_to_mib "$rss")

        # Crosscheck against default's sizes (default ran first and wrote
        # default.log.sizes earlier in this loop).
        local sem="match"
        if [[ "$variant" != "default.dl" ]]; then
            if [[ -s "$default_sizes" ]]; then
                if sizes_match_default "$default_sizes" "${pair_log_dir}/${variant_name}.log.sizes"; then
                    sem="match"
                else
                    sem="MISMATCH"
                    mismatch=$((mismatch + 1))
                    log "$RED" "XCHECK" "${variant_name} relation sizes diverge from default!"
                fi
            else
                sem="n/a"
            fi
        else
            default_total="$total"
        fi

        local vs_def="N/A"
        if [[ -n "$default_total" && "$default_total" != "N/A" ]]; then
            vs_def=$(speedup_ratio "$total" "$default_total")
        fi

        # Quote signature; it contains commas (e.g. "r0=0,1,2;r1=0,2,1").
        echo "${variant_name},${kind},\"${sig}\",${total},${rss_mb},${n_ok},${vs_def},${sem}" >> "$pair_csv"
    done

    log "$GREEN" "PAIR-DONE" "$stem + $dataset — succ=$succ fail=$fail mismatches=$mismatch"
    cleanup_dataset_for_pair "$dataset"
}

# ---- main ---------------------------------------------------------------
main() {
    log "$BLUE" "START" "FlowLog Join-Order Variant Sweep"
    [[ -x "$COMPILER_BIN" ]] \
        || die "flowlog-compiler not found at $COMPILER_BIN — invoke via the Makefile (calls scripts/get_flowlog.sh first)"
    echo "  Compiler   : $COMPILER_BIN"
    [[ -n "${FLOWLOG_RESOLVED_SHA:-}" ]] && echo "  Flowlog SHA: ${FLOWLOG_RESOLVED_SHA:0:12}"
    echo "  Config     : $CONFIG_FILE"
    [[ -n "$TARGET_FILTER" ]] && echo "  Target     : $TARGET_FILTER"
    echo "  Workers    : $WORKERS"
    echo "  Runs/var   : $NUM_RUNS"
    echo "  Run timeout: ${FLOWLOG_RUN_TIMEOUT}s"
    echo ""

    if (( FRESH )); then
        rm -rf "$LOG_DIR"
        log "$YELLOW" "FRESH" "Wiped $LOG_DIR (--fresh)"
    fi
    mkdir -p "$LOG_DIR"

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        parse_config_line "$raw_line" || continue
        local prog_file stem
        prog_file="$(basename "$PROG_NAME")"
        stem="${prog_file%.*}"
        if [[ -n "$TARGET_FILTER" && "${stem}:${DATASET_NAME}" != "$TARGET_FILTER" ]]; then
            continue
        fi
        echo "========================================"
        run_pair "$PROG_NAME" "$DATASET_NAME"
        echo ""
    done < "$CONFIG_FILE"
}

main "$@"
