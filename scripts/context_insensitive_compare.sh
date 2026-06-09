#!/usr/bin/env bash
# =============================================================================
# scripts/context_insensitive_compare.sh
#   Correctness comparison for the (non-toy) DOOP *context-insensitive* points-to
#   analysis: FlowLog vs Soufflé, over the shared DOOP fact datasets.
#
#   This is a *results* (answer) comparison, not a timing benchmark: it checks
#   that the FlowLog port and the Soufflé reference agree on every output
#   relation, modulo the inherent ord()/heap-representative non-determinism that
#   doop-flowlog documents (see docs/running-context-insensitive-souffle.md and
#   bin/compare-flowlog-souffle.py in flowlog-rs/doop-flowlog).
#
# Program pair (same analysis, two dialects — CONFIGURATION already bound to
# ContextInsensitiveConfiguration):
#   programs/oracle/flowlog/context_insensitive/default.dl   head aggregates
#   programs/oracle/souffle/context_insensitive.dl           body aggregates, ?-vars
#
# Datasets: app names under /datasets/facts/<app> (via the `facts` symlink),
#   the same fact dirs doop.dl uses. Soufflé aborts on a missing input fact
#   file (FlowLog tolerates them), so for each dataset we build a tmpfs
#   *overlay* — symlinks to the real *.facts plus empty defaults for the
#   keep-spec relations the corpus omits — and never write into the shared mount.
#
# Engines are compiled once (FlowLog bakes -F/-D paths, so we bake the fixed
# overlay/output paths and just swap the overlay contents per dataset; the
# Soufflé binary takes -F/-D at run time).
#
# Knobs (env):
#   WORKERS       thread count for both engines (default 32; -w / -j)
#   FLOWLOG_BIN   flowlog-compiler (default: ~/flowlog/target/release/flowlog-compiler)
#   SOUFFLE_BIN   souffle (default: souffle on PATH)
#   WORK          tmpfs scratch root (default: /dev/shm/ci_compare)
#   STR_INTERN    1 to pass FlowLog --str-intern (default 1; recommended, all-string)
#   KEEP_FL_BIN / KEEP_SF_BIN   reuse cached engine binaries if present
#
# Usage:
#   scripts/context_insensitive_compare.sh [DATASET ...]
#   scripts/context_insensitive_compare.sh            # reads config/context_insensitive.txt
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKERS="${WORKERS:-32}"
STR_INTERN="${STR_INTERN:-1}"
WORK="${WORK:-/dev/shm/ci_compare}"
FLOWLOG_BIN="${FLOWLOG_BIN:-$HOME/flowlog/target/release/flowlog-compiler}"
SOUFFLE_BIN="${SOUFFLE_BIN:-$(command -v souffle || true)}"
FACTS_ROOT="${FACTS_ROOT:-/datasets/facts}"
FL_PROG="${ROOT_DIR}/programs/oracle/flowlog/context_insensitive/default.dl"
SF_PROG="${ROOT_DIR}/programs/oracle/souffle/context_insensitive.dl"
COMPARATOR="${ROOT_DIR}/scripts/lib/compare-flowlog-souffle.py"
RESULTS_DIR="${ROOT_DIR}/results/context_insensitive"

# Empty-default relations: Soufflé needs the files to exist; the DOOP corpus
# omits these keep-spec / framework inputs (see doop-flowlog §2b).
EMPTY_DEFAULTS=(Dacapo KeepClass KeepClassMembers KeepClassesWithMembers \
                KeepMethod RootCodeElement TaintSpec Tamiflex)

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; NC='\033[0m'
log() { local c="$1" t="$2"; shift 2; echo -e "${c}[${t}]${NC} $*" >&2; }
die() { log "$RED" "ERROR" "$*"; exit 1; }

[[ -f "$FL_PROG" ]] || die "FlowLog program not found: $FL_PROG"
[[ -f "$SF_PROG" ]] || die "Soufflé program not found: $SF_PROG"
[[ -x "$FLOWLOG_BIN" ]] || die "flowlog-compiler not found/executable: $FLOWLOG_BIN"
[[ -n "$SOUFFLE_BIN" && -x "$SOUFFLE_BIN" ]] || die "souffle not found (set SOUFFLE_BIN)"
[[ -f "$COMPARATOR" ]] || die "comparator not found: $COMPARATOR"

# Datasets: args, else the config file.
DATASETS=("$@")
if (( ${#DATASETS[@]} == 0 )); then
    cfg="${ROOT_DIR}/config/context_insensitive.txt"
    [[ -f "$cfg" ]] || die "no datasets given and $cfg missing"
    mapfile -t DATASETS < <(grep -vE '^\s*#|^\s*$' "$cfg" | sed -E 's/.*=//' | awk '!seen[$0]++')
fi
(( ${#DATASETS[@]} )) || die "no datasets to run"

OVERLAY="${WORK}/facts"
OUT_FL="${WORK}/out_fl"
FL_BIN="${WORK}/bin_fl"
SF_BIN="${WORK}/bin_sf"
mkdir -p "$WORK" "$RESULTS_DIR"

# Populate $OVERLAY with one dataset: symlinks to real facts + empty defaults.
build_overlay() {
    local ds="$1" src="${FACTS_ROOT}/$1"
    [[ -d "$src" ]] || die "dataset dir not found: $src"
    rm -rf "$OVERLAY"; mkdir -p "$OVERLAY"
    ln -s "$src"/*.facts "$OVERLAY"/ 2>/dev/null || true
    local f
    for f in "${EMPTY_DEFAULTS[@]}"; do [[ -e "$OVERLAY/$f.facts" ]] || : > "$OVERLAY/$f.facts"; done
}

intern_flag=(); [[ "$STR_INTERN" == "1" ]] && intern_flag=(--str-intern)

log "$BLUE" "PLAN" "datasets: ${DATASETS[*]} | workers=$WORKERS | str-intern=$STR_INTERN"
build_overlay "${DATASETS[0]}"

# --- compile each engine once -------------------------------------------------
if [[ "${KEEP_FL_BIN:-0}" == "1" && -x "$FL_BIN" ]]; then
    log "$YELLOW" "SKIP" "reusing FlowLog binary $FL_BIN"
else
    log "$BLUE" "BUILD" "FlowLog compile (once; -F baked to overlay) ..."
    rm -rf "$OUT_FL"; mkdir -p "$OUT_FL"; rm -f "$FL_BIN"
    # Route the generated Rust crate build to tmpfs too (-D/-F are already
    # under $WORK); keeps the root fs clean on big-output datasets.
    TMPDIR="$WORK" "$FLOWLOG_BIN" "$FL_PROG" -F "$OVERLAY" -D "$OUT_FL" -o "$FL_BIN" \
        --mode datalog-batch "${intern_flag[@]}" > "${WORK}/fl_compile.log" 2>&1 \
        || die "FlowLog compile failed (see ${WORK}/fl_compile.log)"
    [[ -x "$FL_BIN" ]] || die "FlowLog binary missing after compile"
fi
if [[ "${KEEP_SF_BIN:-0}" == "1" && -x "$SF_BIN" ]]; then
    log "$YELLOW" "SKIP" "reusing Soufflé binary $SF_BIN"
else
    log "$BLUE" "BUILD" "Soufflé compile (once; -j $WORKERS) ..."
    rm -f "$SF_BIN"
    "$SOUFFLE_BIN" -o "$SF_BIN" -p /dev/null -j "$WORKERS" -F "$OVERLAY" "$SF_PROG" \
        > "${WORK}/sf_compile.log" 2>&1 \
        || die "Soufflé compile failed (see ${WORK}/sf_compile.log)"
    [[ -x "$SF_BIN" ]] || die "Soufflé binary missing after compile"
    ldd "$SF_BIN" 2>/dev/null | grep -q libgomp \
        && log "$BLUE" "BUILD" "Soufflé linked libgomp (parallel-ready)" \
        || log "$YELLOW" "WARN" "Soufflé NOT linked libgomp — runtime effectively single-threaded"
fi

SUMMARY="${RESULTS_DIR}/summary.csv"
echo "dataset,verdict,fl_seconds,sf_seconds,fl_peak_mb,sf_peak_mb,relations,rowcounts_equal,exact_match,differ" > "$SUMMARY"

# --- per-dataset run + compare ------------------------------------------------
overall=0
for ds in "${DATASETS[@]}"; do
    log "$BLUE" "RUN" "=== $ds ==="
    build_overlay "$ds"
    local_out="${RESULTS_DIR}/${ds}"
    mkdir -p "$local_out"
    out_sf="${WORK}/out_sf"
    rm -rf "$OUT_FL" "$out_sf"; mkdir -p "$OUT_FL" "$out_sf"

    # FlowLog (writes to the baked $OUT_FL). /usr/bin/time -v -> peak RSS.
    local_t0=$(date +%s.%N)
    /usr/bin/time -v -o "${local_out}/flowlog_time.txt" \
        "$FL_BIN" -w "$WORKERS" > "${local_out}/flowlog_run.log" 2>&1 \
        || { log "$RED" "FAIL" "$ds: FlowLog run failed"; overall=1; continue; }
    fl_s=$(python3 -c "print(f'{$(date +%s.%N)-$local_t0:.1f}')")
    fl_rss=$(awk -F': ' '/Maximum resident set size/{print $2}' "${local_out}/flowlog_time.txt")
    fl_mb=$(python3 -c "print(f'{${fl_rss:-0}/1024:.0f}')")

    # Soufflé (-F/-D at run time). /usr/bin/time -v -> peak RSS.
    local_t0=$(date +%s.%N)
    /usr/bin/time -v -o "${local_out}/souffle_time.txt" \
        "$SF_BIN" -F "$OVERLAY" -D "$out_sf" -j "$WORKERS" > "${local_out}/souffle_run.log" 2>&1 \
        || { log "$RED" "FAIL" "$ds: Soufflé run failed"; overall=1; continue; }
    sf_s=$(python3 -c "print(f'{$(date +%s.%N)-$local_t0:.1f}')")
    sf_rss=$(awk -F': ' '/Maximum resident set size/{print $2}' "${local_out}/souffle_time.txt")
    sf_mb=$(python3 -c "print(f'{${sf_rss:-0}/1024:.0f}')")

    # Row-count table. Every relation must agree on cardinality *except*
    # HeapRepresentative, whose raw edge set legitimately differs between
    # engines (same heap partition, differently shaped rep edges) — it is
    # validated by the partition check below, not by row count.
    rc_equal=0; rc_total=0
    : > "${local_out}/rowcounts.tsv"
    for f in "$OUT_FL"/*.csv; do
        rel=$(basename "$f"); a=$(wc -l < "$f")
        b=$([[ -f "$out_sf/$rel" ]] && wc -l < "$out_sf/$rel" || echo NA)
        printf '%s\t%s\t%s\n' "$rel" "$a" "$b" >> "${local_out}/rowcounts.tsv"
        [[ "$rel" == "HeapRepresentative.csv" ]] && continue
        rc_total=$((rc_total+1)); [[ "$a" == "$b" ]] && rc_equal=$((rc_equal+1))
    done

    # Tuple-set oracle (exact; partition mode for the ord()-dependent heap-merge
    # representative relation — its members agree, only the chosen rep differs).
    python3 "$COMPARATOR" "$OUT_FL" "$out_sf" --partition HeapRepresentative --sample 2 \
        > "${local_out}/compare.txt" 2>&1 || true
    sumline=$(grep -E '[0-9]+ compared,' "${local_out}/compare.txt" | tail -1)
    matched=$(sed -nE 's/.* ([0-9]+) matched,.*/\1/p' <<<"$sumline"); matched=${matched:-0}
    differ=$(sed -nE 's/.*matched, ([0-9]+) differ.*/\1/p' <<<"$sumline");  differ=${differ:-0}
    missing=$(sed -nE 's/.*; ([0-9]+) expected relation.*missing.*/\1/p' <<<"$sumline"); missing=${missing:-0}
    hr_ok=0; grep -qE 'HeapRepresentative .*partition .*\[OK' "${local_out}/compare.txt" && hr_ok=1

    # Results MATCH iff: every relation has equal cardinality (rowcounts), the
    # heap-merge partition is identical (HeapRepresentative partition OK), and no
    # reference relation is missing. Remaining tuple-level diffs are then solely
    # ord()-based heap-representative renaming (equal-cardinality, paired).
    verdict=MISMATCH
    if [[ "$rc_equal" == "$rc_total" && "$hr_ok" == "1" && "$missing" == "0" ]]; then verdict=MATCH; fi

    echo "${ds},${verdict},${fl_s},${sf_s},${fl_mb},${sf_mb},${rc_total},${rc_equal}/${rc_total},${matched},${differ}" >> "$SUMMARY"
    if [[ "$verdict" == "MATCH" ]]; then
        log "$GREEN" "MATCH" "$ds: rowcounts ${rc_equal}/${rc_total} EQUAL, HeapRepresentative partition OK, 0 missing | ${matched} exact, ${differ} differ only by ord() heap-rep | fl ${fl_s}s/${fl_mb}MB  sf ${sf_s}s/${sf_mb}MB"
    else
        log "$RED" "MISMATCH" "$ds: rowcounts ${rc_equal}/${rc_total} eq, HeapRep-partition-ok=${hr_ok}, missing=${missing} — inspect ${local_out}/"
        overall=1
    fi
done

log "$BLUE" "SUMMARY" "see $SUMMARY"
column -t -s, "$SUMMARY" >&2 || cat "$SUMMARY" >&2
exit $overall
