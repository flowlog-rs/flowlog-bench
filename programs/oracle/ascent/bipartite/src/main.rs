// Ascent translation of programs/oracle/souffle/bipartite.dl (join order preserved)
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Bipartite;

    relation arc(i32, i32);
    relation source(i32);
    relation bipartiteviolation(i32);
    relation zero(i32);
    relation one(i32);

    zero(x) <-- source(x);

    one(y) <-- arc(x, y), zero(x);
    one(x) <-- arc(x, y), zero(y);

    zero(y) <-- arc(x, y), one(x);
    zero(x) <-- arc(x, y), one(y);

    bipartiteviolation(x) <-- one(x), zero(x);
}

fn main() {
    let dir = bench_init();
    let mut prog = Bipartite::default();
    timed_load(|| {
        prog.arc = load_rel(&dir, "Arc.csv", ',');
        prog.source = load_rel(&dir, "Source.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("BipartiteViolation", prog.bipartiteviolation.len());
    printsize("Zero", prog.zero.len());
    printsize("One", prog.one.len());
}
