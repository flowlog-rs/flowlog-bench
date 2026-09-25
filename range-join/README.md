# Sorted range-join experiment

A standalone Rust experiment using **unmodified, published Differential
Dataflow**. Custom `JoinTactic` implementations replace an equality-key
cross product plus filter with searches over sorted values. This is not
integrated into FlowLog's planner or code generator.

The workloads use generated data. `objects` implements the supplied
DDISASM object-conflict rule shape, but **is not a full DDISASM benchmark
or a measurement on real disassembly inputs**.

## Core logic

For a fixed left row, matching right values must form one contiguous run:

```text
right values:    below ... below | match ... match | above ... above
locate returns:  Less            | Equal           | Greater
```

`locate(key, left, right)` defines that partition. Residual filters and
projection belong in the separate `result` closure.

| Plan | Implementation | Tradeoff |
| --- | --- | --- |
| `range` / Merge | Merge equality keys, flatten the right key group's edits, gallop to each left row's matching slice | Reads the whole right group; usually suits large batches |
| `seek` | Probe each right batch using `lower(key, left)`, then scan the run | Avoids reading whole groups for small left updates |
| `back` | Probe each left batch using `lower_back(key, right)` | Requires reverse-monotone ranges and a valid inverse probe |
| `auto` | Choose one of those plans per DD work item | A coarse heuristic, not an optimal or calibrated cost model |

With one update per value, the merge path costs
`O(R + L log(R + 1) + matching_pairs)` for arbitrary left bounds.
Monotonically moving run starts amortize searches to
`O(L + R + matching_pairs)`. It is **not unconditionally linear**.

Seeking costs a probe per outer value per inner batch, plus the scanned
values and timestamp combinations. Conservative probes may scan rejected
values before the matching run. Multiple histories and residual filters
mean that final output size is not a complete measure of the work.

Auto estimates `L + R`, `L * right_batches * bit_length(R)`, and (if allowed)
`R * left_batches * bit_length(L)`. Here counts are **edits across all
keys**, not distinct values. It does not model key skew, selectivity,
cache behavior, or compaction cost.

## Keys versus payload ordering

The **arrangement key contains equality-join columns**. The range-search
column must lead the arrangement's **value tuple**:

```text
Size1 > Size2:
    left:  (k, (EA1, Size1, ...))
    right: (k, (Size2, EA2, ...))
```

That left layout is valid for forward search: left bounds may arrive in
any order. Forward search requires the right values to be ordered by
`Size2`. To seek in the other direction as well, the left needs the
corresponding leading ordering and a reverse-monotone predicate.

Right values `(EA2, Size2, ...)` are not globally ordered by size. Putting
`Size` in the arrangement key would instead make this operator join equal
sizes, not implement `Size1 > Size2`.

A single lexicographic order does not independently index both address
and size. When both comparisons are present, choose one searchable range
and leave the other as a residual filter. Reordered value tuples may
require separate arrangements; they are not interchangeable just because
the equality key is the same.

### DDISASM-shaped object conflicts

```text
Conflict(EA1, Size1, Type1, EA2, Size2, Type2) :-
    Candidate(EA1, Size1, Type1),
    Candidate(EA2, Size2, Type2),
    EA1 < EA2, EA2 < EA1 + Size1.
```

The sorted plans use:

```text
left:  ((), (EA1, Size1, Type1, End1))   where End1 = EA1 + Size1
right: ((), (EA2, Size2, Type2))
```

The range predicate compares `EA2` with `EA1` and precomputed `End1`.
Variable sizes are fine for forward search. Arbitrary object ends are not
sorted by start address, so this workload does not enable seek-back.
All six output fields are retained. Generated candidates include several
numeric type tags at the same address and varying sizes, including nested
ranges. Type tags are payload, not a searched string column.

Seek-back is not limited to constant widths in principle: any predicate
with `Greater* Equal* Less*` over left values and a sound inverse probe
qualifies. Constant widths are the implemented examples with that property.

## Run it

From this directory, with Rust, Bash, Python 3.10+, and Linux `lscpu`/`taskset`:

```bash
cargo test --release --locked
cargo clippy --release --locked --all-targets -- -D warnings
python3 -m unittest discover -s tests -p 'test_*.py' -v

./bench.sh quick
./bench.sh full
./bench.sh quick --workers 3
./bench.sh full --case object-conflict --runs 5
```

`CARGO_TARGET_DIR` is honored. Focused executable runs do not pin CPUs:

```bash
cargo run --release --locked -- objects auto n=30000 check=1
cargo run --release --locked -- hop seek n=10000 check=1
cargo run --release --locked -- txn auto n=30000 side=lr check=1
```

`band` is a constant-width self join; `keyed` adds an equality key;
`interval` joins variable-width intervals to points; `objects` is the
rule above; `hop` is recursive; `txn` preloads two relations and then
inserts `delta` new rows into **each selected side** per transaction.

Arguments are checked before worker startup. Impossible transaction
requests (not enough unused values in the sampling domain) fail instead
of looping indefinitely. Reported `left_rows` and `right_rows` are actual
initial cardinalities after generation/deduplication, not just requested
`n`/`m`. In `interval`, the left is the interval input (`m`); in `hop`, the
initial left input is the single source.

## Benchmark fairness

The default matrix covers selective, empty, and dense results; tiny key
groups; skew; unbalanced inputs; recursion; and updates to either or both
sides. Inputs stay at or below 100k requested rows by default.

**Two baselines are deliberate:**

- `cross`: published `flowlog-runtime 0.5.0` with its normal fused predicate,
  using lean values and one shared arrangement for self joins.
- `cross-shadow`: the same baseline join with the **same shadow-column
  layout and arrangements as the full sorted plans**. This separates
  sorted searching from expression precomputation and arrangement changes.

`nested` uses the flattening tactic but visits all pairs, with the same
lean inputs as `cross`. It is a control, not another range optimization.
`range1` uses only the lower inequality as a search condition. `arrange`
is a separate diagnostic, not part of the paired matrix; it measures
native input arrangements, not necessarily the sorted plans' extra
arrangements. Do not subtract it from other timings as an exact join cost.

The runner:

1. Builds once with `--release --locked`; all methods use the same
   executable, allocator, optimization level, data seed, and output sink.
2. Pins every method to the same selected physical cores within the
   inherited CPU allowance, excluding SMT siblings.
3. Performs one warm-up and **three measured runs for every method** by
   default, shuffling method order per repetition with a recorded seed.
4. Requires `check=ok`, matching input cardinalities, and matching answer
   fingerprints across methods and repetitions.
5. Computes each metric's median independently and retains min/max and
   every raw run. Transaction medians are not selected by total runtime.
6. Aborts on errors, mismatches, missing metrics, or per-process timeout.
   An incomplete matrix remains marked `complete=false`.

**Timing boundaries:** `secs` includes worker startup, dataflow and
arrangement construction, input insertion, execution, output fingerprinting,
and shutdown. It excludes compilation, data generation, and oracle
construction. Transaction phases wait for the **post-sink** frontier and
all workers at each transaction boundary. `load_secs` includes startup;
`update_secs` spans completion of preload to completion of the last update;
`per_txn_ms` is that run's average over `rounds`, not a tail-latency metric.

Each new `results/<run>/` directory contains:

- `manifest.json`: source and binary hashes, dependency/toolchain versions,
  Git state, host/topology/affinity, arguments, and completion status;
- `raw.jsonl`: commands, stdout/stderr, measurements, and warm-up flags;
- `summary.csv`: per-case/per-method medians, min/max, and output summaries.

Results are gitignored. Pinning does not reserve the machine, bind NUMA
memory, fix frequency, or control cache state. Warm-ups warm executable
pages, not a persistent DD trace between processes. Very small differences
near startup cost are not convincing speedups. Dense output is intrinsically
expensive, and tiny key groups can make the ordinary join preferable.

`check=1` compares cardinality and an order-independent 64-bit fingerprint:
it is probabilistic, not exact row-by-row equality. The small correctness
tests instead compare exact weighted outputs, including retractions,
incomparable product times, inclusive/exclusive boundaries, absent batch
keys, entered recursive traces, and 1/3-worker execution.

### Reviewed measurements

September 25, 2026, AMD EPYC 7763 host, one worker pinned to CPU 0.
Measured source: `48a7271f2714b5e5800088c96028b42e5fcf8039`, with a
clean working tree and source/binary hashes retained in both manifests.
The full matrix used seed 7, one warm-up and three measured runs per
method, Rust 1.96.0, DD 0.25.1, Timely 0.31.0, FlowLog runtime 0.5.0,
and mimalloc 0.1.52. Commands:

```bash
./bench.sh full --output results/review-full-clean-20260925
./bench.sh quick --workers 3 --output results/review-3w-clean-20260925
```

All full-matrix batch cases are below. Times are **median total
milliseconds**, including arrangements and the output sink. Input sizes
are actual left/right row counts, not requested sizes.

| Case | Input rows L/R | `cross` | `cross-shadow` | `range` | `seek` | `auto` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Selective self join | 30000 / 30000 | 2565.886 | 2621.726 | 8.921 | 14.038 | 9.186 |
| Empty range | 30000 / 30000 | 2568.881 | 2610.148 | 5.218 | 4.707 | 5.438 |
| Dense range | 800 / 800 | 5.695 | 5.813 | 4.262 | 8.674 | 4.131 |
| Tiny key groups | 2856 / 2843 | 1.278 | 1.219 | 1.175 | 1.250 | 1.439 |
| Keyed selective | 95210 / 95178 | 57.403 | 59.577 | 30.394 | 41.771 | 31.673 |
| Keyed skew | 24587 / 24512 | 56.795 | 59.750 | 12.814 | 20.144 | 13.711 |
| Variable intervals | 29995 / 30000 | 2590.578 | 2589.491 | 10.348 | 14.528 | 10.720 |
| Few intervals | 30 / 30000 | 5.888 | 5.808 | 2.813 | 1.892 | 1.836 |
| Object conflicts | 30000 / 30000 | 3270.098 | 3382.750 | 29.885 | 41.622 | 30.399 |
| Recursive reachability | 1 / 10000 | 770.805 | 773.459 | 331.939 | 50.465 | 51.408 |

For transactions, these are **median milliseconds per transaction**,
excluding preload: 30000 initial rows per side, 20 rounds, and 10 fresh
rows per selected side per round.

| Updated side | `cross` | `cross-shadow` | `range` | `seek` | `auto` |
| --- | ---: | ---: | ---: | ---: | ---: |
| Left | 2.810 | 2.837 | 0.863 | 0.026 | 0.026 |
| Right | 2.797 | 2.805 | 0.888 | 1.038 | 0.026 |
| Both | 6.411 | 6.636 | 2.572 | 1.080 | 0.044 |

Each completed matrix contains 101 case/method summaries and 404 checked
process runs, including warm-ups. The three-worker quick matrix used
physical cores 0, 2, and 4; it checks multiworker execution, not a scaling
claim. The local result directories retain the other methods, min/max
values, and raw records.

The useful result is conditional: avoid visiting nonmatching pairs when
there are many of them. Forced `seek` is **slower** than the native
baseline on dense output; tiny groups show no convincing benefit.
Forward-only seeking also misses the incremental advantage when updates
arrive on the right; the bidirectional `auto` plan can seek back instead.
These synthetic measurements are not end-to-end FlowLog or DDISASM
speedups, and three repetitions on a shared host are not a performance
guarantee.

## Code map and remaining limits

`range_join.rs` and `seek_join.rs` contain the tactics and iterators;
`gallop.rs` is the search helper. `main.rs` drives the workloads,
`args.rs` validates the CLI, and `objects.rs` isolates the application-shaped
example. `bench.sh` builds; `bench.py` measures and records results.
Tests cover the operators, CLI equivalence, and benchmark bookkeeping.

The per-batch seek cursors avoid DD 0.25.1's `CursorList::seek_val`, which
also advances constituent cursors at unrelated keys or exhausted cursors.
This is not a claim that DD's built-in equality join is generally broken;
no DD code is patched here.

The iterators currently yield between equality-key groups, not within
large groups, and the merge path materializes the right group's history.
This is not yet a memory-bounded, fine-grained production operator.
An empty equality key `()` puts join work on one worker; more workers do
not parallelize that hot key. Multi-dimensional range indexing and
parallel range partitioning are out of scope.

Future compiler integration must preserve the chosen value ordering,
precompute shadow columns, construct sound probe tuples with minimum
trailing fields, and leave unsupported predicates as residual filters.
Interned symbols are fine as payload; ranges over intern IDs are invalid
unless their order matches the language's comparison order.
