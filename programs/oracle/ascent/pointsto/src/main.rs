// Ascent translation of programs/oracle/souffle/pointsto.dl (join order preserved)
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Pointsto;

    relation assignalloc(i32, i32);
    relation primitiveassign(i32, i32);
    relation load(i32, i32, i32);
    relation store(i32, i32, i32);
    relation varpointsto(i32, i32);
    relation alias(i32, i32);
    relation assign(i32, i32);

    assign(var1, var2) <-- primitiveassign(var1, var2);

    alias(instancevar, ivar) <--
        varpointsto(instancevar, instanceheap),
        varpointsto(ivar, instanceheap);

    varpointsto(var, heap) <-- assignalloc(var, heap);

    varpointsto(var1, heap) <--
        assign(var2, var1),
        varpointsto(var2, heap);

    assign(var1, var2) <--
        store(var1, instancevar2, field),
        alias(instancevar2, instancevar1),
        load(instancevar1, var2, field);
}

fn main() {
    let dir = bench_init();
    let mut prog = Pointsto::default();
    timed_load(|| {
        prog.assignalloc = load_rel(&dir, "AssignAlloc.csv", ',');
        prog.primitiveassign = load_rel(&dir, "PrimitiveAssign.csv", ',');
        prog.load = load_rel(&dir, "Load.csv", ',');
        prog.store = load_rel(&dir, "Store.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("Assign", prog.assign.len());
}
