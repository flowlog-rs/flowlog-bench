// Ascent translation of programs/oracle/souffle/cspa.dl (join order preserved)
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Cspa;

    relation assign(i32, i32);
    relation dereference(i32, i32);
    relation valueflow(i32, i32);
    relation memoryalias(i32, i32);
    relation valuealias(i32, i32);

    valueflow(y, x) <-- assign(y, x);
    valueflow(x, y) <-- assign(x, z), memoryalias(z, y);
    valueflow(x, y) <-- valueflow(x, z), valueflow(z, y);
    memoryalias(x, w) <-- dereference(y, x), valuealias(y, z), dereference(z, w);
    valuealias(x, y) <-- valueflow(z, x), valueflow(z, y);
    valuealias(x, y) <-- valueflow(z, x), memoryalias(z, w), valueflow(w, y);
    valueflow(x, x) <-- assign(x, y);
    valueflow(x, x) <-- assign(y, x);
    memoryalias(x, x) <-- assign(y, x);
    memoryalias(x, x) <-- assign(x, y);
}

fn main() {
    let dir = bench_init();
    let mut prog = Cspa::default();
    timed_load(|| {
        prog.assign = load_rel(&dir, "Assign.csv", ',');
        prog.dereference = load_rel(&dir, "Dereference.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("ValueFlow", prog.valueflow.len());
}
