#!/bin/bash
# =============================================================================
# LDBC SNB Correctness Checker (per-param mode)
# =============================================================================
# Reads config lines of the form "query=dataset", downloads the dataset from
# HuggingFace if not cached, then runs each query with DuckDB and Flowlog
# one param row at a time, verifying all results match.
#
# Usage:
#   bash scripts/ldbc.sh [--config <file>] [--param_num <n>] [--timeout <s>] [--sip]
#   --config     config file (default: config/ldbc.txt)
#   --param_num  max param rows per query, 0 = all (default: 0)
#   --timeout    per-param timeout in seconds (default: 300)
#   --sip        forward --sip to flowlog-compiler (sideways info passing)
#
# Environment variables:
#   FLOWLOG_BIN - path to flowlog-compiler binary
#                 (default: ROOT_DIR/flowlog/main/target/release/flowlog-compiler;
#                  the Makefile target sets this from get_flowlog.sh's output)
#   DUCKDB_BIN  - path to duckdb binary (default: duckdb on PATH)
#   WORKERS     - parallelism for both engines (default: 64)
#   FACT_DIR    - dataset cache directory (default: ROOT_DIR/facts/ldbc)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Shared bench helpers: ANSI colors, flowlog_truthy, trim,
# cleanup_dataset_should_clean (CACHE_PATCH_v2 contract).
source "$(dirname "$0")/lib/common.sh"

# log/die kept local with this script's own [CHECK]/[ERROR] branding.
log()  { echo -e "${CYAN}[CHECK]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Verify required external commands are available early, before doing any work.
command -v timeout >/dev/null 2>&1 || die "Required dependency 'timeout' not found on PATH; please install it."
command -v python3 >/dev/null 2>&1 || die "Required dependency 'python3' not found on PATH; please install Python 3."
command -v tar >/dev/null 2>&1 || die "Required dependency 'tar' not found on PATH; please install it."
command -v zstd >/dev/null 2>&1 || die "Required dependency 'zstd' not found on PATH; please install it."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${ROOT_DIR}/config/ldbc.txt"
MAX_PARAMS=0
TIMEOUT_SECS=300
EXTRA_FL_FLAGS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)              CONFIG="$2";       shift 2 ;;
        --param_num)           MAX_PARAMS="$2";   shift 2 ;;
        --timeout|--time_out)  TIMEOUT_SECS="$2"; shift 2 ;;
        --sip)                 EXTRA_FL_FLAGS="$EXTRA_FL_FLAGS --sip"; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

HF_BASE="https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/resolve/main"
FACT_DIR="${FACT_DIR:-${ROOT_DIR}/facts/ldbc}"

FLOWLOG_BIN="${FLOWLOG_BIN:-${ROOT_DIR}/flowlog/main/target/release/flowlog-compiler}"
DUCKDB_BIN="${DUCKDB_BIN:-$(command -v duckdb 2>/dev/null || die "duckdb not found in PATH; set DUCKDB_BIN or install duckdb")}"

# /usr/bin/time -v is GNU time. Bash's builtin `time` does NOT support
# -v (peak RSS), so we require the binary. It is the single source of
# truth for both wall-clock elapsed and peak RSS, mirroring
# cross_engine.sh's contract — having two independent timing sources
# (date brackets + /usr/bin/time sidecar) would diverge by the wrapper
# overhead on very short queries.
TIME_BIN="${TIME_BIN:-/usr/bin/time}"
[[ -x "$TIME_BIN" ]] || die "GNU /usr/bin/time not found at $TIME_BIN — apt install time, or set TIME_BIN=<path>"

DL_DIR="${DL_DIR:-${ROOT_DIR}/programs/ldbc/flowlog}"
SQL_DIR="${SQL_DIR:-${ROOT_DIR}/programs/ldbc/duckdb}"

# WORK_DIR is set later, alongside the run's results/ldbc/<tag>/ dir.

fmt_ms() {
    local ms=${1:-0}
    if [[ $ms -ge 1000 ]]; then
        local sec=$((ms / 1000))
        local cs=$(((ms % 1000) / 10))  # centiseconds (two decimal places)
        printf "%d.%02ds" "$sec" "$cs"
    else
        printf "%dms" "$ms"
    fi
}

# trim() lives in scripts/lib/common.sh.

# ── GNU time -v sidecar extractors ────────────────────────────────────────────
# Both helpers expect the path to a `/usr/bin/time -v -o <file>` output
# file. Empty / missing / unparseable input → "N/A".

_extract_peak_rss_kb() {
    local f="$1"
    [[ -f "$f" ]] || { echo "N/A"; return; }
    local v
    v=$(awk '/Maximum resident set size/ { print $NF; exit }' "$f" 2>/dev/null) || true
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "N/A"
}

# Parse "Elapsed (wall clock) time (h:mm:ss or m:ss): <X>" → integer ms.
# Format X is `h:mm:ss` (rare) or `m:ss[.cc]` (common).
_extract_elapsed_ms() {
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

# ── Tiny stats helpers (operate on integer ms or KiB) ─────────────────────────
_median_int() {
    (( $# > 0 )) || { echo ""; return; }
    printf '%s\n' "$@" | sort -n \
        | awk '{ a[NR]=$1 } END {
            if (NR % 2) print a[(NR+1)/2]
            else printf "%d", int((a[NR/2] + a[NR/2+1]) / 2)
        }'
}
_avg_int() {
    (( $# > 0 )) || { echo ""; return; }
    local sum=0 x
    for x in "$@"; do sum=$(( sum + x )); done
    echo $(( sum / $# ))
}
_kib_to_mib() {
    local kib="$1"
    [[ "$kib" =~ ^[0-9]+$ ]] || { echo "N/A"; return; }
    awk -v k="$kib" 'BEGIN { printf "%.2f", k / 1024.0 }'
}
# _speedup numerator denominator  → ratio (3 decimals); "N/A" on bad input.
# Convention: pass DB time as numerator, FL time as denominator, so >1 means FL is faster.
_speedup() {
    local n="$1" d="$2"
    [[ "$n" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] && (( d > 0 )) \
        || { echo "N/A"; return; }
    awk -v n="$n" -v d="$d" 'BEGIN { printf "%.3f", n / d }'
}

[[ -f "$CONFIG" ]]     || die "Config not found: $CONFIG"
[[ -x "$DUCKDB_BIN" ]] || die "duckdb not found: $DUCKDB_BIN"
[[ -x "$FLOWLOG_BIN" ]] || die "flowlog-compiler not built: $FLOWLOG_BIN"

WORKERS="${WORKERS:-64}"

# Durable per-run output dir under results/ldbc/. Honours AGENTS.md
# principle 3 (scripts only write to results/) and gives principle 6
# something to anchor run_info.txt to. Tag by date+pid so back-to-back
# invocations don't trample each other (no resume model — each ldbc
# run is fresh).
LDBC_RUN_TAG="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LDBC_OUT_DIR="${ROOT_DIR}/results/ldbc/${LDBC_RUN_TAG}"
mkdir -p "$LDBC_OUT_DIR" "$FACT_DIR"

# Per-run scratch lives under the same out-dir so the entire run is
# self-contained and `make clean` (results/ wipe) reclaims it. Replaces
# the old /tmp/ldbc_compare which (a) violated principle 3 and (b)
# could collide between concurrent invocations.
WORK_DIR="${LDBC_OUT_DIR}/work"
mkdir -p "$WORK_DIR"

# Reproducibility manifest. Captures duckdb binary as an "extra" since
# ldbc cross-validates against duckdb (not souffle).
RUN_INFO_BENCH_ROOT="$ROOT_DIR"
RUN_INFO_RUNNER="ldbc.sh"
RUN_INFO_CONFIG_PATH="$CONFIG"
NUM_RUNS="1"     # ldbc runs each (query, params) row once
export RUN_INFO_BENCH_ROOT RUN_INFO_RUNNER RUN_INFO_CONFIG_PATH \
       FLOWLOG_BIN WORKERS NUM_RUNS
source "${ROOT_DIR}/scripts/lib/run_info.sh"
write_run_info "$LDBC_OUT_DIR" \
    "duckdb_bin=${DUCKDB_BIN}" \
    "param_num=${MAX_PARAMS}" \
    "timeout_secs=${TIMEOUT_SECS}" \
    "extra_fl_flags=${EXTRA_FL_FLAGS:-(none)}" \
    "fact_dir=${FACT_DIR}"
log "Output dir: $LDBC_OUT_DIR"

# ── Durable summary CSV + per-pair state ──────────────────────────────────────
# One row per configured (query, dataset) — emitted exactly once via
# emit_summary_row, even when the pair fails before the per-param loop
# (missing .dl, missing .sql, FlowLog compile error, etc.). Downstream
# consumers can rely on this row count == #rows in the config file.
SUMMARY_CSV="${LDBC_OUT_DIR}/summary.csv"
SUMMARY_HEADER="Query,Dataset,Params_Available,Params_Selected,Params_Counted,FL_Median_ms,FL_Avg_ms,DB_Median_ms,DB_Avg_ms,FL_vs_DB_Speedup_Median,FL_Median_RSS_MiB,DB_Median_RSS_MiB,FL_Total_Rows,DB_Total_Rows,Rows_OK,FL_Errors,FL_Timeouts,DB_Errors,DB_Timeouts,Mismatches,Verdict,Failure_Phase,Failure_Message"
echo "$SUMMARY_HEADER" > "$SUMMARY_CSV"

# Per-pair state. Reset by reset_pair_state at the top of run_per_param.
# All summary stats live here so emit_summary_row can be called
# uniformly from any early-return path.
declare -a PAIR_FL_TIMES=() PAIR_DB_TIMES=() PAIR_FL_RSS=() PAIR_DB_RSS=()
PAIR_QUERY=""
PAIR_DATASET=""
PAIR_PARAMS_AVAIL=0
PAIR_PARAMS_SELECTED=0
PAIR_PARAMS_COUNTED=0
PAIR_FL_TOTAL_ROWS=0
PAIR_DB_TOTAL_ROWS=0
PAIR_ROWS_OK=0
PAIR_FL_ERRORS=0
PAIR_FL_TIMEOUTS=0
PAIR_DB_ERRORS=0
PAIR_DB_TIMEOUTS=0
PAIR_MISMATCHES=0
PAIR_VERDICT="FAIL"
PAIR_PHASE="setup"
PAIR_MESSAGE=""

reset_pair_state() {
    PAIR_FL_TIMES=(); PAIR_DB_TIMES=(); PAIR_FL_RSS=(); PAIR_DB_RSS=()
    PAIR_QUERY="$1"; PAIR_DATASET="$2"
    PAIR_PARAMS_AVAIL=0; PAIR_PARAMS_SELECTED=0; PAIR_PARAMS_COUNTED=0
    PAIR_FL_TOTAL_ROWS=0; PAIR_DB_TOTAL_ROWS=0; PAIR_ROWS_OK=0
    PAIR_FL_ERRORS=0; PAIR_FL_TIMEOUTS=0; PAIR_DB_ERRORS=0; PAIR_DB_TIMEOUTS=0
    PAIR_MISMATCHES=0
    PAIR_VERDICT="FAIL"; PAIR_PHASE="setup"; PAIR_MESSAGE=""
}

# Append exactly one row to summary.csv. Computes medians/avgs from
# the PAIR_* state. Sanitizes commas + newlines from the message field
# so the CSV stays parseable by naïve consumers.
emit_summary_row() {
    local fl_med fl_avg db_med db_avg
    fl_med=$(_median_int "${PAIR_FL_TIMES[@]}")
    fl_avg=$(_avg_int    "${PAIR_FL_TIMES[@]}")
    db_med=$(_median_int "${PAIR_DB_TIMES[@]}")
    db_avg=$(_avg_int    "${PAIR_DB_TIMES[@]}")

    local fl_rss_med db_rss_med fl_rss_mib db_rss_mib speedup
    fl_rss_med=$(_median_int "${PAIR_FL_RSS[@]}")
    db_rss_med=$(_median_int "${PAIR_DB_RSS[@]}")
    fl_rss_mib=$(_kib_to_mib "${fl_rss_med:-N/A}")
    db_rss_mib=$(_kib_to_mib "${db_rss_med:-N/A}")
    speedup=$(_speedup "${db_med:-N/A}" "${fl_med:-N/A}")

    local msg="${PAIR_MESSAGE//,/;}"
    msg="${msg//$'\n'/ }"
    msg="${msg//$'\r'/ }"

    printf '%s,%s,%d,%d,%d,%s,%s,%s,%s,%s,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%s,%s,%s\n' \
        "$PAIR_QUERY" "$PAIR_DATASET" \
        "$PAIR_PARAMS_AVAIL" "$PAIR_PARAMS_SELECTED" "$PAIR_PARAMS_COUNTED" \
        "${fl_med:-N/A}" "${fl_avg:-N/A}" "${db_med:-N/A}" "${db_avg:-N/A}" \
        "$speedup" "$fl_rss_mib" "$db_rss_mib" \
        "$PAIR_FL_TOTAL_ROWS" "$PAIR_DB_TOTAL_ROWS" "$PAIR_ROWS_OK" \
        "$PAIR_FL_ERRORS" "$PAIR_FL_TIMEOUTS" "$PAIR_DB_ERRORS" "$PAIR_DB_TIMEOUTS" \
        "$PAIR_MISMATCHES" \
        "$PAIR_VERDICT" "$PAIR_PHASE" "$msg" \
        >> "$SUMMARY_CSV"
}

# ── Dataset management ────────────────────────────────────────────────────────
setup_dataset() {
    local dataset_name="$1"
    local extract_path="${FACT_DIR}/${dataset_name}"

    if [[ -d "$extract_path" ]]; then
        log "Dataset $dataset_name already cached"
        return
    fi

    command -v wget >/dev/null 2>&1 || die "wget not found; cannot download datasets"

    local dataset_tar="/dev/shm/${dataset_name}.tar.zst"
    log "Downloading $dataset_name (.tar.zst) ..."
    wget --no-verbose --timeout=60 --tries=3 --max-redirect=5 -O "$dataset_tar" \
        "${HF_BASE}/dataset/ldbc/${dataset_name}.tar.zst" \
        || die "Download failed: ${HF_BASE}/dataset/ldbc/${dataset_name}.tar.zst"
    log "Extracting $dataset_name ..."
    tar --use-compress-program=zstd -xf "$dataset_tar" -C "$FACT_DIR"
    rm -f "$dataset_tar"

    log "Dataset $dataset_name ready at $extract_path"
}

# Safety policy + symlink check live in scripts/lib/common.sh
# (cleanup_dataset_should_clean) so cross_engine.sh, ldbc.sh, and any
# future runner share one implementation of the CACHE_PATCH_v2 contract.
cleanup_dataset() {
    local dataset_name="$1"
    if cleanup_dataset_should_clean "$dataset_name"; then
        log "Cleaning up dataset $dataset_name"
        rm -rf -- "${FACT_DIR}/${dataset_name}"
    else
        log "Cleaning up dataset $dataset_name (${CLEANUP_SKIP_REASON})"
    fi
}

# ── Per-param runner ──────────────────────────────────────────────────────────
# Runs one (query, dataset) pair through both engines, one param row at
# a time. Always emits exactly one summary.csv row before returning,
# even on early failure (missing files, compile error). Writes a
# per-param TSV incrementally (so SIGINT mid-sweep leaves partial data)
# and a mismatches.txt only when at least one param row diverges.
#
# Args: <query> <dataset> <data_dir>
# Returns: 0 iff PAIR_VERDICT=OK; 1 otherwise (PARTIAL or FAIL).
run_per_param() {
    local query="$1" dataset="$2" data_dir="$3"

    reset_pair_state "$query" "$dataset"

    local dl_file="${DL_DIR}/${query}.dl"
    local sql_file="${SQL_DIR}/${query}.sql"
    local qwork="${WORK_DIR}/${query}"
    local fl_out_dir="${qwork}/fl_out"
    local fl_mode_flags=""
    local perparam_tsv="${LDBC_OUT_DIR}/${query}_${dataset}_perparam.tsv"
    local mismatch_log="${LDBC_OUT_DIR}/${query}_${dataset}_mismatches.txt"

    mkdir -p "$qwork"

    # Write the per-param TSV header upfront so the artifact exists even
    # if no params get to run (missing inputs, compile failure, etc.).
    printf 'param_idx\tparam_row\tfl_ms\tdb_ms\tfl_rss_kb\tdb_rss_kb\tfl_rows\tdb_rows\tverdict\n' \
        > "$perparam_tsv"

    # ── Pre-flight: program files exist? ──
    if [[ ! -f "$dl_file" ]]; then
        PAIR_PHASE="missing_dl"
        PAIR_MESSAGE="program file not found: $dl_file"
        fail "$query: $PAIR_MESSAGE"
        emit_summary_row
        return 1
    fi
    if [[ ! -f "$sql_file" ]]; then
        PAIR_PHASE="missing_sql"
        PAIR_MESSAGE="program file not found: $sql_file"
        fail "$query: $PAIR_MESSAGE"
        emit_summary_row
        return 1
    fi

    if grep -Eq '^[[:space:]]*loop([[:space:]]|$)' "$dl_file"; then
        fl_mode_flags="--mode extend-batch"
    fi

    # Detect param filename from DL
    local param_fname
    param_fname=$(
        { grep 'filename=' "$dl_file" | grep -i param | head -1 \
            | sed 's/.*filename="\([^"]*\)".*/\1/'; } || true
    )
    if [[ -z "${param_fname:-}" ]]; then
        PAIR_PHASE="param_filename_detect"
        PAIR_MESSAGE="could not extract filename= for param input from $dl_file"
        fail "$query: $PAIR_MESSAGE"
        emit_summary_row
        return 1
    fi
    local param_file="${data_dir}/${param_fname}"
    if [[ ! -f "$param_file" ]]; then
        PAIR_PHASE="param_file_missing"
        PAIR_MESSAGE="param file not found: $param_file"
        fail "$query: $PAIR_MESSAGE"
        emit_summary_row
        return 1
    fi

    # ── Compile Flowlog once ──
    log "$query: compiling Flowlog..."
    local fl_bin="${qwork}/program"
    rm -f "$fl_bin"
    rm -rf "$fl_out_dir"
    mkdir -p "$fl_out_dir"
    local fl_compile_log="${qwork}/fl_compile.log"
    if ! "$FLOWLOG_BIN" "$dl_file" -F "$data_dir" -D "$fl_out_dir" -o "$fl_bin" --str-intern $fl_mode_flags $EXTRA_FL_FLAGS >"$fl_compile_log" 2>&1; then
        PAIR_PHASE="fl_compile"
        PAIR_MESSAGE="Flowlog compile failed; tail: $(tail -3 "$fl_compile_log" | tr '\n' ';')"
        fail "$query: Flowlog compilation failed"
        echo "         $(tail -3 "$fl_compile_log")"
        emit_summary_row
        return 1
    fi
    if [[ ! -x "$fl_bin" ]]; then
        PAIR_PHASE="fl_binary_missing"
        PAIR_MESSAGE="$fl_bin not found after compilation"
        fail "$query: $PAIR_MESSAGE"
        emit_summary_row
        return 1
    fi

    # ── Load params ──
    local header
    header=$(head -1 "$param_file")
    mapfile -t param_rows < <(tail -n +2 "$param_file" | grep -v '^$')
    PAIR_PARAMS_AVAIL=${#param_rows[@]}
    if [[ "$MAX_PARAMS" -gt 0 && "$MAX_PARAMS" -lt "$PAIR_PARAMS_AVAIL" ]]; then
        param_rows=("${param_rows[@]:0:$MAX_PARAMS}")
    fi
    PAIR_PARAMS_SELECTED=${#param_rows[@]}
    log "$query: running $PAIR_PARAMS_SELECTED params (per-param)..."

    local orig_backup="${qwork}/param_backup.txt"
    cp "$param_file" "$orig_backup"
    trap "cp '$orig_backup' '$param_file' 2>/dev/null; trap - EXIT INT TERM" EXIT INT TERM

    local sql_subst idx=0
    sql_subst=$(sed "s|:dataDir|'${data_dir}'|g" "$sql_file")

    local row
    for row in "${param_rows[@]}"; do
        idx=$(( idx + 1 ))
        printf '%s\n%s\n' "$header" "$row" > "$param_file"

        local fl_param_out="${qwork}/fl_${idx}.txt"
        local db_param_out="${qwork}/db_${idx}.csv"
        local fl_rss_log="${qwork}/fl_${idx}.rss"
        local db_rss_log="${qwork}/db_${idx}.rss"
        local fl_status="ok" db_status="ok"
        local fl_ms="N/A" db_ms="N/A"
        local fl_rss="N/A" db_rss="N/A"
        local fl_rows=0 db_rows=0
        local row_verdict=""

        # ── FlowLog ──
        find "$fl_out_dir" -maxdepth 1 -type f -delete 2>/dev/null || true
        printf "\r${CYAN}[CHECK]${NC} Flowlog  [%d/%d]  " "$idx" "$PAIR_PARAMS_SELECTED" >&2
        local fl_workers="${FLOWLOG_WORKERS:-$WORKERS}"
        local _fl_rc=0
        # /usr/bin/time -v writes its sidecar to $fl_rss_log via -o; FL's
        # stdout/stderr are still discarded the same way as before.
        # Exit code propagation: time -v → timeout → fl_bin. timeout
        # exits 124 on SIGTERM cap; that's what we classify on.
        "$TIME_BIN" -v -o "$fl_rss_log" \
            timeout "$TIMEOUT_SECS" "$fl_bin" -w "$fl_workers" \
            >/dev/null 2>&1 || _fl_rc=$?
        case $_fl_rc in
            0)
                fl_ms=$(_extract_elapsed_ms "$fl_rss_log")
                fl_rss=$(_extract_peak_rss_kb "$fl_rss_log")
                for f in "$fl_out_dir"/*; do
                    [[ -f "$f" ]] && grep -v '^$' "$f" >> "$fl_param_out" || true
                done
                ;;
            124)
                fl_status="timeout"
                PAIR_FL_TIMEOUTS=$((PAIR_FL_TIMEOUTS + 1))
                : > "$fl_param_out"
                ;;
            *)
                fl_status="error"
                PAIR_FL_ERRORS=$((PAIR_FL_ERRORS + 1))
                : > "$fl_param_out"
                ;;
        esac

        # ── DuckDB ──
        local exec_sql="${qwork}/exec_${idx}.sql"
        printf 'SET threads=%s;\n%s\n' "$WORKERS" "$sql_subst" > "$exec_sql"
        printf "\r${CYAN}[CHECK]${NC} DuckDB   [%d/%d]  " "$idx" "$PAIR_PARAMS_SELECTED" >&2
        local _db_rc=0
        # Pipeline: TIME_BIN -v -o sidecar timeout T duckdb ... | tail.
        # PIPESTATUS[0] is /usr/bin/time's exit, which propagates the
        # underlying timeout's. tail -n +2 strips the CSV header row.
        "$TIME_BIN" -v -o "$db_rss_log" \
            timeout "$TIMEOUT_SECS" "$DUCKDB_BIN" -csv :memory: < "$exec_sql" 2>/dev/null \
            | tail -n +2 > "$db_param_out" || true
        _db_rc=${PIPESTATUS[0]}
        case $_db_rc in
            0)
                db_ms=$(_extract_elapsed_ms "$db_rss_log")
                db_rss=$(_extract_peak_rss_kb "$db_rss_log")
                ;;
            124)
                db_status="timeout"
                PAIR_DB_TIMEOUTS=$((PAIR_DB_TIMEOUTS + 1))
                : > "$db_param_out"
                ;;
            *)
                db_status="error"
                PAIR_DB_ERRORS=$((PAIR_DB_ERRORS + 1))
                : > "$db_param_out"
                ;;
        esac

        # ── Determine row verdict + correctness check ──
        # Engine-level failures take precedence over correctness check —
        # we can't compare a missing output. Order matters for clarity:
        # surface FL_TIMEOUT before DB_TIMEOUT only because FL ran first
        # in this loop iteration; either is a real failure.
        if [[ "$fl_status" == "timeout" ]]; then
            row_verdict="FL_TIMEOUT"
        elif [[ "$fl_status" == "error" ]]; then
            row_verdict="FL_ERROR"
        elif [[ "$db_status" == "timeout" ]]; then
            row_verdict="DB_TIMEOUT"
        elif [[ "$db_status" == "error" ]]; then
            row_verdict="DB_ERROR"
        else
            # Both succeeded — set-equality compare row sets.
            #
            # Whitespace normalization (rstrip per field, both sides):
            # FlowLog's CSV input parser strips trailing whitespace from
            # string fields on load; DuckDB preserves it. The raw LDBC
            # data (e.g. comment.txt) does contain rows whose content
            # field ends in a trailing space — DuckDB emits them with
            # the space, FlowLog never sees the space. Without
            # normalization, every such row appears in both only_db and
            # only_fl with otherwise identical content, masking a clean
            # semantic agreement as a 6%+ row mismatch on q2 / q13.
            #
            # We rstrip each field on both sides before set-equality so
            # the comparator measures the engines' computational
            # agreement, not their CSV-parser cosmetics. Leading
            # whitespace is preserved on both engines, so we don't strip
            # it. If a future query needs strict trailing-whitespace
            # semantics, the raw row sets are still in qwork until the
            # rm at the end of run_per_param.
            local cmp
            cmp=$(python3 - "$db_param_out" "$fl_param_out" <<'PYEOF'
import sys, csv

def _norm(row):
    # rstrip each field — see ldbc.sh comment for rationale.
    return tuple(s.rstrip() for s in row)

def load_csv(p):
    rows = set()
    with open(p, newline='') as f:
        for r in csv.reader(f):
            if r: rows.add(_norm(r))
    return rows
def load_fl(p):
    rows = set()
    with open(p) as f:
        for line in f:
            # rstrip the whole line first to drop the line terminator
            # without losing meaningful inner whitespace; then split on
            # the field delimiter and rstrip each field.
            line = line.rstrip('\n\r')
            if line: rows.add(_norm(line.split('|')))
    return rows
db = load_csv(sys.argv[1]); fl = load_fl(sys.argv[2])
od, of = db - fl, fl - db
print(f"DB_ROWS {len(db)}")
print(f"FL_ROWS {len(fl)}")
if not od and not of:
    print("PASS")
else:
    print(f"FAIL only_db={len(od)} only_fl={len(of)}")
    for r in list(od)[:3]: print(f"    DB: {r}")
    for r in list(of)[:3]: print(f"    FL: {r}")
PYEOF
            )
            db_rows=$(awk '/^DB_ROWS/ {print $2; exit}' <<< "$cmp")
            fl_rows=$(awk '/^FL_ROWS/ {print $2; exit}' <<< "$cmp")
            db_rows=${db_rows:-0}
            fl_rows=${fl_rows:-0}
            PAIR_FL_TOTAL_ROWS=$((PAIR_FL_TOTAL_ROWS + fl_rows))
            PAIR_DB_TOTAL_ROWS=$((PAIR_DB_TOTAL_ROWS + db_rows))
            if grep -q '^PASS$' <<< "$cmp"; then
                row_verdict="OK"
                PAIR_PARAMS_COUNTED=$((PAIR_PARAMS_COUNTED + 1))
                PAIR_ROWS_OK=$((PAIR_ROWS_OK + db_rows))
                PAIR_FL_TIMES+=( "$fl_ms" )
                PAIR_DB_TIMES+=( "$db_ms" )
                [[ "$fl_rss" =~ ^[0-9]+$ ]] && PAIR_FL_RSS+=( "$fl_rss" )
                [[ "$db_rss" =~ ^[0-9]+$ ]] && PAIR_DB_RSS+=( "$db_rss" )
            else
                row_verdict="MISMATCH"
                PAIR_MISMATCHES=$((PAIR_MISMATCHES + 1))
                {
                    echo "=== param[$idx] ($row) ==="
                    echo "$cmp"
                    echo
                } >> "$mismatch_log"
            fi
        fi

        # Append per-param TSV row. Sanitize the param row in case it
        # contains tab characters (LDBC params are pipe-delimited so
        # this should not happen, but cheap insurance).
        local row_sanitized="${row//$'\t'/ }"
        printf '%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\n' \
            "$idx" "$row_sanitized" \
            "$fl_ms" "$db_ms" \
            "$fl_rss" "$db_rss" \
            "$fl_rows" "$db_rows" \
            "$row_verdict" \
            >> "$perparam_tsv"
    done
    printf "\r%80s\r" "" >&2

    cp "$orig_backup" "$param_file"
    trap - EXIT INT TERM

    # ── Pair-level verdict ──
    # OK      = every selected param produced matched output.
    # PARTIAL = some selected params succeeded + matched, but at least
    #           one had timeout/error/mismatch.
    # FAIL    = zero selected params produced matched output (or the
    #           pair failed before this loop, handled in early-returns
    #           above).
    local has_failures=false
    if (( PAIR_FL_ERRORS + PAIR_FL_TIMEOUTS + PAIR_DB_ERRORS + PAIR_DB_TIMEOUTS + PAIR_MISMATCHES > 0 )); then
        has_failures=true
    fi
    if (( PAIR_PARAMS_COUNTED == 0 )); then
        PAIR_VERDICT="FAIL"
        PAIR_PHASE="all_params_failed"
        PAIR_MESSAGE="0/${PAIR_PARAMS_SELECTED} params produced matched output (FL_err=${PAIR_FL_ERRORS} FL_to=${PAIR_FL_TIMEOUTS} DB_err=${PAIR_DB_ERRORS} DB_to=${PAIR_DB_TIMEOUTS} mismatch=${PAIR_MISMATCHES})"
    elif $has_failures; then
        PAIR_VERDICT="PARTIAL"
        PAIR_PHASE="param_loop"
        PAIR_MESSAGE="${PAIR_PARAMS_COUNTED}/${PAIR_PARAMS_SELECTED} OK (FL_err=${PAIR_FL_ERRORS} FL_to=${PAIR_FL_TIMEOUTS} DB_err=${PAIR_DB_ERRORS} DB_to=${PAIR_DB_TIMEOUTS} mismatch=${PAIR_MISMATCHES})"
    else
        PAIR_VERDICT="OK"
        PAIR_PHASE="ok"
        PAIR_MESSAGE=""
    fi

    # ── Per-pair console summary ──
    local fl_med fl_avg db_med db_avg fl_rss_med db_rss_med
    fl_med=$(_median_int "${PAIR_FL_TIMES[@]}")
    fl_avg=$(_avg_int    "${PAIR_FL_TIMES[@]}")
    db_med=$(_median_int "${PAIR_DB_TIMES[@]}")
    db_avg=$(_avg_int    "${PAIR_DB_TIMES[@]}")
    fl_rss_med=$(_median_int "${PAIR_FL_RSS[@]}")
    db_rss_med=$(_median_int "${PAIR_DB_RSS[@]}")

    case "$PAIR_VERDICT" in
        OK)
            pass "${query}  (${PAIR_ROWS_OK} rows, ${PAIR_PARAMS_SELECTED} params)"
            ;;
        PARTIAL)
            fail "${query}  PARTIAL: ${PAIR_PARAMS_COUNTED}/${PAIR_PARAMS_SELECTED} params OK"
            ;;
        *)
            fail "${query}  FAIL: ${PAIR_MESSAGE}"
            ;;
    esac
    if [[ ${#PAIR_FL_TIMES[@]} -gt 0 ]]; then
        echo "         Flowlog  med=$(fmt_ms "${fl_med:-0}")  avg=$(fmt_ms "${fl_avg:-0}")  rss_med=$(_kib_to_mib "${fl_rss_med:-N/A}") MiB"
        echo "         DuckDB   med=$(fmt_ms "${db_med:-0}")  avg=$(fmt_ms "${db_avg:-0}")  rss_med=$(_kib_to_mib "${db_rss_med:-N/A}") MiB"
    fi
    if (( PAIR_MISMATCHES > 0 )); then
        echo "         Mismatch detail: $mismatch_log"
    fi
    if (( PAIR_FL_ERRORS + PAIR_FL_TIMEOUTS + PAIR_DB_ERRORS + PAIR_DB_TIMEOUTS > 0 )); then
        echo "         Per-param detail: $perparam_tsv"
    fi

    # Reclaim disk: bulky raw .txt outputs in qwork are no longer needed.
    # Mismatch artifact lives in $LDBC_OUT_DIR (outside qwork) so survives.
    rm -rf "$qwork"

    emit_summary_row
    [[ "$PAIR_VERDICT" == "OK" ]] && return 0 || return 1
}

# ── End-of-run summary table ──────────────────────────────────────────────────
# Parse summary.csv back and print a fixed-width table to stdout. Mirrors
# cross_engine.sh's generate_results in shape — operators get a quick
# "how did the sweep go" view without scrolling through per-pair output.
print_summary_table() {
    [[ -s "$SUMMARY_CSV" ]] || return 0
    local n_rows
    n_rows=$(( $(wc -l < "$SUMMARY_CSV") - 1 ))   # subtract header
    (( n_rows > 0 )) || return 0

    echo
    echo "=== LDBC summary (workers=$WORKERS) ==============================================================="
    printf '%-32s %-30s %4s %4s %10s %10s %9s %9s %9s  %s\n' \
        "Query" "Dataset" "Avl" "Cnt" "FL_med" "DB_med" "Speedup" "FL_RSS" "DB_RSS" "Verdict"
    printf -- '-%.0s' {1..130}; echo
    awk -F',' 'NR > 1 {
        # Field map: 1=Query 2=Dataset 3=Available 5=Counted
        # 6=FL_med_ms 8=DB_med_ms 10=Speedup 11=FL_RSS_MiB 12=DB_RSS_MiB 21=Verdict
        flms = ($6 == "N/A") ? "N/A" : $6 "ms"
        dbms = ($8 == "N/A") ? "N/A" : $8 "ms"
        spd  = ($10 == "N/A") ? "N/A" : $10 "x"
        flmm = ($11 == "N/A") ? "N/A" : $11 "MiB"
        dbmm = ($12 == "N/A") ? "N/A" : $12 "MiB"
        printf "%-32s %-30s %4s %4s %10s %10s %9s %9s %9s  %s\n",
            $1, $2, $3, $5, flms, dbms, spd, flmm, dbmm, $21
    }' "$SUMMARY_CSV"
    echo
}


# ── Main loop ─────────────────────────────────────────────────────────────────
# Group queries by dataset so each dataset is downloaded/cleaned up only once.
# Also detects duplicate (query, dataset) entries — the per-param TSV
# path is keyed on that pair, so duplicates would silently overwrite.
declare -A dataset_queries   # dataset -> space-separated query list
declare -A pair_seen         # "query=dataset" -> 1
declare -a dataset_order=()  # preserve first-seen order

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue

    query="$(trim "${line%%=*}")"
    dataset="$(trim "${line#*=}")"
    [[ -z "$query" || -z "$dataset" ]] && continue

    pair_key="${query}=${dataset}"
    if [[ -n "${pair_seen[$pair_key]+x}" ]]; then
        die "duplicate config entry: $pair_key (lines must be unique — per-param TSV path collides)"
    fi
    pair_seen[$pair_key]=1

    if [[ -z "${dataset_queries[$dataset]+x}" ]]; then
        dataset_queries[$dataset]=""
        dataset_order+=( "$dataset" )
    fi
    dataset_queries[$dataset]+="${query} "
done < "$CONFIG"

(( ${#dataset_order[@]} > 0 )) || die "no (query, dataset) pairs in $CONFIG"

total=0; passed=0; failed=0

for dataset in "${dataset_order[@]}"; do
    setup_dataset "$dataset"
    DATA_DIR="${FACT_DIR}/${dataset}"

    for query in ${dataset_queries[$dataset]}; do
        log "$query (dataset: $dataset)"
        total=$((total + 1))

        # run_per_param does its own missing-file checks + always emits
        # exactly one summary.csv row before returning, so the main
        # loop here is just bookkeeping.
        if run_per_param "$query" "$dataset" "$DATA_DIR"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
    done

    cleanup_dataset "$dataset"
done

print_summary_table

echo "=========================================="
echo "Results: ${passed}/${total} pairs OK, ${failed} pair(s) PARTIAL/FAIL"
echo "Artifacts: ${LDBC_OUT_DIR}/"
echo "  summary.csv                           # one row per (query, dataset)"
echo "  <query>_<dataset>_perparam.tsv        # per-param granular timings + RSS"
echo "  <query>_<dataset>_mismatches.txt      # only when MISMATCH verdict appears"
echo "  run_info.txt                          # reproducibility manifest"
echo "=========================================="
[[ $failed -eq 0 ]]
