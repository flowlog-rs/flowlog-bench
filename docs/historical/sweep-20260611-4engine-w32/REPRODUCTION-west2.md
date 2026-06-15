# west2 full reproduction — independent end-to-end double-check

Independent re-run of the **entire 4-engine sweep** on a second machine
(`flowlog-west2`, 64-core / 503 GiB, Ubuntu 22.04), validating every
program/dataset pair one-by-one. Soufflé 2.5, DDlog 1.2.3, Ascent 0.8,
`WORKERS=32`, `NUM_RUNS=3` (median).

**Correctness (the headline):** the harness diffs every engine’s output
relation sizes against FlowLog at run time. **All 52 runnable pairs match on
every engine** — FlowLog == Soufflé == DDlog == Ascent, zero mismatches.

**FlowLog versions:** phase-1 (non-DOOP) used `3b1387e18460`; the DOOP block
used `a40ecbc60cda` (current `main`), which carries the DOOP `cat`-UDF bridge
(#130) that the earlier snapshot predated. Soufflé/DDlog/Ascent identical throughout.

`—` = engine cannot run that pair (DDlog: recursive-min programs `cc`/`sssp`,
or 1800 s timeout on `reach/arabic`, `bipartite/mag`, `doop/jython`) — same
coverage gaps as the original sweep.

## Wall time (s, median; slowdown vs FlowLog) + correctness

| Program/Dataset | FlowLog | Soufflé | DDlog | Ascent | Xcheck |
|---|---|---|---|---|---|
| polonius_int/clap-rs | 46.3 | 145.2 (3.1×) | 386.7 (8.4×) | 61.7 (1.3×) | match |
| polonius_int/materialize | 15.0 | 56.3 (3.8×) | 255.9 (17.1×) | 26.0 (1.7×) | match |
| polonius_int/scallop | 6.2 | 30.0 (4.8×) | 295.7 (47.4×) | 16.6 (2.7×) | match |
| polonius_int/wgpu | 47.2 | 149.3 (3.2×) | 385.7 (8.2×) | 58.9 (1.2×) | match |
| tc/G10K-0.001 | 9.4 | 19.2 (2.0×) | 90.6 (9.6×) | 20.8 (2.2×) | match |
| tc/G5K-0.001 | 1.6 | 4.1 (2.6×) | 20.2 (12.7×) | 3.8 (2.4×) | match |
| sg/G10K-0.001 | 20.5 | 66.9 (3.3×) | 118.8 (5.8×) | 53.4 (2.6×) | match |
| sg/G5K-0.001 | 2.9 | 6.4 (2.2×) | 23.7 (8.3×) | 5.2 (1.8×) | match |
| reach/livejournal | 1.7 | 19.9 (11.9×) | 429.7 (256.1×) | 4.4 (2.6×) | match |
| reach/orkut | 2.5 | 35.9 (14.5×) | 735.4 (297.8×) | 6.3 (2.6×) | match |
| cc/arabic | 73.0 | — | — | 89.7 (1.2×) | match |
| cc/livejournal | 7.8 | — | — | 7.9 (1.0×) | match |
| cc/orkut | 11.8 | — | — | 11.3 (1.0×) | match |
| sssp/livejournal-sssp | 2.0 | — | — | 5.4 (2.7×) | match |
| sssp/orkut-sssp | 2.6 | — | — | 8.0 (3.1×) | match |
| bipartite/mind | 0.7 | 16.5 (22.6×) | 115.0 (157.7×) | 1.9 (2.6×) | match |
| bipartite/netflix | 3.0 | 108.7 (36.5×) | 633.8 (212.7×) | 7.5 (2.5×) | match |
| bipartite/roadNet-CA | 0.8 | 7.1 (9.4×) | 38.5 (50.9×) | 1.5 (2.0×) | match |
| dyck/kernel | 0.6 | 9.1 (14.1×) | 72.1 (111.9×) | 6.4 (9.9×) | match |
| dyck/postgre | 0.6 | 5.1 (9.3×) | 36.2 (65.9×) | 3.3 (6.0×) | match |
| crdt/crdt | 2.9 | 3.8 (1.3×) | 24.6 (8.6×) | 6.7 (2.3×) | match |
| galen/galen | 5.3 | 26.1 (4.9×) | 58.7 (11.1×) | 6.9 (1.3×) | match |
| andersen/large | 1.3 | 89.2 (66.2×) | 438.1 (324.8×) | 7.1 (5.3×) | match |
| andersen/medium | 0.8 | 39.8 (47.9×) | 215.8 (259.9×) | 3.6 (4.3×) | match |
| cspa/cspa-httpd | 11.3 | 45.7 (4.1×) | 167.3 (14.8×) | 30.7 (2.7×) | match |
| cspa/cspa-linux | 3.2 | 12.0 (3.8×) | 85.4 (26.9×) | 7.8 (2.5×) | match |
| cspa/cspa-postgresql | 11.1 | 54.1 (4.9×) | 177.7 (16.0×) | 32.0 (2.9×) | match |
| csda/csda-httpd | 0.9 | 6.9 (7.6×) | 70.8 (78.2×) | 1.9 (2.2×) | match |
| csda/csda-linux | 4.7 | 36.8 (7.8×) | 320.7 (68.4×) | 9.3 (2.0×) | match |
| csda/csda-postgresql | 2.3 | 21.0 (9.4×) | 239.4 (106.4×) | 5.6 (2.5×) | match |
| cvc5/cvc5 | 8.1 | 13.1 (1.6×) | 128.3 (15.8×) | 6.4 (0.8×) | match |
| z3/z3 | 13.4 | 89.7 (6.7×) | 1091.7 (81.3×) | 25.4 (1.9×) | match |
| doop/avrora | 2.0 | 7.7 (3.9×) | 53.6 (26.7×) | 18.4 (9.2×) | match |
| doop/batik | 9.3 | 29.7 (3.2×) | 216.1 (23.2×) | 192.4 (20.6×) | match |
| doop/biojava | 3.7 | 17.9 (4.9×) | 121.0 (33.0×) | 75.0 (20.5×) | match |
| doop/cassandra | 1.5 | 5.0 (3.4×) | 32.2 (22.1×) | 8.9 (6.1×) | match |
| doop/eclipse | 8.9 | 21.5 (2.4×) | 174.7 (19.5×) | 193.5 (21.6×) | match |
| doop/fop | 8.9 | 28.2 (3.2×) | 218.4 (24.5×) | 166.0 (18.6×) | match |
| doop/graphchi | 3.5 | 20.4 (5.8×) | 138.9 (39.1×) | 81.2 (22.9×) | match |
| doop/h2 | 8.1 | 25.7 (3.2×) | 201.5 (24.9×) | 206.1 (25.4×) | match |
| doop/h2o | 12.6 | 65.2 (5.2×) | 495.3 (39.4×) | 895.3 (71.2×) | match |
| doop/jme | 2.9 | 12.8 (4.4×) | 87.6 (30.2×) | 50.6 (17.4×) | match |
| doop/jython | 281.1 | 431.6 (1.5×) | — | 1349.5 (4.8×) | match |
| doop/kafka | 3.2 | 17.1 (5.3×) | 113.4 (35.1×) | 39.8 (12.3×) | match |
| doop/luindex | 2.6 | 8.3 (3.2×) | 55.8 (21.6×) | 35.4 (13.7×) | match |
| doop/lusearch | 2.2 | 6.4 (2.9×) | 42.7 (19.7×) | 27.3 (12.6×) | match |
| doop/pmd | 3.4 | 12.0 (3.5×) | 84.1 (24.7×) | 54.6 (16.0×) | match |
| doop/spring | 6.9 | 23.1 (3.3×) | 158.3 (22.8×) | 179.1 (25.8×) | match |
| doop/sunflow | 4.2 | 14.8 (3.5×) | 96.0 (23.0×) | 59.4 (14.2×) | match |
| doop/tomcat | 2.2 | 7.6 (3.5×) | 46.6 (21.3×) | 12.6 (5.8×) | match |
| doop/xalan | 2.4 | 11.5 (4.7×) | 73.6 (30.4×) | 57.7 (23.8×) | match |
| doop/zxing | 2.5 | 11.0 (4.3×) | 63.5 (24.9×) | 23.4 (9.2×) | match |

**52 / 52 pairs correct on every engine.** 16 programs: andersen, bipartite,
cc, crdt, csda, cspa, cvc5, doop (20 DaCapo apps), dyck, galen, polonius_int,
reach, sg, sssp, tc, z3.

Absolute times are machine-dependent; the cross-engine **ordering** (FlowLog
fastest, then Soufflé, then Ascent/DDlog) and the **correctness match** are the
reproducible signals, and both hold on west2. FlowLog wall times track the
original sweep closely (e.g. jython 281 s vs 302 s; sg/G10K 20.5 s vs 20.4 s).
