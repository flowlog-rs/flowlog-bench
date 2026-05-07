#!/usr/bin/env bash
# scripts/cross_engine.sh — multi-engine comparison on the oracle suite.
#
# Times the FlowLog compiler against zero or more other engines
# (vldb26 interpreter, Souffle), one (program × dataset) pair at a time,
# and writes a single CSV with side-by-side timing + peak RSS columns.
#
# Per-engine loops live in scripts/engines/*.sh; this file just
# orchestrates them, manages the dataset cache, writes the CSV, and
# enforces resume safety.
#
# Usage:
#   bash scripts/cross_engine.sh [FLAGS] [config_file]
#   make cross-engine [FLOWLOG_REF=<sha|tag|branch>]
#
# Flags:
#   --engines=<list>            comma list of comparison engines to run
#                               alongside the FlowLog compiler:
#                               {interpreter, souffle, none}.
#                               Default: interpreter. `none` runs only
#                               the compiler column.
#   --target=<stem:ds>          run only one pair (stem = .dl basename without
#                               extension); resume / skip semantics still apply.
#   --fresh                     wipe results/benchmark/ before running.
#                               Otherwise pairs already in the CSV are skipped.
#   --keep-datasets             skip dataset cleanup between pairs.
#                               Required if $FACT_DIR is a symlink — the
#                               script refuses to rm -rf through one.
#   -h, --help                  print this header.
#
# Environment knobs:
#   WORKERS             thread count for every engine; default min(64, nproc).
#                       Same value across runs you compare.
#   NUM_RUNS            timed runs per (engine, pair). Median is kept. Default 3.
#   FLOWLOG_RUN_TIMEOUT SIGTERM cap on a single attempt (seconds). Default 1800.
#   SOUFFLE_BIN         override Souffle binary location (default /usr/bin/souffle).
#   SOUFFLE_PROG_DIR    override Souffle .dl corpus dir.
#   TIME_BIN            override GNU /usr/bin/time location.
# ==========================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Logging + shared helpers (colors, trim, cleanup safety) -------------
source "${ROOT_DIR}/scripts/lib/common.sh"
# Stderr — keeps stdout clean for $(_souffle_compile ...)-style captures
# and for the summary table at the end.
log() { local c="$1" t="$2"; shift 2; echo -e "${c}[${t}]${NC} $*" >&2; }
die() { log "$RED" "ERROR" "$*"; exit 1; }

# --- Argv parsing --------------------------------------------------------
FRESH=0
ENGINES="interpreter"
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
        --engines=*)     ENGINES="${1#--engines=}"; shift ;;
        --engines)       ENGINES="$2"; shift 2 ;;
        --target=*)      TARGET_FILTER="${1#--target=}"; shift ;;
        --target)        TARGET_FILTER="$2"; shift 2 ;;
        --keep-datasets) KEEP_DATASETS=1; shift ;;
        --)              shift; POSITIONAL_ARGS+=("$@"); break ;;
        -*)              die "Unknown option: $1 (try --help)" ;;
        *)               POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done
export KEEP_DATASETS

RUN_INTERPRETER=0; RUN_SOUFFLE=0
case ",$ENGINES," in *,interpreter,*) RUN_INTERPRETER=1 ;; esac
case ",$ENGINES," in *,souffle,*)     RUN_SOUFFLE=1 ;; esac
case ",$ENGINES," in
    *,none,*) ;;  # explicit compiler-only mode is fine
    *)
        (( RUN_INTERPRETER || RUN_SOUFFLE )) \
            || die "--engines must be 'none' or comma list of {interpreter,souffle} (got: $ENGINES)"
        ;;
esac

CONFIG_FILE="${POSITIONAL_ARGS[0]:-${ROOT_DIR}/config/default.txt}"
[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

# --- Pre-flight dependency checks ----------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || die "required command not found: $1${2:+ — $2}"
}
require_cmd python3 "median + diff math; install python3 (>= 3.6)"
require_cmd wget    "needed to download HuggingFace datasets / interpreter programs"
require_cmd unzip   "needed to extract dataset zips"
require_cmd tar     "needed to extract Soufflé reference tarballs (L2 oracle)"

TIME_BIN="${TIME_BIN:-/usr/bin/time}"
[[ -x "$TIME_BIN" ]] \
    || die "GNU /usr/bin/time not found at $TIME_BIN — apt install time, or set TIME_BIN=<path>"

# --- WORKERS / NUM_RUNS / timeout ----------------------------------------
# Default WORKERS = min(64, nproc): caps at the VLDB paper rig (64 cores)
# so cross-machine numbers stay paper-comparable; auto-shrinks on smaller
# hosts so a 16-core laptop doesn't context-switch through a 64-thread storm.
_NPROC=$(nproc 2>/dev/null || echo 64)
[[ "$_NPROC" =~ ^[0-9]+$ ]] && (( _NPROC > 0 )) || _NPROC=64
_DEFAULT_WORKERS=$(( _NPROC < 64 ? _NPROC : 64 ))
WORKERS="${WORKERS:-$_DEFAULT_WORKERS}"
[[ "$WORKERS" =~ ^[0-9]+$ ]] && (( WORKERS > 0 )) \
    || die "WORKERS must be a positive integer, got: $WORKERS"

NUM_RUNS="${NUM_RUNS:-3}"
FLOWLOG_RUN_TIMEOUT="${FLOWLOG_RUN_TIMEOUT:-1800}"
[[ "$FLOWLOG_RUN_TIMEOUT" =~ ^[0-9]+$ ]] && (( FLOWLOG_RUN_TIMEOUT > 0 )) \
    || die "FLOWLOG_RUN_TIMEOUT must be a positive integer (seconds), got: $FLOWLOG_RUN_TIMEOUT"

# --- Paths (env-overridable) ---------------------------------------------
PROG_DIR="${PROG_DIR:-${ROOT_DIR}/programs/oracle/flowlog}"
FACT_DIR="${ROOT_DIR}/facts"
LOG_DIR="${ROOT_DIR}/results/benchmark"
CSV_FILE="${LOG_DIR}/comparison_results.csv"

# flowlog-compiler binary: built by scripts/get_flowlog.sh; Makefile sets
# FLOWLOG_BIN / FLOWLOG_RESOLVED_SHA after the fetch.
COMPILER_BIN="${FLOWLOG_BIN:-${ROOT_DIR}/flowlog/main/target/release/flowlog-compiler}"
FLOWLOG_BIN="$COMPILER_BIN"

# Interpreter: vldb26-artifact lives next to this repo.
INTERPRETER_DIR="${ROOT_DIR}/../vldb26-artifact"
INTERPRETER_BIN="${INTERPRETER_DIR}/target/release/executing"
INTERPRETER_PROG_DIR="${INTERPRETER_DIR}/test/correctness_test/program/flowlog"
INTERPRETER_PROG_URL="https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/resolve/main/program/flowlog_interpreter"

# Souffle:
SOUFFLE_BIN="${SOUFFLE_BIN:-/usr/bin/souffle}"
SOUFFLE_PROG_DIR="${SOUFFLE_PROG_DIR:-${ROOT_DIR}/programs/oracle/souffle}"

# Dataset URL template:
DATASET_URL="https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/resolve/main/dataset/csv"

export FLOWLOG_BIN PROG_DIR FACT_DIR LOG_DIR COMPILER_BIN \
       INTERPRETER_DIR INTERPRETER_BIN INTERPRETER_PROG_DIR \
       INTERPRETER_PROG_URL SOUFFLE_BIN SOUFFLE_PROG_DIR \
       WORKERS NUM_RUNS FLOWLOG_RUN_TIMEOUT TIME_BIN

# --- Library imports -----------------------------------------------------
source "${ROOT_DIR}/scripts/lib/measure.sh"
source "${ROOT_DIR}/scripts/lib/datasets.sh"
source "${ROOT_DIR}/scripts/engines/compiler.sh"
source "${ROOT_DIR}/scripts/engines/interpreter.sh"
source "${ROOT_DIR}/scripts/engines/souffle.sh"

# --- Reproducibility manifest --------------------------------------------
RUN_INFO_BENCH_ROOT="$ROOT_DIR"
RUN_INFO_RUNNER="cross_engine.sh"
RUN_INFO_CONFIG_PATH="$CONFIG_FILE"
export RUN_INFO_BENCH_ROOT RUN_INFO_RUNNER RUN_INFO_CONFIG_PATH
source "${ROOT_DIR}/scripts/lib/run_info.sh"

# --- Config-line parsing -------------------------------------------------
# Per-pair tags follow the dataset in square brackets, multiple tags
# separated by whitespace. Recognised tags:
#   [interp:skip]     skip the interpreter run (vldb26 limitations)
#   [souffle:skip]    skip the Souffle run
parse_config_line() {
    local raw="$1"
    local line="${raw%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && return 1

    PAIR_TAGS=""
    while [[ "$line" =~ ^(.*[^[:space:]])[[:space:]]+(\[[^][]+\])[[:space:]]*$ ]]; do
        line="${BASH_REMATCH[1]}"
        PAIR_TAGS="${BASH_REMATCH[2]}${PAIR_TAGS:+ }${PAIR_TAGS}"
    done

    IFS='=' read -r PROG_NAME DATASET_NAME <<< "$line"
    PROG_NAME="$(trim "${PROG_NAME:-}")"
    DATASET_NAME="$(trim "${DATASET_NAME:-}")"
    [[ -z "$PROG_NAME" || -z "$DATASET_NAME" ]] && return 1
    [[ "$PROG_NAME" == "test.dl" ]] && return 1
    return 0
}
pair_has_tag() { [[ "${PAIR_TAGS:-}" == *"[$1]"* ]]; }

# --- Setup gates ---------------------------------------------------------
setup_compiler() {
    [[ -x "$COMPILER_BIN" ]] \
        || die "flowlog-compiler not found at $COMPILER_BIN — invoke via the Makefile (which calls scripts/get_flowlog.sh first), or set FLOWLOG_BIN=<path> manually."
    local sha="${FLOWLOG_RESOLVED_SHA:-unknown}"
    log "$BLUE" "SETUP" "Compiler: $COMPILER_BIN (flowlog @ ${sha:0:12})"
}

# --- Dataset wrappers ----------------------------------------------------
setup_dataset_for_pair() {
    local name="$1"
    if [[ -d "${FACT_DIR}/${name}" ]]; then
        log "$GREEN" "FOUND" "Dataset $name"
        return 0
    fi
    log "$CYAN" "DOWNLOAD" "${name}.zip -> /dev/shm (tmpfs)"
    log "$YELLOW" "EXTRACT" "$name"
    if ! dataset_ensure_zip "$name" "${DATASET_URL}/${name}.zip"; then
        die "Download/extract failed: $name (try \`source /datasets/env.sh\` if a local cache exists, or check network)"
    fi
    log "$GREEN" "CLEANED" "Removed /dev/shm/${name}.zip from tmpfs"
}
cleanup_dataset_for_pair() {
    local name="$1"
    if dataset_cleanup "$name"; then
        log "$YELLOW" "CLEANUP" "$name"
    else
        log "$YELLOW" "CLEANUP" "$name (${CLEANUP_SKIP_REASON})"
    fi
}

# --- CSV writer ----------------------------------------------------------
# 20 columns: timing (interp/comp) + speedups + peak RSS + souffle +
# crosscheck + per-engine RunsSucceeded counters. Empty *_RunsSucceeded
# = engine wasn't requested for this pair. Header is byte-stable;
# downstream consumers (plot/) parse by column name.
CSV_HEADER="Program,Dataset,Interp_Load,Compiler_Load,Load_Speedup,Interp_Exec,Compiler_Exec,Exec_Speedup,Interp_Total,Compiler_Total,Total_Speedup,Interp_PeakRss_MB,Compiler_PeakRss_MB,Souffle_Total,Souffle_PeakRss_MB,Souffle_vs_Compiler_Total,Crosscheck_Souffle,Interp_RunsSucceeded,Compiler_RunsSucceeded,Souffle_RunsSucceeded"

init_csv() {
    mkdir -p "$(dirname "$CSV_FILE")"
    [[ -s "$CSV_FILE" ]] || echo "$CSV_HEADER" > "$CSV_FILE"
}

pair_already_done() {
    local stem="$1" dataset="$2"
    [[ -f "$CSV_FILE" ]] || return 1
    grep -Fq -- "${stem},${dataset}," "$CSV_FILE"
}

# Cross-validate compiler-vs-Souffle output sizes. See the embedded
# python comments for the exact verdict semantics.
crosscheck_compiler_vs_souffle() {
    local comp_sizes="$1" sf_sizes="$2"
    [[ -s "$comp_sizes" && -s "$sf_sizes" ]] || { echo "n/a"; return; }
    python3 - "$comp_sizes" "$sf_sizes" <<'PY'
# Cross-check verdicts:
#   match(N)           shared relations agree, no extras
#   match(N)+aux(M)    shared agree; FlowLog also reports M relation sizes
#                      that the canonical Souffle .dl does not .printsize
#                      (e.g. cspa MemoryAlias / ValueAlias). Informational.
#   PARTIAL(N):...     Souffle reports relations FlowLog does not — real
#                      signal that FlowLog's output is incomplete.
#   MISMATCH:...       some shared relation has a different row count.
#   n/a                no relations match by name, or one side missing.
import sys
def load(path):
    out = {}
    for line in open(path):
        parts = line.strip().split()
        if len(parts) >= 2 and parts[1].isdigit():
            out[parts[0].lower()] = int(parts[1])
    return out
fl, sf = load(sys.argv[1]), load(sys.argv[2])
shared = set(fl) & set(sf)
only_fl = set(fl) - set(sf)
only_sf = set(sf) - set(fl)
if not shared:
    print("n/a"); sys.exit(0)
mismatches = [(r, fl[r], sf[r]) for r in sorted(shared) if fl[r] != sf[r]]
if mismatches:
    head = ";".join(f"{r}={fl[r]}vs{sf[r]}" for r, _, _ in mismatches[:3])
    suffix = f"+{len(mismatches)-3}more" if len(mismatches) > 3 else ""
    print(f"MISMATCH:{head}{suffix}"); sys.exit(0)
if only_sf:
    parts = []
    head = ",".join(sorted(only_sf)[:2])
    parts.append(f"souffle-only={head}{'+more' if len(only_sf) > 2 else ''}")
    if only_fl:
        head = ",".join(sorted(only_fl)[:2])
        parts.append(f"flowlog-only={head}{'+more' if len(only_fl) > 2 else ''}")
    print(f"PARTIAL({len(shared)}):" + ";".join(parts))
elif only_fl:
    print(f"match({len(shared)})+aux({len(only_fl)})")
else:
    print(f"match({len(shared)})")
PY
}

# Append one CSV row from the median sidecars + log files left by the
# engine adapters.
append_csv_row() {
    local stem="$1" dataset="$2"
    local interp_log="$3" comp_log="$4" sf_log="$5"

    # Median timings (both compiler + interpreter emit Load + Total log lines).
    local i_total i_load i_exec c_total c_load c_exec
    i_total=$(extract_total_seconds "$interp_log")
    i_load=$( extract_load_seconds  "$interp_log")
    i_exec=$( compute_exec_seconds  "$i_total" "$i_load")
    c_total=$(extract_total_seconds "$comp_log")
    c_load=$( extract_load_seconds  "$comp_log")
    c_exec=$( compute_exec_seconds  "$c_total" "$c_load")

    local rs_load rs_exec rs_total
    rs_load=$( speedup_ratio "$i_load"  "$c_load")
    rs_exec=$( speedup_ratio "$i_exec"  "$c_exec")
    rs_total=$(speedup_ratio "$i_total" "$c_total")

    # Median peak RSS (KiB) sidecars -> MiB cells.
    local i_rss_kb c_rss_kb i_rss_mb c_rss_mb
    i_rss_kb=$(cat "${interp_log}.median_rss_kb" 2>/dev/null || echo "N/A")
    c_rss_kb=$(cat "${comp_log}.median_rss_kb"   2>/dev/null || echo "N/A")
    i_rss_mb=$(kib_to_mib "$i_rss_kb")
    c_rss_mb=$(kib_to_mib "$c_rss_kb")

    # Souffle (optional).
    local sf_total="N/A" sf_rss_mb="N/A" sf_vs_comp_total="N/A"
    if [[ -n "${sf_log:-}" && -s "${sf_log}.median_total_s" ]]; then
        sf_total=$(cat "${sf_log}.median_total_s")
        local sf_rss_kb
        sf_rss_kb=$(cat "${sf_log}.median_rss_kb" 2>/dev/null || echo "N/A")
        sf_rss_mb=$(kib_to_mib "$sf_rss_kb")
        sf_vs_comp_total=$(speedup_ratio "$sf_total" "$c_total")
    fi

    # Crosscheck (free if both sides wrote a .sizes sidecar this pair).
    local crosscheck="n/a"
    if [[ "$sf_total" != "N/A" ]]; then
        crosscheck=$(crosscheck_compiler_vs_souffle "${comp_log}.sizes" "${sf_log}.sizes")
        case "$crosscheck" in
            match*)    log "$GREEN" "XCHECK" "compiler vs souffle: $crosscheck" ;;
            MISMATCH*) log "$RED"   "XCHECK" "compiler vs souffle: $crosscheck" ;;
        esac
    fi

    local i_n c_n s_n
    i_n=$(cat "${interp_log}.n_runs_succeeded" 2>/dev/null || true)
    c_n=$(cat "${comp_log}.n_runs_succeeded"   2>/dev/null || true)
    s_n=$(cat "${sf_log}.n_runs_succeeded"     2>/dev/null || true)

    echo "${stem},${dataset},${i_load},${c_load},${rs_load},${i_exec},${c_exec},${rs_exec},${i_total},${c_total},${rs_total},${i_rss_mb},${c_rss_mb},${sf_total},${sf_rss_mb},${sf_vs_comp_total},${crosscheck},${i_n},${c_n},${s_n}" \
        >> "$CSV_FILE"

    log "$GREEN" "CSV" "Appended ${stem}_${dataset} to $CSV_FILE"
}

# --- Per-pair console summary --------------------------------------------
fmt_time() {
    local t="$1"
    [[ "$t" =~ ^[0-9] ]] && printf "%13.6f" "$t" || printf "%13s" "$t"
}
fmt_speedup() {
    local n="$1" d="$2"
    [[ "$n" =~ ^[0-9] && "$d" =~ ^[0-9] ]] \
        && python3 -c "print(f'{${n}/${d}:.2f}x') if ${d}>0 else print('N/A')" 2>/dev/null \
        || echo "N/A"
}

print_pair_summary() {
    local label="$1" interp_log="$2" comp_log="$3" sf_log="${4:-}"

    local i_total i_load i_exec c_total c_load c_exec
    i_total=$(extract_total_seconds "$interp_log")
    i_load=$( extract_load_seconds  "$interp_log")
    i_exec=$( compute_exec_seconds  "$i_total" "$i_load")
    c_total=$(extract_total_seconds "$comp_log")
    c_load=$( extract_load_seconds  "$comp_log")
    c_exec=$( compute_exec_seconds  "$c_total" "$c_load")

    local i_rss_mb c_rss_mb
    i_rss_mb=$(kib_to_mib "$(cat "${interp_log}.median_rss_kb" 2>/dev/null || echo)")
    c_rss_mb=$(kib_to_mib "$(cat "${comp_log}.median_rss_kb"   2>/dev/null || echo)")

    local sf_total="" sf_rss_mb=""
    if [[ -n "$sf_log" && -s "${sf_log}.median_total_s" ]]; then
        sf_total=$(cat "${sf_log}.median_total_s")
        sf_rss_mb=$(kib_to_mib "$(cat "${sf_log}.median_rss_kb" 2>/dev/null || echo)")
    fi

    echo "----------------------------------------"
    log "$GREEN" "RESULT" "$label"
    log "$GREEN" "  LOAD" "Interp=${i_load}s  Comp=${c_load}s  Speedup=$(fmt_speedup "$i_load" "$c_load")"
    log "$GREEN" "  EXEC" "Interp=${i_exec}s  Comp=${c_exec}s  Speedup=$(fmt_speedup "$i_exec" "$c_exec")"
    log "$GREEN" " TOTAL" "Interp=${i_total}s  Comp=${c_total}s  Speedup=$(fmt_speedup "$i_total" "$c_total")"
    log "$GREEN" "   MEM" "Interp=${i_rss_mb}MB  Comp=${c_rss_mb}MB"
    if [[ -n "$sf_total" ]]; then
        log "$GREEN" "SOUFFLE" "Total=${sf_total}s  PeakRss=${sf_rss_mb}MB  Souffle/Comp=$(fmt_speedup "$sf_total" "$c_total")"
    fi
    echo "----------------------------------------"
}

# --- End-of-run summary table -------------------------------------------
# Per-engine grid: one row per (pair, engine). Engines that didn't run for
# a pair (not in --engines, or skipped via [interp:skip]/[souffle:skip])
# are omitted from that pair's block. The "vs Compiler" column is
# engine_total / compiler_total — compiler is always 1.00x, values > 1
# mean slower than compiler.
emit_summary_row() {
    local label="$1" engine="$2" total="$3" rss_mb="$4" ratio="$5"
    printf "| %-40s | %-11s | %s | %13s | %11s |\n" \
        "$label" "$engine" "$(fmt_time "$total")" "$rss_mb" "$ratio"
}

print_summary_table() {
    echo ""
    echo "==================================================================================================================================================="
    log "$BLUE" "SUMMARY" "Cross-engine results (median of $NUM_RUNS runs)"
    echo "==================================================================================================================================================="
    echo ""

    printf "| %-40s | %-11s | %13s | %13s | %11s |\n" \
        "Program-Dataset" "Engine" "Total (s)" "Peak RSS (MB)" "vs Compiler"
    printf '%s\n' "|------------------------------------------|-------------|---------------|---------------|-------------|"

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        parse_config_line "$raw_line" || continue
        local prog_base file_stem display_stem label
        prog_base="$(basename "$PROG_NAME")"
        file_stem="${prog_base%.*}"
        display_stem="${PROG_NAME%.*}"
        label="${display_stem}_${DATASET_NAME}"

        local interp_log="${LOG_DIR}/${file_stem}_${DATASET_NAME}_interpreter.log"
        local comp_log="${LOG_DIR}/${file_stem}_${DATASET_NAME}_compiler.log"
        local sf_log="${LOG_DIR}/${file_stem}_${DATASET_NAME}_souffle.log"

        # Compiler row: always present (compiler always runs); baseline 1.00x.
        local c_total c_rss_mb
        c_total=$(extract_total_seconds "$comp_log")
        c_rss_mb=$(kib_to_mib "$(cat "${comp_log}.median_rss_kb" 2>/dev/null || echo)")
        emit_summary_row "$label" "compiler" "$c_total" "$c_rss_mb" "1.00x"

        if (( RUN_INTERPRETER )) && ! pair_has_tag "interp:skip"; then
            local i_total i_rss_mb
            i_total=$(extract_total_seconds "$interp_log")
            i_rss_mb=$(kib_to_mib "$(cat "${interp_log}.median_rss_kb" 2>/dev/null || echo)")
            emit_summary_row "" "interpreter" "$i_total" "$i_rss_mb" "$(fmt_speedup "$i_total" "$c_total")"
        fi

        if (( RUN_SOUFFLE )) && ! pair_has_tag "souffle:skip"; then
            local sf_total="N/A" sf_rss_mb="N/A"
            if [[ -s "${sf_log}.median_total_s" ]]; then
                sf_total=$(cat "${sf_log}.median_total_s")
                sf_rss_mb=$(kib_to_mib "$(cat "${sf_log}.median_rss_kb" 2>/dev/null || echo)")
            fi
            emit_summary_row "" "souffle" "$sf_total" "$sf_rss_mb" "$(fmt_speedup "$sf_total" "$c_total")"
        fi
    done < "$CONFIG_FILE"
    echo ""
    log "$GREEN" "CSV" "Results saved to: $CSV_FILE"
}

# --- Main loop -----------------------------------------------------------
main() {
    log "$BLUE" "START" "FlowLog Version Comparison Benchmark"
    echo "  Compiler repo : $ROOT_DIR"
    echo "  Interpreter   : $INTERPRETER_DIR  (timed: $RUN_INTERPRETER)"
    echo "  Souffle       : $SOUFFLE_BIN  (timed: $RUN_SOUFFLE)"
    echo "  Config        : $CONFIG_FILE"
    [[ -n "$TARGET_FILTER" ]] && echo "  Target filter : $TARGET_FILTER"
    echo "  Workers       : $WORKERS  (applied identically to every engine)"
    echo "  Run timeout   : ${FLOWLOG_RUN_TIMEOUT}s per attempt"
    echo ""

    (( RUN_INTERPRETER )) && engine_interpreter_setup
    setup_compiler
    (( RUN_SOUFFLE )) && engine_souffle_setup

    if (( FRESH )); then
        rm -rf "$LOG_DIR"
        log "$YELLOW" "FRESH" "Wiped $LOG_DIR (--fresh)"
    fi
    mkdir -p "$LOG_DIR"

    # Resume safety: if results/benchmark/ already has a manifest from
    # a prior run, current invocation's identity must match. Otherwise
    # the CSV could silently mix incompatible rows.
    if ! verify_run_info "$LOG_DIR" \
            "engines=${ENGINES}" \
            "target=${TARGET_FILTER:-(none)}"; then
        die "resume blocked — see diff above. Use --fresh to start over."
    fi
    write_run_info "$LOG_DIR" \
        "engines=${ENGINES}" \
        "target=${TARGET_FILTER:-(none)}"

    init_csv

    local ANY_PAIR_FAILED=0

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        parse_config_line "$raw_line" || continue

        local _display_stem="${PROG_NAME%.*}"
        local file_stem
        file_stem="$(basename "$PROG_NAME" .dl)"

        if [[ -n "$TARGET_FILTER" && "${file_stem}:${DATASET_NAME}" != "$TARGET_FILTER" ]]; then
            continue
        fi

        if pair_already_done "$_display_stem" "$DATASET_NAME"; then
            log "$YELLOW" "SKIP" "$_display_stem + $DATASET_NAME — already in CSV"
            continue
        fi

        echo ""
        echo "========================================"
        log "$CYAN" "BENCH" "$PROG_NAME + $DATASET_NAME${PAIR_TAGS:+  $PAIR_TAGS}"
        echo "========================================"

        setup_dataset_for_pair "$DATASET_NAME"

        local interp_log="${LOG_DIR}/${file_stem}_${DATASET_NAME}_interpreter.log"
        local comp_log="${LOG_DIR}/${file_stem}_${DATASET_NAME}_compiler.log"
        local sf_log="${LOG_DIR}/${file_stem}_${DATASET_NAME}_souffle.log"

        # Clear stale sidecars so this iteration's CSV row is clean.
        rm -f "${interp_log}" "${interp_log}.median_rss_kb" "${interp_log}.n_runs_succeeded" \
              "${comp_log}.n_runs_succeeded" "${comp_log}.sizes" \
              "${sf_log}" "${sf_log}.median_rss_kb" "${sf_log}.median_total_s" "${sf_log}.n_runs_succeeded"

        local rc_interp=0 rc_compiler=0 rc_souffle=0
        local interp_required=0 souffle_required=0

        if (( RUN_INTERPRETER )) && ! pair_has_tag "interp:skip"; then
            interp_required=1
            engine_interpreter_run "$PROG_NAME" "$DATASET_NAME" || rc_interp=$?
        elif pair_has_tag "interp:skip"; then
            log "$YELLOW" "SKIP" "Interpreter: $PROG_NAME + $DATASET_NAME (per [interp:skip] tag)"
        fi

        engine_compiler_run "$PROG_NAME" "$DATASET_NAME" || rc_compiler=$?

        if (( RUN_SOUFFLE )) && ! pair_has_tag "souffle:skip"; then
            souffle_required=1
            engine_souffle_run "$PROG_NAME" "$DATASET_NAME" || rc_souffle=$?
        elif pair_has_tag "souffle:skip"; then
            log "$YELLOW" "SKIP" "Souffle: $PROG_NAME + $DATASET_NAME (per [souffle:skip] tag)"
        fi

        # Gate: a pair is "complete" iff every required engine produced
        # at least one valid sample. Otherwise skip the CSV row so resume
        # can retry on a future invocation. Recording N/A here would mask
        # a transient failure as permanent (pair_already_done would skip).
        local pair_failed=0 fail_reasons=""
        (( rc_compiler != 0 )) && { pair_failed=1; fail_reasons="${fail_reasons:+$fail_reasons, }compiler"; }
        (( interp_required && rc_interp != 0 )) \
            && { pair_failed=1; fail_reasons="${fail_reasons:+$fail_reasons, }interpreter"; }
        (( souffle_required && rc_souffle != 0 )) \
            && { pair_failed=1; fail_reasons="${fail_reasons:+$fail_reasons, }souffle"; }

        if (( pair_failed )); then
            log "$RED" "PAIR-FAIL" \
                "$_display_stem + $DATASET_NAME — required engine(s) all-runs-failed: ${fail_reasons}. NOT writing CSV row; pair will retry on resume."
            ANY_PAIR_FAILED=1
            cleanup_dataset_for_pair "$DATASET_NAME"
            continue
        fi

        print_pair_summary "${_display_stem}_${DATASET_NAME}" \
            "$interp_log" "$comp_log" "$sf_log"
        append_csv_row "$_display_stem" "$DATASET_NAME" \
            "$interp_log" "$comp_log" "$sf_log"
        cleanup_dataset_for_pair "$DATASET_NAME"
    done < "$CONFIG_FILE"

    print_summary_table

    # Exit non-zero on any pair-level failure so the agentic perf gate
    # sees a FAIL — without aborting mid-loop on the first bad pair (a
    # 3-hour sweep shouldn't be killed by one OOM).
    if (( ANY_PAIR_FAILED )); then
        log "$RED" "FINISH" \
            "cross_engine.sh completed with at least one pair-level failure (see PAIR-FAIL above). The CSV does not contain rows for failed pairs; rerun without --fresh to retry."
        return 1
    fi
}

main "$@"
