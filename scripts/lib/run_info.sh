#!/usr/bin/env bash
# =============================================================================
# scripts/lib/run_info.sh — write/verify the per-run reproducibility sidecar.
# =============================================================================

[[ -n "${FLOWLOG_BENCH_RUN_INFO_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_RUN_INFO_LOADED=1

# ---------------------------------------------------------------------
# Internal: resolve flowlog_sha. Tries (most-trusted first):
#   1. $FLOWLOG_RESOLVED_SHA            (set by Makefile from get_flowlog.sh)
#   2. git rev-parse HEAD in $FLOWLOG_SRC_DIR  (any worktree)
#   3. parse cache path flowlog/<short_sha>/target/release/flowlog-compiler
#      (exact form only — no loose substring match)
#   4. "(unknown — set FLOWLOG_RESOLVED_SHA or use the Makefile)"
# ---------------------------------------------------------------------
_run_info_flowlog_sha() {
    if [[ -n "${FLOWLOG_RESOLVED_SHA:-}" ]]; then
        printf '%s\n' "$FLOWLOG_RESOLVED_SHA"
        return
    fi
    local src="${FLOWLOG_SRC_DIR:-}"
    if [[ -n "$src" && (-d "$src/.git" || -f "$src/.git") ]]; then
        local sha
        sha="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
        [[ -n "$sha" ]] && { printf '%s\n' "$sha"; return; }
    fi
    local bin="${FLOWLOG_BIN:-}"
    if [[ -n "$bin" && "$bin" =~ /flowlog/([0-9a-f]{12})/target/release/flowlog-compiler$ ]]; then
        printf 'short:%s\n' "${BASH_REMATCH[1]}"
        return
    fi
    printf '%s\n' "(unknown — set FLOWLOG_RESOLVED_SHA or use the Makefile)"
}

# Bench-repo HEAD + dirty flag (programs/, config/, scripts/ all live here).
# Output: "<sha>\t<yes|no>", or "unknown\tunknown" if not in a git repo.
_run_info_corpus() {
    local root="${RUN_INFO_BENCH_ROOT:?RUN_INFO_BENCH_ROOT must be set}"
    local sha
    sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [[ "$sha" == "unknown" ]]; then
        printf 'unknown\tunknown\n'; return
    fi
    local dirty=yes
    git -C "$root" diff-index --quiet HEAD -- 2>/dev/null && dirty=no
    printf '%s\t%s\n' "$sha" "$dirty"
}

# sha256 of a file; "(missing)" if absent, "(no sha256 tool)" if neither
# sha256sum nor shasum is on PATH.
_run_info_sha256() {
    local f="$1"
    [[ -f "$f" ]] || { printf '(missing)\n'; return; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    else
        printf '(no sha256 tool)\n'
    fi
}

# ---------------------------------------------------------------------
# Render the identity portion of the manifest to stdout. Excludes
# date/host/mtime — those vary between runs and aren't part of identity.
# Used by write_run_info (write) and verify_run_info (compare).
# ---------------------------------------------------------------------
_run_info_render_identity() {
    local config_path="${RUN_INFO_CONFIG_PATH:-}"
    local config_sha corpus_sha corpus_dirty
    config_sha="$(_run_info_sha256 "$config_path")"
    IFS=$'\t' read -r corpus_sha corpus_dirty < <(_run_info_corpus)

    cat <<EOF
runner          : ${RUN_INFO_RUNNER:-?}
flowlog_ref     : ${FLOWLOG_REF:-${FLOWLOG_BASE:-${FLOWLOG_HEAD:-(direct FLOWLOG_BIN)}}}
flowlog_sha     : $(_run_info_flowlog_sha)
flowlog_bin     : ${FLOWLOG_BIN:-(unset)}
workers         : ${WORKERS:-?}
num_runs        : ${NUM_RUNS:-?}
config_path     : ${config_path:-(none)}
config_sha256   : ${config_sha}
corpus_sha      : ${corpus_sha}
corpus_dirty    : ${corpus_dirty}
cargo_version   : $(cargo --version 2>/dev/null || echo unknown)
EOF

    # Caller-supplied <key>=<val> pairs (per-runner knobs: engines,
    # tolerances, base/head shas, …) — appended verbatim.
    local kv
    for kv in "$@"; do
        printf '%-15s : %s\n' "${kv%%=*}" "${kv#*=}"
    done
}

# ---------------------------------------------------------------------
# write_run_info <outdir> [extra_key=val ...]
#   Writes <outdir>/run_info.txt. Creates <outdir> if missing.
# ---------------------------------------------------------------------
write_run_info() {
    local outdir="$1"; shift || true
    [[ -n "$outdir" ]] || { echo "write_run_info: outdir required" >&2; return 2; }
    mkdir -p "$outdir"

    local bin_mtime="(no flowlog_bin)"
    if [[ -n "${FLOWLOG_BIN:-}" && -e "${FLOWLOG_BIN}" ]]; then
        # GNU stat first, BSD fallback for portability.
        bin_mtime="$(stat -c '%y' "$FLOWLOG_BIN" 2>/dev/null \
                  || stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$FLOWLOG_BIN" 2>/dev/null \
                  || echo unknown)"
    fi

    {
        cat <<EOF
# Reproducibility manifest (AGENTS.md principle 6). The CSV beside this
# file was produced under the parameters below. cross_engine.sh hard-
# fails on resume if any identity field changes (use --fresh to override).
date            : $(date -u +%Y-%m-%dT%H:%M:%SZ)
host            : $(hostname 2>/dev/null || echo unknown)
os              : $(uname -srm 2>/dev/null || echo unknown)
flowlog_bin_mtime: ${bin_mtime}
EOF
        _run_info_render_identity "$@"
    } > "${outdir}/run_info.txt"
}

# ---------------------------------------------------------------------
# verify_run_info <outdir> [extra_key=val ...]
#   Resume-safety guard. Returns 0 if no manifest exists yet (first run)
#   or the existing identity matches the would-be current identity.
#   Returns non-zero with a colored diff on mismatch.
# ---------------------------------------------------------------------
verify_run_info() {
    local outdir="$1"; shift || true
    local existing="${outdir}/run_info.txt"
    [[ -f "$existing" ]] || return 0   # first run

    local now_id prev_id
    now_id="$(_run_info_render_identity "$@")"
    # Identity starts at the `runner` line (skips the date/host/mtime header).
    prev_id="$(awk '/^runner[[:space:]]*:/ { found=1 } found' "$existing")"

    [[ "$now_id" == "$prev_id" ]] && return 0

    # Colors from common.sh if loaded; inline ansi-c fallback otherwise.
    local _r="${RED:-$'\033[0;31m'}"
    local _y="${YELLOW:-$'\033[0;33m'}"
    local _n="${NC:-$'\033[0m'}"
    {
        printf '%s[ERROR]%s resume blocked — run identity has changed.\n' "$_r" "$_n"
        printf '%sExisting %s/run_info.txt was produced under:%s\n' "$_y" "$outdir" "$_n"
        printf '%s\n\n' "$prev_id"
        printf '%sCurrent invocation would record:%s\n' "$_y" "$_n"
        printf '%s\n\n' "$now_id"
        printf '%sFix:%s revert the changed parameters, or pass --fresh to start over.\n' "$_y" "$_n"
    } >&2
    return 1
}
