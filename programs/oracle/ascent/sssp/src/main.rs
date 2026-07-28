// Ascent translation of programs/oracle/flowlog/sssp/default.dl (join order
// preserved). No Soufflé counterpart: sssp needs min-aggregation inside the
// recursion — Ascent's Dual<i32> lattice (join = min) expresses FlowLog's
// recursive min() directly. Distances stay i32 like FlowLog's int32 d1+d2.
// inputs (csv -> relation): Arc.csv -> arc, Id.csv -> id
// sizes (printsize): sssp
use ascent::ascent_par;
use ascent::Dual;
use harness::*;

ascent_par! {
    struct Sssp;

    relation arc(i32, i32, i32);
    relation id(i32);
    lattice sssp(i32, Dual<i32>);

    // sssp(x, min(0)) :- id(x).
    sssp(x, Dual(0)) <-- id(x);
    // sssp(y, min(d1 + d2)) :- sssp(x, d1), arc(x, y, d2).
    sssp(y, Dual(d.0 + *w)) <-- sssp(x, d), arc(x, y, w);
}

fn main() {
    let dir = bench_init();
    let mut prog = Sssp::default();
    timed_load(|| {
        prog.arc = load_rel(&dir, "Arc.csv", ',');
        prog.id = load_rel(&dir, "Id.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("sssp", prog.sssp.len());
}
