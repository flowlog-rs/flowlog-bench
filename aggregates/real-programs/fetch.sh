#!/usr/bin/env bash
# Usage: fetch.sh <facts dir>
#
# Downloads the datasets these benchmarks use from the flowlog_benchmark
# Hugging Face dataset into <facts dir>, skipping any that are already there.
set -euo pipefail
[[ $# -eq 1 ]] || { sed -n '2,5p' "$0"; exit 2; }
source "$(cd "$(dirname "$0")/../../scripts/lib" && pwd)/datasets.sh"
mkdir -p "$1"
FACT_DIR=$(cd "$1" && pwd)
hf=https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/resolve/main/dataset
for name in livejournal orkut arabic livejournal-sssp orkut-sssp roadNet-CA; do
    dataset_ensure_zip "$name" "$hf/csv/$name.zip" || die "download failed: $name"
done
name=ldbc_snb_interactive_sf3
dataset_ensure_tar_zst "$name" "$hf/ldbc/$name.tar.zst" || die "download failed: $name"
echo "datasets ready in $FACT_DIR"
