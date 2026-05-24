# DOOP fact data (chopin, 20 apps)

Canonical DOOP context-insensitive points-to facts for all 20 DaCapo 23.11-MR2-chopin benchmarks, consumable by [`programs/oracle/flowlog/doop/default.dl`](../programs/oracle/flowlog/doop/default.dl) and equivalent Soufflé-compatible variants.

All 20 fact sets are published on HuggingFace at
`https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/tree/main/dataset/csv` —
one `<app>.zip` per app. The zip unpacks to `<app>/<RelationName>.facts` (tab-delimited, DOOP-standard naming with hyphens, plus a one-line `MainClass.facts`).

## Use

Prerequisites:

- Docker (only needed to *regenerate* facts; not needed to consume the published zips).
- flowlog ≥ commit `e492d15` (`feat: support escape string`) — earlier flowlog mis-parses `delimiter="\t"`.
- ~3 GB free disk per app you plan to keep extracted at once.

Per-app workflow:

```bash
APP=batik
WORK=/path/to/workspace
mkdir -p $WORK/{facts,out}

# 1. Download + extract one app
wget -O $WORK/${APP}.zip \
  https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/resolve/main/dataset/csv/${APP}.zip
unzip -q -o $WORK/${APP}.zip -d $WORK/facts/

# 2. Compile flowlog binary (fact dir baked into the binary)
$FLOWLOG_COMPILER --str-intern --mode datalog-batch \
    -F $WORK/facts/$APP \
    -D $WORK/out/$APP \
    -o $WORK/${APP}_bin \
    programs/oracle/flowlog/doop/default.dl

# 3. Run (parallel workers via -w; binary prints sizes to stdout)
$WORK/${APP}_bin -w 64
```

Loop for all 20:

```bash
for APP in avrora batik biojava cassandra eclipse fop graphchi h2 h2o jme \
           jython kafka luindex lusearch pmd spring sunflow tomcat xalan zxing; do
    # download, compile, run as above
done
```

Souffl é-equivalent (after `:string`→`:symbol`, `:int32`→`:number`, `a cat b`→`cat(a,b)` source transforms on `doop/default.dl`):

```bash
souffle -o /path/doop_souffle_bin -j 64 doop_souffle.dl   # one-time
$WORK/doop_souffle_bin -j 64 -F $WORK/facts/$APP -D $WORK/out/$APP
```

## Per-app notes

| App | DaCapo source | Main class | Notes |
|---|---|---|---|
| avrora | chopin `jar/avrora/avrora-cvs-20131011.jar` | `avrora.Main` | |
| batik | chopin `jar/batik/batik-all-1.16.jar` (+3 dep jars) | `org.apache.batik.apps.svgbrowser.Main` | |
| biojava | chopin `jar/biojava/AAProperties-jar-with-dependencies.jar` | `org.biojava.nbio.aaproperties.CommandPrompt` | |
| cassandra | chopin `jar/cassandra/core-0.17.0.jar` only | `site.ycsb.Client` | **Extracted with `-i core-0.17.0.jar` and NO `-ld` deps** — passing all 129 cassandra dep jars caused Soot to crash on one of them during preprocessing. YCSB Client is the canonical entry per DaCapo harness. |
| eclipse | chopin `jar/eclipse/eclipse.jar` | `org.eclipse.core.runtime.adaptor.EclipseStarter` | |
| fop | chopin `jar/fop/fop.jar` (+19 dep jars) | `org.apache.fop.cli.Main` | |
| graphchi | chopin `jar/graphchi/graphchi-0.2.2.jar` | `edu.cmu.graphchi.apps.ALSMatrixFactorization` | DaCapo harness dispatches via `"edu.cmu.graphchi.apps." + args[0]` and `args[0]="ALSMatrixFactorization"` for default/small/large. |
| h2 | chopin `jar/lib/h2/h2-2.2.220.jar` (NOT the `dacapo-h2.jar` stub) | `org.h2.tools.Console` | |
| h2o | chopin `jar/h2o/h2o.jar` | `water.H2OApp` | Single 247 MB fat jar. |
| jme | chopin `jar/jme/jMonkeyEngine3.jar` (+66 dep jars) | `jme3test.TestChooser` | Reachability ceiling: TestChooser dispatches via reflection to hundreds of test classes; our static-CI analysis won't follow. |
| jython | chopin `jar/jython/jython.jar` (+22 dep jars) | `org.python.util.jython` | Heaviest workload — VPT=438M. |
| kafka | chopin `jar/kafka/kafka_2.13-3.3.1.jar` (+126 dep jars) | `kafka.Kafka` | |
| **luindex** ★ | chopin `jar/luindex/dacapo-luindex.jar` + lucene libs + **synthetic wrapper jar** | `org.dacapo.luindex.LuindexMain` | Canonical `org.dacapo.luindex.Index` has no static main — only constructor + `indexDir`/`indexLineDoc` instance methods. The wrapper is a hand-written 8-line Java file that `new Index(...).indexDir(...); .indexLineDoc(...);` so Soot can seed from a static main. Reachable set is equivalent to what the DaCapo harness would invoke reflectively. |
| **lusearch** ★ | chopin `jar/lusearch/dacapo-lusearch.jar` + lucene libs + **synthetic wrapper jar** | `org.dacapo.lusearch.LusearchMain` | Canonical `org.dacapo.lusearch.Search.main` is non-static (instance method). Wrapper instantiates Search and calls its instance `main`. |
| pmd | chopin `jar/pmd/pmd-core-6.55.0.jar` (+6 dep jars) | `net.sourceforge.pmd.PMD` | |
| **spring** ★ | chopin `jar/spring/spring-petclinic-2.7.3.jar` **unpacked**: `BOOT-INF/classes/` repackaged into a flat jar | `org.springframework.samples.petclinic.PetClinicApplication` | Spring Boot fat-jar layout puts the app classes under `BOOT-INF/classes/`. Soot can't traverse that. The fix: `unzip -j 'BOOT-INF/classes/*'` and re-`jar cf` into a flat jar; pass that flat jar as `-i`. |
| sunflow | chopin `jar/sunflow/sunflow-0.07.2.jar` | `org.sunflow.Benchmark` | |
| **tomcat** ★ | chopin `jar/tomcat/dacapo-tomcat.jar` + 40 tomcat deps + **synthetic wrapper jar** | `org.dacapo.tomcat.TomcatMain` | Canonical `org.dacapo.tomcat.Control` is instance-only (`new Control(...).exec("prepare"/"startIteration"/"stopIteration"/"cleanup")`); also `Client` (`new Client(...).run()`). Wrapper calls both in sequence. |
| xalan | chopin `jar/xalan/xalan.jar` (NOT the `dacapo-xalan.jar` stub) | `org.apache.xalan.xslt.Process` | |
| zxing | chopin `jar/zxing/javase-3.5.2-jar-with-dependencies.jar` | `com.google.zxing.client.j2se.CommandLineRunner` | |

★ = uses a synthetic main wrapper (5 apps). The wrapper is a tiny `public static void main(String[])` Java file that mimics what the DaCapo Harness does reflectively at runtime — exposes the canonical entry as a real static main so our DOOP rule's `MainMethodDeclaration` can fire. 

## Timings

Single-host, AMD Threadripper 128-core, both engines pinned to 64 threads, fastest of two runs each, run-only (compile excluded). flowlog binary: main-next commit `e492d15` with `--str-intern --mode datalog-batch`. Souffl é binary: 2.4, compiled mode (`-c -j 64`).

| App | flowlog (`-w 64`) | Souffl é (`-j 64`) | sf / fl | VarPointsTo |
|---|---:|---:|---:|---:|
| jython | 263 s | 428 s | 1.63× | 438,304,400 |
| h2 | 11 s | 36 s | 3.27× | 39,871,906 |
| fop | 12 s | 38 s | 3.17× | 39,818,826 |
| eclipse | 11 s | 27 s | 2.45× | 39,139,806 |
| batik | 12 s | 39 s | 3.25× | 37,237,353 |
| spring | 9 s | 32 s | 3.56× | 25,953,984 |
| h2o | 28 s | 76 s | 2.71× | 17,911,631 |
| sunflow | 7 s | 19 s | 2.71× | 11,616,018 |
| pmd | 6 s | 14 s | 2.33× | 8,511,281 |
| luindex | 5 s | 11 s | 2.20× | 6,141,746 |
| tomcat | 4 s | 10 s | 2.50× | 4,986,481 |
| biojava | 9 s | 20 s | 2.22× | 4,901,635 |
| jme | 7 s | 13 s | 1.86× | 4,825,804 |
| zxing | 5 s | 13 s | 2.60× | 4,024,065 |
| xalan | 6 s | 13 s | 2.17× | 2,741,586 |
| lusearch | 5 s | 6 s | 1.20× | 2,704,088 |
| kafka | 8 s | 18 s | 2.25× | 2,513,410 |
| graphchi | 10 s | 21 s | 2.10× | 2,403,445 |
| avrora | 4 s | 8 s | 2.00× | 2,188,265 |
| cassandra | 3 s | 5 s | 1.67× | 1,896,143 |
