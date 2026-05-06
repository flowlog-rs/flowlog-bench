# programs/micro/flowlog/

FlowLog (`.dl`) implementations of every benchmark program in
`config/default.txt` and `config/ldbc.txt`. These are the canonical inputs
to `scripts/cross_engine.sh` and `scripts/bench_one.sh`; the
`Compiler_*` / `Lib_*` / `Interpreter_*` columns in the perf CSV are all
measured against files in this tree.

## Naming

Every config entry is `<subdir>/<stem>.dl=<dataset>`, and the filename
in the entry resolves directly under this directory. For example,
`program_analysis/eclipse.dl=eclipse` reaches for
`programs/micro/flowlog/program_analysis/eclipse.dl`.

The three subdirectories partition programs by analysis flavour:

| Subdirectory             | Coverage                                                        |
|--------------------------|------------------------------------------------------------------|
| `graph_analysis/`        | Reachability, transitive closure, same-generation, sssp, etc.   |
| `knowledge_reasoning/`   | OWL-style reasoning (Galen) + CRDT replay.                      |
| `program_analysis/`      | Andersen / context-sensitive points-to + Doop / Polonius shapes. |

## Programs not yet referenced from the configs

A few `.dl` files are present but not listed in `config/default.txt` or
`config/ldbc.txt`. They are kept for two reasons:

1. **Future config additions** — points-to and Polonius variants we may
   want to fold into the regular sweep once matching corpora and Soufflé
   counterparts are in place.
2. **Cross-engine pairing** — `pointsto.dl` and `crdt_slow.dl` exist as
   FlowLog counterparts to `programs/micro/souffle/pointsto.dl` and
   `programs/micro/souffle/crdt_slow.dl`, so a future config row gets a
   matched pair on day one.

| File                                  | Origin / purpose                                                                                  |
|---------------------------------------|---------------------------------------------------------------------------------------------------|
| `program_analysis/doop.dl`            | Doop-style points-to analysis (646 LOC). Heavy program reserved for stress-testing the harness.   |
| `program_analysis/polonius.dl`        | Polonius borrow-checker (205 LOC). Also used by the parent flowlog repo's correctness oracle (`tests/oracle/config_string.txt=clap`); kept here for future perf coverage. |
| `program_analysis/pointsto.dl`        | Minimal points-to analysis (35 LOC). Pairs with `souffle/pointsto.dl`.                            |
| `knowledge_reasoning/crdt_slow.dl`    | Slow variant of `crdt.dl` (133 LOC). Pairs with `souffle/crdt_slow.dl`; useful for timing-harness validation. |

If you decide one of these is dead weight, removing it is safe — it
just narrows the harness's coverage for that particular pattern. If you
remove one, also drop the matching `.dl` (if any) from
`programs/micro/souffle/` and update that side's README.

## Asymmetry to be aware of

`programs/micro/souffle/borrow.dl` exists with no FlowLog counterpart
here. The Soufflé side documents it as a placeholder for a future
borrow-checker benchmark; the matching FlowLog program needs to be
authored before that row can land in `config/default.txt`.
