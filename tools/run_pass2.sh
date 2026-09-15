#!/usr/bin/env bash
# Pass-2 orchestrator: run each (algo,dataset) pair in isolation so an OOM or
# crash on one pair cannot abort the whole batch. Each pair writes its own CSV
# under results/glx_pass2/<algo>_<dataset>/. Souffle uses -j16 at compile+run
# (handled inside bench_graphalytics.py); FlowLog uses -w16.
set -u
cd "$(dirname "$0")/.."
OUTROOT=results/glx_pass2
mkdir -p "$OUTROOT"
W=16

run_pair() {
  local algo="$1" ds="$2" runs="$3" tmo="$4"
  local od="$OUTROOT/${algo}_${ds}"
  if [ -f "$od/graphalytics_w${W}_n${runs}.csv" ]; then
    echo "[skip] $algo/$ds already done"; return 0
  fi
  echo "######## $algo / $ds (runs=$runs timeout=${tmo}s) ########"
  timeout "$tmo" python3 tools/bench_graphalytics.py \
      --algos "$algo" --datasets "$ds" --workers "$W" --runs "$runs" \
      --outdir "$od" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "[FAIL rc=$rc] $algo/$ds" | tee "$od.FAILED"
  fi
}

# Parse "algo ds runs tmo" lines from stdin.
while read -r algo ds runs tmo; do
  [ -z "$algo" ] && continue
  case "$algo" in \#*) continue;; esac
  run_pair "$algo" "$ds" "$runs" "$tmo"
done
echo "==== PASS2 ORCHESTRATION COMPLETE ===="
