# FlowLog rerun (main @ 6c111b729e4b) vs PR#14 baseline engines

Generated 2026-07-28 05:08 UTC.
FlowLog: fresh run, this host, WORKERS=32, median of 3.
Soufflé 2.5 / DDlog 1.2.3 / Ascent 0.8: docs/historical/sweep-20260611-4engine-w32 (PR#14), WORKERS=32, median of 3.
Times in seconds (engine slowdown vs FlowLog in parens), RSS in GB.

| Pair | FlowLog t | FL RSS | FL prev t | FL prev RSS | Soufflé t | Sf RSS | DDlog t | DD RSS | Ascent t | As RSS |
|---|---|---|---|---|---|---|---|---|---|---|
| doop/avrora | 2.3 | 1.3 | 2.2 | 1.3 | 8.7 (3.8x) | 0.7 | 48.7 (21.1x) | 7.3 | 18.2 (7.9x) | 1.4 |
| doop/batik | 10.0 | 4.5 | 9.9 | 4.5 | 38.9 (3.9x) | 2.5 | 242.5 (24.4x) | 35.2 | 178.1 (17.9x) | 4.0 |
| doop/biojava | 4.9 | 2.3 | 4.7 | 2.4 | 20.3 (4.1x) | 1.6 | 113.7 (23.0x) | 13.2 | 68.5 (13.9x) | 3.3 |
| doop/cassandra | 1.6 | 0.9 | 1.6 | 1.0 | 5.9 (3.7x) | 0.4 | 27.4 (17.2x) | 5.8 | 9.8 (6.2x) | 0.9 |
| doop/eclipse | 8.9 | 4.0 | 9.6 | 4.1 | 25.5 (2.9x) | 1.8 | 209.2 (23.4x) | 34.2 | 181.7 (20.3x) | 3.1 |
| doop/fop | 9.1 | 4.8 | 9.4 | 5.0 | 37.8 (4.2x) | 2.6 | 253.1 (27.8x) | 37.0 | 156.6 (17.2x) | 4.1 |
| doop/graphchi | 5.6 | 2.3 | 4.8 | 2.4 | 19.6 (3.5x) | 1.8 | 125.7 (22.6x) | 12.8 | 66.6 (12.0x) | 3.7 |
| doop/h2 | 8.0 | 4.7 | 8.7 | 4.8 | 37.1 (4.7x) | 2.3 | 231.1 (29.0x) | 37.8 | 194.6 (24.5x) | 3.8 |
| doop/h2o | 18.4 | 7.5 | 19.5 | 7.5 | 69.1 (3.8x) | 5.4 | 482.7 (26.2x) | 45.4 | 805.6 (43.8x) | 11.2 |
| doop/jme | 3.4 | 1.8 | 3.2 | 1.8 | 13.6 (3.9x) | 1.1 | 80.4 (23.3x) | 10.9 | 45.1 (13.1x) | 2.2 |
| doop/jython | 300.2 | 43.4 | 301.7 | 51.6 | 461.9 (1.5x) | 18.5 | — | — | 1340.9 (4.5x) | 21.5 |
| doop/kafka | 4.7 | 2.1 | 4.4 | 2.2 | 18.0 (3.9x) | 1.5 | 96.0 (20.6x) | 11.3 | 37.4 (8.0x) | 3.2 |
| doop/luindex | 2.7 | 1.5 | 2.7 | 1.6 | 10.4 (3.8x) | 0.7 | 57.6 (21.1x) | 10.0 | 34.5 (12.6x) | 1.2 |
| doop/lusearch | 2.3 | 1.1 | 2.4 | 1.2 | 7.2 (3.1x) | 0.5 | 39.0 (16.9x) | 7.1 | 25.2 (10.9x) | 1.0 |
| doop/pmd | 3.6 | 2.0 | 3.7 | 2.1 | 14.2 (4.0x) | 1.0 | 84.7 (23.7x) | 13.4 | 50.0 (14.0x) | 2.1 |
| doop/spring | 7.0 | 3.8 | 7.3 | 3.9 | 30.2 (4.3x) | 1.8 | 177.0 (25.4x) | 27.5 | 167.2 (24.0x) | 2.9 |
| doop/sunflow | 4.2 | 2.5 | 4.6 | 2.6 | 18.8 (4.5x) | 1.3 | 101.6 (24.2x) | 16.1 | 56.0 (13.3x) | 2.1 |
| doop/tomcat | 2.2 | 1.3 | 2.4 | 1.4 | 9.4 (4.3x) | 0.6 | 46.4 (21.2x) | 9.0 | 12.9 (5.9x) | 1.1 |
| doop/xalan | 2.9 | 1.5 | 3.2 | 1.6 | 12.4 (4.2x) | 1.0 | 62.3 (21.2x) | 9.2 | 58.8 (20.0x) | 1.9 |
| doop/zxing | 2.8 | 1.6 | 3.1 | 1.6 | 12.4 (4.5x) | 0.8 | 58.4 (21.2x) | 9.5 | 23.8 (8.6x) | 1.6 |
| polonius_int/clap-rs | 45.3 | 14.5 | 50.4 | 14.4 | 329.4 (7.3x) | 12.5 | 478.7 (10.6x) | 158.2 | 145.1 (3.2x) | 24.1 |
| polonius_int/materialize | 16.7 | 4.4 | 15.8 | 4.5 | 81.4 (4.9x) | 4.6 | 237.8 (14.3x) | 58.9 | 57.9 (3.5x) | 10.7 |
| polonius_int/scallop | 6.4 | 5.4 | 7.1 | 5.6 | 37.5 (5.9x) | 5.2 | 252.2 (39.6x) | 51.6 | 37.5 (5.9x) | 11.5 |
| polonius_int/wgpu | 47.0 | 14.4 | 48.5 | 14.5 | 341.4 (7.3x) | 13.9 | 496.1 (10.6x) | 158.0 | 145.2 (3.1x) | 24.1 |

## FlowLog then vs now (baseline sweep ran older flowlog)

| Pair | baseline FL t | new FL t | new/old |
|---|---|---|---|
| doop/avrora | 2.2 | 2.3 | 1.05x |
| doop/batik | 9.9 | 10.0 | 1.01x |
| doop/biojava | 4.7 | 4.9 | 1.05x |
| doop/cassandra | 1.6 | 1.6 | 1.02x |
| doop/eclipse | 9.6 | 8.9 | 0.93x |
| doop/fop | 9.4 | 9.1 | 0.97x |
| doop/graphchi | 4.8 | 5.6 | 1.16x |
| doop/h2 | 8.7 | 8.0 | 0.91x |
| doop/h2o | 19.5 | 18.4 | 0.94x |
| doop/jme | 3.2 | 3.4 | 1.06x |
| doop/jython | 301.7 | 300.2 | 0.99x |
| doop/kafka | 4.4 | 4.7 | 1.07x |
| doop/luindex | 2.7 | 2.7 | 0.99x |
| doop/lusearch | 2.4 | 2.3 | 0.97x |
| doop/pmd | 3.7 | 3.6 | 0.96x |
| doop/spring | 7.3 | 7.0 | 0.96x |
| doop/sunflow | 4.6 | 4.2 | 0.91x |
| doop/tomcat | 2.4 | 2.2 | 0.89x |
| doop/xalan | 3.2 | 2.9 | 0.93x |
| doop/zxing | 3.1 | 2.8 | 0.89x |
| polonius_int/clap-rs | 50.4 | 45.3 | 0.90x |
| polonius_int/materialize | 15.8 | 16.7 | 1.05x |
| polonius_int/scallop | 7.1 | 6.4 | 0.89x |
| polonius_int/wgpu | 48.5 | 47.0 | 0.97x |
