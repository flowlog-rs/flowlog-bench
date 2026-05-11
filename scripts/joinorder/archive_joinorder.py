#!/usr/bin/env python3
"""
Snapshot the current join-order sweep results into docs/historical/.

Reads:
    results/joinorder/*.csv        per-pair timing CSVs
    results/joinorder.run.log      sweep log (for SHA + run conditions)

Writes:
    docs/historical/joinorder-YYYYMMDD-flowlog-<sha12>/
        README.md                  auto-filled run conditions + caveats
        SUMMARY.md                 regenerated joinorder_summary output
        pairs/<stem>_<dataset>.csv copy of each pair CSV

Does NOT delete results/joinorder/; this is a snapshot, not a move.
Does NOT git-add or commit; the script prints the suggested command.

Usage:
    python3 scripts/archive_joinorder.py           # interactive, fails if archive exists
    python3 scripts/archive_joinorder.py --force   # overwrite existing archive
"""
from __future__ import annotations

import argparse
import datetime
import re
import shutil
import socket
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
RESULTS_DIR = ROOT / "results/joinorder"
RUN_LOG = ROOT / "results/joinorder.run.log"
HIST_DIR = ROOT / "docs/historical"
SUMMARY_SCRIPT = ROOT / "scripts/joinorder/joinorder_summary.py"

ANSI = re.compile(r"\x1b\[[0-9;]*m")


def read_log_head(n_lines: int = 50) -> list[str]:
    if not RUN_LOG.exists():
        return []
    raw = RUN_LOG.read_text(errors="replace").splitlines()[:n_lines]
    return [ANSI.sub("", ln) for ln in raw]


def parse_run_conditions(log_head: list[str]) -> dict[str, str]:
    """Pull human-readable values out of the cross_joinorder.sh banner."""
    info: dict[str, str] = {}
    patterns = {
        "compiler":  re.compile(r"Compiler\s*:\s*(.+)"),
        "sha":       re.compile(r"Flowlog SHA:\s*(\w+)"),
        "config":    re.compile(r"Config\s*:\s*(.+)"),
        "workers":   re.compile(r"Workers\s*:\s*(\d+)"),
        "num_runs":  re.compile(r"Runs/var\s*:\s*(\d+)"),
        "timeout":   re.compile(r"Run timeout:\s*(\d+s)"),
    }
    for ln in log_head:
        for key, pat in patterns.items():
            m = pat.search(ln)
            if m and key not in info:
                info[key] = m.group(1).strip()
    return info


def read_meminfo() -> dict[str, str]:
    out = {}
    try:
        for ln in Path("/proc/meminfo").read_text().splitlines():
            if ":" not in ln:
                continue
            k, v = ln.split(":", 1)
            out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def gather_machine_info() -> dict[str, str]:
    info = {"hostname": socket.gethostname()}
    try:
        info["cpu_count"] = subprocess.check_output(["nproc"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        info["cpu_count"] = "?"
    mem = read_meminfo()
    if "MemTotal" in mem:
        kb = int(mem["MemTotal"].split()[0])
        info["ram_gb"] = f"{kb / 1024 / 1024:.0f}"
    try:
        info["vm_max_map_count"] = Path("/proc/sys/vm/max_map_count").read_text().strip()
    except OSError:
        info["vm_max_map_count"] = "?"
    return info


def regenerate_summary(out_path: Path) -> None:
    proc = subprocess.run(
        [sys.executable, str(SUMMARY_SCRIPT), "--no-write"],
        check=True, capture_output=True, text=True,
    )
    out_path.write_text(proc.stdout)


def csv_inventory(pairs_dir: Path) -> tuple[int, int]:
    """(n_files, total_bytes) — used to size the README."""
    files = list(pairs_dir.glob("*.csv"))
    return len(files), sum(p.stat().st_size for p in files)


def render_readme(arch_dir: Path, info: dict[str, str], n_pairs: int, total_bytes: int) -> str:
    sha = info.get("sha", "unknown")
    date = info.get("_date", "")
    mach = info.get("_machine", {})
    config_path = info.get("config", "?")
    config_name = Path(config_path).name if config_path != "?" else "?"
    workers = info.get("workers", "?")
    num_runs = info.get("num_runs", "?")
    timeout = info.get("timeout", "?")
    cpu = mach.get("cpu_count", "?")
    ram = mach.get("ram_gb", "?")
    vma = mach.get("vm_max_map_count", "?")
    host = mach.get("hostname", "?")

    return f"""# Join-order variant sweep — {date}

## Run conditions
- Flowlog SHA: `{sha}`
- Date: {date} (host time)
- Host: `{host}` ({cpu} cores, {ram} GB RAM)
- `vm.max_map_count` at sweep end: {vma}
- WORKERS: {workers}
- NUM_RUNS per variant: {num_runs}
- Per-attempt timeout: {timeout}
- Config: `{config_name}`

## Headline findings

_TODO: fill in 3–5 bullets summarising what this sweep showed. Suggested
fields to cover: programs where a non-default plan beat default by ≥5%,
programs where default was at the optimum, plan-sensitive programs
(spread ≥ 5×), and any failure-mode insights worth flagging._

## What's in this snapshot

- `pairs/<stem>_<dataset>.csv` — {n_pairs} CSVs, ~{total_bytes / 1024:.0f} KB total.
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
FLOWLOG_REF={sha[:12]} make cross-joinorder CONFIG=config/{config_name}
```

Note: run-to-run timing variance is typically ±10% on this machine.

## Caveats

- `SemanticPreserve=TIMEOUT` rows hit the {timeout} per-attempt cap and
  have no time/RSS data (the runner short-circuits after the first
  timeout since variants are deterministic).
- `SemanticPreserve=FAIL` rows died at runtime — usually OOM-abort. Some
  early FAILs in this snapshot may predate the `vm.max_map_count` bump
  to 1 M; see [`../joinorder-mmap-limit.md`](../joinorder-mmap-limit.md).
- `SemanticPreserve=match` is the gate verifying that the variant
  produced byte-identical per-relation output to `default.dl`. Zero
  MISMATCH rows is what we expect — variants should differ only in cost.
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--force", action="store_true",
                    help="overwrite existing archive directory")
    args = ap.parse_args()

    if not RESULTS_DIR.exists():
        print(f"ERROR: {RESULTS_DIR} not found — nothing to archive.", file=sys.stderr)
        return 1
    csvs = sorted(RESULTS_DIR.glob("*.csv"))
    if not csvs:
        print(f"ERROR: no CSVs in {RESULTS_DIR}.", file=sys.stderr)
        return 1

    info = parse_run_conditions(read_log_head())
    info["_machine"] = gather_machine_info()
    info["_date"] = datetime.date.today().isoformat()

    sha = info.get("sha", "unknown")[:12]
    arch_name = f"joinorder-{info['_date'].replace('-', '')}-flowlog-{sha}"
    arch_dir = HIST_DIR / arch_name

    if arch_dir.exists():
        if not args.force:
            print(f"ERROR: {arch_dir} already exists. Use --force to overwrite.",
                  file=sys.stderr)
            return 1
        shutil.rmtree(arch_dir)

    arch_dir.mkdir(parents=True)
    (arch_dir / "pairs").mkdir()

    for c in csvs:
        shutil.copy2(c, arch_dir / "pairs" / c.name)

    regenerate_summary(arch_dir / "SUMMARY.md")

    n_pairs, total_bytes = csv_inventory(arch_dir / "pairs")
    (arch_dir / "README.md").write_text(render_readme(arch_dir, info, n_pairs, total_bytes))

    rel = arch_dir.relative_to(ROOT)
    print(f"Archived {n_pairs} pairs ({total_bytes / 1024:.0f} KB) to {rel}/")
    print(f"  pairs/        {n_pairs} CSVs")
    print(f"  SUMMARY.md    regenerated from pairs/")
    print(f"  README.md     run conditions + 'Headline findings' TODO")
    print()
    print("Suggested next step:")
    print(f"  git add {rel}/")
    print(f"  # then edit {rel}/README.md 'Headline findings' before committing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
