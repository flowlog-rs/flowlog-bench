# Ascent translations of the oracle suite

[Ascent](https://github.com/s-arash/ascent) is Datalog embedded in Rust via a
proc-macro — it has **no I/O of its own**: a relation is a plain
`Vec<(T, ...)>` field on the macro-generated struct. The shared `harness`
crate owns all fact-reading/timing/printsize logic, so each program is just
the `ascent_par!` rules plus one type-free `load_rel` line per input relation
(column types are inferred from the relation declaration, the way Soufflé's
`.input` directive is schema-driven).

## Layout

- `harness/` — generic CSV loader (`load_rel`, delimiter per Soufflé
  `.input`), global string interner (`IStr`, u32 key; `sym`/`res`),
  `bench_init` (fact dir from argv[1], rayon pool from `$WORKERS`),
  `timed_load` / `timed_run`, `printsize`.
- `<stem>/` — one bin crate per `programs/oracle/souffle/<stem>.dl`,
  translated with join order preserved.

## Build / run

```sh
cargo build --release -p <stem>          # ~30 s for the whole workspace
WORKERS=8 target/release/<stem> <fact_dir>
```

Output contract — deliberately mirrors FlowLog's log lines so
`scripts/lib/measure.sh` extracts both engines identically:

```
Data loaded for all inputs: <secs>s   # extract_load_seconds
Dataflow executed in <secs>s          # extract_total_seconds (= load + run)
<relation>\t<size>                    # one line per .printsize, lowercased
```

(exec = total − load via the existing compute_exec_seconds, same as FlowLog.)

## Translation conventions

- Relation names: Soufflé name lowercased verbatim (`Method_SimpleName` →
  `method_simplename`).
- Rule order and body atom order preserved exactly — join order is what the
  suite benchmarks. One exception: Ascent requires variables of a negated
  atom to be bound by *earlier* clauses, so a negation that Soufflé places
  before its binding atom moves directly after it (commented at each site;
  Soufflé schedules negations as filters, so this is order-neutral).
- `symbol` → `IStr` (interned u32 — the apples-to-apples choice: FlowLog runs
  `--str-intern`, the DDlog translation uses `istring`); `number` → `i32`.
- `cat(a, b)` → `sym(&format!(...))`; string constants → `sym("...")`;
  `v = const` equality constraints fold into the atom or an `if` clause.
- Rust keywords in variable names get renamed (`return` → `ret`, `type` →
  `type_`, `super` → `super_`).

## cc / sssp (no Soufflé counterpart)

`cc` and `sssp` need min-aggregation *inside* the recursion, which Soufflé
cannot stratify (the suite tags them `[souffle:skip]`/`[ddlog:skip]`). Ascent
expresses them directly with `lattice` relations over `Dual<i32>` (lattice
join = min), translated from `programs/oracle/flowlog/{cc,sssp}/default.dl`.

## Verified against FlowLog (exact size matches, full-pipeline crosscheck)

Every crate is size-crosschecked against the FlowLog compiler by
`scripts/cross_engine.sh` on each run. The 2026-06-11 four-engine sweep
(54 program×dataset pairs, `docs/historical/splash_demo/`)
crosschecked clean on all pairs — e.g. tc + G5K-0.001 `tc` = 24,730,729,
galen `p` = 7,560,179 / `q` = 16,595,494, doop × 20 DaCapo apps `match(26)`
each, cc/sssp on livejournal/orkut/arabic vs FlowLog's recursive `min()`.
