#!/usr/bin/env bash
#
# scripts/regression.sh — perf + peak-RSS drift check between two flowlog refs.
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
#   2. For each pair, run `scripts/bench_one.sh <prog> <dataset>` twice
#      — once against <base_ref>'s build, once against <head_ref>'s —
#      capturing the median elapsed_seconds + median peak_rss_kb from
#      bench_one's stable stdout contract.
#   3. Compare each metric to its baseline; flag PASS / FAIL.
#   4. Exit 0 iff every pair stayed within both tolerances; otherwise 1.
#
# Build strategy: BASE and HEAD are both fetched + built via
# tools/get_flowlog.sh into flowlog/<short_sha>/. Each cached build
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
#   3  internal error (get_flowlog.sh, cargo build, bench_one)
#
# Usage:
#   scripts/regression.sh <base_ref> <head_ref> <config_file>
#   scripts/regression.sh --help
#
# Or via the AGENTS.md-canonical env-var form (see "Specifying which
# flowlog commit to bench"):
#   FLOWLOG_BASE=abc1234 FLOWLOG_HEAD=def5678 make regression CONFIG=config/default.txt
#
# Both refs are passed to tools/get_flowlog.sh (branch / tag / sha all OK).
# Each fetched build is cached at flowlog/<short_sha>/, so re-running the
# same BASE-vs-HEAD is free after the first build.
#
# Environment:
#   PERF_COMPARE_TIME_PCT     wall-time regression tolerance  (default 10)
#   PERF_COMPARE_RSS_PCT      peak-RSS regression tolerance   (default 20)
#   PERF_COMPARE_NUM_RUNS     bench_one.sh NUM_RUNS           (default 3)
#   PERF_COMPARE_WORKERS      bench_one.sh WORKERS            (default 1
#                             — single-thread is the most stable signal
#                             for small-bench measurements)
#
# This script is the implementation behind `make regression`.

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
if [[ $# -ne 3 ]]; then
    echo "usage: $0 <base_ref> <head_ref> <config_file>" >&2
    echo "       $0 --help" >&2
    exit 2
fi
BASE_SHA="$1"
HEAD_SHA="$2"
CONFIG_FILE="$3"

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config file not found: $CONFIG_FILE" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Shared helpers (ANSI colors). log() stays local so the [perf-compare]
# brand prefix is preserved.
source "${ROOT_DIR}/scripts/lib/common.sh"

TIME_PCT="${PERF_COMPARE_TIME_PCT:-10}"
RSS_PCT="${PERF_COMPARE_RSS_PCT:-20}"
NUM_RUNS="${PERF_COMPARE_NUM_RUNS:-3}"
WORKERS="${PERF_COMPARE_WORKERS:-1}"

for var in TIME_PCT RSS_PCT NUM_RUNS WORKERS; do
    val="${!var}"
    [[ "$val" =~ ^[0-9]+$ ]] \
        || { echo "ERROR: PERF_COMPARE_$var must be a non-negative integer (got: $val)" >&2; exit 2; }
done

log() { printf '%s[perf-compare]%s %s\n' "${BLUE}" "${NC}" "$*" >&2; }

# ----------------------------------------------------------------------
# Resolve shas via tools/get_flowlog.sh — both BASE and HEAD are *fetched*
# inputs in the bench repo (no in-tree HEAD assumption like the original
# in-flowlog version). FLOWLOG_BASE and FLOWLOG_HEAD env vars override
# the positional args (matches the AGENTS.md "Specifying which flowlog
# commit to bench" call shape).
# ----------------------------------------------------------------------
BASE_REF="${FLOWLOG_BASE:-$BASE_SHA}"
HEAD_REF="${FLOWLOG_HEAD:-$HEAD_SHA}"

log "fetching + building BASE: $BASE_REF"
read BASE_FULL BASE_SHORT BASE_TREE < <(FLOWLOG_REF="$BASE_REF" bash "${ROOT_DIR}/tools/get_flowlog.sh" | tail -1)
[[ -n "${BASE_FULL:-}" ]] || { echo "ERROR: get_flowlog.sh failed for BASE=$BASE_REF" >&2; exit 3; }

log "fetching + building HEAD: $HEAD_REF"
read HEAD_FULL HEAD_SHORT HEAD_TREE < <(FLOWLOG_REF="$HEAD_REF" bash "${ROOT_DIR}/tools/get_flowlog.sh" | tail -1)
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
# BASE and HEAD trees are populated by tools/get_flowlog.sh above.
# Each lives at flowlog/<short_sha>/ with src + target/release/.
# Both `facts/` resolution and the bench primitive (bench_one.sh) live
# in the bench repo — we do NOT shell into the fetched flowlog tree's
# legacy tools/benchmark/ (which doesn't exist post-split: the perf
# surface lives only in this repo).
# ----------------------------------------------------------------------
log "config             : $CONFIG_FILE  (${#PAIRS[@]} pair(s))"
log "base sha           : $BASE_FULL  ($BASE_TREE)"
log "head sha           : $HEAD_FULL  ($HEAD_TREE)"
log "tolerances         : time +${TIME_PCT}%, peak RSS +${RSS_PCT}%"
log "bench knobs        : NUM_RUNS=$NUM_RUNS, WORKERS=$WORKERS"

# ----------------------------------------------------------------------
# Durable per-run output dir under results/regression/. Honours
# AGENTS.md principle 3 (scripts only write to results/) and gives
# principle 6 something to anchor the run_info.txt manifest to.
#
# Wipe-and-recreate: regression.sh has no resume model — every
# invocation is fresh, so back-to-back invocations with the same
# BASE+HEAD pair (rare, but possible) do not accumulate stale rows.
# ----------------------------------------------------------------------
OUT_DIR="${ROOT_DIR}/results/regression/${BASE_SHORT}_vs_${HEAD_SHORT}"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
SUMMARY_TSV="${OUT_DIR}/summary.tsv"

# Write the run_info.txt manifest now (before benching). The manifest
# captures BOTH refs, so a year from now you can reproduce the exact
# A/B even if both refs have moved or been rewritten.
RUN_INFO_BENCH_ROOT="$ROOT_DIR"
RUN_INFO_RUNNER="regression.sh"
RUN_INFO_CONFIG_PATH="$CONFIG_FILE"
# regression resolves two SHAs via get_flowlog.sh; we record both
# explicitly. The single FLOWLOG_RESOLVED_SHA slot in run_info.sh
# becomes "n/a (see base_sha + head_sha)".
FLOWLOG_RESOLVED_SHA="n/a (A/B run — see base_sha + head_sha)"
FLOWLOG_BIN="(varies — base + head trees benched separately)"
FLOWLOG_REF="(see base_ref + head_ref)"
export RUN_INFO_BENCH_ROOT RUN_INFO_RUNNER RUN_INFO_CONFIG_PATH \
       FLOWLOG_RESOLVED_SHA FLOWLOG_BIN FLOWLOG_REF WORKERS NUM_RUNS
source "${ROOT_DIR}/scripts/lib/run_info.sh"
write_run_info "$OUT_DIR" \
    "base_ref=${BASE_REF}" \
    "base_sha=${BASE_FULL}" \
    "base_short=${BASE_SHORT}" \
    "head_ref=${HEAD_REF}" \
    "head_sha=${HEAD_FULL}" \
    "head_short=${HEAD_SHORT}" \
    "time_pct=${TIME_PCT}" \
    "rss_pct=${RSS_PCT}"
log "output dir         : $OUT_DIR"

# ----------------------------------------------------------------------
# Bench one pair against a given fetched flowlog tree. Returns
# "<sec> <kb>" on stdout (both medians, per bench_one's stable contract);
# empty on failure. We invoke bench_one.sh from THIS repo's scripts/
# and override FLOWLOG_SRC_DIR so the lib-mode runner's Cargo path-dep
# resolves into the chosen flowlog source tree.
# ----------------------------------------------------------------------
bench_one_pair() {
    local tree="$1" prog="$2" ds="$3"
    local out
    if ! out=$(WORKERS="$WORKERS" NUM_RUNS="$NUM_RUNS" QUIET=1 \
               FLOWLOG_SRC_DIR="${tree}/src" \
               FLOWLOG_BIN="${tree}/target/release/flowlog-compiler" \
               bash "${ROOT_DIR}/scripts/bench_one.sh" "$prog" "$ds" 2>/dev/null); then
        return 1
    fi
    local sec kb
    sec=$(awk '$1 == "elapsed_seconds" { print $2; exit }' <<< "$out")
    kb=$( awk '$1 == "peak_rss_kb"     { print $2; exit }' <<< "$out")
    [[ -n "$sec" ]] || return 1
    printf '%s %s\n' "$sec" "${kb:-N/A}"
}

# ----------------------------------------------------------------------
# Iterate the pair list, collecting per-pair (b_sec, h_sec, b_kb, h_kb).
# ----------------------------------------------------------------------
declare -A B_SEC B_KB H_SEC H_KB

for pair in "${PAIRS[@]}"; do
    prog="${pair%%=*}"
    ds="${pair#*=}"
    log "pair: $pair"

    log "  base@${BASE_SHORT} ..."
    if out=$(bench_one_pair "$BASE_TREE" "$prog" "$ds"); then
        B_SEC[$pair]="${out% *}"; B_KB[$pair]="${out##* }"
    else
        log "  ${YELLOW}WARN${NC}: base bench failed for $pair"
    fi

    log "  head@${HEAD_SHORT} ..."
    if out=$(bench_one_pair "$HEAD_TREE" "$prog" "$ds"); then
        H_SEC[$pair]="${out% *}"; H_KB[$pair]="${out##* }"
    else
        log "  ${YELLOW}WARN${NC}: head bench failed for $pair"
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
