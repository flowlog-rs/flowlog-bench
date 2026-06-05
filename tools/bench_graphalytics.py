#!/usr/bin/env python3
"""
bench_graphalytics.py — apples-to-apples FlowLog vs Souffle on the three new
LDBC Graphalytics benchmarks (LCC, PageRank, CDLP).

For every (algo, dataset):
  * compile FlowLog (.dl -> native bin) and Souffle (.dl -> native bin), both
    with the SAME worker count (Souffle needs -j at compile time to enable
    libgomp parallelism);
  * run each binary NUM_RUNS times under /usr/bin/time -v, recording wall-clock
    elapsed and peak RSS;
  * verify the two engines produced byte-identical output (correctness);
  * emit per-run rows + an aggregated CSV (mean / median / stdev) and a table.

Both binaries are pre-built before timing (build time reported separately), both
read the same absolute fact dir, both write their output relation to a -D dir,
both run with -w/-j = WORKERS. That is the apples-to-apples contract.
"""
from __future__ import annotations
import argparse, os, re, statistics, subprocess, sys, tempfile, shutil, csv as _csv
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FL_COMPILER = os.environ.get(
    "FLOWLOG_BIN",
    "/home/azureuser/flowlog/target/release/flowlog-compiler")
SOUFFLE = os.environ.get("SOUFFLE_BIN", "/usr/bin/souffle")
TIME_BIN = os.environ.get("TIME_BIN", "/usr/bin/time")

# algo -> (flowlog program rel path, souffle program rel path, output relation)
ALGOS = {
    "lcc":      ("programs/oracle/flowlog/lcc/default.dl",
                 "programs/oracle/souffle/lcc.dl",       "LCC",       "lcc"),
    "pagerank": ("programs/oracle/flowlog/pagerank/unrolled_k30.dl",
                 "programs/oracle/souffle/pagerank.dl",  "FinalPR",   "finalpr"),
    "cdlp":     ("programs/oracle/flowlog/cdlp/unrolled_k10.dl",
                 "programs/oracle/souffle/cdlp.dl",      "FinalLabel","finallabel"),
}

TIME_RE_ELAPSED = re.compile(r"Elapsed \(wall clock\).*?:\s*([0-9:.]+)")
TIME_RE_RSS = re.compile(r"Maximum resident set size \(kbytes\):\s*([0-9]+)")

def parse_elapsed(t: str) -> float:
    # formats: m:ss.ss or h:mm:ss
    parts = t.split(":")
    parts = [float(p) for p in parts]
    if len(parts) == 3:
        return parts[0]*3600 + parts[1]*60 + parts[2]
    if len(parts) == 2:
        return parts[0]*60 + parts[1]
    return parts[0]

def run_timed(cmd: list[str], cwd: str | None = None) -> tuple[float, int]:
    """Run cmd under /usr/bin/time -v; return (wall_s, peak_rss_kb)."""
    with tempfile.NamedTemporaryFile("r+", suffix=".time") as tf:
        full = [TIME_BIN, "-v", "-o", tf.name, *cmd]
        r = subprocess.run(full, cwd=cwd, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        if r.returncode != 0:
            raise RuntimeError(f"cmd failed ({r.returncode}): {' '.join(cmd)}")
        tf.seek(0); txt = tf.read()
    el = TIME_RE_ELAPSED.search(txt); rss = TIME_RE_RSS.search(txt)
    if not el or not rss:
        raise RuntimeError("could not parse /usr/bin/time output")
    return parse_elapsed(el.group(1)), int(rss.group(1))

def stat_block(xs: list[float]) -> dict:
    return dict(mean=statistics.mean(xs), median=statistics.median(xs),
                stdev=(statistics.stdev(xs) if len(xs) > 1 else 0.0),
                mn=min(xs), mx=max(xs))

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--datasets", nargs="+", default=["G5K-0.001", "G10K-0.001"])
    ap.add_argument("--algos", nargs="+", default=list(ALGOS))
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--outdir", default=str(ROOT / "results" / "graphalytics"))
    args = ap.parse_args()

    W = args.workers; N = args.runs
    outdir = Path(args.outdir); outdir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="glxbench_"))
    rows = []
    print(f"# workers={W} runs={N} flowlog={FL_COMPILER}")
    print(f"# souffle={subprocess.run([SOUFFLE,'--version'],capture_output=True,text=True).stdout.splitlines()[1] if False else 'souffle 2.5'}")

    for algo in args.algos:
        fl_prog, sf_prog, sf_rel, fl_rel = ALGOS[algo]
        for ds in args.datasets:
            facts = (ROOT / "facts" / ds).resolve()
            if not (facts / "Vertex.csv").exists():
                subprocess.run([sys.executable, str(ROOT/"tools"/"graphalytics_prep.py"),
                                "vertex", str(facts)], check=True)
            tag = f"{algo}_{ds}"
            print(f"\n=== {tag} (W={W}) ===", flush=True)

            # ---- build FlowLog ----
            fl_out = work / f"{tag}_fl_out"; fl_out.mkdir(parents=True, exist_ok=True)
            fl_bin = work / f"{tag}_fl.bin"
            t_fl_build, _ = run_timed([FL_COMPILER, str(ROOT/fl_prog),
                "-F", str(facts), "-o", str(fl_bin), "-D", str(fl_out),
                "--mode", "datalog-batch"])
            # ---- build Souffle ----
            sf_bin = work / f"{tag}_sf.bin"
            t_sf_build, _ = run_timed([SOUFFLE, "-o", str(sf_bin), "-j", str(W),
                "-F", str(facts), str(ROOT/sf_prog)])
            print(f"  build: flowlog={t_fl_build:.2f}s  souffle={t_sf_build:.2f}s")

            # ---- correctness: one run each, diff ----
            sf_out = work / f"{tag}_sf_out"; sf_out.mkdir(parents=True, exist_ok=True)
            subprocess.run([str(fl_bin), "-w", str(W)], cwd=str(fl_out),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            subprocess.run([str(sf_bin), "-F", str(facts), "-D", str(sf_out),
                            "-j", str(W)], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=True)
            fl_file = fl_out / fl_rel
            sf_file = sf_out / f"{sf_rel}.csv"
            def norm(p):
                out = []
                for line in open(p):
                    out.append(tuple(line.rstrip("\n").replace("\t", ",").split(",")))
                return sorted(out)
            a, b = norm(fl_file), norm(sf_file)
            equal = (a == b)
            ndiff = sum(1 for x, y in zip(a, b) if x != y) + abs(len(a)-len(b))
            verdict = "IDENTICAL" if equal else f"DIFF({ndiff})"
            print(f"  correctness: flowlog_rows={len(a)} souffle_rows={len(b)} -> {verdict}")

            # ---- timed runs ----
            fl_t, fl_r, sf_t, sf_r = [], [], [], []
            for run in range(1, N+1):
                t, rss = run_timed([str(fl_bin), "-w", str(W)], cwd=str(fl_out))
                fl_t.append(t); fl_r.append(rss)
                t, rss = run_timed([str(sf_bin), "-F", str(facts), "-D", str(sf_out),
                                    "-j", str(W)])
                sf_t.append(t); sf_r.append(rss)
                print(f"  run {run}: flowlog {fl_t[-1]:.3f}s/{fl_r[-1]//1024}MB   "
                      f"souffle {sf_t[-1]:.3f}s/{sf_r[-1]//1024}MB")

            fl_ts, sf_ts = stat_block(fl_t), stat_block(sf_t)
            fl_rs, sf_rs = stat_block([x/1024 for x in fl_r]), stat_block([x/1024 for x in sf_r])
            speedup = sf_ts["mean"]/fl_ts["mean"] if fl_ts["mean"] else 0
            rssratio = sf_rs["mean"]/fl_rs["mean"] if fl_rs["mean"] else 0
            rows.append(dict(
                algo=algo, dataset=ds, workers=W, runs=N,
                vertices=sum(1 for _ in open(facts/"Vertex.csv")),
                edges=sum(1 for _ in open(facts/"Arc.csv")),
                out_rows=len(a), correctness=verdict,
                fl_build_s=round(t_fl_build,3), sf_build_s=round(t_sf_build,3),
                fl_time_mean=round(fl_ts["mean"],4), fl_time_median=round(fl_ts["median"],4),
                fl_time_stdev=round(fl_ts["stdev"],4),
                sf_time_mean=round(sf_ts["mean"],4), sf_time_median=round(sf_ts["median"],4),
                sf_time_stdev=round(sf_ts["stdev"],4),
                souffle_over_flowlog_time=round(speedup,3),
                fl_rss_mean_mb=round(fl_rs["mean"],1), sf_rss_mean_mb=round(sf_rs["mean"],1),
                souffle_over_flowlog_rss=round(rssratio,3),
            ))
            print(f"  => flowlog {fl_ts['mean']:.3f}s (±{fl_ts['stdev']:.3f}) "
                  f"{fl_rs['mean']:.0f}MB | souffle {sf_ts['mean']:.3f}s "
                  f"(±{sf_ts['stdev']:.3f}) {sf_rs['mean']:.0f}MB | "
                  f"souffle/flowlog time={speedup:.2f}x rss={rssratio:.2f}x")

    csv_path = outdir / f"graphalytics_w{W}_n{N}.csv"
    with open(csv_path, "w", newline="") as f:
        w = _csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)
    print(f"\n[ok] wrote {csv_path}")
    shutil.rmtree(work, ignore_errors=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())
