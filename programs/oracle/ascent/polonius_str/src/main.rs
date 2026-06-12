// Ascent translation of programs/oracle/souffle/polonius_str.dl (join order preserved)
// borrow/src/main.rs is this same program (borrow.dl == polonius_str.dl);
// polonius_str/src/main.rs is this program with interned IStr columns.
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Polonius;

    relation subset_base(IStr, IStr, IStr);
    relation cfg_edge(IStr, IStr);
    relation loan_issued_at(IStr, IStr, IStr);
    relation universal_region(IStr);
    relation var_used_at(IStr, IStr);
    relation loan_killed_at(IStr, IStr);
    relation known_placeholder_subset(IStr, IStr);
    relation var_dropped_at(IStr, IStr);
    relation drop_of_var_derefs_origin(IStr, IStr);
    relation var_defined_at(IStr, IStr);
    relation child_path(IStr, IStr);
    relation path_moved_at_base(IStr, IStr);
    relation path_assigned_at_base(IStr, IStr);
    relation path_accessed_at_base(IStr, IStr);
    relation path_is_var(IStr, IStr);
    relation loan_invalidated_at(IStr, IStr);
    relation use_of_var_derefs_origin(IStr, IStr);

    relation subset(IStr, IStr, IStr);
    relation origin_live_on_entry(IStr, IStr);
    relation origin_contains_loan_on_entry(IStr, IStr, IStr);
    relation loan_live_at(IStr, IStr);
    relation errors(IStr, IStr);
    relation placeholder_origin(IStr);
    relation subset_error(IStr, IStr, IStr);
    relation var_maybe_partly_initialized_on_exit(IStr, IStr);
    relation var_maybe_partly_initialized_on_entry(IStr, IStr);
    relation var_live_on_entry(IStr, IStr);
    relation ancestor_path(IStr, IStr);
    relation path_moved_at(IStr, IStr);
    relation path_assigned_at(IStr, IStr);
    relation path_accessed_at(IStr, IStr);
    relation path_begins_with_var(IStr, IStr);
    relation path_maybe_initialized_on_exit(IStr, IStr);
    relation path_maybe_uninitialized_on_exit(IStr, IStr);
    relation move_error(IStr, IStr);
    relation cfg_node(IStr);
    relation var_drop_live_on_entry(IStr, IStr);

    // basic
    subset(origin1, origin2, point) <-- subset_base(origin1, origin2, point);
    origin_contains_loan_on_entry(origin, loan, point) <-- loan_issued_at(loan, origin, point);
    placeholder_origin(origin) <-- universal_region(origin);
    known_placeholder_subset(x, z) <--
        known_placeholder_subset(x, y),
        known_placeholder_subset(y, z);
    subset(origin1, origin3, point) <--
        subset(origin1, origin2, point),
        subset_base(origin2, origin3, point),
        if origin1 != origin3;
    subset(origin1, origin2, point2) <--
        subset(origin1, origin2, point1),
        cfg_edge(point1, point2),
        origin_live_on_entry(origin1, point2),
        origin_live_on_entry(origin2, point2);
    origin_contains_loan_on_entry(origin2, loan, point) <--
        origin_contains_loan_on_entry(origin1, loan, point),
        subset(origin1, origin2, point);
    origin_contains_loan_on_entry(origin, loan, point2) <--
        origin_contains_loan_on_entry(origin, loan, point1),
        cfg_edge(point1, point2),
        !loan_killed_at(loan, point1),
        origin_live_on_entry(origin, point2);
    loan_live_at(loan, point) <--
        origin_contains_loan_on_entry(origin, loan, point),
        origin_live_on_entry(origin, point);
    errors(loan, point) <--
        loan_invalidated_at(loan, point),
        loan_live_at(loan, point);
    subset_error(origin1, origin2, point) <--
        subset(origin1, origin2, point),
        placeholder_origin(origin1),
        placeholder_origin(origin2),
        !known_placeholder_subset(origin1, origin2),
        if origin1 != origin2;
    // make_universal_regions_live (liveness.rs)
    origin_live_on_entry(origin, point) <--
        cfg_node(point),
        universal_region(origin);
    // populating cfg_node (output/mod.rs)
    cfg_node(point1) <-- cfg_edge(point1, _);
    cfg_node(point2) <-- cfg_edge(_, point2);
    // liveness logic (liveness.rs)
    var_live_on_entry(var, point) <-- var_used_at(var, point);
    var_maybe_partly_initialized_on_entry(var, point2) <--
        var_maybe_partly_initialized_on_exit(var, point1),
        cfg_edge(point1, point2);
    var_drop_live_on_entry(var, point) <--
        var_dropped_at(var, point),
        var_maybe_partly_initialized_on_entry(var, point);
    origin_live_on_entry(origin, point) <--
        var_drop_live_on_entry(var, point),
        drop_of_var_derefs_origin(var, origin);
    origin_live_on_entry(origin, point) <--
        var_live_on_entry(var, point),
        use_of_var_derefs_origin(var, origin);
    var_live_on_entry(var, point1) <--
        var_live_on_entry(var, point2),
        cfg_edge(point1, point2),
        !var_defined_at(var, point1);
    var_drop_live_on_entry(var, sourcenode) <--
        var_drop_live_on_entry(var, targetnode),
        cfg_edge(sourcenode, targetnode),
        !var_defined_at(var, sourcenode),
        var_maybe_partly_initialized_on_exit(var, sourcenode);
    // initialization logic (initialization.rs)
    // Step 1: compute transitive closures of path operations
    ancestor_path(x, y) <-- child_path(x, y);
    path_moved_at(x, y) <-- path_moved_at_base(x, y);
    path_assigned_at(x, y) <-- path_assigned_at_base(x, y);
    path_accessed_at(x, y) <-- path_accessed_at_base(x, y);
    path_begins_with_var(x, var) <-- path_is_var(x, var);
    ancestor_path(grandparent, child) <--
        ancestor_path(parent, child),
        child_path(parent, grandparent);
    path_moved_at(child, point) <--
        path_moved_at(parent, point),
        ancestor_path(parent, child);
    path_assigned_at(child, point) <--
        path_assigned_at(parent, point),
        ancestor_path(parent, child);
    path_accessed_at(child, point) <--
        path_accessed_at(parent, point),
        ancestor_path(parent, child);
    path_begins_with_var(child, var) <--
        path_begins_with_var(parent, var),
        ancestor_path(parent, child);
    // Step 2: Compute path initialization and deinitialization across the CFG.
    path_maybe_initialized_on_exit(path, point) <-- path_assigned_at(path, point);
    path_maybe_uninitialized_on_exit(path, point) <-- path_moved_at(path, point);
    path_maybe_initialized_on_exit(path, point2) <--
        path_maybe_initialized_on_exit(path, point1),
        cfg_edge(point1, point2),
        !path_moved_at(path, point2);
    path_maybe_uninitialized_on_exit(path, point2) <--
        path_maybe_uninitialized_on_exit(path, point1),
        cfg_edge(point1, point2),
        !path_assigned_at(path, point2);
    var_maybe_partly_initialized_on_exit(var, point) <--
        path_maybe_initialized_on_exit(path, point),
        path_begins_with_var(path, var);
    move_error(path, targetnode) <--
        path_maybe_uninitialized_on_exit(path, sourcenode),
        cfg_edge(sourcenode, targetnode);
}

fn main() {
    let dir = bench_init();
    let mut prog = Polonius::default();
    timed_load(|| {
        prog.subset_base = load_rel(&dir, "subset_base.csv", ',');
        prog.cfg_edge = load_rel(&dir, "cfg_edge.csv", ',');
        prog.loan_issued_at = load_rel(&dir, "loan_issued_at.csv", ',');
        prog.universal_region = load_rel(&dir, "universal_region.csv", ',');
        prog.var_used_at = load_rel(&dir, "var_used_at.csv", ',');
        prog.loan_killed_at = load_rel(&dir, "loan_killed_at.csv", ',');
        prog.known_placeholder_subset = load_rel(&dir, "known_placeholder_subset.csv", ',');
        prog.var_dropped_at = load_rel(&dir, "var_dropped_at.csv", ',');
        prog.drop_of_var_derefs_origin = load_rel(&dir, "drop_of_var_derefs_origin.csv", ',');
        prog.var_defined_at = load_rel(&dir, "var_defined_at.csv", ',');
        prog.child_path = load_rel(&dir, "child_path.csv", ',');
        prog.path_moved_at_base = load_rel(&dir, "path_moved_at_base.csv", ',');
        prog.path_assigned_at_base = load_rel(&dir, "path_assigned_at_base.csv", ',');
        prog.path_accessed_at_base = load_rel(&dir, "path_accessed_at_base.csv", ',');
        prog.path_is_var = load_rel(&dir, "path_is_var.csv", ',');
        prog.loan_invalidated_at = load_rel(&dir, "loan_invalidated_at.csv", ',');
        prog.use_of_var_derefs_origin = load_rel(&dir, "use_of_var_derefs_origin.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("subset", prog.subset.len());
    printsize("origin_live_on_entry", prog.origin_live_on_entry.len());
    printsize("origin_contains_loan_on_entry", prog.origin_contains_loan_on_entry.len());
    printsize("loan_live_at", prog.loan_live_at.len());
    printsize("errors", prog.errors.len());
    printsize("placeholder_origin", prog.placeholder_origin.len());
    printsize("subset_error", prog.subset_error.len());
    printsize("var_maybe_partly_initialized_on_exit", prog.var_maybe_partly_initialized_on_exit.len());
    printsize("var_maybe_partly_initialized_on_entry", prog.var_maybe_partly_initialized_on_entry.len());
    printsize("var_live_on_entry", prog.var_live_on_entry.len());
    printsize("ancestor_path", prog.ancestor_path.len());
    printsize("path_moved_at", prog.path_moved_at.len());
    printsize("path_assigned_at", prog.path_assigned_at.len());
    printsize("path_accessed_at", prog.path_accessed_at.len());
    printsize("path_begins_with_var", prog.path_begins_with_var.len());
    printsize("path_maybe_initialized_on_exit", prog.path_maybe_initialized_on_exit.len());
    printsize("path_maybe_uninitialized_on_exit", prog.path_maybe_uninitialized_on_exit.len());
    printsize("move_error", prog.move_error.len());
    printsize("cfg_node", prog.cfg_node.len());
    printsize("var_drop_live_on_entry", prog.var_drop_live_on_entry.len());
}
