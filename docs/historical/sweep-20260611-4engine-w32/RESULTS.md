## Wall time (seconds, median of runs; slowdown vs FlowLog; load+exec split)

| Program/Dataset | FlowLog | FL load+exec | Soufflé | Sf load+exec | DDlog | DD load+exec | Ascent | As load+exec |
|---|---|---|---|---|---|---|---|---|
| andersen/large | 1.3 | 0.0+1.3 | 85.2 (64.7×) | 55.7+31.3 | 246.6 (187.4×) | 240.8+4.0 | 8.1 (6.1×) | 2.5+5.6 |
| andersen/medium | 0.8 | 0.0+0.7 | 37.7 (49.1×) | 24.6+13.1 | 121.4 (158.0×) | 118.5+2.0 | 4.0 (5.2×) | 1.2+2.8 |
| bipartite/mag | 37.7 | 0.0+37.7 | 322.9 (8.6×) | 303.8+17.5 | — | — | 186.5 (4.9×) | 55.3+131.2 |
| bipartite/mind | 0.7 | 0.0+0.7 | 15.0 (22.4×) | 13.9+1.3 | 67.8 (100.9×) | 65.8+1.3 | 1.7 (2.5×) | 0.7+1.0 |
| bipartite/netflix | 2.8 | 0.0+2.8 | 102.5 (36.8×) | 97.2+5.6 | 371.6 (133.3×) | 365.3+3.6 | 9.3 (3.3×) | 3.5+5.8 |
| bipartite/roadNet-CA | 0.7 | 0.0+0.7 | 8.0 (11.9×) | 1.5+6.4 | 23.4 (35.0×) | 18.6+4.2 | 1.8 (2.6×) | 0.2+1.6 |
| cc/arabic | 74.5 | 1.4+73.1 | — | — | — | — | 140.9 (1.9×) | 22.4+118.5 |
| cc/livejournal | 8.4 | 0.3+8.2 | — | — | — | — | 10.8 (1.3×) | 2.8+8.0 |
| cc/orkut | 12.5 | 0.4+12.1 | — | — | — | — | 15.9 (1.3×) | 4.2+11.6 |
| crdt/crdt | 3.4 | 0.0+3.4 | 3.9 (1.1×) | 0.1+3.3 | 16.5 (4.9×) | 1.0+14.8 | 10.3 (3.0×) | 0.0+10.2 |
| csda/csda-httpd | 0.8 | 0.0+0.8 | 9.6 (11.3×) | 3.3+6.0 | 43.0 (50.8×) | 35.5+6.5 | 2.3 (2.7×) | 0.4+1.9 |
| csda/csda-linux | 4.7 | 0.1+4.6 | 54.1 (11.4×) | 14.4+34.5 | 204.7 (43.2×) | 154.7+45.1 | 19.6 (4.1×) | 1.6+18.0 |
| csda/csda-postgresql | 2.3 | 0.1+2.2 | 24.4 (10.4×) | 11.7+11.2 | 143.7 (61.5×) | 124.7+16.7 | 9.2 (3.9×) | 1.3+7.9 |
| cspa/cspa-httpd | 12.6 | 0.0+12.6 | 57.0 (4.5×) | 0.4+54.1 | 226.3 (17.9×) | 5.2+212.3 | 78.3 (6.2×) | 0.1+78.2 |
| cspa/cspa-linux | 3.5 | 0.0+3.4 | 15.7 (4.5×) | 2.6+13.2 | 69.9 (20.2×) | 32.7+34.3 | 14.7 (4.3×) | 0.4+14.4 |
| cspa/cspa-postgresql | 13.2 | 0.0+13.2 | 62.9 (4.8×) | 1.3+59.4 | 232.1 (17.5×) | 15.4+207.7 | 78.1 (5.9×) | 0.2+77.9 |
| cvc5/cvc5 | 9.0 | 0.0+9.0 | 16.7 (1.9×) | 0.5+15.5 | 137.0 (15.3×) | 6.2+121.2 | 8.6 (1.0×) | 0.1+8.5 |
| doop/avrora | 2.2 | 0.0+2.2 | 8.7 (4.0×) | 3.8+3.8 | 48.7 (22.2×) | 26.2+14.9 | 18.2 (8.3×) | 1.3+16.9 |
| doop/batik | 9.9 | 0.0+9.9 | 38.9 (3.9×) | 5.5+31.5 | 242.5 (24.6×) | 34.5+176.1 | 178.1 (18.0×) | 1.7+176.4 |
| doop/biojava | 4.7 | 0.0+4.7 | 20.3 (4.3×) | 10.2+8.1 | 113.7 (24.2×) | 65.3+34.7 | 68.5 (14.6×) | 4.0+64.4 |
| doop/cassandra | 1.6 | 0.0+1.6 | 5.9 (3.8×) | 2.4+2.8 | 27.4 (17.5×) | 13.0+9.5 | 9.8 (6.3×) | 0.7+9.1 |
| doop/eclipse | 9.6 | 0.0+9.6 | 25.5 (2.6×) | 2.4+22.4 | 209.2 (21.7×) | 16.3+168.8 | 181.7 (18.8×) | 0.7+181.0 |
| doop/fop | 9.4 | 0.0+9.4 | 37.8 (4.0×) | 5.5+29.6 | 253.1 (26.9×) | 36.1+184.8 | 156.6 (16.7×) | 1.7+154.9 |
| doop/graphchi | 4.8 | 0.0+4.8 | 19.6 (4.1×) | 11.1+6.5 | 125.7 (26.3×) | 83.3+28.8 | 66.6 (14.0×) | 3.8+62.8 |
| doop/h2 | 8.7 | 0.0+8.7 | 37.1 (4.3×) | 4.5+30.7 | 231.1 (26.5×) | 30.6+172.4 | 194.6 (22.3×) | 1.4+193.3 |
| doop/h2o | 19.5 | 0.1+19.5 | 69.1 (3.5×) | 33.3+32.7 | 482.7 (24.7×) | 255.6+176.7 | 805.6 (41.2×) | 14.9+790.8 |
| doop/jme | 3.2 | 0.0+3.2 | 13.6 (4.2×) | 6.4+5.7 | 80.4 (24.8×) | 41.3+27.9 | 45.1 (13.9×) | 2.0+43.1 |
| doop/jython | 301.7 | 0.0+301.7 | 461.9 (1.5×) | 6.3+436.5 | — | — | 1,340.9 (4.4×) | 2.1+1,338.7 |
| doop/kafka | 4.4 | 0.0+4.3 | 18.0 (4.1×) | 10.4+6.0 | 96.0 (22.0×) | 60.9+22.0 | 37.4 (8.6×) | 3.2+34.2 |
| doop/luindex | 2.7 | 0.0+2.7 | 10.4 (3.8×) | 2.5+7.0 | 57.6 (21.0×) | 15.2+32.6 | 34.5 (12.5×) | 0.8+33.7 |
| doop/lusearch | 2.4 | 0.0+2.4 | 7.2 (3.0×) | 2.6+3.9 | 39.0 (16.4×) | 15.3+17.3 | 25.2 (10.6×) | 0.8+24.4 |
| doop/pmd | 3.7 | 0.0+3.7 | 14.2 (3.8×) | 4.7+8.2 | 84.7 (22.7×) | 31.0+41.4 | 50.0 (13.4×) | 1.4+48.6 |
| doop/spring | 7.3 | 0.0+7.3 | 30.2 (4.2×) | 4.6+23.9 | 177.0 (24.3×) | 29.7+124.5 | 167.2 (23.0×) | 1.3+165.9 |
| doop/sunflow | 4.6 | 0.0+4.6 | 18.8 (4.1×) | 3.5+13.9 | 101.6 (22.0×) | 22.3+64.1 | 56.0 (12.1×) | 1.1+54.9 |
| doop/tomcat | 2.4 | 0.0+2.4 | 9.4 (3.8×) | 2.3+6.4 | 46.4 (18.9×) | 13.1+25.0 | 12.9 (5.3×) | 0.6+12.3 |
| doop/xalan | 3.2 | 0.0+3.2 | 12.4 (3.9×) | 5.7+5.5 | 62.3 (19.7×) | 34.8+18.7 | 58.8 (18.6×) | 1.7+57.1 |
| doop/zxing | 3.1 | 0.0+3.1 | 12.4 (4.0×) | 3.6+7.9 | 58.4 (18.9×) | 24.0+25.4 | 23.8 (7.7×) | 1.2+22.6 |
| dyck/kernel | 0.7 | 0.0+0.7 | 8.8 (12.3×) | 5.7+2.7 | 47.3 (66.5×) | 39.4+6.0 | 7.8 (11.0×) | 0.5+7.4 |
| dyck/postgre | 0.6 | 0.0+0.5 | 5.4 (9.7×) | 3.1+2.1 | 23.7 (42.8×) | 19.1+3.4 | 3.9 (7.1×) | 0.3+3.7 |
| galen/galen | 5.6 | 0.0+5.6 | 35.0 (6.2×) | 0.4+31.6 | 68.4 (12.2×) | 3.6+57.2 | 8.0 (1.4×) | 0.0+8.0 |
| polonius_int/clap-rs | 50.4 | 0.0+50.4 | 329.4 (6.5×) | 0.4+327.0 | 478.7 (9.5×) | 4.3+433.0 | 145.1 (2.9×) | 0.1+145.0 |
| polonius_int/materialize | 15.8 | 0.0+15.8 | 81.4 (5.1×) | 6.4+73.2 | 237.8 (15.0×) | 81.3+134.7 | 57.9 (3.7×) | 0.9+57.0 |
| polonius_int/scallop | 7.1 | 0.0+7.1 | 37.5 (5.3×) | 11.0+23.8 | 252.2 (35.4×) | 134.1+96.0 | 37.5 (5.3×) | 1.1+36.4 |
| polonius_int/wgpu | 48.5 | 0.0+48.5 | 341.4 (7.0×) | 0.4+339.2 | 496.1 (10.2×) | 4.5+452.0 | 145.2 (3.0×) | 0.1+145.1 |
| reach/arabic | 11.8 | 1.9+9.9 | 174.3 (14.8×) | 167.9+4.3 | — | — | 58.6 (5.0×) | 23.1+35.5 |
| reach/livejournal | 1.6 | 0.1+1.5 | 18.0 (11.0×) | 17.2+0.9 | 259.4 (157.8×) | 252.9+4.8 | 5.9 (3.6×) | 2.6+3.3 |
| reach/orkut | 2.3 | 0.2+2.0 | 32.3 (14.2×) | 30.1+1.5 | 425.9 (187.6×) | 420.1+4.0 | 8.6 (3.8×) | 4.1+4.5 |
| sg/G10K-0.001 | 20.4 | 0.0+20.4 | 68.5 (3.4×) | 0.0+66.5 | 134.3 (6.6×) | 0.3+124.0 | 64.9 (3.2×) | 0.0+64.9 |
| sg/G5K-0.001 | 2.9 | 0.0+2.9 | 8.9 (3.1×) | 0.0+8.3 | 29.0 (10.0×) | 0.1+25.9 | 6.7 (2.3×) | 0.0+6.7 |
| sssp/livejournal-sssp | 2.0 | 0.0+2.0 | — | — | — | — | 8.0 (4.0×) | 3.3+4.7 |
| sssp/orkut-sssp | 2.9 | 0.0+2.9 | — | — | — | — | 10.9 (3.7×) | 4.9+5.9 |
| tc/G10K-0.001 | 8.9 | 0.0+8.9 | 24.1 (2.7×) | 0.0+24.4 | 116.3 (13.0×) | 0.3+106.4 | 40.3 (4.5×) | 0.0+40.3 |
| tc/G5K-0.001 | 1.6 | 0.0+1.6 | 7.0 (4.5×) | 0.0+6.6 | 24.3 (15.5×) | 0.1+21.6 | 4.4 (2.8×) | 0.0+4.4 |
| z3/z3 | 14.9 | 0.0+14.9 | 104.8 (7.0×) | 45.1+54.8 | 735.2 (49.3×) | 559.3+135.0 | 40.3 (2.7×) | 4.6+35.7 |

## Peak RSS (GiB)

| Program/Dataset | FlowLog | Soufflé | DDlog | Ascent |
|---|---|---|---|---|
| andersen/large | 2.0 | 2.1 | 12.2 | 6.9 |
| andersen/medium | 1.1 | 1.0 | 6.2 | 3.5 |
| bipartite/mag | 34.6 | 20.6 | — | 53.7 |
| bipartite/mind | 0.9 | 0.5 | 4.7 | 0.9 |
| bipartite/netflix | 4.5 | 2.8 | 20.6 | 3.7 |
| bipartite/roadNet-CA | 0.4 | 0.2 | 3.1 | 0.7 |
| cc/arabic | 26.2 | — | — | 34.0 |
| cc/livejournal | 6.3 | — | — | 4.6 |
| cc/orkut | 7.3 | — | — | 4.7 |
| crdt/crdt | 0.2 | 0.1 | 1.1 | 0.2 |
| csda/csda-httpd | 0.7 | 0.6 | 5.0 | 1.4 |
| csda/csda-linux | 2.7 | 2.9 | 24.8 | 7.3 |
| csda/csda-postgresql | 1.4 | 1.6 | 13.0 | 5.8 |
| cspa/cspa-httpd | 11.3 | 9.4 | 65.1 | 11.7 |
| cspa/cspa-linux | 3.3 | 1.8 | 15.2 | 4.6 |
| cspa/cspa-postgresql | 11.6 | 9.9 | 64.7 | 12.2 |
| cvc5/cvc5 | 3.5 | 1.5 | 22.5 | 2.6 |
| doop/avrora | 1.3 | 0.7 | 7.3 | 1.4 |
| doop/batik | 4.5 | 2.5 | 35.2 | 4.0 |
| doop/biojava | 2.4 | 1.6 | 13.2 | 3.3 |
| doop/cassandra | 1.0 | 0.4 | 5.8 | 0.9 |
| doop/eclipse | 4.1 | 1.8 | 34.2 | 3.1 |
| doop/fop | 5.0 | 2.6 | 37.0 | 4.1 |
| doop/graphchi | 2.4 | 1.8 | 12.8 | 3.7 |
| doop/h2 | 4.8 | 2.3 | 37.8 | 3.8 |
| doop/h2o | 7.5 | 5.4 | 45.4 | 11.2 |
| doop/jme | 1.8 | 1.1 | 10.9 | 2.2 |
| doop/jython | 51.6 | 18.5 | — | 21.5 |
| doop/kafka | 2.2 | 1.5 | 11.3 | 3.2 |
| doop/luindex | 1.6 | 0.7 | 10.0 | 1.2 |
| doop/lusearch | 1.2 | 0.5 | 7.1 | 1.0 |
| doop/pmd | 2.1 | 1.0 | 13.4 | 2.1 |
| doop/spring | 3.9 | 1.8 | 27.5 | 2.9 |
| doop/sunflow | 2.6 | 1.3 | 16.1 | 2.1 |
| doop/tomcat | 1.4 | 0.6 | 9.0 | 1.1 |
| doop/xalan | 1.6 | 1.0 | 9.2 | 1.9 |
| doop/zxing | 1.6 | 0.8 | 9.5 | 1.6 |
| dyck/kernel | 1.0 | 0.6 | 5.9 | 3.6 |
| dyck/postgre | 0.8 | 0.3 | 3.7 | 1.7 |
| galen/galen | 4.5 | 3.2 | 20.2 | 2.3 |
| polonius_int/clap-rs | 14.4 | 12.5 | 158.2 | 24.1 |
| polonius_int/materialize | 4.5 | 4.6 | 58.9 | 10.7 |
| polonius_int/scallop | 5.6 | 5.2 | 51.6 | 11.5 |
| polonius_int/wgpu | 14.5 | 13.9 | 158.0 | 24.1 |
| reach/arabic | 16.9 | 12.2 | — | 26.2 |
| reach/livejournal | 2.0 | 1.4 | 12.6 | 3.5 |
| reach/orkut | 3.3 | 2.4 | 14.4 | 3.6 |
| sg/G10K-0.001 | 8.1 | 5.1 | 63.6 | 3.9 |
| sg/G5K-0.001 | 2.7 | 1.2 | 18.0 | 0.9 |
| sssp/livejournal-sssp | 2.9 | — | — | 5.1 |
| sssp/orkut-sssp | 4.8 | — | — | 5.3 |
| tc/G10K-0.001 | 4.8 | 4.8 | 56.7 | 4.1 |
| tc/G5K-0.001 | 1.3 | 1.1 | 15.1 | 1.0 |
| z3/z3 | 10.3 | 6.0 | 69.8 | 23.8 |

## Crosscheck (relation sizes vs FlowLog) + runs succeeded

| Program/Dataset | Soufflé | DDlog | Ascent | runs FL/Sf/DD/As |
|---|---|---|---|---|
| andersen/large | ok | ok | ok | 3/3/3/3 |
| andersen/medium | ok | ok | ok | 3/3/3/3 |
| bipartite/mag | ok | — | ok | 3/3/—/3 |
| bipartite/mind | ok | ok | ok | 3/3/3/3 |
| bipartite/netflix | ok | ok | ok | 3/3/3/3 |
| bipartite/roadNet-CA | ok | ok | ok | 3/3/3/3 |
| cc/arabic | — | — | ok | 3/—/—/3 |
| cc/livejournal | — | — | ok | 3/—/—/3 |
| cc/orkut | — | — | ok | 3/—/—/3 |
| crdt/crdt | ok | ok | ok | 3/3/3/3 |
| csda/csda-httpd | ok | ok | ok | 3/3/3/3 |
| csda/csda-linux | ok | ok | ok | 3/3/3/3 |
| csda/csda-postgresql | ok | ok | ok | 3/3/3/3 |
| cspa/cspa-httpd | ok | ok | ok | 3/3/3/3 |
| cspa/cspa-linux | ok | ok | ok | 3/3/3/3 |
| cspa/cspa-postgresql | ok | ok | ok | 3/3/3/3 |
| cvc5/cvc5 | ok | ok | ok | 3/3/3/3 |
| doop/avrora | ok | ok | ok | 3/3/3/3 |
| doop/batik | ok | ok | ok | 3/3/3/3 |
| doop/biojava | ok | ok | ok | 3/3/3/3 |
| doop/cassandra | ok | ok | ok | 3/3/3/3 |
| doop/eclipse | ok | ok | ok | 3/3/3/3 |
| doop/fop | ok | ok | ok | 3/3/3/3 |
| doop/graphchi | ok | ok | ok | 3/3/3/3 |
| doop/h2 | ok | ok | ok | 3/3/3/3 |
| doop/h2o | ok | ok | ok | 3/3/3/3 |
| doop/jme | ok | ok | ok | 3/3/3/3 |
| doop/jython | ok | — | ok | 3/3/—/3 |
| doop/kafka | ok | ok | ok | 3/3/3/3 |
| doop/luindex | ok | ok | ok | 3/3/3/3 |
| doop/lusearch | ok | ok | ok | 3/3/3/3 |
| doop/pmd | ok | ok | ok | 3/3/3/3 |
| doop/spring | ok | ok | ok | 3/3/3/3 |
| doop/sunflow | ok | ok | ok | 3/3/3/3 |
| doop/tomcat | ok | ok | ok | 3/3/3/3 |
| doop/xalan | ok | ok | ok | 3/3/3/3 |
| doop/zxing | ok | ok | ok | 3/3/3/3 |
| dyck/kernel | ok | ok | ok | 3/3/3/3 |
| dyck/postgre | ok | ok | ok | 3/3/3/3 |
| galen/galen | ok | ok | ok | 3/3/3/3 |
| polonius_int/clap-rs | ok | PARTIAL(20):souffle-only=out_known_placeholder_subset | ok | 3/3/3/3 |
| polonius_int/materialize | ok | PARTIAL(20):souffle-only=out_known_placeholder_subset | ok | 3/3/3/3 |
| polonius_int/scallop | ok | PARTIAL(20):souffle-only=out_known_placeholder_subset | ok | 3/3/3/3 |
| polonius_int/wgpu | ok | PARTIAL(20):souffle-only=out_known_placeholder_subset | ok | 3/3/3/3 |
| reach/arabic | ok | — | ok | 3/3/—/3 |
| reach/livejournal | ok | ok | ok | 3/3/3/3 |
| reach/orkut | ok | ok | ok | 3/3/3/3 |
| sg/G10K-0.001 | ok | ok | ok | 3/3/3/3 |
| sg/G5K-0.001 | ok | ok | ok | 3/3/3/3 |
| sssp/livejournal-sssp | — | — | ok | 3/—/—/3 |
| sssp/orkut-sssp | — | — | ok | 3/—/—/3 |
| tc/G10K-0.001 | ok | ok | ok | 3/3/3/3 |
| tc/G5K-0.001 | ok | ok | ok | 3/3/3/3 |
| z3/z3 | ok | ok | ok | 3/3/3/3 |
## Method

- Machine: 128-core, 251 GiB RAM, Linux 5.15; WORKERS=32 for every engine; median of NUM_RUNS=3; timeout 1800 s/attempt.
- FlowLog: flowlog-compiler @ 20f2aa0a7d5a, `--mode datalog-batch --str-intern` (default).
- Soufflé: compiled (`-o`, `-j 32`); load/exec split from one extra profiled run (untimed).
- DDlog: v1.2.3, crates built with cargo +1.76; facts fed as a .dat command stream (generation untimed); load/exec from timestamp markers.
- Ascent: 0.8 (`ascent_par!`), one bin crate per program + shared harness (rayon pool from WORKERS, global u32 interner = flowlog --str-intern / ddlog istring analogue); cc/sssp use `Dual<i32>` lattices (recursive min — souffle/ddlog have no translation, hence their N/A there).
- Geomeans vs FlowLog (54 pairs): Ascent 5.50× (3.37× integer programs / 12.65× doop), Soufflé 5.79× (49 pairs), DDlog 27.2× (46 pairs). Ascent peak RSS geomean 1.19× FlowLog.

## Footnotes

- reach/arabic, bipartite/mag, doop/jython: DDlog cells are N/A — 3×1800 s timeouts (arabic, jython) and .dat-generation OOM (mag); rows re-measured with the remaining engines.
- polonius_int DDlog crosscheck PARTIAL: ddlog additionally reported the derived `out_known_placeholder_subset` closure that no other engine prints; all 20 shared relation sizes match exactly. The extra output line is removed from the translation going forward.
- reach/twitter and the borrow pairs are not in this sweep (dataset too large for the box's disk; no flowlog oracle program for borrow in this corpus).
