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

_TODO: fill in 3–5 bullets summarising what this sweep showed. Suggested
fields to cover: programs where a non-default plan beat default by ≥5%,
programs where default was at the optimum, plan-sensitive programs
(spread ≥ 5×), and any failure-mode insights worth flagging._

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
