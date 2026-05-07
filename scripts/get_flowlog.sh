#!/usr/bin/env bash
# =============================================================================
# scripts/get_flowlog.sh — fetch + build flowlog at FLOWLOG_REF, idempotently.
# =============================================================================
#
# Clones flowlog at FLOWLOG_REF=<sha|tag|branch> (default: main), builds
# release, and caches the result at flowlog/<short_sha>/. Re-running with
# the same ref is a no-op.
#
# Usage:
#   bash scripts/get_flowlog.sh                       # ref=main
#   FLOWLOG_REF=v0.5.0  bash scripts/get_flowlog.sh   # tag
#   FLOWLOG_REF=abc1234 bash scripts/get_flowlog.sh   # commit
#
# Output (last stdout line, tab-separated, machine-readable):
#
#   <full_sha>\t<short_sha>\t<absolute_build_dir>
#
# Capture from a caller:
#
#   read FULL SHORT BUILD < <(bash scripts/get_flowlog.sh | tail -1)
#   FLOWLOG_BIN="${BUILD}/target/release/flowlog-compiler"
#   FLOWLOG_SRC_DIR="${BUILD}/src"
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FLOWLOG_REF="${FLOWLOG_REF:-main}"
FLOWLOG_REPO="${FLOWLOG_REPO:-https://github.com/flowlog-rs/flowlog.git}"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${CYAN}[get-flowlog]${NC} $*" >&2; }
die() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
ok()  { echo -e "${GREEN}[ok]${NC} $*" >&2; }

command -v git   >/dev/null 2>&1 || die "git is required"
command -v cargo >/dev/null 2>&1 || die "cargo (rust toolchain) is required — run env/env.sh"

CACHE_ROOT="${ROOT_DIR}/flowlog"
mkdir -p "$CACHE_ROOT"

# -----------------------------------------------------------------------
# Step 1: resolve FLOWLOG_REF -> full SHA via a bare mirror at
# flowlog/.mirror, kept across runs so per-ref fetches stay cheap.
# -----------------------------------------------------------------------
MIRROR="${CACHE_ROOT}/.mirror"
if [[ ! -d "$MIRROR" ]]; then
    log "cloning bare mirror from $FLOWLOG_REPO ..."
    git clone --bare --quiet "$FLOWLOG_REPO" "$MIRROR" \
        || die "failed to clone $FLOWLOG_REPO"
fi

log "fetching latest refs into mirror ..."
git -C "$MIRROR" fetch --quiet --tags --prune origin '+refs/heads/*:refs/heads/*' \
    || die "git fetch failed in $MIRROR"

# Resolve to full SHA. Try as branch, tag, then bare ref.
FULL_SHA="$(git -C "$MIRROR" rev-parse --verify "refs/heads/${FLOWLOG_REF}^{commit}" 2>/dev/null \
        || git -C "$MIRROR" rev-parse --verify "refs/tags/${FLOWLOG_REF}^{commit}"  2>/dev/null \
        || git -C "$MIRROR" rev-parse --verify "${FLOWLOG_REF}^{commit}"            2>/dev/null \
        || die "FLOWLOG_REF='${FLOWLOG_REF}' did not resolve to a commit in mirror")"
SHORT_SHA="${FULL_SHA:0:12}"

BUILD_DIR="${CACHE_ROOT}/${SHORT_SHA}"
SRC_DIR="${BUILD_DIR}/src"
RELEASE_BIN="${BUILD_DIR}/target/release/flowlog-compiler"

# -----------------------------------------------------------------------
# Step 2: idempotency — bail out early if the binary already exists.
# -----------------------------------------------------------------------
if [[ -x "$RELEASE_BIN" ]]; then
    ok "${SHORT_SHA} already built at ${BUILD_DIR}"
    printf '%s\t%s\t%s\n' "$FULL_SHA" "$SHORT_SHA" "$BUILD_DIR"
    exit 0
fi

# -----------------------------------------------------------------------
# Step 3: materialize source via a worktree off the mirror, so multiple
# SHAs share object storage.
# -----------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
if [[ ! -d "$SRC_DIR/.git" && ! -f "$SRC_DIR/.git" ]]; then
    log "creating worktree at ${SRC_DIR} (sha=${SHORT_SHA})"
    git -C "$MIRROR" worktree add --detach --force "$SRC_DIR" "$FULL_SHA" \
        || die "git worktree add failed at $SRC_DIR"
else
    # Worktree exists from a partial prior run — defensively re-pin.
    log "re-pinning existing worktree to ${SHORT_SHA}"
    ( cd "$SRC_DIR" && git checkout --quiet --detach "$FULL_SHA" ) \
        || die "failed to re-pin worktree to $SHORT_SHA"
fi

# -----------------------------------------------------------------------
# Step 4: build release. CARGO_TARGET_DIR keeps each SHA's target/ inside
# its own BUILD_DIR so concurrent regression runs don't stomp each other.
# -----------------------------------------------------------------------
log "cargo build --release (this may take a few minutes on first run) ..."
(
    cd "$SRC_DIR"
    CARGO_TARGET_DIR="${BUILD_DIR}/target" cargo build --release --quiet
) || die "cargo build --release failed for sha ${SHORT_SHA}"

[[ -x "$RELEASE_BIN" ]] || die "build succeeded but binary not found at $RELEASE_BIN"

ok "built ${SHORT_SHA} at ${BUILD_DIR}"
printf '%s\t%s\t%s\n' "$FULL_SHA" "$SHORT_SHA" "$BUILD_DIR"
