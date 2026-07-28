// Ascent translation of programs/oracle/flowlog/cc/default.dl (join order
// preserved). No Soufflé counterpart: cc needs min-aggregation inside the
// recursion, which Soufflé can't stratify — Ascent's Dual<i32> lattice (join
// = min) expresses it directly, mirroring FlowLog's recursive min().
// inputs (csv -> relation): Arc.csv -> arc
// sizes (printsize): cc   (lattice keeps one row per node = FlowLog's
//                          one (node, min) group per node)
use ascent::ascent_par;
use ascent::Dual;
use harness::*;

ascent_par! {
    struct Cc;

    relation arc(i32, i32);
    lattice cc(i32, Dual<i32>);

    // CC(node, min(node)) :- Arc(node, _).
    cc(node, Dual(*node)) <-- arc(node, _);
    // CC(node, min(cc)) :- Arc(other, node), CC(other, cc).
    cc(node, Dual(c.0)) <-- arc(other, node), cc(other, c);
}

fn main() {
    let dir = bench_init();
    let mut prog = Cc::default();
    timed_load(|| {
        prog.arc = load_rel(&dir, "Arc.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("CC", prog.cc.len());
}
