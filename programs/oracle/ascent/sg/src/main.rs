// Ascent translation of programs/oracle/souffle/sg.dl (join order preserved)
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Sg;

    relation arc(i32, i32);
    relation sg(i32, i32);

    sg(x, y) <-- arc(a, x), arc(a, y), if x != y;
    sg(x, y) <-- arc(a, x), sg(a, b), arc(b, y);
}

fn main() {
    let dir = bench_init();
    let mut prog = Sg::default();
    timed_load(|| {
        prog.arc = load_rel(&dir, "Arc.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("Sg", prog.sg.len());
}
