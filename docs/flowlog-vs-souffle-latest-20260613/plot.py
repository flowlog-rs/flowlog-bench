import csv, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

rows=[r for r in csv.DictReader(open("/datasets/results.csv")) if r.get("stem") in ("ci","pol") and r.get("crosscheck","").startswith("match")]
def f(x):
    try: return float(x)
    except: return float("nan")
FL="#2563eb"; SF="#f59e0b"  # blue / amber, light theme
plt.rcParams.update({"font.family":"DejaVu Sans","font.size":11,"axes.spines.top":False,"axes.spines.right":False,"figure.facecolor":"white","axes.facecolor":"white"})

def grouped(ax,labels,fl,sf,ylabel,title,logy=False):
    x=np.arange(len(labels)); w=0.4
    ax.bar(x-w/2,fl,w,label="FlowLog",color=FL)
    ax.bar(x+w/2,sf,w,label="Soufflé",color=SF)
    ax.set_xticks(x); ax.set_xticklabels(labels,rotation=45,ha="right")
    ax.set_ylabel(ylabel); ax.set_title(title,loc="left",fontweight="bold")
    if logy: ax.set_yscale("log")
    ax.legend(frameon=False,ncol=2,loc="upper left")
    ax.grid(axis="y",alpha=.25)

# ---- ci (DOOP context-insensitive) ----
ci=[r for r in rows if r["stem"]=="ci"]
ci.sort(key=lambda r:f(r["FL_s"]))
lab=[r["ds"] for r in ci]; fls=[f(r["FL_s"]) for r in ci]; sfs=[f(r["SF_s"]) for r in ci]
flm=[f(r["FL_MB"])/1024 for r in ci]; sfm=[f(r["SF_MB"])/1024 for r in ci]
fig,(a1,a2)=plt.subplots(2,1,figsize=(11,9)); fig.suptitle("DOOP context-insensitive points-to — FlowLog vs Soufflé  (−w/−j 32, fair I/O, identical output)",fontsize=13,fontweight="bold")
grouped(a1,lab,fls,sfs,"run time (s)","Run time  (lower is better)")
grouped(a2,lab,flm,sfm,"peak RSS (GB)","Peak memory  (lower is better)")
fig.tight_layout(rect=[0,0,1,.97]); fig.savefig("/datasets/doop_ci.png",dpi=140)

# speedup bar
fig,ax=plt.subplots(figsize=(11,4.2))
sp=[f(r["SF_over_FL"]) for r in ci]
cols=[FL if s>=1 else SF for s in sp]
ax.bar(lab,sp,color=cols); ax.axhline(1,color="#444",lw=1,ls="--")
ax.set_ylabel("Soufflé / FlowLog\n(>1 ⇒ FlowLog faster)"); ax.set_title("Speedup  (DOOP context-insensitive)",loc="left",fontweight="bold")
ax.set_xticklabels(lab,rotation=45,ha="right"); ax.grid(axis="y",alpha=.25)
import math
gm=math.exp(sum(math.log(s) for s in sp)/len(sp))
ax.text(0.99,0.95,f"geomean {gm:.2f}×",transform=ax.transAxes,ha="right",va="top",fontsize=11,fontweight="bold")
fig.tight_layout(); fig.savefig("/datasets/doop_speedup.png",dpi=140)

# ---- polonius ----
pol=[r for r in rows if r["stem"]=="pol"]
if pol:
    lab=[r["ds"] for r in pol]; fls=[f(r["FL_s"]) for r in pol]; sfs=[f(r["SF_s"]) for r in pol]
    flm=[f(r["FL_MB"])/1024 for r in pol]; sfm=[f(r["SF_MB"])/1024 for r in pol]
    fig,(a1,a2)=plt.subplots(1,2,figsize=(10,4.2)); fig.suptitle("Polonius (borrow checker) — FlowLog vs Soufflé  (−w/−j 32, identical output)",fontsize=12,fontweight="bold")
    grouped(a1,lab,fls,sfs,"run time (s)","Run time")
    grouped(a2,lab,flm,sfm,"peak RSS (GB)","Peak memory")
    fig.tight_layout(rect=[0,0,1,.93]); fig.savefig("/datasets/polonius.png",dpi=140)
print("plots written:",len(ci),"ci,",len(pol),"polonius")
