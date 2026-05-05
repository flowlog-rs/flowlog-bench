#!/bin/bash
# =============================================================================
# scripts/lib/run_info.sh — reproducibility manifest helpers.
# =============================================================================
#
# Implements AGENTS.md principle 6:
#
#   "Reproducibility over cleverness. Each result CSV is accompanied by a
#    run_info.txt sidecar that records the flowlog commit (resolved to a
#    full SHA, not `main`), corpus revision, host, worker count, and
#    wall-clock timestamp. A run from a year ago must be reconstructable."
#
# Why a sidecar (not extra CSV columns)? The CSV is consumed by
# plot_speedup.py and downstream extractors that key on column position
# (no header parsing). Adding columns would break them. A sibling
# manifest is additive — old consumers see nothing different.
#
# Two functions:
#
#   write_run_info <outdir> [extra_key=val ...]
#       Writes <outdir>/run_info.txt. <outdir> must already exist.
#       Captures: date, host, os, runner, flowlog_ref, flowlog_sha (via
#       fallback chain), flowlog_bin, flowlog_bin_mtime, workers,
#       num_runs, config_path, config_sha256, corpus_sha, corpus_dirty,
#       cargo_version. Extra args are appended verbatim (key: value),
#       used by each runner to record its own knobs (--baseline, --target,
#       tolerances, …).
#
#   verify_run_info <outdir> [extra_key=val ...]
#       If <outdir>/run_info.txt does not exist, returns 0 (first run).
#       Else, builds the would-be-current manifest and compares against
#       the existing one (excluding date / mtime). On mismatch, prints
#       a colourised diff to stderr and returns non-zero, instructing
#       the caller to either `--fresh` or change parameters back. This
#       is the resume-safety guard: the existing CSV / pair logs were
#       produced under different parameters; mixing rows is a footgun.
#
# `flowlog_sha` resolution fallback chain (most-trusted first):
#   1. $FLOWLOG_RESOLVED_SHA           (set by Makefile from get_flowlog.sh)
#   2. git -C "$FLOWLOG_SRC_DIR" rev-parse HEAD   (when src tree is a worktree)
#   3. parse the standard cache-layout path:
#         <bench_root>/flowlog/<short_sha>/target/release/flowlog-compiler
#      (only if the path matches that exact form)
#   4. "(unknown — set FLOWLOG_RESOLVED_SHA or use the Makefile)"
#
# Loaded once via include guard so multiple `source`s from the same
# script are safe.
# =============================================================================

[[ -n "${FLOWLOG_BENCH_RUN_INFO_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_RUN_INFO_LOADED=1

# ---------------------------------------------------------------------------
# Internal: resolve flowlog_sha. Returns the SHA on stdout.
# ---------------------------------------------------------------------------
_run_info_flowlog_sha() {
    local bin="${FLOWLOG_BIN:-}"
    local src="${FLOWLOG_SRC_DIR:-}"

    # 1. Explicit env (the Makefile sets this from get_flowlog.sh's output).
    if [[ -n "${FLOWLOG_RESOLVED_SHA:-}" ]]; then
        printf '%s\n' "$FLOWLOG_RESOLVED_SHA"
        return 0
    fi

    # 2. Worktree HEAD (works for any flowlog source tree, in or out of
    #    our cache layout).
    if [[ -n "$src" && (-d "$src/.git" || -f "$src/.git") ]]; then
        local sha
        sha="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
        if [[ -n "$sha" ]]; then
            printf '%s\n' "$sha"
            return 0
        fi
    fi

    # 3. Path-pattern: only if FLOWLOG_BIN matches the exact get_flowlog.sh
    #    cache layout. We do NOT loosely substring-match — a user-supplied
    #    binary anywhere else would lie.
    if [[ -n "$bin" && "$bin" =~ /flowlog/([0-9a-f]{12})/target/release/flowlog-compiler$ ]]; then
        # 12-char short SHA from the cache dir name. Mark as short so the
        # consumer knows it's not a full SHA.
        printf 'short:%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    # 4. Last resort.
    printf '%s\n' "(unknown — set FLOWLOG_RESOLVED_SHA or use the Makefile)"
}

# ---------------------------------------------------------------------------
# Internal: resolve corpus_sha + corpus_dirty for the bench repo itself.
# `programs/`, `config/`, `scripts/` all live in this repo; their state
# is captured by HEAD + the dirty flag.
# ---------------------------------------------------------------------------
_run_info_corpus() {
    local root="${RUN_INFO_BENCH_ROOT:?RUN_INFO_BENCH_ROOT must be set}"
    local sha dirty
    sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [[ "$sha" == "unknown" ]]; then
        printf '%s\t%s\n' "unknown" "unknown"
        return 0
    fi
    if git -C "$root" diff-index --quiet HEAD -- 2>/dev/null; then
        dirty="no"
    else
        dirty="yes"
    fi
    printf '%s\t%s\n' "$sha" "$dirty"
}

# ---------------------------------------------------------------------------
# Internal: hash a file. Empty / missing → "(missing)".
# ---------------------------------------------------------------------------
_run_info_sha256() {
    local f="$1"
    [[ -f "$f" ]] || { printf '(missing)\n'; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    else
        printf '(no sha256 tool)\n'
    fi
}

# ---------------------------------------------------------------------------
# Render the manifest body to stdout. Called by both write_run_info (to
# write) and verify_run_info (to compare the *would-be* current against
# the on-disk previous). Excludes timestamp + mtime (those are
# expected to differ between runs and not part of run identity).
# ---------------------------------------------------------------------------
_run_info_render_identity() {
    local config_path="${RUN_INFO_CONFIG_PATH:-}"
    local config_sha
    config_sha="$(_run_info_sha256 "$config_path")"

    local flowlog_sha
    flowlog_sha="$(_run_info_flowlog_sha)"

    local corpus_sha corpus_dirty
    IFS=$'\t' read -r corpus_sha corpus_dirty < <(_run_info_corpus)

    local cargo_ver
    cargo_ver="$(cargo --version 2>/dev/null || echo unknown)"

    cat <<EOF
runner          : ${RUN_INFO_RUNNER:-?}
flowlog_ref     : ${FLOWLOG_REF:-${FLOWLOG_BASE:-${FLOWLOG_HEAD:-(direct FLOWLOG_BIN)}}}
flowlog_sha     : ${flowlog_sha}
flowlog_bin     : ${FLOWLOG_BIN:-(unset)}
workers         : ${WORKERS:-?}
num_runs        : ${NUM_RUNS:-?}
config_path     : ${config_path:-(none)}
config_sha256   : ${config_sha}
corpus_sha      : ${corpus_sha}
corpus_dirty    : ${corpus_dirty}
cargo_version   : ${cargo_ver}
EOF

    # Append any extra <key>=<val> args verbatim, formatted as the
    # rest of the file. Used for runner-specific knobs (baselines,
    # tolerances, target filter, base/head sha pair, …).
    local kv
    for kv in "$@"; do
        printf '%-15s : %s\n' "${kv%%=*}" "${kv#*=}"
    done
}

# ---------------------------------------------------------------------------
# write_run_info <outdir> [extra_key=val ...]
# ---------------------------------------------------------------------------
write_run_info() {
    local outdir="$1"; shift || true
    [[ -n "$outdir" ]] || { echo "write_run_info: outdir required" >&2; return 2; }
    mkdir -p "$outdir"

    local now host_str os_str bin_mtime
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    host_str="$(hostname 2>/dev/null || echo unknown)"
    os_str="$(uname -srm 2>/dev/null || echo unknown)"
    if [[ -n "${FLOWLOG_BIN:-}" && -e "${FLOWLOG_BIN}" ]]; then
        # Portable across GNU and BSD `stat`: prefer GNU `-c %y`, fall
        # back to BSD `-f %Sm`. Both yield ISO-ish strings.
        bin_mtime="$(stat -c '%y' "$FLOWLOG_BIN" 2>/dev/null \
                   || stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$FLOWLOG_BIN" 2>/dev/null \
                   || echo unknown)"
    else
        bin_mtime="(no flowlog_bin)"
    fi

    {
        cat <<EOF
# Reproducibility manifest (AGENTS.md principle 6).
# Pair: results / run_info.txt. The CSV beside this file was produced
# under the parameters below. cross_engine.sh hard-fails on resume if
# any identity field changes (use --fresh or revert the change).
date            : ${now}
host            : ${host_str}
os              : ${os_str}
flowlog_bin_mtime: ${bin_mtime}
EOF
        _run_info_render_identity "$@"
    } > "${outdir}/run_info.txt"
}

# ---------------------------------------------------------------------------
# verify_run_info <outdir> [extra_key=val ...]
# Returns 0 when no manifest exists OR the existing manifest's identity
# fields match the current would-be manifest. Returns non-zero with a
# coloured diff on mismatch.
# ---------------------------------------------------------------------------
verify_run_info() {
    local outdir="$1"; shift || true
    local existing="${outdir}/run_info.txt"

    [[ -f "$existing" ]] || return 0   # first run; nothing to verify

    # Identity = the manifest body excluding the volatile (date, host,
    # os, mtime) header lines. Compute "would-be" identity for current
    # invocation, compare against the on-disk identity.
    local now_id prev_id
    now_id="$(_run_info_render_identity "$@")"
    prev_id="$(awk '
        /^runner[[:space:]]*:/         { found=1 }
        found { print }
    ' "$existing")"

    if [[ "$now_id" != "$prev_id" ]]; then
        # Use colors from common.sh if loaded, else fall back to inline
        # ansi-c-quoted defaults so this helper works standalone.
        local _r="${RED:-$'\033[0;31m'}"
        local _y="${YELLOW:-$'\033[0;33m'}"
        local _n="${NC:-$'\033[0m'}"
        {
            printf '%s[ERROR]%s resume blocked — run identity has changed.\n' "$_r" "$_n"
            printf '%sExisting %s/run_info.txt was produced under:%s\n' "$_y" "$outdir" "$_n"
            printf '%s\n' "$prev_id"
            printf '\n%sCurrent invocation would record:%s\n' "$_y" "$_n"
            printf '%s\n' "$now_id"
            printf '\n%sFix:%s either revert the changed parameters, OR pass --fresh to start a new run.\n' "$_y" "$_n"
        } >&2
        return 1
    fi

    return 0
}
