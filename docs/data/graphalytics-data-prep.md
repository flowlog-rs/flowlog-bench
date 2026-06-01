# LDBC Graphalytics — data prep & dataset pointers

The Graphalytics programs (`pagerank`, `lcc`, `cdlp`) reuse the existing
`Arc.csv` graph-dataset format (`int64 src, int64 dst`, comma-delimited)
plus two small derived EDB files that the prep script materialises in
place.

## Required per-dataset EDB layout

```
<facts_dir>/
├── Arc.csv       # already provided by the existing dataset cache
├── Vertex.csv    # one int64 vertex id per line (derived from Arc.csv)
└── MaxIter.csv   # single int line: K  (pagerank/cdlp only)
```

`Vertex.csv` must include isolated vertices if the dataset has any (LCC
defines `LCC(v) = 0` for them, so they need to appear in the output).
The prep tool re-uses the vertex IDs that appear as either `src` or `dst`
in `Arc.csv`. For LDBC datasets shipped with a separate vertex file,
prefer to materialise `Vertex.csv` from that file directly so that
isolated vertices are not lost.

## One-shot prep

```bash
# Run after `Arc.csv` has been downloaded into facts/<dataset>/.
python3 tools/graphalytics_prep.py all facts/livejournal --k 30
```

Generated files:
- `facts/livejournal/Vertex.csv`
- `facts/livejournal/MaxIter.csv`   (contains the single line `30`)

`--k 30` matches the LDBC Graphalytics-style default for fast iteration;
LDBC's *official* PageRank validation uses K=50, CDLP uses K=10. Pass
`--k 50` (or `--k 10` for CDLP) to match the LDBC validation oracle.

## Datasets

### Reuse the existing FlowLog graph cache (recommended for timing)

The three programs are written against the same `Arc.csv` schema already
used by `tc.dl`, `reach.dl`, `cc.dl`, `sssp.dl`, and `bipartite.dl`, so
**any existing FlowLog graph dataset works without re-download**:

| stem        | source                                              | size    |
|-------------|-----------------------------------------------------|---------|
| `G5K-0.001` | synthetic Erdős–Rényi (5K vertices, ~25K edges)     | 0.2 MB  |
| `G10K-0.001`| synthetic Erdős–Rényi (10K vertices, ~100K edges)   | 1 MB    |
| `livejournal` | SNAP soc-LiveJournal1 (4.8M vertices, 69M edges) | 1.1 GB  |
| `orkut`     | SNAP com-Orkut (3.1M vertices, 117M edges)          | 1.7 GB  |
| `arabic`    | LAW arabic-2005 (22.7M vertices, 640M edges)        | 6.6 GB  |
| `twitter`   | LAW twitter-2010 (41.6M vertices, 1.5B edges)       | 17 GB   |

All are mirrored at the HuggingFace dataset:
<https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/tree/main/dataset/csv>

LCC's triangle enumeration is O(Σ deg(v)²) and OOMs on the larger
crawls — keep `lcc.dl` to `G5K-0.001`, `G10K-0.001`, and small social
graphs in the bench config.

### LDBC official Graphalytics datasets (for *correctness* validation)

If you want to check FlowLog's PR / LCC / CDLP outputs against LDBC's
reference oracle (`<dataset>-<algo>` validation file), download from the
LDBC Graphalytics archive:

- Hub (browse): <https://www.ldbcouncil.org/benchmarks/graphalytics/>
- Reference impl + dataset URLs: <https://github.com/ldbc/ldbc_graphalytics_docs>
- Direct mirror (CWI, recommended for reproducibility):
  <https://atlarge.ewi.tudelft.nl/graphalytics/>

Small / medium reference graphs that are quick to validate against:

| LDBC stem        | vertices | edges  | size  |
|------------------|---------:|-------:|------:|
| `dota-league`    |    61 K  | 51 M  | 0.5 GB |
| `kgs`            |   833 K  | 17 M  | 0.3 GB |
| `wiki-Talk`      |   2.4 M  | 5 M   | 0.1 GB |
| `cit-Patents`    |   3.8 M  | 16 M  | 0.4 GB |
| `datagen-7_5-fb` |   633 K  | 34 M  | 0.7 GB |
| `datagen-7_9-fb` |   1.4 M  | 86 M  | 1.7 GB |
| `graph500-22`    |   2.4 M  | 64 M  | 1.3 GB |

LDBC ships each dataset as a tar with `<name>.v` (vertex file) and
`<name>.e` (edge file). Convert to FlowLog's `Arc.csv` + `Vertex.csv`
layout with:

```bash
# Edges: LDBC's .e file is space-delimited, sometimes 2-col, sometimes 3-col
awk '{ print $1 "," $2 }' dataset.e > Arc.csv
awk '{ print $1 }'        dataset.v > Vertex.csv
echo 30 > MaxIter.csv
```

LDBC validation outputs live alongside each dataset as
`<name>-PR.txt`, `<name>-LCC.txt`, `<name>-CDLP.txt`. The validation
files are floating-point; compare against FlowLog's integer-scaled output
by dividing FlowLog's `pr_scaled` / `lcc_scaled` columns by `10^9`.
