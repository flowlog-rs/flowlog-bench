#!/usr/bin/env python3
"""Check Cargo's resolved graph, whether the compiler emitted a path or patch."""

import json
from pathlib import Path
import sys


def verify_runtime(metadata, runtime):
    runtime = Path(runtime).resolve()
    resolved = {node["id"] for node in metadata["resolve"]["nodes"]}
    packages = [p for p in metadata["packages"] if p["id"] in resolved]
    matches = [p for p in packages if p["name"] == "flowlog-runtime"]
    if len(matches) != 1 or matches[0]["source"] is not None or \
            Path(matches[0]["manifest_path"]).resolve() != runtime / "Cargo.toml":
        raise ValueError("flowlog-runtime did not resolve to the selected checkout; "
                         "FLOWLOG_RUNTIME_PATH may be ignored or an old patch unused")
    for package in packages:
        if package["id"] == metadata["resolve"]["root"]:
            continue
        if package["name"].startswith("flowlog-") and (
            package["source"] is not None or
            not Path(package["manifest_path"]).resolve().is_relative_to(runtime.parent)
        ):
            raise ValueError(f"{package['name']} resolved outside the selected checkout")


if __name__ == "__main__":
    try:
        verify_runtime(json.loads(Path(sys.argv[1]).read_text()), sys.argv[2])
    except (ValueError, OSError, KeyError) as error:
        print(f"runtime verification failed: {error}", file=sys.stderr)
        sys.exit(1)
