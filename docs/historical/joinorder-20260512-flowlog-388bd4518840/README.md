# Join-order variant sweep — 2026-05-12

## Run conditions
- Flowlog SHA: `388bd4518840`
- Date: 2026-05-12 (host time)
- Host: `node0.zhhong-304787.advosuwmadison-pg0.clemson.cloudlab.us` (128 cores, 250 GB RAM)
- `vm.max_map_count` at sweep end: 1048576
- WORKERS: 64
- NUM_RUNS per variant: 3
- Per-attempt timeout: 600s
- Config: `joinorder.txt`

## Headline findings

- **Heavy doop-family programs have catastrophic plan tails.** batik (59.5× worst slowdown, 25% TIMEOUTs), biojava (127× worst, 17% TIMEOUTs), cvc5 (67× worst, 7% TIMEOUTs), galen (27× worst). Trap plans push RSS to 100–250 GB (host ceiling).
- **Non-default plans beat default by ≥5% on three programs.** biojava 1.23× (biggest), batik 1.15×, cvc5 1.07×. Default ranks: biojava 52nd pct (half the plan space beats default), batik/cvc5 ~20th pct.
- **Default plan is at the optimum (0th pct)** on andersen_medium, cspa-httpd, cspa-linux, cspa-postgresql, galen — default heuristic already wins.
- **Distributions are bimodal: a tight basin around default + a sparse catastrophic tail.** biojava is the cleanest example: 54% of variants land in 2.5–3.5 s, only 4% land in 3.5–30 s, then 17% timeout. Ablations (single-rule swaps) almost never escape the basin (1% TIMEOUT for biojava ablations vs 56% for biojava random samples).
- **Plan-insensitive programs confirmed** (spread ≤ 1.13×): andersen, cspa, dyck, sg — the `joinorder.txt` config correctly relegates them to the commented-out section.

## Coverage caveats

- **Mixed SHAs.** galen/cvc5/z3 and batik rows 1–75 were measured under `aa01e8e6a76b`; batik 76–326, biojava, and eclipse were measured under `388bd4518840` after a resume. Run-to-run variance is typically ±10%, so cross-pair comparisons remain meaningful, but be cautious comparing batik's first quartile to its last three quartiles.
- **eclipse partial: 121/326 variants (ablation phase only).** No random `sample_*` data — the catastrophic-tail story for eclipse is not yet measured.
- **xalan, zxing: not measured.** Sweep was stopped mid-eclipse before reaching them.

## What's in this snapshot

- `pairs/<stem>_<dataset>.csv` — 15 CSVs, ~429 KB total.
  One row per variant with columns:
  `Variant, Kind, Signature, Total_s, PeakRss_MB, RunsSucceeded, vs_Default, SemanticPreserve`.
  `Signature` is the per-rule permutation (e.g. `r0=0,1,2;r1=0,2,1`) — see
  the explanation in `docs/joinorder-mmap-limit.md` for the variant naming
  scheme.
- `SUMMARY.md` — overview table + per-pair detail, regenerated from
  `pairs/` by `scripts/joinorder_summary.py`. Re-run that script with the
  `pairs/` dir if you want to refresh it later.

## Reproducing

```bash
# At the SHA captured above:
FLOWLOG_REF=388bd4518840 make cross-joinorder CONFIG=config/joinorder.txt
```

Note: run-to-run timing variance is typically ±10% on this machine.

## Caveats

- `SemanticPreserve=TIMEOUT` rows hit the 600s per-attempt cap and
  have no time/RSS data (the runner short-circuits after the first
  timeout since variants are deterministic).
- `SemanticPreserve=FAIL` rows died at runtime — usually OOM-abort. Some
  early FAILs in this snapshot may predate the `vm.max_map_count` bump
  to 1 M; see [`../joinorder-mmap-limit.md`](../joinorder-mmap-limit.md).
- `SemanticPreserve=match` is the gate verifying that the variant
  produced byte-identical per-relation output to `default.dl`. Zero
  MISMATCH rows is what we expect — variants should differ only in cost.
