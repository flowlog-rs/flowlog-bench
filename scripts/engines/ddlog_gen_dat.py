#!/usr/bin/env python3
"""ddlog_gen_dat.py — turn a dataset directory into a DDlog command stream.

A compiled DDlog program has no `.input` CSV directive; it is driven by a
command stream on stdin (`start; insert Rel(...); ... commit; dump
RelationSizes;`). This builds that stream for one oracle program + dataset.

Schema-aware: each `input relation` declaration gives the per-column types
(resolving `typedef` aliases), so `string`/`istring` columns are quoted and
escaped while integer columns are emitted bare. The file->relation mapping is
read from the program's header comment (`// inputs (... -> relation): F -> R`);
relations without a header entry fall back to <Relation>.csv / <Relation>.facts.
`.csv` is comma-delimited, `.facts` is tab-delimited (DOOP).

Usage:  ddlog_gen_dat.py <program.dl> <dataset_dir>   [> out.dat]
"""
import os
import re
import sys


def parse_typedefs(text):
    return {m.group(1): m.group(2).strip()
            for m in re.finditer(r"typedef\s+(\w+)\s*=\s*(.+)", text)}


def resolve_type(t, aliases, depth=0):
    t = t.strip()
    while t in aliases and depth < 16:
        t = aliases[t].strip()
        depth += 1
    return t


def parse_program(dl_path):
    text = open(dl_path, encoding="utf-8").read()
    aliases = parse_typedefs(text)
    inputs = {}
    for m in re.finditer(r"input\s+relation\s+(\w+)\s*\(([^)]*)\)", text):
        cols = []
        for part in m.group(2).split(","):
            part = part.strip()
            if part:
                cols.append(part.split(":", 1)[1].strip() if ":" in part else part)
        inputs[m.group(1)] = cols
    file2rel = {os.path.basename(m.group(1)): m.group(2)
                for m in re.finditer(r"([\w./-]+\.(?:csv|facts))\s*->\s*(\w+)", text)}
    return inputs, file2rel, aliases


def is_string_type(t):
    # string and istring (= Intern<string>) are both fed as quoted literals;
    # the CLI auto-interns plain strings into istring columns.
    return t == "string" or t == "istring" or t.startswith("Intern<")


def quote(v):
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    dl, data_dir = sys.argv[1], sys.argv[2]
    inputs, file2rel, aliases = parse_program(dl)
    rel2file = {r: f for f, r in file2rel.items()}

    out = sys.stdout
    # `timestamp;` prints "Timestamp: <ns since CLI start>" — three markers
    # bracket the insert phase (T0..T1 = stream parse + feed, ~"load") and
    # the commit (T1..T2 = differential synchronizes to fixpoint, ~"exec").
    # ddlog.sh parses these into the load/exec split sidecars. Approximate by
    # construction: differential computes asynchronously during inserts, so
    # some compute overlaps the load window.
    out.write("timestamp;\n")
    out.write("start;\n")
    for rel, types in inputs.items():
        candidates = []
        if rel in rel2file:
            candidates.append(os.path.join(data_dir, rel2file[rel]))
        candidates += [os.path.join(data_dir, rel + ext) for ext in (".csv", ".facts")]
        path = next((c for c in candidates if os.path.exists(c)), None)
        if path is None:
            sys.stderr.write(f"[ddlog_gen_dat] WARN no data file for {rel} (tried {candidates})\n")
            continue
        delim = "\t" if path.endswith(".facts") else ","
        str_cols = [is_string_type(resolve_type(t, aliases)) for t in types]
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\r\n")
                if line == "":
                    continue
                fields = line.split(delim)
                args = [quote(fields[i]) if str_cols[i]
                        else (fields[i] if i < len(fields) else "")
                        for i in range(len(types))]
                out.write(f"insert {rel}({', '.join(args)});\n")
    out.write("timestamp;\n")
    out.write("commit;\n")
    out.write("timestamp;\n")
    out.write("dump RelationSizes;\n")


if __name__ == "__main__":
    main()
