# Sorted range-join experiment

This standalone Rust crate tests whether FlowLog can use Differential
Dataflow's sorted arrangements for range joins instead of forming an
equality-key cross product and filtering it.

It is intentionally isolated from the FlowLog compiler and the other
benchmarks. Work here can refine the runtime algorithm and its cost model
before changing FlowLog's planner, IR, or code generation.

## Main finding

For a query such as:

```text
Out(x, y) :- L(x), R(y), x < y, y < x + width.
```

the values beneath an arrangement key are sorted. The join can therefore
choose among three plans:

| Plan | Use when | Work, excluding output |
| --- | --- | --- |
| merge | both sides are substantial batches | `O(left + right)` |
| seek | a small left batch meets a large right trace | `O(left * batches(right) * log(right))` |
| seek back | a small right batch meets a large left trace | `O(right * batches(left) * log(left))` |

`Strategy::Auto` estimates these costs for each unit of Differential
Dataflow join work. This matters because batch evaluation favors merge,
while recursive and incremental evaluation often favor a directional seek.

Results measured on September 25, 2026:

| Workload | Baseline | Sorted plan |
| --- | ---: | ---: |
| unkeyed range join, 100k rows | 28.5 s | 0.025 s merge |
| interval join, 30k rows | 2.72 s | 0.011 s merge |
| keyed range join, 1M rows | 2.84 s | 0.30 s merge |
| recursive hops, 30k rows | 6.50 s cross product | 0.155 s seek |
| recursive hops, 100k rows | 27.4 s merge | 0.52 s seek |

For 30k-row incremental traces with transactions of 10 inserts:

| Changed side | Cross product + filter | Merge | Auto |
| --- | ---: | ---: | ---: |
| left | 2.85 ms | 0.86 ms | 0.023 ms |
| right | 2.93 ms | 0.86 ms | 0.025 ms |

With 300k rows and both sides changing, merge took 25.6 ms per transaction;
auto took 0.054 ms.

These are experiment results, not performance gates. Re-run them on the
target machine before comparing a new implementation.

## Run it

```bash
cd range-join
cargo test --release
cargo clippy --release --all-targets
./bench.sh quick
./bench.sh
```

The benchmark binary also supports focused runs:

```bash
cargo run --release -- band auto n=100000 check=1
cargo run --release -- hop seek n=100000 check=1
cargo run --release -- txn auto n=300000 m=300000 side=lr check=1
```

Every `check=1` run compares the result with a direct oracle.

## Files

- `src/range_join.rs` implements the sorted merge plan.
- `src/seek_join.rs` implements forward seek, seek back, and automatic
  selection.
- `src/main.rs` contains the batch, keyed, interval, recursive, and
  incremental workloads.
- `tests/incremental.rs` checks retractions, timestamps, entered traces,
  multiple workers, and every applicable strategy.
- `bench.sh` runs the reproducible benchmark matrix.

## Differential Dataflow cursor issue

The experiment exposed a likely correctness bug in Differential Dataflow
0.25.1's `CursorList::seek_val`. A `CursorList` represents the minimum key
across several batch cursors, but `seek_val` advances every constituent
cursor, including cursors positioned at a different key or already
exhausted. This can skip values or panic.

This is not evidence that Differential Dataflow's built-in equality join is
generally incorrect. It is a narrower issue in the generic multi-batch
cursor operation, exposed by this custom range-join tactic.

`SeekIter` works around it by keeping one cursor per batch and calling
`seek_val` only after verifying that the cursor is at the requested key.
Before upstreaming the diagnosis, reduce it to a focused Differential
Dataflow regression test and confirm the intended `CursorList` contract
with its maintainers.

## FlowLog integration shape

A future FlowLog implementation would add a runtime range-join operator and
have code generation provide:

1. the range column first in each arranged value tuple;
2. shadow columns for expressions such as `x + width`;
3. a comparison closure classifying a value as below, inside, or above a
   range;
4. lower-bound probe tuples, using minimum values in trailing columns; and
5. an inverse lower-bound probe for seek back when the range has a known
   constant width.

Variable-width intervals cannot generally seek back. Interned strings also
need the existing join fallback unless their stored ordering matches the
language's comparison ordering. An arrangement on the empty key `()` still
runs on one worker; parallel bucketing is separate future work.
