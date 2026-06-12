// Ascent translation of programs/oracle/souffle/galen.dl (join order preserved)
// Soufflé's ?x variables become plain x.
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Galen;

    relation p(i32, i32);
    relation q(i32, i32, i32);
    relation r(i32, i32, i32);
    relation c(i32, i32, i32);
    relation u(i32, i32, i32);
    relation s(i32, i32);

    p(x, z) <-- p(x, y), p(y, z);
    q(x, r_, z) <-- p(x, y), q(y, r_, z);
    p(x, z) <-- p(y, w), u(w, r_, z), q(x, r_, y);
    p(x, z) <-- c(y, w, z), p(x, w), p(x, y);
    q(x, q_, z) <-- q(x, r_, z), s(r_, q_);
    q(x, e, o) <-- q(x, y, z), r(y, u_, e), q(z, u_, o);
}

fn main() {
    let dir = bench_init();
    let mut prog = Galen::default();
    timed_load(|| {
        prog.p = load_rel(&dir, "P.csv", ',');
        prog.q = load_rel(&dir, "Q.csv", ',');
        prog.r = load_rel(&dir, "R.csv", ',');
        prog.c = load_rel(&dir, "C.csv", ',');
        prog.u = load_rel(&dir, "U.csv", ',');
        prog.s = load_rel(&dir, "S.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("P", prog.p.len());
    printsize("Q", prog.q.len());
}
