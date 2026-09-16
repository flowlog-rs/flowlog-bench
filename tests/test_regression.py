"""Offline CI contract tests: real Git refs, Cargo builds and generated programs.

Run: python3 -m unittest discover -s tests -v
No datasets, registry downloads, or full FlowLog builds are needed.
"""

import importlib.util
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("verify_runtime", ROOT / "scripts/lib/verify_runtime.py")
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)

COMPILER = r'''
use std::{env, fs, path::PathBuf, process::Command};
const PATCH: bool = true;
fn main() {
    let args: Vec<String> = env::args().collect();
    let dest = PathBuf::from(&args[args.iter().position(|v| v == "-o").unwrap() + 1]);
    let dir = PathBuf::from(&args[args.iter().position(|v| v == "-B").unwrap() + 1]);
    fs::create_dir_all(dir.join("src")).unwrap();
    let runtime = env::var("FLOWLOG_RUNTIME_PATH").unwrap();
    let dependency = if PATCH {
        format!("[dependencies]\nflowlog-runtime = \"0.1\"\n[patch.crates-io]\nflowlog-runtime = {{ path = {runtime:?} }}\n")
    } else {
        format!("[dependencies]\nflowlog-runtime = {{ path = {runtime:?} }}\n")
    };
    fs::write(dir.join("Cargo.toml"), format!("[package]\nname = \"fixture\"\nversion = \"0.1.0\"\nedition = \"2021\"\n[workspace]\n{dependency}")).unwrap();
    fs::write(dir.join("src/main.rs"), "fn main() { flowlog_runtime::run(); }\n").unwrap();
    let status = Command::new("cargo").args(["build", "--release", "--message-format=json-render-diagnostics"]).current_dir(&dir).status().unwrap();
    if !status.success() { std::process::exit(1); }
    fs::copy(dir.join("target/release/fixture"), &dest).unwrap();
}
'''


class RegressionIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="regression-contract-")
        cls.root = Path(cls.tmp.name)
        cls.repo = cls.root / "upstream"
        cls.repo.mkdir()
        cls.env = dict(os.environ, CARGO_NET_OFFLINE="true", BENCH_NO_PIN="1",
                       PERF_COMPARE_WORKERS="1", PERF_COMPARE_NUM_RUNS="2",
                       PERF_COMPARE_RSS_PCT="100000", KEEP_DATASETS="1")
        for key in ("FLOWLOG_BASE", "FLOWLOG_HEAD", "FLOWLOG_REF", "CARGO_TARGET_DIR",
                    "CARGO_BUILD_TARGET_DIR", "FLOWLOG_RUNTIME_PATH", "RUSTFLAGS",
                    "CARGO_ENCODED_RUSTFLAGS", "EXTRA_FL_FLAGS"):
            cls.env.pop(key, None)
        cls.git("init", "-q", "-b", "main")
        cls.git("config", "user.email", "test@example.invalid")
        cls.git("config", "user.name", "Regression test")
        (cls.repo / "Cargo.toml").write_text('[workspace]\nmembers = ["flowlog-compiler", "flowlog-runtime"]\nresolver = "2"\n')
        for name in ("flowlog-compiler", "flowlog-runtime"):
            (cls.repo / name / "src").mkdir(parents=True)
            (cls.repo / name / "Cargo.toml").write_text(f'[package]\nname = "{name}"\nversion = "0.1.0"\nedition = "2021"\n')
        (cls.repo / "flowlog-compiler/src/main.rs").write_text(COMPILER)
        (cls.repo / "flowlog-runtime/src/lib.rs").write_text('pub fn run() { println!("Dataflow executed in 1s"); println!("[size][out] t=() size=1"); }\n')
        cls.command(["cargo", "generate-lockfile", "--offline"], cls.repo)
        cls.commit("old patch compiler")
        cls.old = cls.git("rev-parse", "HEAD").stdout.strip()
        cls.git("tag", "-a", "old", "-m", "annotated old version")
        (cls.repo / "flowlog-compiler/src/main.rs").write_text(COMPILER.replace("PATCH: bool = true", "PATCH: bool = false"))
        # A different runtime version proves the new path dependency is not
        # accidentally constrained by the old published version requirement.
        runtime_manifest = cls.repo / "flowlog-runtime/Cargo.toml"
        runtime_manifest.write_text(runtime_manifest.read_text().replace('"0.1.0"', '"0.2.0"'))
        cls.command(["cargo", "generate-lockfile", "--offline"], cls.repo)
        cls.commit("new path compiler")
        cls.new = cls.git("rev-parse", "HEAD").stdout.strip()
        cls.git("branch", "new", cls.new)
        cls.git("branch", "moving", cls.old)
        cls.git("switch", "-qc", "stale-lock")
        runtime_manifest.write_text(runtime_manifest.read_text().replace('"0.2.0"', '"0.3.0"'))
        cls.commit("runtime version changed without updating lock")
        cls.git("switch", "-q", "main")
        cls.git("switch", "-qc", "wrong-runtime")
        compiler = cls.repo / "flowlog-compiler/src/main.rs"
        compiler.write_text(compiler.read_text().replace('env::var("FLOWLOG_RUNTIME_PATH")', 'env::var("WRONG_RUNTIME")'))
        cls.commit("compiler ignores requested runtime")
        cls.git("switch", "-q", "main")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    @classmethod
    def command(cls, args, cwd, env=None):
        return subprocess.run(args, cwd=cwd, env=env or cls.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)

    @classmethod
    def git(cls, *args):
        return cls.command(["git", *args], cls.repo)

    @classmethod
    def commit(cls, message):
        cls.git("add", ".")
        cls.git("commit", "-qm", message)

    def setUp(self):
        self.bench = self.root / self.id().rsplit(".", 1)[-1]
        self.bench.mkdir()
        shutil.copytree(ROOT / "scripts", self.bench / "scripts")
        (self.bench / "programs/oracle/flowlog/tiny").mkdir(parents=True)
        (self.bench / "programs/oracle/flowlog/tiny/default.dl").write_text("// fixture\n")
        (self.bench / "facts/tiny").mkdir(parents=True)
        (self.bench / "config.txt").write_text("tiny.dl=tiny\n")
        self.run_env = dict(self.env, FLOWLOG_REPO=str(self.repo),
                            FLOWLOG_CACHE_DIR=str(self.bench / "flowlog"))

    def run_script(self, script, *args, code=0, **env):
        result = subprocess.run(["bash", str(self.bench / "scripts" / script), *args],
                                cwd=self.bench, env=dict(self.run_env, **env), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        details = result.stdout + result.stderr
        if result.returncode != code:
            for log in (self.bench / "results").rglob("*_build.log"):
                details += f"\n{log}:\n{log.read_text()}"
        self.assertEqual(result.returncode, code, details)
        return result

    def test_patch_and_path_end_to_end_and_rerun(self):
        self.run_script("regression.sh", "old", "new", "config.txt")
        result = self.bench / f"results/regression/{self.old[:12]}_vs_{self.new[:12]}"
        self.assertIn("\tOK", (result / "summary.tsv").read_text())
        for side, commit in (("base", self.old), ("head", self.new)):
            dependencies = result / side / "generated/tiny_tiny"
            metadata = json.loads((dependencies / "metadata.json").read_text())
            runtime = next(p for p in metadata["packages"] if p["name"] == "flowlog-runtime")
            self.assertIsNone(runtime["source"])
            self.assertIn(commit[:12], runtime["manifest_path"])
            self.assertTrue((dependencies / "Cargo.lock").is_file())
            self.assertTrue((result / side / "compiler.Cargo.lock").is_file())
            self.assertTrue((result / side / "toolchain.txt").is_file())
            self.assertFalse((dependencies / "target").exists())
        self.run_script("regression.sh", "old", "new", "config.txt")
        self.run_script("regression.sh", "old", "new", "config.txt", code=3, FL_NO_STR_INTERN="1")

    def test_concurrent_fresh_cannot_remove_running_results(self):
        result = self.bench / f"results/regression/{self.old[:12]}_vs_{self.new[:12]}"
        result.mkdir(parents=True)
        sentinel = result / "sentinel"
        sentinel.write_text("running\n")
        with Path(str(result) + ".lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_script("regression.sh", "--fresh", "old", "new", "config.txt", code=3)
        self.assertEqual(sentinel.read_text(), "running\n")

    def test_stale_workspace_lock_is_rejected(self):
        result = self.run_script("get_flowlog.sh", FLOWLOG_REF="stale-lock", code=1)
        self.assertIn("--locked", result.stderr)

    def test_wrong_runtime_is_rejected_before_measurement(self):
        wrong = self.bench / "wrong-runtime"
        (wrong / "src").mkdir(parents=True)
        (wrong / "Cargo.toml").write_text('[package]\nname = "flowlog-runtime"\nversion = "0.2.0"\nedition = "2021"\n')
        (wrong / "src/lib.rs").write_text('pub fn run() { println!("Dataflow executed in 1s"); }\n')
        self.run_script("regression.sh", "old", "wrong-runtime", "config.txt", code=3, WRONG_RUNTIME=str(wrong))
        output = next((self.bench / "results/regression").glob("*_vs_*/head"))
        self.assertIn("runtime verification failed", (output / "tiny_tiny_compiler_build.log").read_text())
        self.assertFalse((output / "tiny_tiny_compiler_run1.log").exists())

    def test_ref_resolution_and_dirty_cache(self):
        result = self.run_script("get_flowlog.sh", FLOWLOG_REF=self.old[:12])
        self.assertEqual(result.stdout.split()[0], self.old)
        self.run_script("get_flowlog.sh", FLOWLOG_REF="refs/tags/old")
        source = self.bench / f"flowlog/{self.old[:12]}/src"
        with (source / "flowlog-runtime/src/lib.rs").open("a") as file:
            file.write("// dirty runtime\n")
        result = self.run_script("get_flowlog.sh", FLOWLOG_REF="old", code=1)
        self.assertIn("dirty", result.stderr)

    def test_explicit_remote_ref_and_ambiguous_name(self):
        self.git("update-ref", "refs/pull/7/head", self.old)
        result = self.run_script("get_flowlog.sh", FLOWLOG_REF="refs/pull/7/head")
        self.assertEqual(result.stdout.split()[0], self.old)
        self.git("update-ref", "refs/pull/7/head", self.new)
        result = self.run_script("get_flowlog.sh", FLOWLOG_REF="refs/pull/7/head")
        self.assertEqual(result.stdout.split()[0], self.new)
        self.git("branch", "ambiguous", self.new)
        self.git("tag", "ambiguous", self.old)
        self.run_script("get_flowlog.sh", FLOWLOG_REF="ambiguous", code=2)
        self.run_script("get_flowlog.sh", FLOWLOG_REF="refs/tags/ambiguous")

    def test_same_commit_is_invalid(self):
        self.run_script("regression.sh", "old", self.old, "config.txt", code=2)

    def test_measured_regression_returns_one(self):
        # Inject a deterministic runtime increase into the captured HEAD log;
        # both actual generated binaries still have to compile and run first.
        time = self.bench / "time"
        time.write_text('''#!/bin/bash
/usr/bin/time "$@"
rc=$?
if [[ "$*" == */head/* ]]; then echo 'Dataflow executed in 2s'; fi
exit "$rc"
''')
        time.chmod(0o755)
        result = self.run_script("regression.sh", "old", "new", "config.txt", code=1, TIME_BIN=str(time))
        self.assertIn("REGRESSION", result.stderr)
        self.assertNotIn("MEASURE_FAIL", result.stderr)

    def test_moving_branch_is_fetched_again(self):
        self.git("branch", "-f", "moving", self.old)
        first = self.run_script("get_flowlog.sh", FLOWLOG_REF="moving")
        self.git("branch", "-f", "moving", self.new)
        second = self.run_script("get_flowlog.sh", FLOWLOG_REF="moving")
        self.assertEqual(first.stdout.split()[0], self.old)
        self.assertEqual(second.stdout.split()[0], self.new)

    def test_unknown_ref_and_invalid_config(self):
        self.run_script("regression.sh", "does-not-exist", "new", "config.txt", code=2)
        self.run_script("regression.sh", "old", "new", "config.txt", code=2, PERF_COMPARE_NUM_RUNS="0")
        (self.bench / "config.txt").write_text("tiny.dl=tiny\ntiny.dl=tiny\n")
        self.run_script("regression.sh", "old", "new", "config.txt", code=2)

    def test_failed_build_never_uses_old_binary(self):
        self.run_script("get_flowlog.sh", FLOWLOG_REF="old")
        fake = self.bench / "fake-bin"
        fake.mkdir()
        (fake / "cargo").write_text("#!/bin/sh\nexit 27\n")
        (fake / "cargo").chmod(0o755)
        result = self.run_script("regression.sh", "old", "new", "config.txt", code=3,
                                 PATH=str(fake) + os.pathsep + self.run_env["PATH"])
        self.assertIn("failed", result.stderr)

    def test_partial_measurement_is_error(self):
        self.run_script("regression.sh", "old", "new", "config.txt")
        time = self.bench / "time"
        # First attempt works; the next fails. Previously this could yield OK.
        time.write_text(f'''#!/bin/bash
if [[ "$*" == *run2.log* ]]; then exit 124; fi
exec /usr/bin/time "$@"
''')
        time.chmod(0o755)
        result = self.run_script("regression.sh", "old", "new", "config.txt", code=3, TIME_BIN=str(time))
        self.assertIn("MEASURE_FAIL", result.stderr)
        self.assertNotIn("ALL OK", result.stdout)
        self.assertFalse(any((self.bench / "results").rglob("*.n_runs_succeeded")))

    def test_failed_rerun_does_not_leave_passing_summary(self):
        self.run_script("regression.sh", "old", "new", "config.txt")
        (self.bench / "facts/tiny").rmdir()
        fake = self.bench / "fake-bin"
        fake.mkdir()
        (fake / "wget").write_text("#!/bin/sh\nexit 1\n")
        (fake / "wget").chmod(0o755)
        self.run_script("regression.sh", "old", "new", "config.txt", code=3,
                        PATH=str(fake) + os.pathsep + self.run_env["PATH"])
        self.assertFalse(any((self.bench / "results").rglob("summary.tsv")))

    def test_missing_rss_is_error(self):
        time = self.bench / "time"
        time.write_text('''#!/bin/bash
shift
shift
rss="$1"
shift
: > "$rss"
exec "$@"
''')
        time.chmod(0o755)
        result = self.run_script("regression.sh", "old", "new", "config.txt", code=3, TIME_BIN=str(time))
        self.assertIn("MEASURE_FAIL", result.stderr)


class DependencyVerification(unittest.TestCase):
    def test_unused_old_patch_registry_fallback_is_rejected(self):
        runtime = {"id": "registry-runtime", "name": "flowlog-runtime", "version": "0.3.1",
                   "source": "registry+https://github.com/rust-lang/crates.io-index",
                   "manifest_path": "/registry/flowlog-runtime/Cargo.toml"}
        metadata = {"packages": [runtime], "resolve": {"root": "root", "nodes": [{"id": runtime["id"]}]}}
        with self.assertRaisesRegex(ValueError, "old patch unused"):
            RUNTIME.verify_runtime(metadata, "/snapshot/flowlog-runtime")

    def test_wrong_revision_runtime_is_rejected(self):
        runtime = {"id": "local-runtime", "name": "flowlog-runtime", "version": "0.1.0",
                   "source": None, "manifest_path": "/other-commit/flowlog-runtime/Cargo.toml"}
        metadata = {"packages": [runtime], "resolve": {"root": "root", "nodes": [{"id": runtime["id"]}]}}
        with self.assertRaisesRegex(ValueError, "selected checkout"):
            RUNTIME.verify_runtime(metadata, "/snapshot/flowlog-runtime")



if __name__ == "__main__":
    unittest.main()
