#!/usr/bin/env bash
# =============================================================================
# scripts/lib/common.sh — colors + tiny utilities used by every runner.
# =============================================================================

# shellcheck disable=SC2034  # color constants are read by sourcing scripts.

[[ -n "${FLOWLOG_BENCH_COMMON_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_COMMON_LOADED=1

# ---------------------------------------------------------------------
# ANSI colors. $'...' so the var holds the actual ESC byte; works with
# both `printf '%s'` and `echo -e`.
# ---------------------------------------------------------------------
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[0;33m'
readonly BLUE=$'\033[0;34m'
readonly CYAN=$'\033[0;36m'
readonly NC=$'\033[0m'

# ---------------------------------------------------------------------
# trim <string>: strip leading + trailing whitespace, print to stdout.
# ---------------------------------------------------------------------
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}
