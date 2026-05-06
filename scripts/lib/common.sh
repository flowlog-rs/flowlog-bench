#!/usr/bin/env bash
# =============================================================================
# scripts/lib/common.sh — shared bench helpers (mirrors flowlog's
# tests/lib/shared.sh pattern).
# =============================================================================
#
# Pure presentation + tiny utilities. No test or measurement semantics.
# Sourced by cross_engine.sh, ldbc.sh, regression.sh; also picked up
# transitively by run_info.sh's color fallbacks.
#
# Use the include guard below — multiple `source`s are safe.
#
# Note: log() and die() are NOT defined here. Each runner has its own
# branded prefix ([CHECK], [perf-compare], [INFO], [ERROR]) and slightly
# different signatures (cross_engine.sh's takes <colour> <tag> <msg…>;
# ldbc.sh's takes a single message). Keeping them local to each script
# is intentional — and a one-line definition each.
# =============================================================================
#
# shellcheck disable=SC2034
# Color constants and CLEANUP_SKIP_REASON are written here and read by
# every script that sources this file; shellcheck only sees this file
# in isolation, so the unused-warning is a false positive.

[[ -n "${FLOWLOG_BENCH_COMMON_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_COMMON_LOADED=1

###############################################################################
# ANSI color constants. ansi-c quoting (`$'...'`) so the variable holds
# the actual ESC byte, not a literal backslash sequence — works with
# both `printf '%s'` and `echo -e`.
###############################################################################

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[0;33m'
readonly BLUE=$'\033[0;34m'
readonly CYAN=$'\033[0;36m'
readonly NC=$'\033[0m'

###############################################################################
# trim <string>: strip leading + trailing whitespace, print to stdout.
###############################################################################

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

###############################################################################
# flowlog_truthy <value>: returns 0 (true) on `1/y/yes/true/on` (any case).
# Returns 1 (false) on everything else (including unset / empty).
#
# Used by the cleanup_dataset_should_clean guard below to interpret
# FLOWLOG_KEEP_DATASETS and FLOWLOG_FORCE_CLEANUP. Same contract as
# flowlog's tests/lib/shared.sh::flowlog_truthy — both repos share the
# same set of truthy spellings on purpose, so users don't learn one
# rule for tests and another for bench. If you change this set, change
# both repos in the same PR.
#
# Implementation note: lowercases the input first, then matches against
# the lowercase set. An earlier version enumerated mixed-case spellings
# directly (`yes|YES|Yes|...`) and silently fell through on inputs like
# `TrUe` or `oN` — meaning a user who set FLOWLOG_KEEP_DATASETS=Yes
# could lose their dataset cache. tr-then-match is robust by
# construction.
###############################################################################

flowlog_truthy() {
    local v="${1:-}"
    v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
    case "$v" in
        1|y|yes|true|on) return 0 ;;
        *) return 1 ;;
    esac
}

###############################################################################
# cleanup_dataset_should_clean <name> [extract_path]
#
# CACHE_PATCH_v2: dataset-cache safety guard.
#
# (The literal "CACHE_PATCH_v2" string above is grep'd by an external
# tool — `/datasets/lib/patch_repo.py` on dev VMs — as an idempotency
# marker. Do not rename without updating that tool. The same marker
# appears in flowlog's tests/oracle/common.sh so all layers stay in
# lockstep.)
#
# Returns 0 if the caller should proceed with `rm -rf`, 1 if cleanup
# should be skipped. On skip, sets the global $CLEANUP_SKIP_REASON
# string with a human-readable explanation that the caller can include
# in its own branded log message.
#
# Policy:
#   FLOWLOG_KEEP_DATASETS truthy  → never clean (highest priority).
#   FACT_DIR is a symlink         → never clean unless FLOWLOG_FORCE_CLEANUP
#                                   is truthy. (Protects a persistent
#                                   /datasets cache from being rm -rf'd
#                                   through the symlink.)
#   FACT_DIR or name empty        → never clean (safety net against
#                                   accidental `rm -rf /`).
###############################################################################

CLEANUP_SKIP_REASON=""

cleanup_dataset_should_clean() {
    local name="$1"
    CLEANUP_SKIP_REASON=""

    if flowlog_truthy "${FLOWLOG_KEEP_DATASETS:-}"; then
        CLEANUP_SKIP_REASON="kept; FLOWLOG_KEEP_DATASETS=${FLOWLOG_KEEP_DATASETS}"
        return 1
    fi

    if [[ -z "${FACT_DIR:-}" || -z "$name" ]]; then
        CLEANUP_SKIP_REASON="empty FACT_DIR or name (refusing to rm -rf)"
        return 1
    fi

    # Portable symlink check. `cd <dir> && pwd -P` resolves symlinks on
    # both GNU (Linux) and BSD (macOS) without depending on `readlink -f`
    # being GNU.
    local fd_real
    fd_real="$(cd "${FACT_DIR}" 2>/dev/null && pwd -P || echo "${FACT_DIR}")"
    if [[ "${fd_real}" != "${FACT_DIR}" ]] && ! flowlog_truthy "${FLOWLOG_FORCE_CLEANUP:-}"; then
        CLEANUP_SKIP_REASON="kept; ${FACT_DIR} → ${fd_real}; set FLOWLOG_FORCE_CLEANUP=1 to override"
        return 1
    fi

    return 0
}
