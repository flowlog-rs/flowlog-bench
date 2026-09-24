#!/usr/bin/env bash
# Fair FlowLog-vs-Souffle: both .output full .csv, -w/-j 32, time run (not compile), peak RSS, row-count crosscheck.
FB=/datasets/flowlog-latest/target/release/flowlog-compiler; SF=/usr/bin/souffle; W=32
secs(){ awk '/Elapsed .wall clock/{n=split($NF,a,":"); print (n==3?a[1]*3600+a[2]*60+a[3]:a[1]*60+a[2])}' "$1"; }
rssmb(){ awk '/Maximum resident/{printf "%.0f",$NF/1024}' "$1"; }
benchone(){ # stem ds fl_dl sf_dl extra_fl
  local stem=$1 ds=$2 fl=$3 sf=$4 xfl=$5; local facts=/datasets/facts/$ds
  local fo=/datasets/out/${stem}_${ds}_fl so=/datasets/out/${stem}_${ds}_sf L=/datasets/log
  rm -rf "$fo" "$so" "/datasets/bin/.${stem}_${ds}_fl.build"; mkdir -p "$fo" "$so"
  local fb=/datasets/bin/${stem}_${ds}_fl sb=/datasets/bin/${stem}_sf
  $FB "$fl" $xfl -F "$facts" -D "$fo" -o "$fb" >"$L/${stem}_${ds}_flc.log" 2>&1 || { echo "$stem,$ds,FL_COMPILE_FAIL,,,,,"; return; }
  /usr/bin/time -v -o "$L/${stem}_${ds}_flt" timeout 1800 "$fb" -w $W >"$L/${stem}_${ds}_flr.log" 2>&1
  [ -x "$sb" ] || $SF -o "$sb" -j $W "$sf" >"$L/${stem}_sfc.log" 2>&1
  /usr/bin/time -v -o "$L/${stem}_${ds}_sft" timeout 1800 "$sb" -F "$facts" -D "$so" -j $W >"$L/${stem}_${ds}_sfr.log" 2>&1
  local fls=$(secs "$L/${stem}_${ds}_flt") flm=$(rssmb "$L/${stem}_${ds}_flt") sfs=$(secs "$L/${stem}_${ds}_sft") sfm=$(rssmb "$L/${stem}_${ds}_sft")
  # crosscheck row counts per relation (data rows; souffle .csv has no header, flowlog .csv no header)
  local xc=$(python3 - "$fo" "$so" <<'PY'
import sys,os,glob
fo,so=sys.argv[1],sys.argv[2]
def counts(d):
  r={}
  for f in glob.glob(os.path.join(d,'*.csv')):
    rel=os.path.basename(f)[:-4].lower()
    with open(f,'rb') as fh: r[rel]=sum(1 for _ in fh)
  return r
fl,sf=counts(fo),counts(so); shared=set(fl)&set(sf)
mm=[(r,fl[r],sf[r]) for r in sorted(shared) if fl[r]!=sf[r]]
if not shared: print("n/a")
elif mm: print("MISMATCH:"+";".join(f"{r}={a}vs{b}" for r,a,b in mm[:4]))
else: print(f"match({len(shared)})"+(f"+SFonly{len(set(sf)-set(fl))}" if set(sf)-set(fl) else "")+(f"+FLonly{len(set(fl)-set(sf))}" if set(fl)-set(sf) else ""))
PY
)
  local sp=$(awk "BEGIN{printf \"%.2f\", $sfs/$fls}")
  echo "$stem,$ds,$fls,$flm,$sfs,$sfm,$sp,$xc"
  rm -rf "$fo" "$so"
}
