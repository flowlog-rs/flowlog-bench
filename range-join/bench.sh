#!/usr/bin/env bash
# Standalone runner. Usage: ./bench.sh [quick|full] [bench.py options]
set -euo pipefail
cd "$(dirname "$0")"
TARGET_DIR="${CARGO_TARGET_DIR:-target}"
cargo build --release --locked --quiet --target-dir "$TARGET_DIR"
exec python3 bench.py --binary "$TARGET_DIR/release/rangejoin-toy" "$@"
