// Ascent translation of programs/oracle/souffle/andersen.dl (join order preserved)
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Andersen;

    relation addressof(i32, i32);
    relation assign(i32, i32);
    relation load(i32, i32);
    relation store(i32, i32);
    relation pointsto(i32, i32);

    pointsto(y, x) <-- addressof(y, x);
    pointsto(y, x) <-- assign(y, z), pointsto(z, x);
    pointsto(y, w) <-- load(y, x), pointsto(x, z), pointsto(z, w);
    pointsto(z, w) <-- store(y, x), pointsto(y, z), pointsto(x, w);
}

fn main() {
    let dir = bench_init();
    let mut prog = Andersen::default();
    timed_load(|| {
        prog.addressof = load_rel(&dir, "addressOf.csv", ',');
        prog.assign = load_rel(&dir, "assign.csv", ',');
        prog.load = load_rel(&dir, "load.csv", ',');
        prog.store = load_rel(&dir, "store.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("PointsTo", prog.pointsto.len());
}
