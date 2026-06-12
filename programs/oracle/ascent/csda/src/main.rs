// Ascent translation of programs/oracle/souffle/csda.dl (join order preserved)
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Csda;

    relation nulledge(i32, i32);
    relation edge(i32, i32);
    relation nullnode(i32, i32);

    nullnode(x, y) <-- nulledge(x, y);
    nullnode(x, y) <-- nullnode(x, w), edge(w, y);
}

fn main() {
    let dir = bench_init();
    let mut prog = Csda::default();
    timed_load(|| {
        prog.nulledge = load_rel(&dir, "NullEdge.csv", ',');
        prog.edge = load_rel(&dir, "Edge.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("NullNode", prog.nullnode.len());
}
