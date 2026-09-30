# Range-join experiment scope

This directory is a standalone Differential Dataflow experiment. Its purpose
is to establish the runtime algorithm, correctness contract, and cost model
for sorted range joins before integrating them into FlowLog.

## Working rules

1. Keep experiments self-contained under `range-join/` unless an integration
   change is explicitly requested.
2. Use the term **range join**.
3. Model range predicates as variable-to-variable comparisons. Computed
   bounds such as `x + width` are precomputed shadow columns.
4. Preserve correctness under retractions, multiple logical times, entered
   traces, recursion, and multiple workers.
5. Run `cargo test --release` and
   `cargo clippy --release --all-targets -- -D warnings` after code changes.
   Run `python3 -m unittest discover -s tests -p 'test_*.py' -v` for the
   benchmark driver. Build measurements with `--locked`.
6. Use `check=1` for focused benchmark runs so results are compared with the
   direct oracle.
7. Keep generated datasets manageable. This module studies algorithmic
   behavior, not maximum-scale throughput.
8. Do not turn benchmark timings into correctness tests or fixed performance
   gates.
9. Keep `bench.sh` independently runnable; do not add this experiment to an
   unrelated top-level sweep.

## Cursor safety

Do not replace the per-batch cursors in `SeekIter` with
`CursorList::seek_val` without a focused regression test. Differential
Dataflow 0.25.1 advances every constituent cursor in that method, including
cursors at other keys, which can skip values or panic.
