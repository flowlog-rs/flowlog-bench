#!/usr/bin/env bash
# =============================================================================
# scripts/get_flowlog.sh — fetch + build flowlog at FLOWLOG_REF, idempotently.
# =============================================================================
#
# Clones flowlog at FLOWLOG_REF=<sha|tag|branch> (default: main), builds
# release with the revision's Cargo.lock, and caches at flowlog/<short_sha>/.
# Re-running validates the checkout and lets Cargo check build freshness.
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
#   BUILD_INFO=$(bash scripts/get_flowlog.sh) || exit $?
#   IFS=$'\t' read -r FULL SHORT BUILD <<< "$BUILD_INFO"
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
command -v cargo >/dev/null 2>&1 || die "cargo (rust toolchain) is required — run env.sh"
command -v flock >/dev/null 2>&1 || die "flock is required"

CACHE_ROOT="${FLOWLOG_CACHE_DIR:-${ROOT_DIR}/flowlog}"
mkdir -p "$CACHE_ROOT"
CACHE_ROOT="$(realpath "$CACHE_ROOT")"
# Serialize mirror/worktree mutations and builds, including simultaneous CI jobs.
exec 9>"${CACHE_ROOT}/.fetch.lock"
flock 9

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
[[ "$(git -C "$MIRROR" remote get-url origin)" == "$FLOWLOG_REPO" ]] \
    || die "cache belongs to another FLOWLOG_REPO; use a separate FLOWLOG_CACHE_DIR"

log "fetching latest refs into mirror ..."
git -C "$MIRROR" fetch --quiet --tags --prune origin '+refs/heads/*:refs/heads/*' \
    || die "git fetch failed in $MIRROR"

# Fetch an explicit ref too (e.g. refs/pull/123/head or an unadvertised SHA).
# Reject ambiguous short names instead of silently preferring a branch to a tag.
if git -C "$MIRROR" show-ref --verify --quiet "refs/heads/$FLOWLOG_REF" \
    && git -C "$MIRROR" show-ref --verify --quiet "refs/tags/$FLOWLOG_REF"; then
    echo "ERROR: ambiguous ref '$FLOWLOG_REF'; use refs/heads/ or refs/tags/" >&2
    exit 2
fi
if ! git -C "$MIRROR" rev-parse --verify --end-of-options "${FLOWLOG_REF}^{commit}" >/dev/null 2>&1; then
    git -C "$MIRROR" fetch --quiet origin "$FLOWLOG_REF" \
        || { echo "ERROR: unknown ref '$FLOWLOG_REF'" >&2; exit 2; }
    FLOWLOG_REF=FETCH_HEAD
elif [[ "$FLOWLOG_REF" == refs/* && "$FLOWLOG_REF" != refs/heads/* && "$FLOWLOG_REF" != refs/tags/* ]]; then
    git -C "$MIRROR" fetch --quiet origin "$FLOWLOG_REF" || die "fetch failed: $FLOWLOG_REF"
    FLOWLOG_REF=FETCH_HEAD
fi
FULL_SHA="$(git -C "$MIRROR" rev-parse --verify "refs/heads/${FLOWLOG_REF}^{commit}" 2>/dev/null \
        || git -C "$MIRROR" rev-parse --verify "refs/tags/${FLOWLOG_REF}^{commit}"  2>/dev/null \
        || git -C "$MIRROR" rev-parse --verify --end-of-options "${FLOWLOG_REF}^{commit}" 2>/dev/null \
        || die "FLOWLOG_REF='${FLOWLOG_REF}' did not resolve to a commit in mirror")"
SHORT_SHA="${FULL_SHA:0:12}"

BUILD_DIR="${CACHE_ROOT}/${SHORT_SHA}"
SRC_DIR="${BUILD_DIR}/src"
RELEASE_BIN="${BUILD_DIR}/target/release/flowlog-compiler"

# -----------------------------------------------------------------------
# Step 2: materialize source via a worktree off the mirror, so multiple
# SHAs share object storage.
# -----------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
if [[ ! -d "$SRC_DIR/.git" && ! -f "$SRC_DIR/.git" ]]; then
    log "creating worktree at ${SRC_DIR} (sha=${SHORT_SHA})"
    git -C "$MIRROR" worktree add --detach "$SRC_DIR" "$FULL_SHA" >&2 \
        || die "git worktree add failed at $SRC_DIR"
fi
[[ "$(git -C "$SRC_DIR" rev-parse HEAD)" == "$FULL_SHA" ]] \
    || die "cached checkout has the wrong commit: $SRC_DIR"
[[ -z "$(git -C "$SRC_DIR" status --porcelain --untracked-files=all)" ]] \
    || die "cached checkout is dirty: $SRC_DIR (use a new FLOWLOG_CACHE_DIR)"
git -C "$SRC_DIR" submodule update --init --recursive >&2 || die "submodule checkout failed"
[[ -f "$SRC_DIR/Cargo.lock" ]] || die "revision has no Cargo.lock; cannot build with --locked"
[[ -f "$SRC_DIR/flowlog-runtime/Cargo.toml" ]] || die "revision has no flowlog-runtime crate"

# -----------------------------------------------------------------------
# Step 3: build release. CARGO_TARGET_DIR keeps each SHA's target/ inside
# its own BUILD_DIR so concurrent regression runs don't stomp each other.
# -----------------------------------------------------------------------
log "cargo build --release --locked (this may take a few minutes on first run) ..."
(
    cd "$SRC_DIR"
    CARGO_TARGET_DIR="${BUILD_DIR}/target" cargo build --release --locked --quiet --bin flowlog-compiler >&2
) || die "cargo build --release --locked failed for sha ${SHORT_SHA}"

[[ -x "$RELEASE_BIN" ]] || die "build succeeded but binary not found at $RELEASE_BIN"
[[ -z "$(git -C "$SRC_DIR" status --porcelain --untracked-files=all)" ]] \
    || die "build modified the pinned checkout: $SRC_DIR"
ok "built ${SHORT_SHA} at ${BUILD_DIR}"
printf '%s\t%s\t%s\n' "$FULL_SHA" "$SHORT_SHA" "$BUILD_DIR"
