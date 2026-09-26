#!/usr/bin/env python3
"""Check that every variant gives the same batch answer.

Runs each PROGRAM:FACTS_DIR case once per variant, using the program's `_out`
build when there is one (so the answer is written out), then records the row
count and a SHA-256 prefix of the sorted output lines. Exits 1 if the
variants disagree or an answer is empty (an empty answer proves nothing).

Example:
  check_batch.py --variant main=<main bins> --variant pr=<pr bins> \\
      --output outputs.csv cc:<facts>/livejournal ic13:<facts>/ldbc_snb_interactive_sf3
"""

import argparse
import csv
import hashlib
from pathlib import Path
import tempfile

from time_batch import run

FIELDS = ["variant", "program", "dataset", "rows", "sha256_prefix"]


def answer(directory):
    """Row count and hash, equal to `cat <files> | sort | sha256sum` under LC_ALL=C."""
    data = b"".join(p.read_bytes() for p in sorted(directory.rglob("*")) if p.is_file())
    lines = data.split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    body = b"".join(line + b"\n" for line in sorted(lines))
    return len(lines), hashlib.sha256(body).hexdigest()[:12]


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--variant", action="append", required=True, metavar="NAME=BIN_DIR")
    parser.add_argument("--output", type=Path, required=True, help="CSV file, appended to")
    parser.add_argument("--workers", type=int, default=32)
    parser.add_argument("cases", nargs="+", metavar="PROGRAM:FACTS_DIR")
    args = parser.parse_args()
    variants = [(name, Path(path)) for name, _, path in (v.partition("=") for v in args.variant)]
    new = not args.output.exists()
    failed = []
    with args.output.open("a", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        if new:
            writer.writeheader()
        for case in args.cases:
            program, _, facts = case.partition(":")
            facts = Path(facts).resolve()
            if not facts.is_dir():  # FlowLog reads missing inputs as empty
                raise SystemExit(f"no such facts directory: {facts}")
            answers = set()
            for name, bins in variants:
                binary = bins / "batch" / f"{program}_out"
                if not binary.exists():
                    binary = bins / "batch" / program
                with tempfile.TemporaryDirectory() as tmp:
                    scratch = Path(tmp)
                    (scratch / "out").mkdir()
                    run(binary, ["-w", str(args.workers), "-F", str(facts),
                                 "-D", str(scratch / "out")], scratch)
                    rows, digest = answer(scratch / "out")
                answers.add((rows, digest))
                row = {"variant": name, "program": binary.name, "dataset": facts.name,
                       "rows": rows, "sha256_prefix": digest}
                writer.writerow(row)
                handle.flush()
                print(",".join(str(row[field]) for field in FIELDS), flush=True)
            if len(answers) > 1 or any(rows == 0 for rows, _ in answers):
                failed.append(case)
    if failed:
        raise SystemExit(f"variants disagree or gave no rows: {' '.join(failed)}")
    print("all variants agree")


if __name__ == "__main__":
    main()
