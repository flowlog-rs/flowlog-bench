#!/bin/bash
# =============================================================================
# tools/env/env.sh — one-time bootstrap for a fresh Linux/macOS box.
# =============================================================================
#
# Per AGENTS.md design principles 7 ("Bench env is heavier than test env,
# and that's fine — Soufflé, DuckDB, GNU time, larger dataset caches all
# live with this repo's tools/env/; the flowlog repo's env stays
# minimal") and 8 ("No env_check.sh — if a script needs deps, it fails
# loudly at the first call"):
#
# This script is a one-time machine install (souffle, duckdb, GNU time,
# rustup). Same philosophy as the flowlog repo: run env.sh once on a
# fresh box, you're done.
#
# Usage:  bash tools/env/env.sh
# Idempotent: safe to re-run; it skips anything already installed.
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${CYAN}[env]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}  $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

OS="$(uname -s)"

# --------------------------------------------------------------------
# 1. Rust toolchain (rustup + stable + cargo).
# --------------------------------------------------------------------
if ! command -v rustup >/dev/null 2>&1; then
    log "installing rustup (stable toolchain) ..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
else
    ok "rustup already installed"
fi
rustup show active-toolchain >/dev/null 2>&1 || rustup default stable

# --------------------------------------------------------------------
# 2. OS package manager — install bench-side deps.
#
#    Required:  git, python3, wget, unzip, tar, build-essential,
#               souffle, duckdb, GNU time (gtime on macOS), zstd
#    Optional:  jq (results munging)
# --------------------------------------------------------------------
case "$OS" in
    Linux)
        if command -v apt-get >/dev/null 2>&1; then
            log "installing Linux deps via apt-get (sudo) ..."
            sudo apt-get update -qq
            sudo apt-get install -y -qq \
                git python3 wget unzip tar build-essential pkg-config \
                protobuf-compiler bsdmainutils \
                time zstd jq
            # Soufflé: not always in default apt; try, then warn.
            if ! command -v souffle >/dev/null 2>&1; then
                if ! sudo apt-get install -y -qq souffle 2>/dev/null; then
                    warn "souffle not in apt repos on this box."
                    warn "  Install from source: https://souffle-lang.github.io/install"
                    warn "  Or via the project's release builds. Required for cross-engine.sh."
                fi
            fi
            # DuckDB: ships as a single binary; install if missing.
            if ! command -v duckdb >/dev/null 2>&1; then
                warn "duckdb not on PATH."
                warn "  Install from https://duckdb.org/docs/installation/ (CLI binary)."
                warn "  Required for ldbc.sh."
            fi
        else
            die "no apt-get found; please install deps manually (see top of this script)"
        fi
        ;;
    Darwin)
        if ! command -v brew >/dev/null 2>&1; then
            die "Homebrew not installed. Install from https://brew.sh first."
        fi
        log "installing macOS deps via brew ..."
        brew update
        # GNU time on mac is `gtime` (provided by gnu-time formula).
        brew install \
            git python3 wget gnu-tar coreutils util-linux \
            protobuf zstd jq gnu-time
        if ! command -v souffle >/dev/null 2>&1; then
            brew install souffle || warn "souffle install failed; required for cross-engine.sh"
        fi
        if ! command -v duckdb >/dev/null 2>&1; then
            brew install duckdb || warn "duckdb install failed; required for ldbc.sh"
        fi
        ;;
    *)
        die "unsupported OS: $OS (Linux/macOS only; Windows users see env.ps1)"
        ;;
esac

ok "env bootstrap complete"
echo
echo "Next steps:"
echo "  1. Verify cargo:   cargo --version"
echo "  2. Try a fetch:    bash tools/get_flowlog.sh           # default FLOWLOG_REF=main"
echo "  3. Run a smoke:    make cross-engine PROG=program_analysis/cspa.dl DATASET=cspa-httpd"
echo
echo "Optional:"
echo "  - Point /datasets at your shared dataset cache (or set FACT_DIR per-run)."
echo "  - See AGENTS.md for the bench-repo contract."
