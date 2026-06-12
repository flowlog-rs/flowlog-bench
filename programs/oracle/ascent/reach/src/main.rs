// Ascent translation of programs/oracle/souffle/reach.dl (join order preserved)
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Reach;

    relation source(i32);
    relation arc(i32, i32);
    relation reach(i32);

    reach(y) <-- source(y);
    reach(y) <-- reach(x), arc(x, y);
}

fn main() {
    let dir = bench_init();
    let mut prog = Reach::default();
    timed_load(|| {
        prog.source = load_rel(&dir, "Source.csv", ',');
        prog.arc = load_rel(&dir, "Arc.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("Reach", prog.reach.len());
}
