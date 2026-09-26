#!/usr/bin/env bash
# Usage: build.sh <flowlog checkout> <bin dir>
#
# Builds flowlog-compiler from the checkout, then compiles these programs
# against the checkout's own flowlog-runtime:
#   <bin dir>/batch/{cc,sssp,ic13}       timed batch programs, from programs/
#   <bin dir>/batch/{cc,sssp}_out        the same, writing their answer out
#   <bin dir>/incremental/{cc,sssp}_out  incremental/*.dl, with --mode inc
# Make one <bin dir> per FlowLog version you want to compare. The exact
# programs compiled are kept in <bin dir>/build/programs/.
set -euo pipefail
[[ $# -eq 2 ]] || { sed -n '2,10p' "$0"; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
corpus=$(cd "$here/../../programs" && pwd)
source=$(cd "$1" && pwd)
mkdir -p "$2"/{batch,incremental} "$2"/build/programs/{batch,incremental}
bin=$(cd "$2" && pwd)
programs=$bin/build/programs

cargo build --release --locked --quiet --manifest-path "$source/Cargo.toml" \
    --target-dir "$bin/build/compiler" -p flowlog-compiler
compiler=$bin/build/compiler/release/flowlog-compiler

cp "$corpus/ldbc/flowlog/interactive-complex-13.dl" "$programs/batch/ic13.dl"
for name in cc sssp; do
    cp "$corpus/oracle/flowlog/$name/default.dl" "$programs/batch/$name.dl"
    sed 's/^\.printsize \([A-Za-z_]*\)$/.output \1(delimiter=",")/' \
        "$programs/batch/$name.dl" > "$programs/batch/${name}_out.dl"
    cp "$here/incremental/${name}_out.dl" "$programs/incremental/"
done

compile() {  # <mode> <name> [compiler flags]
    local mode=$1 name=$2 log=$bin/build/$1-$2.log
    shift 2
    FLOWLOG_RUNTIME_PATH=$source/flowlog-runtime "$compiler" "$programs/$mode/$name.dl" "$@" \
        -o "$bin/$mode/$name" -B "$bin/build/$mode-$name" -T "$bin/build/target" \
        > "$log" 2>&1 || { echo "failed: $mode/$name (see $log)" >&2; exit 1; }
    echo "built $bin/$mode/$name"
}

for name in cc sssp cc_out sssp_out; do
    compile batch "$name"
done
compile batch ic13 --str-intern
for name in cc_out sssp_out; do
    compile incremental "$name" --mode inc
done
