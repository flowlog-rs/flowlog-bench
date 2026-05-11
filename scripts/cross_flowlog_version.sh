#!/usr/bin/env bash
#
# scripts/cross_flowlog_version.sh — perf + peak-RSS drift check between two flowlog refs.
#
# Designed for closed-loop tooling that wants to verify a series of
# in-tree changes hasn't regressed any benchmark beyond a tolerance,
# without invoking the heavy `cross_engine.sh` cross-engine machinery
# (no Soufflé, no legacy interpreter).
#
# What it does:
#   1. Read a list of `<prog>=<dataset>` pairs from a config file
#      (same format as `config/default.txt`; per-pair `[tag]` markers
#      are stripped so the same files can be reused).
#   2. For each pair, compile <prog>.dl with each ref's flowlog-compiler
#      and run the resulting binary NUM_RUNS times; capture the median
#      "Dataflow executed in <Dur>" + median peak RSS.
#   3. Compare each metric to BASE; flag PASS / FAIL.
#   4. Exit 0 iff every pair stayed within both tolerances; otherwise 1.
#
# Build strategy: BASE and HEAD are both fetched + built via
# scripts/get_flowlog.sh into flowlog/<short_sha>/. Each cached build
# survives across runs, so iterative loops (same BASE, varying HEAD)
# only pay for HEAD's build. `flowlog/` and `results/` are gitignored.
#
# Output:
#   - One stdout line per pair on success: `<pair>  time%  rss%  OK`
#   - The summary table on stdout when every pair is OK; on stderr
#     when any pair failed, so wrapper scripts can keep extractors
#     pointed at stdout for clean signals.
#
# Exit code:
#   0  every pair within tolerances
#   1  at least one pair regressed beyond a tolerance
#   2  argument / I/O error (config missing, ref unknown)
#   3  internal error (get_flowlog.sh, cargo build, compile/run failure)
#
# Usage:
#   scripts/cross_flowlog_version.sh [--keep-datasets] <base_ref> <head_ref> <config_file>
#   scripts/cross_flowlog_version.sh --help
#
#   --keep-datasets   skip per-pair dataset cleanup. Required if $FACT_DIR
#                     is a symlink — the runner refuses to rm -rf through
#                     one (would wipe the linked target).
#
# Or via the env-var form:
#   FLOWLOG_BASE=abc1234 FLOWLOG_HEAD=def5678 make cross-flowlog-version CONFIG=config/default.txt
#
# Both refs are passed to scripts/get_flowlog.sh (branch / tag / sha all OK).
# Each fetched build is cached at flowlog/<short_sha>/, so re-running the
# same BASE-vs-HEAD is free after the first build.
#
# Datasets: this script downloads each pair's dataset into $FACT_DIR
# (default: ROOT_DIR/facts) before benching and removes it after both
# refs have been measured (skipped under --keep-datasets).
#
# Environment:
#   PERF_COMPARE_TIME_PCT     wall-time regression tolerance  (default 10)
#   PERF_COMPARE_RSS_PCT      peak-RSS regression tolerance   (default 20)
#   PERF_COMPARE_NUM_RUNS     timed runs per ref per pair     (default 3)
#   PERF_COMPARE_WORKERS      `-w` value passed to the binary (default
#                             min(64, nproc) — matches cross_engine.sh)
#
# This script is the implementation behind `make cross-flowlog-version`.

set -euo pipefail

# ----------------------------------------------------------------------
# --help: extract the doc header above (everything up to the first
# bash command after `set -euo pipefail`).
# ----------------------------------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    awk '/^set -euo pipefail/ { exit }
         NR > 1 { sub(/^# ?/, ""); print }' "$0"
    exit 0
fi

# ----------------------------------------------------------------------
# Argument parsing.
# ----------------------------------------------------------------------
KEEP_DATASETS=0
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
    echo "usage: $0 [--keep-datasets] <base_ref> <head_ref> <config_file>" >&2
    echo "       $0 --help" >&2
    exit 2
fi
BASE_SHA="${POSITIONAL[0]}"
HEAD_SHA="${POSITIONAL[1]}"
CONFIG_FILE="${POSITIONAL[2]}"
export KEEP_DATASETS

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config file not found: $CONFIG_FILE" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Shared helpers (ANSI colors, cleanup_dataset_should_clean, time_wrap +
# extractors + median helpers, engine_compiler_run).
source "${ROOT_DIR}/scripts/lib/common.sh"
source "${ROOT_DIR}/scripts/lib/datasets.sh"
source "${ROOT_DIR}/scripts/lib/measure.sh"

PROG_DIR="${PROG_DIR:-${ROOT_DIR}/programs/oracle/flowlog}"
FACT_DIR="${FACT_DIR:-${ROOT_DIR}/facts}"
DATASET_URL="https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/resolve/main/dataset/csv"
TIME_BIN="${TIME_BIN:-/usr/bin/time}"
FLOWLOG_RUN_TIMEOUT="${FLOWLOG_RUN_TIMEOUT:-86400}"
export FACT_DIR TIME_BIN

TIME_PCT="${PERF_COMPARE_TIME_PCT:-10}"
RSS_PCT="${PERF_COMPARE_RSS_PCT:-20}"
NUM_RUNS="${PERF_COMPARE_NUM_RUNS:-3}"
# Default WORKERS = min(64, nproc): matches cross_engine.sh, caps at the
# VLDB rig's 64 cores so cross-machine numbers stay comparable, scales
# down on smaller hosts so a laptop doesn't context-switch through it.
_NPROC=$(nproc 2>/dev/null || echo 64)
[[ "$_NPROC" =~ ^[0-9]+$ ]] && (( _NPROC > 0 )) || _NPROC=64
WORKERS="${PERF_COMPARE_WORKERS:-$(( _NPROC < 64 ? _NPROC : 64 ))}"

for var in TIME_PCT RSS_PCT NUM_RUNS WORKERS; do
    val="${!var}"
    [[ "$val" =~ ^[0-9]+$ ]] \
        || { echo "ERROR: PERF_COMPARE_$var must be a non-negative integer (got: $val)" >&2; exit 2; }
done

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
die() { printf '%s[ERROR]%s %s\n' "${RED}" "${NC}" "$*" >&2; exit 1; }

[[ -x "$TIME_BIN" ]] || die "GNU /usr/bin/time not found at $TIME_BIN; apt install time"

# engine_compiler_run reuses the same compile+run primitive cross_engine.sh
# uses — DRY: there's exactly one place that knows how to compile + run +
# pick a median for the flowlog compiler.
source "${ROOT_DIR}/scripts/engines/compiler.sh"

# ----------------------------------------------------------------------
# Resolve shas via scripts/get_flowlog.sh — both BASE and HEAD are *fetched*
# inputs in the bench repo (no in-tree HEAD assumption like the original
# in-flowlog version). FLOWLOG_BASE and FLOWLOG_HEAD env vars override
# the positional args (matches the AGENTS.md "Specifying which flowlog
# commit to bench" call shape).
# ----------------------------------------------------------------------
BASE_REF="${FLOWLOG_BASE:-$BASE_SHA}"
HEAD_REF="${FLOWLOG_HEAD:-$HEAD_SHA}"

log "fetching + building BASE: $BASE_REF"
read BASE_FULL BASE_SHORT BASE_TREE < <(FLOWLOG_REF="$BASE_REF" bash "${ROOT_DIR}/scripts/get_flowlog.sh" | tail -1)
[[ -n "${BASE_FULL:-}" ]] || { echo "ERROR: get_flowlog.sh failed for BASE=$BASE_REF" >&2; exit 3; }

log "fetching + building HEAD: $HEAD_REF"
read HEAD_FULL HEAD_SHORT HEAD_TREE < <(FLOWLOG_REF="$HEAD_REF" bash "${ROOT_DIR}/scripts/get_flowlog.sh" | tail -1)
[[ -n "${HEAD_FULL:-}" ]] || { echo "ERROR: get_flowlog.sh failed for HEAD=$HEAD_REF" >&2; exit 3; }

if [[ "$BASE_FULL" == "$HEAD_FULL" ]]; then
    echo "ERROR: BASE and HEAD resolve to the same sha ($BASE_FULL); nothing to compare" >&2
    exit 2
fi

# ----------------------------------------------------------------------
# Parse the config: one `<prog>=<dataset>` per line, blanks/comments
# skipped, trailing `[tag]` markers (a cross_engine.sh feature) stripped so
# the same files can be reused across both tools.
# ----------------------------------------------------------------------
PAIRS=()
while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    while [[ "$line" =~ ^(.*[^[:space:]])[[:space:]]+(\[[^][]+\])[[:space:]]*$ ]]; do
        line="${BASH_REMATCH[1]}"
    done
    [[ "$line" == *=* ]] || { echo "ERROR: malformed pair (expected '<prog>=<dataset>'): $raw" >&2; exit 2; }
    PAIRS+=("$line")
done < "$CONFIG_FILE"

(( ${#PAIRS[@]} > 0 )) || { echo "ERROR: config has no pairs: $CONFIG_FILE" >&2; exit 2; }

# ----------------------------------------------------------------------
# BASE and HEAD trees are populated by scripts/get_flowlog.sh above.
# Each lives at flowlog/<short_sha>/target/release/flowlog-compiler.
# ----------------------------------------------------------------------
log "config             : $CONFIG_FILE  (${#PAIRS[@]} pair(s))"
log "base sha           : $BASE_FULL  ($BASE_TREE)"
log "head sha           : $HEAD_FULL  ($HEAD_TREE)"
log "tolerances         : time +${TIME_PCT}%, peak RSS +${RSS_PCT}%"
log "bench knobs        : NUM_RUNS=$NUM_RUNS, WORKERS=$WORKERS"

# ----------------------------------------------------------------------
# Durable per-run output dir under results/cross-flowlog-version/.
# Honours AGENTS.md principle 3 (scripts only write to results/) and
# gives principle 6 something to anchor the run_info.txt manifest to.
#
# Strict resume: a re-run with the SAME OUT_DIR but a different identity
# (workers, num_runs, tolerances, config sha) hard-fails so we don't
# silently clobber a previous A/B result. --fresh wipes and starts over.
# ----------------------------------------------------------------------
OUT_DIR="${ROOT_DIR}/results/cross-flowlog-version/${BASE_SHORT}_vs_${HEAD_SHORT}"
mkdir -p "$OUT_DIR"
SUMMARY_TSV="${OUT_DIR}/summary.tsv"

# Write the run_info.txt manifest now (before benching). The manifest
# captures BOTH refs, so a year from now you can reproduce the exact
# A/B even if both refs have moved or been rewritten.
RUN_INFO_BENCH_ROOT="$ROOT_DIR"
RUN_INFO_RUNNER="cross_flowlog_version.sh"
RUN_INFO_CONFIG_PATH="$CONFIG_FILE"
# cross_flowlog_version resolves two SHAs via get_flowlog.sh; we record both
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
        "time_pct=${TIME_PCT}" \
        "rss_pct=${RSS_PCT}" \
    || die "resume blocked — see diff above. Use --fresh to start over."
log "output dir         : $OUT_DIR"

# ----------------------------------------------------------------------
# bench_pair <tree_path> <prog_rel> <dataset_name> <sublabel>
#
# Thin wrapper around engine_compiler_run: sets COMPILER_BIN + LOG_DIR
# for the given <tree_path>, runs the engine adapter, then reads the
# median time + median RSS back out of the sidecars it writes.
#
# <sublabel> is "base" or "head" — selects ${OUT_DIR}/<sublabel>/ as
# this call's LOG_DIR so per-tree per-pair logs are kept side-by-side
# under the run's results dir.
#
# Emits "<median_sec> <median_kb>" on stdout; returns 1 on any failure
# (missing binary, all runs failed).
# ----------------------------------------------------------------------
bench_pair() {
    local tree="$1" prog="$2" ds="$3" sublabel="$4"
    COMPILER_BIN="${tree}/target/release/flowlog-compiler"
    LOG_DIR="${OUT_DIR}/${sublabel}"
    mkdir -p "$LOG_DIR"

    [[ -x "$COMPILER_BIN" ]] \
        || { log "$RED" "FAIL" "compiler not found: $COMPILER_BIN"; return 1; }

    engine_compiler_run "$prog" "$ds" || return 1

    # Read back the medians from engine_compiler_run's sidecar layout.
    local stem; stem="$(basename "$prog" .dl)"
    local best_log="${LOG_DIR}/${stem}_${ds}_compiler.log"
    local sec rss
    sec=$(extract_total_seconds "$best_log")
    rss=$(cat "${best_log}.median_rss_kb" 2>/dev/null || echo "N/A")
    [[ "$sec" =~ ^[0-9] ]] || return 1
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

for pair in "${PAIRS[@]}"; do
    b_sec="${B_SEC[$pair]:-}"; h_sec="${H_SEC[$pair]:-}"
    b_kb="${B_KB[$pair]:-}";   h_kb="${H_KB[$pair]:-}"

    if [[ -z "$b_sec" || -z "$h_sec" ]]; then
        ROWS+=("${pair}|${b_sec:-N/A}|${h_sec:-N/A}|N/A|${b_kb:-N/A}|${h_kb:-N/A}|N/A|MEASURE_FAIL")
        FAILED=1
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
[[ "$FAILED" = "1" ]] && SINK=2

# Persist summary as TSV alongside the run_info.txt manifest. This is
# the durable artifact that makes regression runs reconstructable
# (principle 6) without having to scroll back through stdout.
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
    if (( FAILED )); then
        printf '%sREGRESSION%s — at least one pair exceeded a tolerance\n' "$RED" "$NC"
    else
        printf '%sALL OK%s — every pair within tolerances\n' "$GREEN" "$NC"
    fi
    printf '\n'
} >&$SINK

exit $FAILED
