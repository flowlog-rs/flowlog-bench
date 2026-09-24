"""Contracts for unprofiled, parallel compiler comparisons."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CompilerComparisonTests(unittest.TestCase):
    def test_compilation_failure_returns_to_caller(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "programs/tiny").mkdir(parents=True)
            (root / "programs/tiny/default.dl").write_text("// invalid fixture\n")
            (root / "facts/tiny").mkdir(parents=True)
            compiler = root / "compiler"
            compiler.write_text("#!/bin/sh\necho compile-failed >&2\nexit 9\n")
            compiler.chmod(0o755)
            env = dict(
                os.environ, COMPILER_BIN=str(compiler),
                PROG_DIR=str(root / "programs"), FACT_DIR=str(root / "facts"),
                LOG_DIR=str(root / "logs"), WORKERS="32", NUM_RUNS="3",
                FLOWLOG_VERIFY_RUNTIME="0",
            )
            result = subprocess.run(
                ["bash", "-c",
                 'set -euo pipefail; BLUE= RED=; log() { echo "$*" >&2; }; '
                 'source "$1"; rc=0; engine_compiler_run tiny.dl tiny || rc=$?; '
                 'printf "survived:%s\\n" "$rc"',
                 "test", str(ROOT / "scripts/engines/compiler.sh")],
                env=env, text=True, capture_output=True, check=True,
            )
            self.assertEqual(result.stdout, "survived:1\n")
            self.assertIn("Compilation failed", result.stderr)

    def test_flowlog_size_formats(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "run.log"
            log.write_text(
                "[size][Old] t=() size=12\n"
                "[size][New]  t=()  size=34\n"
                "[size][Empty]\tt=()\tsize=0\n"
                "[size][Incremental] t=1 size=56\n"
            )
            result = subprocess.run(
                ["bash", "-c", 'source "$1"; extract_compiler_sizes "$2"',
                 "test", str(ROOT / "scripts/lib/measure.sh"), str(log)],
                text=True, capture_output=True, check=True,
            )
            self.assertEqual(result.stdout, "Old\t12\nNew\t34\nEmpty\t0\n")

    def test_souffle_compile_and_run_use_32_workers_without_profiling(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("programs", "facts/tiny", "logs/sf-bin"):
                (root / name).mkdir(parents=True)
            (root / "programs/tiny.dl").write_text(".decl Out(x:number)\n")
            stale = root / "logs/sf-bin/tiny-w32"
            stale.write_text("#!/bin/sh\nexit 99\n")
            stale.chmod(0o755)
            compiler = root / "souffle"
            compiler.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, sys\n"
                "args=sys.argv[1:]\n"
                "pathlib.Path(os.environ['COMPILE_ARGS']).write_text(json.dumps(args))\n"
                "dest=pathlib.Path(args[args.index('-o')+1])\n"
                "dest.write_text('#!/bin/sh\\n"
                "printf \"%s\\\\n\" \"$@\" > \"$RUN_ARGS\"\\n"
                "printf \"Out\\\\t1\\\\n\"\\n')\n"
                "dest.chmod(0o755)\n"
            )
            compiler.chmod(0o755)
            env = dict(
                os.environ, SOUFFLE_BIN=str(compiler),
                SOUFFLE_PROG_DIR=str(root / "programs"),
                FACT_DIR=str(root / "facts"), LOG_DIR=str(root / "logs"),
                WORKERS="32", NUM_RUNS="1", FLOWLOG_RUN_TIMEOUT="10",
                SOUFFLE_PROFILE_SPLIT="0",
                COMPILE_ARGS=str(root / "compile.json"),
                RUN_ARGS=str(root / "run.args"),
            )
            result = subprocess.run(
                ["bash", "-c",
                 'set -euo pipefail; '
                 'BLUE= YELLOW= GREEN= RED=; log() { :; }; '
                 'source "$1"; engine_souffle_run tiny.dl tiny',
                 "test", str(ROOT / "scripts/engines/souffle.sh")],
                env=env, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            compile_args = json.loads((root / "compile.json").read_text())
            run_args = (root / "run.args").read_text().splitlines()
            self.assertEqual(compile_args[compile_args.index("-j") + 1], "32")
            self.assertEqual(run_args[run_args.index("-j") + 1], "32")
            self.assertNotIn("-p", compile_args)
            self.assertTrue(compile_args[compile_args.index("-o") + 1].endswith("-unprofiled"))
            self.assertEqual((root / "logs/tiny_tiny_souffle.log.sizes").read_text(), "out\t1\n")


if __name__ == "__main__":
    unittest.main()
