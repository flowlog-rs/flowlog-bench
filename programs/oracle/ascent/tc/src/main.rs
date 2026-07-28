// Ascent translation of programs/oracle/souffle/tc.dl (join order preserved)
// inputs (csv -> relation): Arc.csv -> arc
// sizes (printsize): tc
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Tc;

    relation arc(i32, i32);
    relation tc(i32, i32);

    tc(x, y) <-- arc(x, y);
    tc(x, y) <-- tc(x, z), arc(z, y);
}

fn main() {
    let dir = bench_init();
    let mut prog = Tc::default();
    timed_load(|| {
        prog.arc = load_rel(&dir, "Arc.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("Tc", prog.tc.len());
}
