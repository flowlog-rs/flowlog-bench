# west2 reproduction — independent double-check

Independent re-run of a representative subset of the 4-engine sweep on a
**second machine** (flowlog-west2, 64-core / 503 GiB, Ubuntu 22.04), to
double-check the headline numbers and verify cross-engine correctness. Same
FlowLog commit (3b1387e18460), Souffle 2.5, Ascent 0.8, WORKERS=32,
NUM_RUNS=3 (median of 3). DDlog omitted from this spot-check.

**Correctness:** every engine output relation sizes are diffed against
FlowLog at run time (the Crosscheck columns). All pairs below matched on
every successful run — FlowLog == Souffle == Ascent.

## Wall time (s, median; slowdown vs FlowLog) + peak RSS (MiB)

| Program/Dataset | FlowLog | Souffle | Ascent | Xcheck | FL RSS | Sf RSS | As RSS |
|---|---|---|---|---|---|---|---|
| dyck/postgre | 0.6 | 5.1 (8.7x) | 3.4 (5.7x) | match | 1299 | 339 | 1689 |
| tc/G5K-0.001 | 1.6 | 4.2 (2.6x) | 3.9 (2.4x) | match | 1625 | 1119 | 1041 |
| sg/G5K-0.001 | 2.9 | 6.5 (2.2x) | 5.3 (1.8x) | match | 3024 | 1209 | 917 |
| reach/livejournal | 1.5 | 19.9 (13.1x) | 4.4 (2.9x) | match | 2549 | 1414 | 3563 |
| galen/galen | 5.3 | 26.7 (5.0x) | 7.0 (1.3x) | match | 5330 | 3228 | 2397 |
| crdt/crdt | 2.9 | 3.7 (1.3x) | 6.7 (2.3x) | match | 377 | 117 | 222 |

Absolute times are machine-dependent; the cross-engine ratios and the
correctness match are the reproducible signal. FlowLog wall times track the
original sweep closely (same-class westus2 hardware), and the engine ordering
holds at every pair.
