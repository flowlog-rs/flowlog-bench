#!/usr/bin/env bash
# =============================================================================
# env.sh — one-time bootstrap for a fresh Ubuntu box.
# =============================================================================
#
# Installs the dep set the bench scripts call: basic deps + rustup, plus
# the requested comparison engines. FlowLog itself is fetched on demand by
# scripts/get_flowlog.sh at the FLOWLOG_REF you pass to make.
#
# Usage:
#   bash env.sh                           # basic deps + rustup only
#   bash env.sh --all                     # + every engine below
#   bash env.sh duckdb souffle            # subset (positional)
#   bash env.sh --systems duckdb,souffle  # subset (comma list)
#   bash env.sh --list                    # print engine list
#   bash env.sh --help
#
# Engines: duckdb, souffle, umbra, interpreter.
# Idempotent: every install_* function early-returns if the target
# binary is already present, so running this with --all on a partially-
# bootstrapped box only fills in the gaps.
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${CYAN}[env]${NC}   $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}    $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "Ubuntu/Linux only (macOS / Windows not supported)"
command -v apt-get >/dev/null 2>&1 || die "apt-get required (Ubuntu/Debian only)"

HOME_BIN="$HOME/bin"

# ---------------------------------------------------------------------
# CLI parsing.
# ---------------------------------------------------------------------
AVAILABLE=("duckdb" "souffle" "umbra" "interpreter")
SELECTED=()

show_help() {
    awk '/^# ===*$/ { sep++; next }
         sep >= 1 && sep < 3 { sub(/^# ?/, ""); print }' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        --list)    echo "${AVAILABLE[*]}"; exit 0 ;;
        --all)     SELECTED=("${AVAILABLE[@]}"); shift ;;
        --systems) shift; IFS=',' read -ra SELECTED <<< "${1:-}"; shift ;;
        *)
            if [[ " ${AVAILABLE[*]} " == *" $1 "* ]]; then
                SELECTED+=("$1"); shift
            else
                die "unknown engine '$1' (try --list)"
            fi
            ;;
    esac
done

selected() {
    local needle="$1" s
    for s in "${SELECTED[@]:-}"; do [[ "$s" == "$needle" ]] && return 0; done
    return 1
}

# ---------------------------------------------------------------------
# Idempotent .bashrc edits.
# ---------------------------------------------------------------------
add_to_path() {
    local d="$1" line="export PATH=\"$d:\$PATH\""
    grep -Fq "$line" "$HOME/.bashrc" 2>/dev/null || echo "$line" >> "$HOME/.bashrc"
    export PATH="$d:$PATH"
}
add_env_line() {
    local line="$1"
    grep -Fq "$line" "$HOME/.bashrc" 2>/dev/null || echo "$line" >> "$HOME/.bashrc"
}

# ---------------------------------------------------------------------
# Basic deps + rustup (always run).
# ---------------------------------------------------------------------
setup_basic() {
    log "installing core apt deps ..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        git python3 python3-pip wget curl unzip tar build-essential \
        pkg-config protobuf-compiler bsdmainutils \
        time zstd jq dos2unix htop

    if command -v rustup >/dev/null 2>&1; then
        ok "rustup already installed"
    else
        log "installing rustup (stable toolchain) ..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --default-toolchain stable
        add_to_path "$HOME/.cargo/bin"
    fi
    rustup show active-toolchain >/dev/null 2>&1 || rustup default stable
    rustup update >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------
# Shared helpers.
# ---------------------------------------------------------------------

# Idempotent docker install. Used by container-based engines (umbra)
# so they don't have to repeat the package + service + group dance.
_ensure_docker() {
    if command -v docker >/dev/null 2>&1; then
        return
    fi
    log "installing docker.io ..."
    sudo apt-get install -y -qq docker.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER" || true
    warn "docker group membership requires re-login (or 'newgrp docker') to take effect"
}

# ---------------------------------------------------------------------
# Per-engine installers.
# ---------------------------------------------------------------------
install_duckdb() {
    if command -v duckdb >/dev/null 2>&1; then
        ok "duckdb already on PATH"
        return
    fi
    log "installing duckdb CLI ..."
    mkdir -p "$HOME_BIN"
    local url="https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip"
    curl -fsSL "$url" -o "$HOME_BIN/duckdb.zip"
    unzip -oq "$HOME_BIN/duckdb.zip" -d "$HOME_BIN"
    chmod +x "$HOME_BIN/duckdb"
    rm -f "$HOME_BIN/duckdb.zip"
    add_to_path "$HOME_BIN"
    ok "duckdb installed at $HOME_BIN/duckdb"
}

install_souffle() {
    if command -v souffle >/dev/null 2>&1; then
        ok "souffle already installed at $(command -v souffle)"
        return
    fi
    log "installing souffle from upstream apt repo ..."
    sudo wget -q https://souffle-lang.github.io/ppa/souffle-key.public \
        -O /usr/share/keyrings/souffle-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/souffle-archive-keyring.gpg] https://souffle-lang.github.io/ppa/ubuntu/ stable main" \
        | sudo tee /etc/apt/sources.list.d/souffle.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq souffle
    ok "souffle installed at $(command -v souffle)"
}

install_umbra() {
    _ensure_docker
    if [[ -n "$(sudo docker images -q umbradb/umbra:latest 2>/dev/null)" ]]; then
        ok "umbra docker image already pulled"
        return
    fi
    log "pulling umbra docker image ..."
    sudo docker pull umbradb/umbra:latest
    ok "umbra docker image ready"
}

install_interpreter() {
    # vldb26-artifact (the FlowLog interpreter from the VLDB'26 paper) lives
    # next to flowlog-bench/, matching scripts/cross_engine.sh's default
    # INTERPRETER_DIR=${ROOT_DIR}/../vldb26-artifact.
    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local interpreter_root="${script_dir}/../vldb26-artifact"
    local interpreter_bin="${interpreter_root}/target/release/executing"

    if [[ -x "$interpreter_bin" ]]; then
        ok "interpreter already installed at $interpreter_root"
        return
    fi

    if [[ ! -d "$interpreter_root" ]]; then
        log "cloning vldb26-artifact into $interpreter_root ..."
        git clone --depth=1 https://github.com/flowlog-rs/vldb26-artifact.git \
            "$interpreter_root" \
            || die "failed to clone vldb26-artifact"
    fi

    log "building interpreter (cargo build --release) ..."
    ( cd "$interpreter_root" && cargo build --release ) \
        || die "cargo build --release failed in $interpreter_root"
    [[ -x "$interpreter_bin" ]] \
        || die "interpreter binary missing after build: $interpreter_bin"

    ok "interpreter installed at $interpreter_root"
}

# ---------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------
echo "=========================================="
echo "flowlog-bench env bootstrap (Ubuntu)"
echo "=========================================="

setup_basic

if (( ${#SELECTED[@]} > 0 )); then
    log "engines requested: ${SELECTED[*]}"
    selected duckdb      && install_duckdb
    selected souffle     && install_souffle
    selected umbra       && install_umbra
    selected interpreter && install_interpreter
else
    warn "no engines selected — only basic deps + rustup were installed."
    warn "  add engines with:  bash env.sh --all"
    warn "                  or bash env.sh duckdb souffle"
fi

ok "env bootstrap complete"
echo
echo "Next steps:"
echo "  1. source ~/.bashrc   # pick up PATH updates"
echo "  2. cargo --version"
echo "  3. bash scripts/get_flowlog.sh   # default FLOWLOG_REF=main"
echo "  4. make cross-engine        # FlowLog vs. Soufflé sweep (or 'make help')"
