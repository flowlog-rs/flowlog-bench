// Ascent translation of programs/oracle/souffle/doop.dl (join order preserved)
// Strings are globally interned (harness IStr, u32 keys) —
// matching FlowLog --str-intern and the DDlog istring translation.
// Notes:
//  - cat(cat(cat(rt, "("), ps), ")") => sym(&format!("{}({})", ...)).
//  - Soufflé `t = "<const>"` equality constraints become `if *t == sym(...)`.
//  - Variable `return` (Rust keyword) renamed to `ret`; `type`/`super` get a
//    trailing underscore.
use ascent::ascent_par;
use harness::*;

ascent_par! {
    struct Doop;

    // EDBs
    relation directsuperclass(IStr, IStr);
    relation directsuperinterface(IStr, IStr);
    relation mainclass(IStr);
    relation formalparam(i32, IStr, IStr);
    relation componenttype(IStr, IStr);
    relation assignreturnvalue(IStr, IStr);
    relation actualparam(i32, IStr, IStr);
    relation method_modifier(IStr, IStr);
    relation var_type(IStr, IStr);
    relation heapallocation_type(IStr, IStr);

    // Main schema
    relation istype(IStr);
    relation isreferencetype(IStr);
    relation isarraytype(IStr);
    relation isclasstype(IStr);
    relation isinterfacetype(IStr);
    relation applicationclass(IStr);
    relation field_declaringtype(IStr, IStr);
    relation method_declaringtype(IStr, IStr);
    relation method_returntype(IStr, IStr);
    relation method_simplename(IStr, IStr);
    relation method_paramtypes(IStr, IStr);
    relation thisvar(IStr, IStr);
    relation var_declaringmethod(IStr, IStr);
    relation instruction_method(IStr, IStr);
    relation isvirtualmethodinvocation_insn(IStr);
    relation isstaticmethodinvocation_insn(IStr);
    relation fieldinstruction_signature(IStr, IStr);
    relation loadinstancefield_base(IStr, IStr);
    relation loadinstancefield_to(IStr, IStr);
    relation storeinstancefield_from(IStr, IStr);
    relation storeinstancefield_base(IStr, IStr);
    relation loadstaticfield_to(IStr, IStr);
    relation storestaticfield_from(IStr, IStr);
    relation loadarrayindex_base(IStr, IStr);
    relation loadarrayindex_to(IStr, IStr);
    relation storearrayindex_from(IStr, IStr);
    relation storearrayindex_base(IStr, IStr);
    relation assigninstruction_to(IStr, IStr);
    relation assigncast_from(IStr, IStr);
    relation assigncast_type(IStr, IStr);
    relation assignlocal_from(IStr, IStr);
    relation assignheapallocation_heap(IStr, IStr);
    relation returnnonvoid_var(IStr, IStr);
    relation methodinvocation_method(IStr, IStr);
    relation virtualmethodinvocation_base(IStr, IStr);
    relation virtualmethodinvocation_simplename(IStr, IStr);
    relation virtualmethodinvocation_descriptor(IStr, IStr);
    relation specialmethodinvocation_base(IStr, IStr);
    relation methodinvocation_base(IStr, IStr);

    // Fat schema
    relation loadinstancefield(IStr, IStr, IStr, IStr);
    relation storeinstancefield(IStr, IStr, IStr, IStr);
    relation loadstaticfield(IStr, IStr, IStr);
    relation storestaticfield(IStr, IStr, IStr);
    relation loadarrayindex(IStr, IStr, IStr);
    relation storearrayindex(IStr, IStr, IStr);
    relation assigncast(IStr, IStr, IStr, IStr);
    relation assignlocal(IStr, IStr, IStr);
    relation assignheapallocation(IStr, IStr, IStr);
    relation returnvar(IStr, IStr);
    relation staticmethodinvocation(IStr, IStr, IStr);

    // imports
    relation _classtype(IStr);
    relation _arraytype(IStr);
    relation _interfacetype(IStr);
    relation _var_declaringmethod(IStr, IStr);
    relation _applicationclass(IStr);
    relation _thisvar(IStr, IStr);
    relation _normalheap(IStr, IStr);
    relation _stringconstant(IStr);
    relation _assignheapallocation(IStr, i32, IStr, IStr, IStr, i32);
    relation _assignlocal(IStr, i32, IStr, IStr, IStr);
    relation _assigncast(IStr, i32, IStr, IStr, IStr, IStr);
    relation _field(IStr, IStr, IStr, IStr);
    relation _staticmethodinvocation(IStr, i32, IStr, IStr);
    relation _specialmethodinvocation(IStr, i32, IStr, IStr, IStr);
    relation _virtualmethodinvocation(IStr, i32, IStr, IStr, IStr);
    relation _method(IStr, IStr, IStr, IStr, IStr, IStr, i32);
    relation method_descriptor(IStr, IStr);
    relation _storeinstancefield(IStr, i32, IStr, IStr, IStr, IStr);
    relation _loadinstancefield(IStr, i32, IStr, IStr, IStr, IStr);
    relation _storestaticfield(IStr, i32, IStr, IStr, IStr);
    relation _loadstaticfield(IStr, i32, IStr, IStr, IStr);
    relation _storearrayindex(IStr, i32, IStr, IStr, IStr);
    relation _loadarrayindex(IStr, i32, IStr, IStr, IStr);
    relation _return(IStr, i32, IStr, IStr);

    // Basic (type-based) analysis
    relation methodlookup(IStr, IStr, IStr, IStr);
    relation methodimplemented(IStr, IStr, IStr, IStr);
    relation directsubclass(IStr, IStr);
    relation subclass(IStr, IStr);
    relation superclass(IStr, IStr);
    relation superinterface(IStr, IStr);
    relation subtypeof(IStr, IStr);
    relation supertypeof(IStr, IStr);
    relation subtypeofdifferent(IStr, IStr);
    relation mainmethoddeclaration(IStr);

    // class initialization
    relation classinitializer(IStr, IStr);
    relation initializedclass(IStr);

    // Main (value-based) analysis
    relation assign(IStr, IStr);
    relation varpointsto(IStr, IStr);
    relation instancefieldpointsto(IStr, IStr, IStr);
    relation staticfieldpointsto(IStr, IStr);
    relation callgraphedge(IStr, IStr);
    relation arrayindexpointsto(IStr, IStr);
    relation reachable(IStr);

    // .rule
    istype(class) <-- _classtype(class);
    isreferencetype(class) <-- _classtype(class);
    isclasstype(class) <-- _classtype(class);

    istype(arraytype) <-- _arraytype(arraytype);
    isreferencetype(arraytype) <-- _arraytype(arraytype);
    isarraytype(arraytype) <-- _arraytype(arraytype);

    istype(interface) <-- _interfacetype(interface);
    isreferencetype(interface) <-- _interfacetype(interface);
    isinterfacetype(interface) <-- _interfacetype(interface);

    var_declaringmethod(var, method) <-- _var_declaringmethod(var, method);

    istype(type_) <-- _applicationclass(type_);
    isreferencetype(type_) <-- _applicationclass(type_);
    applicationclass(type_) <-- _applicationclass(type_);

    thisvar(method, var) <-- _thisvar(method, var);

    istype(type_) <-- _normalheap(_, type_);
    heapallocation_type(id, type_) <-- _normalheap(id, type_);
    heapallocation_type(id, sym("java.lang.String")) <-- _stringconstant(id);

    instruction_method(instruction, method) <--
        _assignheapallocation(instruction, index, heap, to, method, linenumber);
    assigninstruction_to(instruction, to) <--
        _assignheapallocation(instruction, index, heap, to, method, linenumber);
    assignheapallocation_heap(instruction, heap) <--
        _assignheapallocation(instruction, index, heap, to, method, linenumber);

    instruction_method(instruction, method) <--
        _assignlocal(instruction, index, from, to, method);
    assignlocal_from(instruction, from) <--
        _assignlocal(instruction, index, from, to, method);
    assigninstruction_to(instruction, to) <--
        _assignlocal(instruction, index, from, to, method);

    instruction_method(instruction, method) <--
        _assigncast(instruction, index, from, to, type_, method);
    assigncast_type(instruction, type_) <--
        _assigncast(instruction, index, from, to, type_, method);
    assigncast_from(instruction, from) <--
        _assigncast(instruction, index, from, to, type_, method);
    assigninstruction_to(instruction, to) <--
        _assigncast(instruction, index, from, to, type_, method);

    field_declaringtype(signature, declaringtype) <-- _field(signature, declaringtype, _, _);

    methodinvocation_base(invocation, base) <-- virtualmethodinvocation_base(invocation, base);
    methodinvocation_base(invocation, base) <-- specialmethodinvocation_base(invocation, base);

    instruction_method(instruction, method) <--
        _staticmethodinvocation(instruction, index, signature, method);
    isstaticmethodinvocation_insn(instruction) <--
        _staticmethodinvocation(instruction, index, signature, method);
    methodinvocation_method(instruction, signature) <--
        _staticmethodinvocation(instruction, index, signature, method);

    instruction_method(instruction, method) <--
        _specialmethodinvocation(instruction, index, signature, base, method);
    specialmethodinvocation_base(instruction, base) <--
        _specialmethodinvocation(instruction, index, signature, base, method);
    methodinvocation_method(instruction, signature) <--
        _specialmethodinvocation(instruction, index, signature, base, method);

    instruction_method(instruction, method) <--
        _virtualmethodinvocation(instruction, index, signature, base, method);
    isvirtualmethodinvocation_insn(instruction) <--
        _virtualmethodinvocation(instruction, index, signature, base, method);
    virtualmethodinvocation_base(instruction, base) <--
        _virtualmethodinvocation(instruction, index, signature, base, method);
    methodinvocation_method(instruction, signature) <--
        _virtualmethodinvocation(instruction, index, signature, base, method);

    method_simplename(method, simplename) <--
        _method(method, simplename, params, declaringtype, returntype, jvmdescriptor, arity);
    method_paramtypes(method, params) <--
        _method(method, simplename, params, declaringtype, returntype, jvmdescriptor, arity);
    method_declaringtype(method, declaringtype) <--
        _method(method, simplename, params, declaringtype, returntype, jvmdescriptor, arity);
    method_returntype(method, returntype) <--
        _method(method, simplename, params, declaringtype, returntype, jvmdescriptor, arity);

    // Method_Descriptor computed via cat
    method_descriptor(method, sym(&format!("{}({})", res(*returntype), res(*params)))) <--
        method_returntype(method, returntype),
        method_paramtypes(method, params);

    instruction_method(instruction, method) <--
        _storeinstancefield(instruction, index, from, base, signature, method);
    fieldinstruction_signature(instruction, signature) <--
        _storeinstancefield(instruction, index, from, base, signature, method);
    storeinstancefield_base(instruction, base) <--
        _storeinstancefield(instruction, index, from, base, signature, method);
    storeinstancefield_from(instruction, from) <--
        _storeinstancefield(instruction, index, from, base, signature, method);

    instruction_method(instruction, method) <--
        _loadinstancefield(instruction, index, to, base, signature, method);
    fieldinstruction_signature(instruction, signature) <--
        _loadinstancefield(instruction, index, to, base, signature, method);
    loadinstancefield_base(instruction, base) <--
        _loadinstancefield(instruction, index, to, base, signature, method);
    loadinstancefield_to(instruction, to) <--
        _loadinstancefield(instruction, index, to, base, signature, method);

    instruction_method(instruction, method) <--
        _storestaticfield(instruction, index, from, signature, method);
    fieldinstruction_signature(instruction, signature) <--
        _storestaticfield(instruction, index, from, signature, method);
    storestaticfield_from(instruction, from) <--
        _storestaticfield(instruction, index, from, signature, method);

    instruction_method(instruction, method) <--
        _loadstaticfield(instruction, index, to, signature, method);
    fieldinstruction_signature(instruction, signature) <--
        _loadstaticfield(instruction, index, to, signature, method);
    loadstaticfield_to(instruction, to) <--
        _loadstaticfield(instruction, index, to, signature, method);

    instruction_method(instruction, method) <--
        _storearrayindex(instruction, index, from, base, method);
    storearrayindex_base(instruction, base) <--
        _storearrayindex(instruction, index, from, base, method);
    storearrayindex_from(instruction, from) <--
        _storearrayindex(instruction, index, from, base, method);

    instruction_method(instruction, method) <--
        _loadarrayindex(instruction, index, to, base, method);
    loadarrayindex_base(instruction, base) <--
        _loadarrayindex(instruction, index, to, base, method);
    loadarrayindex_to(instruction, to) <--
        _loadarrayindex(instruction, index, to, base, method);

    instruction_method(instruction, method) <--
        _return(instruction, index, var, method);
    returnnonvoid_var(instruction, var) <--
        _return(instruction, index, var, method);

    // fat schema population
    loadinstancefield(base, sig, to, inmethod) <--
        instruction_method(insn, inmethod),
        loadinstancefield_base(insn, base),
        fieldinstruction_signature(insn, sig),
        loadinstancefield_to(insn, to);
    storeinstancefield(from, base, sig, inmethod) <--
        instruction_method(insn, inmethod),
        storeinstancefield_from(insn, from),
        storeinstancefield_base(insn, base),
        fieldinstruction_signature(insn, sig);
    loadstaticfield(sig, to, inmethod) <--
        instruction_method(insn, inmethod),
        fieldinstruction_signature(insn, sig),
        loadstaticfield_to(insn, to);
    storestaticfield(from, sig, inmethod) <--
        instruction_method(insn, inmethod),
        storestaticfield_from(insn, from),
        fieldinstruction_signature(insn, sig);
    loadarrayindex(base, to, inmethod) <--
        instruction_method(insn, inmethod),
        loadarrayindex_base(insn, base),
        loadarrayindex_to(insn, to);
    storearrayindex(from, base, inmethod) <--
        instruction_method(insn, inmethod),
        storearrayindex_from(insn, from),
        storearrayindex_base(insn, base);
    assigncast(type_, from, to, inmethod) <--
        instruction_method(insn, inmethod),
        assigncast_from(insn, from),
        assigninstruction_to(insn, to),
        assigncast_type(insn, type_);
    assignlocal(from, to, inmethod) <--
        assigninstruction_to(insn, to),
        instruction_method(insn, inmethod),
        assignlocal_from(insn, from);
    assignheapallocation(heap, to, inmethod) <--
        instruction_method(insn, inmethod),
        assignheapallocation_heap(insn, heap),
        assigninstruction_to(insn, to);
    returnvar(var, method) <--
        instruction_method(insn, method),
        returnnonvoid_var(insn, var);
    staticmethodinvocation(invocation, signature, inmethod) <--
        isstaticmethodinvocation_insn(invocation),
        instruction_method(invocation, inmethod),
        methodinvocation_method(invocation, signature);
    virtualmethodinvocation_simplename(invocation, simplename) <--
        isvirtualmethodinvocation_insn(invocation),
        methodinvocation_method(invocation, signature),
        method_simplename(signature, simplename),
        method_descriptor(signature, descriptor);
    virtualmethodinvocation_descriptor(invocation, descriptor) <--
        isvirtualmethodinvocation_insn(invocation),
        methodinvocation_method(invocation, signature),
        method_simplename(signature, simplename),
        method_descriptor(signature, descriptor);

    // Basic (type-based) analysis
    methodlookup(simplename, descriptor, type_, method) <--
        methodimplemented(simplename, descriptor, type_, method);
    methodlookup(simplename, descriptor, type_, method) <--
        directsuperclass(type_, supertype),
        methodlookup(simplename, descriptor, supertype, method),
        !methodimplemented(simplename, descriptor, type_, _);
    methodlookup(simplename, descriptor, type_, method) <--
        directsuperinterface(type_, supertype),
        methodlookup(simplename, descriptor, supertype, method),
        !methodimplemented(simplename, descriptor, type_, _);
    methodimplemented(simplename, descriptor, type_, method) <--
        method_simplename(method, simplename),
        method_descriptor(method, descriptor),
        method_declaringtype(method, type_),
        !method_modifier(sym("abstract"), method);
    mainmethoddeclaration(method) <--
        mainclass(type_),
        method_declaringtype(method, type_),
        if *method != sym("<java.util.prefs.Base64: void main(java.lang.String[])>"),
        if *method != sym("<sun.java2d.loops.GraphicsPrimitiveMgr: void main(java.lang.String[])>"),
        if *method != sym("<sun.security.provider.PolicyParser: void main(java.lang.String[])>"),
        method_simplename(method, sym("main")),
        method_descriptor(method, sym("void(java.lang.String[])")),
        method_modifier(sym("public"), method),
        method_modifier(sym("static"), method);

    directsubclass(a, c) <-- directsuperclass(a, c);
    subclass(c, a) <-- directsubclass(a, c);
    subclass(c, a) <--
        subclass(b, a),
        directsubclass(b, c);
    superclass(c, a) <-- subclass(a, c);
    superinterface(k, c) <-- directsuperinterface(c, k);
    superinterface(k, c) <--
        directsuperinterface(c, j),
        superinterface(k, j);
    superinterface(k, c) <--
        directsuperclass(c, super_),
        superinterface(k, super_);

    subtypeof(s, s) <-- isclasstype(s);
    subtypeof(t, t) <-- istype(t);
    subtypeof(s, t) <-- subclass(t, s);
    subtypeof(s, s) <-- isinterfacetype(s);
    subtypeof(s, t) <--
        isclasstype(s),
        superinterface(t, s);
    subtypeof(s, t) <--
        isinterfacetype(s),
        istype(t),
        if *t == sym("java.lang.Object");
    subtypeof(s, t) <--
        isarraytype(s),
        istype(t),
        if *t == sym("java.lang.Object");
    subtypeof(s, t) <--
        isinterfacetype(s),
        superinterface(t, s);
    subtypeof(s, t) <--
        subtypeof(sc, tc),
        componenttype(s, sc),
        componenttype(t, tc),
        isreferencetype(sc),
        isreferencetype(tc);
    subtypeof(s, t) <--
        isarraytype(s),
        isinterfacetype(t),
        istype(t),
        if *t == sym("java.lang.Cloneable");
    subtypeof(s, t) <--
        isarraytype(s),
        isinterfacetype(t),
        istype(t),
        if *t == sym("java.io.Serializable");

    supertypeof(s, t) <-- subtypeof(t, s);
    subtypeofdifferent(s, t) <--
        subtypeof(s, t),
        if s != t;

    // class initialization
    classinitializer(type_, method) <--
        methodimplemented(sym("<clinit>"), sym("void()"), type_, method);
    initializedclass(superclass_) <--
        initializedclass(class),
        directsuperclass(class, superclass_);
    initializedclass(superinterface_) <--
        initializedclass(classorinterface),
        directsuperinterface(classorinterface, superinterface_);
    initializedclass(class) <--
        mainmethoddeclaration(method),
        method_declaringtype(method, class);
    initializedclass(class) <--
        reachable(inmethod),
        assignheapallocation(heap, _, inmethod),
        heapallocation_type(heap, class);
    initializedclass(class) <--
        reachable(inmethod),
        instruction_method(invocation, inmethod),
        isstaticmethodinvocation_insn(invocation),
        methodinvocation_method(invocation, signature),
        method_declaringtype(signature, class);
    initializedclass(classorinterface) <--
        reachable(inmethod),
        storestaticfield(_, signature, inmethod),
        field_declaringtype(signature, classorinterface);
    initializedclass(classorinterface) <--
        reachable(inmethod),
        loadstaticfield(signature, _, inmethod),
        field_declaringtype(signature, classorinterface);
    reachable(clinit) <--
        initializedclass(class),
        classinitializer(class, clinit);

    // Main (value-based) analysis
    assign(actual, formal) <--
        callgraphedge(invocation, method),
        formalparam(index, method, formal),
        actualparam(index, invocation, actual);
    assign(ret, local) <--
        callgraphedge(invocation, method),
        returnvar(ret, method),
        assignreturnvalue(invocation, local);
    varpointsto(heap, var) <--
        assignheapallocation(heap, var, inmethod),
        reachable(inmethod);
    varpointsto(heap, to) <--
        assign(from, to),
        varpointsto(heap, from);
    varpointsto(heap, to) <--
        reachable(inmethod),
        assignlocal(from, to, inmethod),
        varpointsto(heap, from);
    varpointsto(heap, to) <--
        reachable(inmethod),
        assigncast(type_, from, to, inmethod),
        supertypeof(type_, heaptype),
        heapallocation_type(heap, heaptype),
        varpointsto(heap, from);
    arrayindexpointsto(baseheap, heap) <--
        reachable(inmethod),
        storearrayindex(from, base, inmethod),
        varpointsto(baseheap, base),
        varpointsto(heap, from),
        heapallocation_type(heap, heaptype),
        heapallocation_type(baseheap, baseheaptype),
        componenttype(baseheaptype, componenttype_),
        supertypeof(componenttype_, heaptype);
    varpointsto(heap, to) <--
        reachable(inmethod),
        loadarrayindex(base, to, inmethod),
        varpointsto(baseheap, base),
        arrayindexpointsto(baseheap, heap),
        var_type(to, type_),
        heapallocation_type(baseheap, baseheaptype),
        componenttype(baseheaptype, basecomponenttype),
        supertypeof(type_, basecomponenttype);
    varpointsto(heap, to) <--
        reachable(inmethod),
        loadinstancefield(base, signature, to, inmethod),
        varpointsto(baseheap, base),
        instancefieldpointsto(heap, signature, baseheap);
    varpointsto(heap, to) <--
        reachable(inmethod),
        loadstaticfield(fld, to, inmethod),
        staticfieldpointsto(heap, fld);
    varpointsto(heap, this) <--
        reachable(inmethod),
        instruction_method(invocation, inmethod),
        virtualmethodinvocation_base(invocation, base),
        varpointsto(heap, base),
        heapallocation_type(heap, heaptype),
        virtualmethodinvocation_simplename(invocation, simplename),
        virtualmethodinvocation_descriptor(invocation, descriptor),
        methodlookup(simplename, descriptor, heaptype, tomethod),
        thisvar(tomethod, this);
    instancefieldpointsto(heap, fld, baseheap) <--
        reachable(inmethod),
        storeinstancefield(from, base, fld, inmethod),
        varpointsto(heap, from),
        varpointsto(baseheap, base);
    staticfieldpointsto(heap, fld) <--
        reachable(inmethod),
        storestaticfield(from, fld, inmethod),
        varpointsto(heap, from);

    // Reachable(toMethod), CallGraphEdge(invocation, toMethod)
    reachable(tomethod) <--
        reachable(inmethod),
        instruction_method(invocation, inmethod),
        virtualmethodinvocation_base(invocation, base),
        varpointsto(heap, base),
        heapallocation_type(heap, heaptype),
        virtualmethodinvocation_simplename(invocation, simplename),
        virtualmethodinvocation_descriptor(invocation, descriptor),
        methodlookup(simplename, descriptor, heaptype, tomethod);
    callgraphedge(invocation, tomethod) <--
        reachable(inmethod),
        instruction_method(invocation, inmethod),
        virtualmethodinvocation_base(invocation, base),
        varpointsto(heap, base),
        heapallocation_type(heap, heaptype),
        virtualmethodinvocation_simplename(invocation, simplename),
        virtualmethodinvocation_descriptor(invocation, descriptor),
        methodlookup(simplename, descriptor, heaptype, tomethod);

    reachable(tomethod) <--
        reachable(inmethod),
        staticmethodinvocation(invocation, tomethod, inmethod);
    callgraphedge(invocation, tomethod) <--
        reachable(inmethod),
        staticmethodinvocation(invocation, tomethod, inmethod);

    reachable(tomethod) <--
        reachable(inmethod),
        instruction_method(invocation, inmethod),
        specialmethodinvocation_base(invocation, base),
        varpointsto(heap, base),
        methodinvocation_method(invocation, tomethod),
        thisvar(tomethod, this);
    callgraphedge(invocation, tomethod) <--
        reachable(inmethod),
        instruction_method(invocation, inmethod),
        specialmethodinvocation_base(invocation, base),
        varpointsto(heap, base),
        methodinvocation_method(invocation, tomethod),
        thisvar(tomethod, this);
    varpointsto(heap, this) <--
        reachable(inmethod),
        instruction_method(invocation, inmethod),
        specialmethodinvocation_base(invocation, base),
        varpointsto(heap, base),
        methodinvocation_method(invocation, tomethod),
        thisvar(tomethod, this);

    reachable(method) <-- mainmethoddeclaration(method);
}

fn main() {
    let dir = bench_init();
    let mut prog = Doop::default();
    timed_load(|| {
        prog.directsuperclass = load_rel(&dir, "DirectSuperclass.facts", '\t');
        prog.directsuperinterface = load_rel(&dir, "DirectSuperinterface.facts", '\t');
        prog.mainclass = load_rel(&dir, "MainClass.facts", '\t');
        prog.formalparam = load_rel(&dir, "FormalParam.facts", '\t');
        prog.componenttype = load_rel(&dir, "ComponentType.facts", '\t');
        prog.assignreturnvalue = load_rel(&dir, "AssignReturnValue.facts", '\t');
        prog.actualparam = load_rel(&dir, "ActualParam.facts", '\t');
        prog.method_modifier = load_rel(&dir, "Method-Modifier.facts", '\t');
        prog.var_type = load_rel(&dir, "Var-Type.facts", '\t');
        prog._classtype = load_rel(&dir, "ClassType.facts", '\t');
        prog._arraytype = load_rel(&dir, "ArrayType.facts", '\t');
        prog._interfacetype = load_rel(&dir, "InterfaceType.facts", '\t');
        prog._var_declaringmethod = load_rel(&dir, "Var-DeclaringMethod.facts", '\t');
        prog._applicationclass = load_rel(&dir, "ApplicationClass.facts", '\t');
        prog._thisvar = load_rel(&dir, "ThisVar.facts", '\t');
        prog._normalheap = load_rel(&dir, "NormalHeap.facts", '\t');
        prog._stringconstant = load_rel(&dir, "StringConstant.facts", '\t');
        prog._assignheapallocation = load_rel(&dir, "AssignHeapAllocation.facts", '\t');
        prog._assignlocal = load_rel(&dir, "AssignLocal.facts", '\t');
        prog._assigncast = load_rel(&dir, "AssignCast.facts", '\t');
        prog._field = load_rel(&dir, "Field.facts", '\t');
        prog._staticmethodinvocation = load_rel(&dir, "StaticMethodInvocation.facts", '\t');
        prog._specialmethodinvocation = load_rel(&dir, "SpecialMethodInvocation.facts", '\t');
        prog._virtualmethodinvocation = load_rel(&dir, "VirtualMethodInvocation.facts", '\t');
        prog._method = load_rel(&dir, "Method.facts", '\t');
        prog._storeinstancefield = load_rel(&dir, "StoreInstanceField.facts", '\t');
        prog._loadinstancefield = load_rel(&dir, "LoadInstanceField.facts", '\t');
        prog._storestaticfield = load_rel(&dir, "StoreStaticField.facts", '\t');
        prog._loadstaticfield = load_rel(&dir, "LoadStaticField.facts", '\t');
        prog._storearrayindex = load_rel(&dir, "StoreArrayIndex.facts", '\t');
        prog._loadarrayindex = load_rel(&dir, "LoadArrayIndex.facts", '\t');
        prog._return = load_rel(&dir, "Return.facts", '\t');
    });
    timed_run(|| prog.run());
    printsize("MainClass", prog.mainclass.len());
    printsize("Method_SimpleName", prog.method_simplename.len());
    printsize("Method_DeclaringType", prog.method_declaringtype.len());
    printsize("Method_Modifier", prog.method_modifier.len());
    printsize("Method_ParamTypes", prog.method_paramtypes.len());
    printsize("Method_ReturnType", prog.method_returntype.len());
    printsize("Method_Descriptor", prog.method_descriptor.len());
    printsize("MethodLookup", prog.methodlookup.len());
    printsize("MethodImplemented", prog.methodimplemented.len());
    printsize("DirectSubclass", prog.directsubclass.len());
    printsize("Subclass", prog.subclass.len());
    printsize("Superclass", prog.superclass.len());
    printsize("Superinterface", prog.superinterface.len());
    printsize("SubtypeOf", prog.subtypeof.len());
    printsize("SupertypeOf", prog.supertypeof.len());
    printsize("SubtypeOfDifferent", prog.subtypeofdifferent.len());
    printsize("MainMethodDeclaration", prog.mainmethoddeclaration.len());
    printsize("ClassInitializer", prog.classinitializer.len());
    printsize("InitializedClass", prog.initializedclass.len());
    printsize("Assign", prog.assign.len());
    printsize("VarPointsTo", prog.varpointsto.len());
    printsize("InstanceFieldPointsTo", prog.instancefieldpointsto.len());
    printsize("StaticFieldPointsTo", prog.staticfieldpointsto.len());
    printsize("CallGraphEdge", prog.callgraphedge.len());
    printsize("ArrayIndexPointsTo", prog.arrayindexpointsto.len());
    printsize("Reachable", prog.reachable.len());
}
