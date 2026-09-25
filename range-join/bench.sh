#!/usr/bin/env bash
# Median-of-3 wall times for the toy workloads. Usage: ./bench.sh [quick]
set -euo pipefail
cd "$(dirname "$0")"
TARGET_DIR="${CARGO_TARGET_DIR:-target}"
cargo build --release --quiet --target-dir "$TARGET_DIR"
BIN="$TARGET_DIR/release/rangejoin-toy"
FULL=true
if [[ "${1:-}" == quick ]]; then FULL=false; fi

# Prints the median line of three runs (by seconds); `once` runs a single time.
median() {
  local reps=3
  if [[ "$1" == once ]]; then reps=1; shift; fi
  for _ in $(seq "$reps"); do "$BIN" "$@"; done |
    sort -t= -k6 -n | awk -v r="$reps" 'NR == int((r + 1) / 2)'
}

echo "# band: R(x),R(y), x<y, y<x+100 (no equality key; ~10 matches per x)"
for n in 10000 30000; do
  for m in cross nested range1 range seek back auto; do median band $m n=$n check=1; done
done
if $FULL; then
  for m in cross nested range1; do median once band $m n=100000 check=1; done
fi
for m in range seek back auto; do median band $m n=100000 check=1; done
for m in range seek auto; do median band $m n=1000000 check=1; done
for m in range auto; do median band $m n=1000000 w=8; done

echo "# interval: I(s,e),P(p), s<=p, p<e (var-var both sides; ~10 points per interval)"
for n in 10000 30000; do
  for m in cross nested range1 range seek auto; do median interval $m n=$n check=1; done
done
for m in range seek auto; do median interval $m n=1000000 check=1; done

echo "# keyed: R(k,y),S(k,z), y<z, z<y+100 (1000 keys)"
for n in 100000 1000000; do
  for m in cross nested range1 range seek back auto; do median keyed $m n=$n check=1; done
done
for w in 8 32; do
  for m in cross range auto; do median keyed $m n=1000000 w=$w check=1; done
done
echo "# keyed, skewed keys (skew=3: a few heavy keys)"
for m in cross nested range1 range seek back auto; do median keyed $m n=300000 skew=3 check=1; done
for m in cross range auto; do median keyed $m n=300000 skew=3 w=8 check=1; done

echo "# hop (recursive): Reach(y) :- Reach(x), P(y), x<y, y<x+100 (~10 points per hop)"
for n in 10000 30000; do
  for m in cross range seek back auto; do median hop $m n=$n check=1; done
done
if $FULL; then median once hop range n=100000 check=1; fi
for m in seek auto; do median hop $m n=100000 check=1; done

echo "# txn (incremental): L(x),R(y), x<y, y<x+100; 20 transactions of 10 inserts each"
for side in l r lr; do
  median once txn cross n=30000 m=30000 side=$side check=1
  for m in range seek back auto; do median txn $m n=30000 m=30000 side=$side check=1; done
  for m in range seek back auto; do median txn $m n=300000 m=300000 side=$side check=1; done
done
