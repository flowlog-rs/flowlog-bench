# FlowLog-only rerun — doop + polonius_int, main @ `6c111b729e4b` (2026-07-28)

Re-measures the **FlowLog compiler column only** on the doop + polonius
subset of the 4-engine sweep, at the sweep's run conditions, using the
first crates.io-released FlowLog (`6c111b729e4b`, flowlog-compiler 0.5.0
— includes the dd 0.25.1 / timely 0.31 migration and the opt-level 2 +
panic=abort generated-crate profile, folded in via #269).

Purpose: check that the release line did not regress against the FlowLog
snapshots used in [`../sweep-20260611-4engine-w32/`](../sweep-20260611-4engine-w32/)
(doop block: `a40ecbc60cda`; polonius block: `3b1387e18460`).

## Verdict

Perf-neutral to mildly better: geomean **−2.4 % wall time, −3.8 % peak
RSS** over the 24 pairs (faster on 16/24). Outliers: `doop/jython` peak
RSS 51.6 → 43.4 GB (**−16 %**) at equal time; `doop/graphchi` +16 % time
(4.8 → 5.6 s) — the only regression above noise.

## Run conditions

| | |
|---|---|
| pairs | `doop.dl` × 20 DaCapo chopin apps + `polonius_int` × {clap-rs, wgpu, materialize, scallop} |
| flowlog | `6c111b729e4bf8bffb5037b85b894031786140cc` (main, 2026-07-28) |
| harness | `cross_engine.sh --engines=none`, WORKERS=32, NUM_RUNS=3 (median), timeout 1800 s, `--str-intern` default-on |
| host | CloudLab c6525 (`node0…clemson.cloudlab.us`), 2× AMD EPYC 7543 (128 threads), 251 GB RAM, Ubuntu (Linux 5.15) |

## Files

- `comparison_results.csv` — raw harness output (FlowLog columns only;
  other-engine columns are N/A by construction).
- `RESULTS.md` — merged four-engine table: FlowLog from this run,
  Soufflé 2.5 / DDlog 1.2.3 / Ascent 0.8 columns carried over from the
  June sweep CSV, plus a FlowLog then-vs-now section. Cross-engine
  ratios mix two hosts at equal WORKERS — treat as indicative.
- `run_info.txt` — reproducibility manifest of this run.
- `baseline-sweep-20260611.csv` — the June sweep CSV the engine columns
  came from (copy of `../sweep-20260611-4engine-w32/comparison_results.csv`).
- `gen_report.py` — the merge script that produced `RESULTS.md`
  (archived here for provenance; point its two input paths at the CSVs
  above to regenerate).

Extra data point measured en route (not in the CSVs): `polonius_str` on
clap-rs = 48.0 s / 14.3 GB and wgpu = 51.0 s / 14.3 GB (2/3 runs) —
string-typed polonius is ~free vs `polonius_int` under `--str-intern`.
