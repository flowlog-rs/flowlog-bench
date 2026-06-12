// Ascent translation of programs/oracle/souffle/crdt.dl (join order preserved)
// Negated atoms are placed immediately after the positive atoms that bind
// their variables (Ascent requires negation args to be bound); Soufflé treats
// them as filters anyway, so join order is unchanged.
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Crdt;

    relation insert_input(i32, i32, i32, i32);
    relation remove_input(i32, i32);

    relation insert(i32, i32, i32, i32);
    relation remove(i32, i32);
    relation haschild(i32, i32);
    relation assign(i32, i32, i32, i32, i32);

    relation laterchild(i32, i32, i32, i32);
    relation firstchild(i32, i32, i32, i32);
    relation sibling(i32, i32, i32, i32);
    relation latersibling(i32, i32, i32, i32);
    relation latersibling2(i32, i32, i32, i32);
    relation nextsibling(i32, i32, i32, i32);
    relation hasnextsibling(i32, i32);
    relation nextsiblinganc(i32, i32, i32, i32);
    relation nextelem(i32, i32, i32, i32);

    relation currentvalue(i32, i32, i32);
    relation hasvalue(i32, i32);
    relation valuestep(i32, i32, i32, i32);
    relation blankstep(i32, i32, i32, i32);
    relation value_blank_star(i32, i32, i32, i32);
    relation nextvisible(i32, i32, i32, i32);
    relation result(i32, i32, i32);

    insert(a, b, c, d) <-- insert_input(a, b, c, d);
    remove(a, b) <-- remove_input(a, b);
    assign(ctr, n, ctr, n, n) <-- insert(ctr, n, _, _);
    haschild(parentctr, parentn) <-- insert(_, _, parentctr, parentn);

    laterchild(parentctr, parentn, ctr2, n2) <--
        insert(ctr1, n1, parentctr, parentn),
        insert(ctr2, n2, parentctr, parentn),
        if ctr1 * 10 + n1 > ctr2 * 10 + n2;

    firstchild(parentctr, parentn, childctr, childn) <--
        insert(childctr, childn, parentctr, parentn),
        !laterchild(parentctr, parentn, childctr, childn);

    sibling(childctr1, childn1, childctr2, childn2) <--
        insert(childctr1, childn1, parentctr, parentn),
        insert(childctr2, childn2, parentctr, parentn);

    latersibling(ctr1, n1, ctr2, n2) <--
        sibling(ctr1, n1, ctr2, n2),
        if ctr1 * 10 + n1 > ctr2 * 10 + n2;

    latersibling2(ctr1, n1, ctr3, n3) <--
        sibling(ctr1, n1, ctr2, n2),
        sibling(ctr1, n1, ctr3, n3),
        if ctr1 * 10 + n1 > ctr2 * 10 + n2,
        if ctr2 * 10 + n2 > ctr3 * 10 + n3;

    nextsibling(ctr1, n1, ctr2, n2) <--
        latersibling(ctr1, n1, ctr2, n2),
        !latersibling2(ctr1, n1, ctr2, n2);

    hasnextsibling(sibctr1, sibn1) <-- latersibling(sibctr1, sibn1, _, _);

    nextsiblinganc(startctr, startn, nextctr, nextn) <--
        nextsibling(startctr, startn, nextctr, nextn);
    // Soufflé body order: !hasNextSibling first; moved after the binding atom.
    nextsiblinganc(startctr, startn, nextctr, nextn) <--
        insert(startctr, startn, parentctr, parentn),
        !hasnextsibling(startctr, startn),
        nextsiblinganc(parentctr, parentn, nextctr, nextn);

    nextelem(prevctr, prevn, nextctr, nextn) <--
        firstchild(prevctr, prevn, nextctr, nextn);
    // Soufflé body order: !hasChild first; moved after the binding atom.
    nextelem(prevctr, prevn, nextctr, nextn) <--
        nextsiblinganc(prevctr, prevn, nextctr, nextn),
        !haschild(prevctr, prevn);

    currentvalue(elemctr, elemn, value) <--
        assign(idctr, idn, elemctr, elemn, value),
        !remove(idctr, idn);

    hasvalue(elemctr, elemn) <-- currentvalue(elemctr, elemn, _);
    valuestep(fromctr, fromn, toctr, ton) <--
        hasvalue(fromctr, fromn),
        nextelem(fromctr, fromn, toctr, ton);
    // Soufflé body order: !valueStep first; moved after the binding atom.
    blankstep(fromctr, fromn, toctr, ton) <--
        nextelem(fromctr, fromn, toctr, ton),
        !valuestep(fromctr, fromn, toctr, ton);

    value_blank_star(fromctr, fromn, toctr, ton) <--
        valuestep(fromctr, fromn, toctr, ton);
    value_blank_star(fromctr, fromn, toctr, ton) <--
        value_blank_star(fromctr, fromn, viactr, vian),
        blankstep(viactr, vian, toctr, ton);

    nextvisible(prevctr, prevn, nextctr, nextn) <--
        value_blank_star(prevctr, prevn, nextctr, nextn),
        hasvalue(nextctr, nextn);

    result(ctr1, ctr2, value) <--
        nextvisible(ctr1, _, ctr2, n2),
        currentvalue(ctr2, n2, value);
}

fn main() {
    let dir = bench_init();
    let mut prog = Crdt::default();
    timed_load(|| {
        prog.insert_input = load_rel(&dir, "Insert_input.csv", ',');
        prog.remove_input = load_rel(&dir, "Remove_input.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("nextSiblingAnc", prog.nextsiblinganc.len());
    printsize("currentValue", prog.currentvalue.len());
    printsize("hasValue", prog.hasvalue.len());
    printsize("valueStep", prog.valuestep.len());
    printsize("blankStep", prog.blankstep.len());
    printsize("value_blank_star", prog.value_blank_star.len());
    printsize("nextVisible", prog.nextvisible.len());
    printsize("result", prog.result.len());
}
