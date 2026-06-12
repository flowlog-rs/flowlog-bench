// Ascent translation of programs/oracle/souffle/dyck.dl (join order preserved)
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Dyck;

    relation arc(i32, i32, i32);
    relation zero(i32, i32);
    relation one(i32, i32);
    relation dyck(i32, i32);

    zero(x, y) <-- arc(x, y, 0);
    one(x, y) <-- arc(x, y, 1);

    dyck(x, y) <-- zero(x, z), zero(z, y);
    dyck(x, y) <-- one(x, z), one(z, y);
    dyck(x, y) <-- zero(x, z), dyck(z, w), zero(w, y);
    dyck(x, y) <-- one(x, z), dyck(z, w), one(w, y);
    dyck(x, y) <-- dyck(x, z), dyck(z, y);
}

fn main() {
    let dir = bench_init();
    let mut prog = Dyck::default();
    timed_load(|| {
        prog.arc = load_rel(&dir, "Arc.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("Zero", prog.zero.len());
    printsize("One", prog.one.len());
    printsize("Dyck", prog.dyck.len());
}
