# Aggregate benchmarks

The code behind the [aggregate report](../docs/benchmarks/2026-09-26-aggregates/README.md).
It measures FlowLog's `min`, `max`, `count`, `sum` and `avg` in two ways:

- **`real-programs/`** runs whole FlowLog programs (CC, SSSP and LDBC IC13) on
  real graphs, and compares FlowLog builds, for example main against a PR.
- **`programs/` + `scripts/`** are microbenchmarks: small Rust programs that
  run one aggregate over made-up groups, so many designs can be compared side
  by side.

Results go in `results/` and scratch files in `work/`; both are git-ignored.

## Real programs

You need Rust, Python 3 with numpy, GNU time at `/usr/bin/time`, and about
30 GB of disk for the datasets.

```bash
cd aggregates/real-programs
./fetch.sh ../work/facts                      # the datasets, once
./build.sh <main checkout> ../work/bins/main  # one bin dir per FlowLog checkout
./build.sh <PR checkout> ../work/bins/pr
V="--variant main=../work/bins/main --variant pr=../work/bins/pr"
F=../work/facts W=../work/workloads R=../results

# Batch: time the programs, then check that the answers match.
./time_batch.py $V --output $R/batch.csv cc:$F/livejournal cc:$F/orkut \
    sssp:$F/livejournal-sssp sssp:$F/orkut-sssp ic13:$F/ldbc_snb_interactive_sf3
./time_batch.py $V --reps 3 --output $R/batch.csv cc:$F/arabic
./check_batch.py $V --output $R/outputs.csv cc:$F/livejournal cc:$F/orkut cc:$F/arabic \
    sssp:$F/livejournal-sssp sssp:$F/orkut-sssp ic13:$F/ldbc_snb_interactive_sf3

# Incremental: make the workloads, then time them. Outputs are compared too.
./workloads.py --facts $F --out $W
./time_incremental.py $V --output $R/incremental.csv \
    cc_out:$W/cc-lj250k cc_out:$W/cc-lj250k-shuf sssp_out:$W/sssp-lj250k
./time_incremental.py $V --reps 2 --output $R/incremental.csv \
    cc_out:$W/cc-roadnet sssp_out:$W/sssp-roadnet
./time_incremental.py $V --workers 1 --reps 3 --output $R/incremental.csv \
    cc_out:$W/cc-lj250k cc_out:$W/cc-lj250k-shuf sssp_out:$W/sssp-lj250k
```

| Script | What it does |
|---|---|
| `fetch.sh` | Downloads the seven datasets from the [flowlog_benchmark](https://huggingface.co/datasets/NemoYuu/flowlog_benchmark) Hugging Face dataset. |
| `build.sh` | Builds the FlowLog compiler from a checkout, then compiles the programs with it. |
| `time_batch.py` | Times the batch programs: FlowLog's own "Dataflow executed" time, wall time and peak memory. |
| `check_batch.py` | Runs each variant once and compares a hash of the sorted output. Fails if they differ or an answer is empty. |
| `workloads.py` | Makes the incremental inputs: one bulk load, then 10 transactions of 1,000 inserts and 1,000 deletes. |
| `time_incremental.py` | Times every commit of a workload and checks that the variants give the same output changes. |

The timing scripts interleave the variants. One warmup run is thrown away.
Then each round runs every variant once, in an order that rotates each round.

The report's numbers came from earlier one-off versions of these scripts.
These cleaned-up versions run the same programs on the same inputs (the
workloads match byte for byte) and take the same measurements.

A FlowLog binary reads a missing input file as an empty relation, so a wrong
facts path quietly gives an empty answer. The batch scripts stop if the facts
directory is missing, and `check_batch.py` fails on an empty answer.

## Microbenchmarks

Each script builds its Rust program from `programs/` against the
`flowlog-runtime` of a FlowLog checkout, pins it to the physical cores of one
NUMA node, and checks every output. `aggregation_modes.py` and
`aggregate_designs.py` write the designs under test into the program itself,
so one binary holds them all and code-layout noise mostly cancels. The other
scripts compare separate builds.

| Script | Program | What it compares |
|---|---|---|
| `aggregation_modes.py` | `aggregation_modes/` | Whole aggregate pipelines: main, no dedup, fused and weighted versions. |
| `aggregate_designs.py` | `aggregate_designs/` | 19 batch and incremental designs, listed at the top of `main.rs`. |
| `interleave_builds.py` | `aggregate_designs/` | The same designs across several FlowLog builds. |
| `incremental_extrema.py` | `incremental_extrema/` | Incremental min/max, one FlowLog build against another. |
| `diagnose_incremental_extrema.py` | `incremental_extrema/` | Several binaries interleaved; can also switch between a full scan and first/last inside one binary. |
| `duplicate_extrema.py` | `incremental_extrema/duplicates.rs` | Full scan against first/last when many derivations repeat a value. |

<details>
<summary>The commands behind each folder of the report's <code>microbench/</code></summary>

Flags not shown are at their defaults. Each folder's `metadata.json` records
every parameter, the FlowLog commit, and the binary's SHA-256. `$S` is a
FlowLog checkout, `$B` a build directory and `$O` an output directory.

```bash
# pipelines/: 8d2d1a9 plus the prototype patch stored in metadata.json
aggregation_modes.py --source $S --output $O/w1 --runs 10 --warmup-rounds 10 --rounds 200
aggregation_modes.py --source $S --output $O/w32 --workers 32 --scale 4 \
    --warmup-rounds 10 --rounds 200

# designs/: 19ab062 = PR #380's code on 8d2d1a9 (same code as 08f1ea2; only comments differ)
aggregate_designs.py --source $S --build $B --output $O/w1 --runs 5 \
    --shapes small large small-dup large-dup
aggregate_designs.py --source $S --build $B --output $O/w32 --runs 5 --workers 32 --scale 4
aggregate_designs.py --source $S --build $B --output $O/w32-batch-hash --runs 5 --workers 32 \
    --scale 4 --families batch \
    --modes b-main b-hash b-hash-combine b-hash-local b-dedup-hash b-dedup-local b-pair-local
aggregate_designs.py --source $S --build $B --output $O/w32-incremental-operators --runs 5 \
    --workers 32 --scale 4 --families incremental --modes i-runtime i-custom i-lean
aggregate_designs.py --source $S --build $B --output $O/w1-batch-extrema-hash --runs 5 \
    --families batch --kinds min max --modes b-main b-hash b-hash-local
aggregate_designs.py --source $S --build $B --output $O/w32-batch-extrema-hash --runs 5 \
    --workers 32 --scale 4 --families batch --kinds min max \
    --modes b-main b-hash b-hash-local b-hash-adaptive

# hash-fold/: old = 19ab062, final = old + ../docs/.../patches/hash-fold.patch,
# foreach = an earlier draft of that patch. Build each with
#   aggregate_designs.py --source <checkout> --build <dir> --build-only
X="--binary old=<old> --binary final=<final> --binary foreach=<foreach>"
EXT="--variants old/b-main old/b-weights final/b-weights foreach/b-weights
     --ratios final/b-weights,old/b-main,vs-main final/b-weights,old/b-weights,vs-19ab062
              final/b-weights,foreach/b-weights,control"
ADD="--variants old/b-main final/b-main foreach/b-main
     --ratios final/b-main,old/b-main,vs-main final/b-main,foreach/b-main,control"
interleave_builds.py $X $EXT --output $O/w32-min-max
interleave_builds.py $X $ADD --kinds count sum --output $O/w32-count-sum
interleave_builds.py $X $EXT --kinds max --workers 1 --scale 1 --runs 7 --output $O/w1-max
interleave_builds.py $X $ADD --kinds sum --workers 1 --scale 1 --runs 7 --output $O/w1-sum

# incremental-endpoint/: base = 8d2d1a9,
# candidate = base + ../docs/.../patches/incremental-endpoint.patch
incremental_extrema.py --base-source <base> --head-source <candidate> --rounds 256  # separate-builds-full
incremental_extrema.py --base-source <base> --head-source <candidate> --tag pilot \
    --runs 1 --rounds 16 --process-warmups 0                                        # separate-builds-pilot
diagnose_incremental_extrema.py --variant scan=<bin> --variant endpoint=<same bin> \
    --mode scan:scan --mode endpoint:endpoint --runs 7 --rounds 128 --output $O/same-binary
diagnose_incremental_extrema.py --variant original=<base bin> --variant specialized=<candidate bin> \
    --runs 7 --rounds 128 --output $O/same-build-path  # both built in turn at one path
diagnose_incremental_extrema.py --variant original_build=<base bin> \
    --variant rebuilt_same_source=<base bin, rebuilt> --output $O/unchanged-source-control
diagnose_incremental_extrema.py --variant original=<base bin> --variant refactor=<refactor bin> \
    --variant specialized=<candidate bin> --output $O/three-way  # refactor: the patch minus first/last
duplicate_extrema.py --source <base> --output $O/duplicates
duplicate_extrema.py --source <base> --output $O/duplicates-heavy --runs 15 --rounds 256 \
    --duplicates 32 64
# profiles/ holds perf sample counts; findings.json sums up this folder.
```

</details>
