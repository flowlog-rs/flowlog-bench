// Ascent translation of programs/oracle/souffle/z3.dl (join order preserved)
// cvc5/src/main.rs is the same program with different magic constants.
// Notes:
//  - Soufflé `Type = <const>` equality constraints are folded into the atom
//    args (binding is identical).
//  - Negated atoms whose vars are bound only by a LATER positive atom are
//    moved after that atom (Ascent requires negation args bound); Soufflé
//    schedules them as filters, so the join order is unchanged.
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Ddisasm;

    relation arch_memory_access(i32, i32, i32, i32, i32, i32);
    relation arch_reg_reg_arithmetic_operation(i32, i32, i32, i32, i32, i32);
    relation arch_return_reg(i32);
    relation block_next(i32, i32, i32);
    relation block_last_instruction(i32, i32);
    relation code_in_block(i32, i32);
    relation direct_call(i32, i32);
    relation may_fallthrough(i32, i32);
    relation reg_def_use_block_last_def(i32, i32, i32);
    relation reg_def_use_defined_in_block(i32, i32);
    relation reg_def_use_flow_def(i32, i32, i32, i32);
    relation reg_def_use_live_var_def(i32, i32, i32, i32);
    relation reg_def_use_ref_in_block(i32, i32);
    relation reg_def_use_return_block_end(i32, i32, i32, i32);
    relation reg_def_use_used(i32, i32, i32);
    relation reg_def_use_used_in_block(i32, i32, i32, i32);
    relation reg_used_for(i32, i32, i32);
    relation relative_jump_table_entry_candidate(i32, i32, i32, i32, i32, i32, i32);
    relation stack_def_use_def(i32, i32, i32);
    relation stack_def_use_defined_in_block(i32, i32, i32);
    relation stack_def_use_live_var_def(i32, i32, i32, i32, i32, i32);
    relation stack_def_use_ref_in_block(i32, i32, i32);
    relation stack_def_use_used_in_block(i32, i32, i32, i32, i32);
    relation stack_def_use_used(i32, i32, i32, i32);
    relation stack_def_use_live_var_used(i32, i32, i32, i32, i32, i32, i32, i32);
    relation jump_table_start(i32, i32, i32, i32, i32);
    relation def_used_for_address_0(i32, i32, i32);
    relation stack_def_use_block_last_def(i32, i32, i32, i32);

    relation stack_def_use_def_used(i32, i32, i32, i32, i32, i32);
    relation reg_def_use_return_val_used(i32, i32, i32, i32, i32);
    relation reg_def_use_live_var_used(i32, i32, i32, i32);
    relation jump_table_target(i32, i32);
    relation reg_def_use_def_used(i32, i32, i32, i32);
    relation reg_def_use_live_var_at_prior_used(i32, i32, i32);
    relation reg_def_use_live_var_at_block_end(i32, i32, i32);
    relation reg_reg_arithmetic_operation_defs(i32, i32, i32, i32, i32, i32, i32, i32);
    relation def_used_for_address(i32, i32, i32);
    relation stack_def_use_live_var_at_block_end(i32, i32, i32, i32);
    relation stack_def_use_live_var_at_prior_used(i32, i32, i32, i32);

    ////////// Jump_table_target
    jump_table_target(ea, dest) <--
        jump_table_start(ea, size, tablestart, _, _),
        relative_jump_table_entry_candidate(_, tablestart, size, _, dest, _, _);

    ////////// Reg_def_use_def_used
    reg_def_use_def_used(ea_def, var, ea_used, index) <--
        reg_def_use_used(ea_used, var, index),
        reg_def_use_block_last_def(ea_used, ea_def, var);

    reg_def_use_def_used(ea_def, varidentity, ea_used, index) <--
        reg_def_use_live_var_at_block_end(block, blockused, var),
        reg_def_use_live_var_def(block, varidentity, var, ea_def),
        reg_def_use_live_var_used(blockused, var, ea_used, index);

    reg_def_use_def_used(ea_def, var, next_ea_used, nextindex) <--
        reg_def_use_live_var_at_prior_used(ea_used, nextusedblock, var),
        reg_def_use_def_used(ea_def, var, ea_used, _),
        reg_def_use_live_var_used(nextusedblock, var, next_ea_used, nextindex);

    reg_def_use_def_used(ea_def, reg, ea_used, index) <--
        reg_def_use_return_val_used(_, callee, reg, ea_used, index),
        reg_def_use_return_block_end(callee, _, _, blockend),
        reg_def_use_block_last_def(blockend, ea_def, reg);

    ////////// Reg_def_use_return_val_used
    reg_def_use_return_val_used(ea_call, callee, reg, ea_used, index_used) <--
        arch_return_reg(reg),
        reg_def_use_def_used(ea_call, reg, ea_used, index_used),
        direct_call(ea_call, callee);

    ////////// Reg_def_use_live_var_def
    reg_def_use_live_var_used(block, var, ea_used, index) <--
        reg_def_use_used_in_block(block, ea_used, var, index),
        !reg_def_use_block_last_def(ea_used, _, var);

    // Soufflé body order: negation before Reg_def_use_return_val_used; moved
    // after it (binds Reg).
    reg_def_use_live_var_used(retblock, reg, ea_used, index) <--
        reg_def_use_return_block_end(callee, _, retblock, retblockend),
        reg_def_use_return_val_used(_, callee, reg, ea_used, index),
        !reg_def_use_block_last_def(retblockend, _, reg);

    ////////// Reg_def_use_live_var_at_prior_used
    reg_def_use_live_var_at_prior_used(ea_used, blockused, var) <--
        reg_def_use_live_var_at_block_end(block, blockused, var),
        reg_def_use_used_in_block(block, ea_used, var, _),
        !reg_def_use_defined_in_block(block, var);

    ////////// Reg_def_use_live_var_at_block_end
    reg_def_use_live_var_at_block_end(prevblock, block, var) <--
        block_next(prevblock, prevblockend, block),
        reg_def_use_live_var_used(block, var, _, _),
        !reg_def_use_flow_def(prevblockend, var, block, _);

    reg_def_use_live_var_at_block_end(prevblock, blockused, var) <--
        reg_def_use_live_var_at_block_end(block, blockused, var),
        !reg_def_use_ref_in_block(block, var),
        block_next(prevblock, _, block);

    ////////// Reg_reg_arithmetic_operation_defs
    reg_reg_arithmetic_operation_defs(ea, reg_def, ea_def1, reg1, ea_def2, reg2, mult, offset) <--
        def_used_for_address(ea, reg_def, _),
        arch_reg_reg_arithmetic_operation(ea, reg_def, reg1, reg2, mult, offset),
        if reg1 != reg2,
        reg_def_use_def_used(ea_def1, reg1, ea, _),
        if ea != ea_def1,
        reg_def_use_def_used(ea_def2, reg2, ea, _),
        if ea != ea_def2;

    ////////// Def_used_for_address
    def_used_for_address(ea, reg, 8859592) <--
        def_used_for_address_0(ea, reg, 8859592);

    def_used_for_address(ea_def, reg, type_) <--
        reg_def_use_def_used(ea_def, reg, ea, _),
        reg_used_for(ea, reg, type_);

    def_used_for_address(ea_def, reg, type_) <--
        def_used_for_address(ea_used, _, type_),
        reg_def_use_def_used(ea_def, reg, ea_used, _);

    def_used_for_address(ea_def, reg1, type_) <--
        def_used_for_address(eaload, reg2, type_),
        arch_memory_access(0, eaload, reg2, regbaseload, 4, stackposload),
        stack_def_use_def_used(eastore, regbasestore, stackposstore, eaload, regbaseload, stackposload),
        arch_memory_access(2309374, eastore, reg1, regbasestore, 4, stackposstore),
        reg_def_use_def_used(ea_def, reg1, eastore, _);

    ////////// Stack_def_use_def_used
    stack_def_use_def_used(ea_def, varr, varp, ea_used, varr, varp) <--
        stack_def_use_used(ea_used, varr, varp, _),
        stack_def_use_block_last_def(ea_used, ea_def, varr, varp);

    stack_def_use_def_used(ea_def, defvarr, defvarp, ea_used, varusedr, varusedp) <--
        stack_def_use_live_var_at_block_end(block, blockused, varr, varp),
        stack_def_use_live_var_def(block, defvarr, defvarp, varr, varp, ea_def),
        stack_def_use_live_var_used(blockused, varr, varp, varusedr, varusedp, ea_used, _, _);

    stack_def_use_def_used(ea_def, defvarr, defvarp, ea_used, usedvarr, usedvarp) <--
        stack_def_use_live_var_used(ea, defvarr, defvarp, usedvarr, usedvarp, ea_used, _, _),
        may_fallthrough(ea_def, ea),
        code_in_block(ea_def, block),
        code_in_block(ea, block),
        stack_def_use_def(ea_def, defvarr, defvarp);

    stack_def_use_def_used(ea_def, vardefr, vardefp, next_ea_used, varusedr, varusedp) <--
        stack_def_use_live_var_at_prior_used(ea_used, nextusedblock, varr, varp),
        stack_def_use_def_used(ea_def, vardefr, vardefp, ea_used, varr, varp),
        stack_def_use_live_var_used(nextusedblock, varr, varp, varusedr, varusedp, next_ea_used, _, _);

    ////////// Stack_def_use_live_var_at_block_end
    stack_def_use_live_var_at_block_end(prevblock, blockused, inlined_basereg_374, inlined_stackpos_374) <--
        stack_def_use_live_var_at_block_end(block, blockused, inlined_basereg_374, inlined_stackpos_374),
        !stack_def_use_ref_in_block(block, inlined_basereg_374, inlined_stackpos_374),
        !reg_def_use_defined_in_block(block, inlined_basereg_374),
        block_next(prevblock, _, block);

    stack_def_use_live_var_at_block_end(prevblock, block, varr, varp) <--
        block_next(prevblock, _, block),
        stack_def_use_live_var_used(block, varr, varp, _, _, _, _, _);

    ////////// Stack_def_use_live_var_at_prior_used
    stack_def_use_live_var_at_prior_used(ea_used, blockused, inlined_basereg_375, inlined_stackpos_375) <--
        stack_def_use_live_var_at_block_end(block, blockused, inlined_basereg_375, inlined_stackpos_375),
        stack_def_use_used_in_block(block, ea_used, inlined_basereg_375, inlined_stackpos_375, _),
        !reg_def_use_defined_in_block(block, inlined_basereg_375),
        !stack_def_use_defined_in_block(block, inlined_basereg_375, inlined_stackpos_375);
}

fn main() {
    let dir = bench_init();
    let mut prog = Ddisasm::default();
    timed_load(|| {
        prog.arch_memory_access = load_rel(&dir, "Arch_memory_access_truncate.csv", ',');
        prog.arch_reg_reg_arithmetic_operation = load_rel(&dir, "Arch_reg_reg_arithmetic_operation.csv", ',');
        prog.arch_return_reg = load_rel(&dir, "Arch_return_reg.csv", ',');
        prog.block_next = load_rel(&dir, "Block_next.csv", ',');
        prog.block_last_instruction = load_rel(&dir, "Block_last_instruction.csv", ',');
        prog.code_in_block = load_rel(&dir, "Code_in_block.csv", ',');
        prog.direct_call = load_rel(&dir, "Direct_call.csv", ',');
        prog.may_fallthrough = load_rel(&dir, "May_fallthrough.csv", ',');
        prog.reg_def_use_block_last_def = load_rel(&dir, "Reg_def_use_block_last_def.csv", ',');
        prog.reg_def_use_defined_in_block = load_rel(&dir, "Reg_def_use_defined_in_block.csv", ',');
        prog.reg_def_use_flow_def = load_rel(&dir, "Reg_def_use_flow_def.csv", ',');
        prog.reg_def_use_live_var_def = load_rel(&dir, "Reg_def_use_live_var_def.csv", ',');
        prog.reg_def_use_ref_in_block = load_rel(&dir, "Reg_def_use_ref_in_block.csv", ',');
        prog.reg_def_use_return_block_end = load_rel(&dir, "Reg_def_use_return_block_end.csv", ',');
        prog.reg_def_use_used = load_rel(&dir, "Reg_def_use_used.csv", ',');
        prog.reg_def_use_used_in_block = load_rel(&dir, "Reg_def_use_used_in_block.csv", ',');
        prog.reg_used_for = load_rel(&dir, "Reg_used_for.csv", ',');
        prog.relative_jump_table_entry_candidate = load_rel(&dir, "Relative_jump_table_entry_candidate.csv", ',');
        prog.stack_def_use_def = load_rel(&dir, "Stack_def_use_def.csv", ',');
        prog.stack_def_use_defined_in_block = load_rel(&dir, "Stack_def_use_defined_in_block.csv", ',');
        prog.stack_def_use_live_var_def = load_rel(&dir, "Stack_def_use_live_var_def.csv", ',');
        prog.stack_def_use_ref_in_block = load_rel(&dir, "Stack_def_use_ref_in_block.csv", ',');
        prog.stack_def_use_used_in_block = load_rel(&dir, "Stack_def_use_used_in_block.csv", ',');
        prog.stack_def_use_used = load_rel(&dir, "Stack_def_use_used.csv", ',');
        prog.stack_def_use_live_var_used = load_rel(&dir, "Stack_def_use_live_var_used.csv", ',');
        prog.jump_table_start = load_rel(&dir, "Jump_table_start.csv", ',');
        prog.def_used_for_address_0 = load_rel(&dir, "Def_used_for_address.csv", ',');
        prog.stack_def_use_block_last_def = load_rel(&dir, "Stack_def_use_block_last_def.csv", ',');
    });
    timed_run(|| prog.run());
    printsize("Stack_def_use_def_used", prog.stack_def_use_def_used.len());
    printsize("Reg_def_use_return_val_used", prog.reg_def_use_return_val_used.len());
    printsize("Reg_def_use_live_var_used", prog.reg_def_use_live_var_used.len());
    printsize("Jump_table_target", prog.jump_table_target.len());
    printsize("Reg_def_use_def_used", prog.reg_def_use_def_used.len());
    printsize("Reg_def_use_live_var_at_prior_used", prog.reg_def_use_live_var_at_prior_used.len());
    printsize("Reg_def_use_live_var_at_block_end", prog.reg_def_use_live_var_at_block_end.len());
    printsize("Reg_reg_arithmetic_operation_defs", prog.reg_reg_arithmetic_operation_defs.len());
    printsize("Def_used_for_address", prog.def_used_for_address.len());
    printsize("Stack_def_use_live_var_at_block_end", prog.stack_def_use_live_var_at_block_end.len());
    printsize("Stack_def_use_live_var_at_prior_used", prog.stack_def_use_live_var_at_prior_used.len());
}
