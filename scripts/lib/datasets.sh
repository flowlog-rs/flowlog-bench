#!/usr/bin/env bash
# =============================================================================
# scripts/lib/datasets.sh — dataset cache helpers (download / extract / cleanup).
# =============================================================================

[[ -n "${FLOWLOG_BENCH_DATASETS_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_DATASETS_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------
# cleanup_dataset_should_clean <name>   (gate before every rm -rf)
#
# Returns: 0 caller may rm | 1 caller must skip | dies on symlinked FACT_DIR.
# Policy:
#   KEEP_DATASETS=1 (from --keep-datasets) → skip
#   empty FACT_DIR or name                 → skip (rm -rf guard)
#   FACT_DIR is a symlink                  → DIE LOUDLY (would wipe target;
#                                            user must pass --keep-datasets)
# Sets $CLEANUP_SKIP_REASON on skip for caller logging.
# ---------------------------------------------------------------------
CLEANUP_SKIP_REASON=""

cleanup_dataset_should_clean() {
    local name="$1"
    CLEANUP_SKIP_REASON=""
    if [[ "${KEEP_DATASETS:-0}" == "1" ]]; then
        CLEANUP_SKIP_REASON="kept (--keep-datasets)"
        return 1
    fi
    if [[ -z "${FACT_DIR:-}" || -z "$name" ]]; then
        CLEANUP_SKIP_REASON="empty FACT_DIR or name (refusing to rm -rf)"
        return 1
    fi
    # `cd <dir> && pwd -P` resolves symlinks portably.
    local fd_real
    fd_real="$(cd "${FACT_DIR}" 2>/dev/null && pwd -P || echo "${FACT_DIR}")"
    if [[ "${fd_real}" != "${FACT_DIR}" ]]; then
        die "FACT_DIR='${FACT_DIR}' is a symlink → '${fd_real}'.
  Refusing to rm -rf through it (would blow away the linked target).
  Pass --keep-datasets to skip cleanup — recommended when FACT_DIR
  points to a shared dataset mount."
    fi
    return 0
}

# Download <url> to <dest>; standard retry policy. Returns wget exit code.
_download() {
    wget --no-verbose --timeout=60 --tries=3 --max-redirect=5 -O "$2" "$1"
}

# dataset_ensure_zip <name> <url>
#   No-op if $FACT_DIR/<name> exists. Else download <url> to /dev/shm
#   and unzip into $FACT_DIR. Returns non-zero on any failure.
dataset_ensure_zip() {
    local name="$1" url="$2"
    [[ -d "${FACT_DIR}/${name}" ]] && return 0

    mkdir -p "$FACT_DIR"
    local tmp="/dev/shm/${name}.zip"
    _download "$url" "$tmp" || return 1
    unzip -q "$tmp" -d "$FACT_DIR" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# dataset_ensure_tar_zst <name> <url>
#   Same as dataset_ensure_zip but for .tar.zst archives (LDBC).
#   Requires `tar` and `zstd` on PATH (caller verifies).
dataset_ensure_tar_zst() {
    local name="$1" url="$2"
    [[ -d "${FACT_DIR}/${name}" ]] && return 0

    mkdir -p "$FACT_DIR"
    local tmp="/dev/shm/${name}.tar.zst"
    _download "$url" "$tmp" || return 1
    tar --use-compress-program=zstd -xf "$tmp" -C "$FACT_DIR" \
        || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# dataset_cleanup <name>
#   rm -rf $FACT_DIR/<name>, gated by cleanup_dataset_should_clean.
#   Returns 0 if removed, 1 if skipped ($CLEANUP_SKIP_REASON set).
dataset_cleanup() {
    local name="$1"
    if cleanup_dataset_should_clean "$name"; then
        # `:?` is belt-and-braces with the empty-FACT_DIR check above —
        # both layers guarantee no expansion to a bare "/" or "/<name>".
        rm -rf -- "${FACT_DIR:?}/${name}"
        return 0
    fi
    return 1
}
