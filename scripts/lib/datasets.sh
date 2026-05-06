#!/usr/bin/env bash
# scripts/lib/datasets.sh — dataset cache helpers.
#
# Both cross_engine.sh (zip) and ldbc.sh (tar.zst) need to:
#   - check if a dataset is already extracted under $FACT_DIR/<name>
#   - if not, download the archive and extract it
#   - clean it back up, respecting the cache-safety guard from common.sh
#
# This file factors that out. Caller passes the URL template + how to
# log the operation; they keep their own [DOWNLOAD]/[EXTRACT]/etc.
# branding so existing transcripts stay readable.
#
# Required globals: FACT_DIR (extract destination, may be a symlink).

[[ -n "${FLOWLOG_BENCH_DATASETS_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_DATASETS_LOADED=1

# common.sh provides cleanup_dataset_should_clean (CACHE_PATCH_v2 contract).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------
# Internal: download <url> to <dest> with the same retry policy used
# everywhere in this repo. Returns the wget exit code.
# ---------------------------------------------------------------------
_download() {
    local url="$1" dest="$2"
    wget --no-verbose --timeout=60 --tries=3 --max-redirect=5 \
         -O "$dest" "$url"
}

# ---------------------------------------------------------------------
# dataset_ensure_zip <name> <url>
#
# If $FACT_DIR/<name> exists, no-op. Else download the .zip from <url>
# (no extension appended; pass the full URL) into /dev/shm and unzip
# into FACT_DIR. On any failure: returns non-zero, writes nothing.
# ---------------------------------------------------------------------
dataset_ensure_zip() {
    local name="$1" url="$2"
    local dst="${FACT_DIR}/${name}"
    [[ -d "$dst" ]] && return 0

    mkdir -p "$FACT_DIR"
    local tmp="/dev/shm/${name}.zip"
    _download "$url" "$tmp" || return 1
    unzip -q "$tmp" -d "$FACT_DIR" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# ---------------------------------------------------------------------
# dataset_ensure_tar_zst <name> <url>
#
# Same as dataset_ensure_zip but for .tar.zst archives (LDBC).
# Requires `tar` and `zstd` on PATH; caller is expected to verify those.
# ---------------------------------------------------------------------
dataset_ensure_tar_zst() {
    local name="$1" url="$2"
    local dst="${FACT_DIR}/${name}"
    [[ -d "$dst" ]] && return 0

    mkdir -p "$FACT_DIR"
    local tmp="/dev/shm/${name}.tar.zst"
    _download "$url" "$tmp" || return 1
    tar --use-compress-program=zstd -xf "$tmp" -C "$FACT_DIR" \
        || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# ---------------------------------------------------------------------
# dataset_cleanup <name>
#
# Remove $FACT_DIR/<name> if cleanup_dataset_should_clean approves.
# Sets $CLEANUP_SKIP_REASON when it doesn't (caller can log it).
# ---------------------------------------------------------------------
dataset_cleanup() {
    local name="$1"
    if cleanup_dataset_should_clean "$name"; then
        rm -rf -- "${FACT_DIR}/${name}"
        return 0
    fi
    return 1
}
