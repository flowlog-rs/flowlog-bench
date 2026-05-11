#!/usr/bin/env python3
"""
Generate join-order variants of FlowLog programs for benchmarking.

For each rule with k>=3 *positive relational* body atoms, enumerate distinct
left-deep plans (modulo the commutative first pair) and filter out plans
that include a cartesian (no-shared-variable) join at any step. Filter
atoms (a != b, a = const, arithmetic comparisons, negations) don't
participate in joins; they're appended at the end of the body in their
original textual order.

Per program (variant policy):
  - if total cartesian (product of valid plans per multi-atom rule) <= 500:
        enumerate every whole-program plan as a `variant_NNNN.dl`
  - else:
        default + per-rule ablation (cap 12 random plans per rule for k>=5)
        + 100 random whole-program samples (uniform over per-rule valid plans)

Layout:
  programs/oracle/flowlog/<stem>/
      default.dl              (untouched original; the textual order)
      ablation_r<i>_p<j>.dl   (only rule i differs from default)
      sample_NNNN.dl          (random whole-program sample)
      variant_NNNN.dl         (full-cartesian enumeration, when small enough)
      manifest.csv            (variant, kind, rule_perms, signature)

Usage:
    python3 scripts/gen_joinorder_variants.py --all
    python3 scripts/gen_joinorder_variants.py --stems andersen cspa
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import itertools
import random
import re
import sys
from pathlib import Path

# ---- knobs (mirrored in the README'd plan) ----------------------------------
CARTESIAN_ENUMERATE_THRESHOLD = 500
RANDOM_SAMPLE_COUNT = 100
ABLATION_CAP_FOR_K5_PLUS = 12
RANDOM_SEED = 42

ROOT = Path(__file__).resolve().parent.parent.parent
PROG_DIR = ROOT / "programs/oracle/flowlog"

# Programs to generate variants for. Others keep just default.dl on disk.
SMALL_CORE = [
    "andersen", "cspa", "csda", "sg", "dyck", "tc", "reach", "cc", "sssp",
    "bipartite", "crdt", "crdt_slow", "galen", "pointsto", "polonius",
    "cvc5", "z3",
    # doop-family static analyses — large rule sets, mostly k=3..5 bodies.
    # `doop.dl` itself excluded by request (still huge; same rule set as
    # the per-benchmark variants below).
    "batik", "biojava", "eclipse", "xalan", "zxing",
]

# ---- Parser -----------------------------------------------------------------

ATOM_RE = re.compile(r"^[A-Za-z_][\w]*\s*\(.*\)\s*$", re.S)


def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return src


def split_top_commas(s: str) -> list[str]:
    """Split a string on top-level (depth-0) commas."""
    out, buf, depth = [], [], 0
    for c in s:
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == "," and depth == 0:
            out.append("".join(buf))
            buf = []
        else:
            buf.append(c)
    if buf:
        out.append("".join(buf))
    return [p.strip() for p in out if p.strip()]


def _scan_directive(src: str, i: int) -> tuple[str, int]:
    """Scan a directive starting at src[i] (which is '.'). Directives in
    Souffle / FlowLog end at the first newline outside any parens (no '.'
    terminator). Returns (raw_text_without_leading_dot, next_index)."""
    assert src[i] == "."
    i += 1  # skip the leading dot
    buf, depth = [], 0
    while i < len(src):
        c = src[i]
        if c == "\n" and depth == 0:
            break
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        buf.append(c)
        i += 1
    return "".join(buf).strip(), i


def _scan_rule(src: str, i: int) -> tuple[str, int]:
    """Scan a rule / fact ending at the first depth-0 '.'. Returns
    (raw_text_without_trailing_dot, next_index_after_dot)."""
    buf, depth = [], 0
    while i < len(src):
        c = src[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == "." and depth == 0:
            return "".join(buf), i + 1
        buf.append(c)
        i += 1
    return "".join(buf), i


def is_positive_relational(atom: str) -> bool:
    """True iff atom is a positive relational atom `Pred(args)`. Negation
    (`! Pred(args)`) and arithmetic / equality filters are not."""
    s = atom.lstrip()
    if s.startswith("!"):
        return False
    return bool(ATOM_RE.match(atom))


def atom_vars(atom: str) -> set[str]:
    """Variables in a positive relational atom's argument list. Anonymous
    `_` is excluded — each occurrence is a fresh, non-shared variable."""
    m = re.match(r"^[A-Za-z_]\w*\s*\((.*)\)\s*$", atom, re.S)
    if not m:
        return set()
    args = split_top_commas(m.group(1))
    out = set()
    for a in args:
        a = a.strip()
        # An argument is a variable iff it's a bare identifier (not a
        # quoted string, not a number, not an arithmetic expression).
        # We're permissive: anything matching [A-Za-z_]\w* counts.
        if a == "_":
            continue
        if re.fullmatch(r"[A-Za-z_]\w*", a):
            out.add(a)
        # else: number / string / arithmetic expr -> not a variable for
        # the purposes of join-graph connectivity.
    return out


def parse_program(text: str) -> list[dict]:
    """Returns a list of statements, each:
        {kind: 'directive'|'fact'|'rule',
         raw: normalized statement text (directive: no leading dot;
              rule/fact: no trailing dot),
         (rule only) head: str,
         (rule only) pos_atoms: list[str]   in original order,
         (rule only) other_atoms: list[str] (filters / negations, original order)}

    The parser is paren-aware and respects two distinct statement-end
    rules: directives end at the first newline at paren-depth 0 (no '.'
    terminator), rules / facts end at the first depth-0 '.'.
    """
    src = strip_comments(text)
    parsed: list[dict] = []
    i, n = 0, len(src)
    while i < n:
        while i < n and src[i].isspace():
            i += 1
        if i >= n:
            break
        if src[i] == ".":
            raw, i = _scan_directive(src, i)
            raw = re.sub(r"\s+", " ", raw).strip()
            if raw:
                parsed.append({"kind": "directive", "raw": raw})
        else:
            raw, i = _scan_rule(src, i)
            raw = re.sub(r"\s+", " ", raw).strip()
            if not raw:
                continue
            if ":-" in raw:
                head, body = raw.split(":-", 1)
                atoms = split_top_commas(body)
                pos: list[str] = []
                other: list[str] = []
                for a in atoms:
                    if is_positive_relational(a):
                        pos.append(a)
                    else:
                        other.append(a)
                parsed.append({
                    "kind": "rule",
                    "raw": raw,
                    "head": head.strip(),
                    "pos_atoms": pos,
                    "other_atoms": other,
                })
            else:
                parsed.append({"kind": "fact", "raw": raw})
    return parsed


# ---- Plan enumeration --------------------------------------------------------

def is_noncartesian(pos_atoms: list[str], perm: tuple[int, ...]) -> bool:
    """Simulate left-deep build with order `perm`. Reject if any join
    step has zero shared variables between operands."""
    if len(perm) < 2:
        return True
    va = atom_vars(pos_atoms[perm[0]])
    vb = atom_vars(pos_atoms[perm[1]])
    if not (va & vb):
        return False
    running = va | vb
    for j in perm[2:]:
        vj = atom_vars(pos_atoms[j])
        if not (running & vj):
            return False
        running |= vj
    return True


def enumerate_plans(pos_atoms: list[str]) -> list[tuple[int, ...]]:
    """Distinct, non-cartesian left-deep plans. First-pair canonicalised
    by sorted indices to collapse the commutative first join."""
    k = len(pos_atoms)
    if k < 2:
        return [tuple(range(k))]
    plans: list[tuple[int, ...]] = []
    for perm in itertools.permutations(range(k)):
        if perm[0] > perm[1]:  # collapse first-pair commutativity
            continue
        if is_noncartesian(pos_atoms, perm):
            plans.append(perm)
    return plans


def default_plan(pos_atoms: list[str]) -> tuple[int, ...]:
    """The textual order, with the first pair canonicalised."""
    k = len(pos_atoms)
    if k < 2:
        return tuple(range(k))
    base = list(range(k))
    if base[0] > base[1]:
        base[0], base[1] = base[1], base[0]
    return tuple(base)


# ---- Variant emission --------------------------------------------------------

def emit_variant(stmts: list[dict], plan_per_stmt: dict[int, tuple[int, ...]]) -> str:
    """Re-emit the program with each rule's positive atoms in the chosen
    order; filter / negation atoms preserve their original textual order
    and are appended at the end of the body."""
    lines: list[str] = []
    for i, st in enumerate(stmts):
        if st["kind"] == "directive":
            # directives carry no trailing dot; reattach the leading one
            lines.append(f".{st['raw']}")
        elif st["kind"] == "fact":
            lines.append(f"{st['raw']}.")
        elif st["kind"] == "rule":
            pos = st["pos_atoms"]
            perm = plan_per_stmt.get(i, default_plan(pos))
            ordered_pos = [pos[j] for j in perm]
            body_atoms = ordered_pos + st["other_atoms"]
            body = ", ".join(body_atoms)
            lines.append(f"{st['head']} :- {body}.")
    return "\n".join(lines) + "\n"


def signature(plan_per_stmt: dict[int, tuple[int, ...]],
              rule_indices: list[int]) -> str:
    """Compact `r0=2,1,0;r1=1,0,2` signature listing each multi-atom rule's
    plan. Indexing is by *position among multi-atom rules*, not raw
    statement index, so rN is human-friendly."""
    parts: list[str] = []
    for n, ri in enumerate(rule_indices):
        perm = plan_per_stmt.get(ri)
        if perm is None:
            continue
        parts.append(f"r{n}=" + ",".join(map(str, perm)))
    return ";".join(parts)


def short_id(sig: str) -> str:
    return hashlib.sha1(sig.encode()).hexdigest()[:8]


# ---- Per-program driver ------------------------------------------------------

def generate_for_program(stem: str, prog_dir: Path) -> tuple[int, str]:
    """Returns (n_variants, summary_str)."""
    src_path = prog_dir / "default.dl"
    text = src_path.read_text()
    stmts = parse_program(text)

    # Multi-atom rules (the only ones that admit variants).
    # Each entry: (stmt_idx, pos_atoms, default_perm, valid_plans)
    multi_rules: list[tuple[int, list[str], tuple[int, ...], list[tuple[int, ...]]]] = []
    for i, st in enumerate(stmts):
        if st["kind"] != "rule":
            continue
        pos = st["pos_atoms"]
        if len(pos) < 3:
            continue
        plans = enumerate_plans(pos)
        if not plans:
            print(f"  [{stem}] rule {i} ({st['head'][:50]}...): no non-cartesian "
                  f"plans (disconnected variable graph); leaving at default")
            continue
        dp = default_plan(pos)
        if dp not in plans:
            # The textual default itself is cartesian. Rare; fall back to
            # using it as the "default" anyway (so default.dl == original
            # file) but the manifest will mark it as a cartesian default.
            print(f"  [{stem}] WARN: rule {i} ({st['head'][:50]}) default plan is "
                  f"cartesian; keeping textual order for default.dl")
        multi_rules.append((i, pos, dp, plans))

    rule_indices = [t[0] for t in multi_rules]

    # If no multi-atom rules: just record default in the manifest. default.dl
    # already exists (the original file).
    if not multi_rules:
        manifest = prog_dir / "manifest.csv"
        with manifest.open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["variant", "kind", "rule_perms", "signature"])
            w.writerow(["default.dl", "default", "", short_id("")])
        return 1, "no multi-atom rules; default only"

    total_cart = 1
    for (_, _, _, plans) in multi_rules:
        total_cart *= len(plans)

    rng = random.Random(RANDOM_SEED)

    # Default assignment: each rule at its textual order
    default_assignment = {ri: dp for (ri, _, dp, _) in multi_rules}

    variants: list[tuple[str | None, str, dict[int, tuple[int, ...]]]] = []
    variants.append(("default.dl", "default", default_assignment))

    if total_cart <= CARTESIAN_ENUMERATE_THRESHOLD:
        per_rule_plans = [plans for (_, _, _, plans) in multi_rules]
        seen = {tuple(sorted(default_assignment.items()))}
        for combo in itertools.product(*per_rule_plans):
            assn = {ri: combo[k] for k, ri in enumerate(rule_indices)}
            key = tuple(sorted(assn.items()))
            if key in seen:
                continue
            seen.add(key)
            # Tag: ablation if exactly one rule differs, else cartesian-sample
            differing = [ri for ri in rule_indices if assn[ri] != default_assignment[ri]]
            kind = "ablation" if len(differing) == 1 else "variant"
            variants.append((None, kind, assn))
        mode_summary = f"full cartesian ({total_cart} <= {CARTESIAN_ENUMERATE_THRESHOLD})"
    else:
        # Ablation per rule
        for (ri, pos, dp, plans) in multi_rules:
            non_default = [p for p in plans if p != dp]
            if len(pos) >= 5 and len(non_default) > ABLATION_CAP_FOR_K5_PLUS:
                non_default = rng.sample(non_default, ABLATION_CAP_FOR_K5_PLUS)
            for p in non_default:
                assn = dict(default_assignment)
                assn[ri] = p
                variants.append((None, "ablation", assn))

        # Random whole-program samples
        seen_keys = {tuple(sorted(a.items())) for (_, _, a) in variants}
        sampled = 0
        attempts = 0
        max_attempts = RANDOM_SAMPLE_COUNT * 50
        while sampled < RANDOM_SAMPLE_COUNT and attempts < max_attempts:
            attempts += 1
            assn = {ri: rng.choice(plans) for (ri, _, _, plans) in multi_rules}
            key = tuple(sorted(assn.items()))
            if key in seen_keys:
                continue
            seen_keys.add(key)
            variants.append((None, "sample", assn))
            sampled += 1
        mode_summary = (f"ablation+sample (cartesian={total_cart} > "
                        f"{CARTESIAN_ENUMERATE_THRESHOLD}, sampled={sampled})")

    # Map raw statement index -> multi-atom-rule index (r0, r1, ...).
    rule_n_of_stmt = {ri: n for n, ri in enumerate(rule_indices)}

    # Assign filenames
    final: list[tuple[str, str, dict[int, tuple[int, ...]]]] = []
    ablation_counters: dict[int, int] = {}
    sample_counter = 0
    variant_counter = 0
    for (name, kind, assn) in variants:
        if name is not None:
            final.append((name, kind, assn))
            continue
        if kind == "ablation":
            differing = [ri for ri in rule_indices if assn[ri] != default_assignment[ri]]
            assert len(differing) == 1, "ablation should differ in exactly one rule"
            ri = differing[0]
            rn = rule_n_of_stmt[ri]
            ablation_counters[rn] = ablation_counters.get(rn, 0) + 1
            fname = f"ablation_r{rn}_p{ablation_counters[rn]:02d}.dl"
        elif kind == "sample":
            sample_counter += 1
            fname = f"sample_{sample_counter:04d}.dl"
        elif kind == "variant":
            variant_counter += 1
            fname = f"variant_{variant_counter:04d}.dl"
        else:
            raise ValueError(kind)
        final.append((fname, kind, assn))

    # Only files this script owns — don't clobber e.g. an experiment.dl
    # a user dropped next to default.dl.
    for f in prog_dir.iterdir():
        if f.suffix == ".dl" and re.match(r"^(ablation_r\d+_p\d+|sample_\d+|variant_\d+)\.dl$", f.name):
            f.unlink()
    prog_dir.joinpath("manifest.csv").unlink(missing_ok=True)

    for (fname, kind, assn) in final:
        if fname == "default.dl":
            # leave the original textual file untouched — comments etc.
            continue
        out = emit_variant(stmts, assn)
        (prog_dir / fname).write_text(out)

    manifest = prog_dir / "manifest.csv"
    with manifest.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["variant", "kind", "rule_perms", "signature"])
        for (fname, kind, assn) in final:
            sig = signature(assn, rule_indices)
            w.writerow([fname, kind, sig, short_id(sig)])

    summary = (f"{mode_summary} -- {len(final)} variants "
               f"({sum(1 for _, k, _ in final if k == 'ablation')} ablation, "
               f"{sum(1 for _, k, _ in final if k == 'sample')} sample, "
               f"{sum(1 for _, k, _ in final if k == 'variant')} cartesian)")
    return len(final), summary


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--all", action="store_true",
                   help="generate variants for the small-core program list")
    g.add_argument("--stems", nargs="+", help="specific program stems")
    args = ap.parse_args()

    targets = SMALL_CORE if args.all else args.stems

    total = 0
    for stem in targets:
        prog_dir = PROG_DIR / stem
        if not prog_dir.is_dir():
            print(f"  [{stem}] SKIP: directory not found at {prog_dir}")
            continue
        if not (prog_dir / "default.dl").is_file():
            print(f"  [{stem}] SKIP: default.dl not found")
            continue
        n, summary = generate_for_program(stem, prog_dir)
        total += n
        print(f"  [{stem}] {summary}")
    print(f"\nTotal variants emitted across {len(targets)} programs: {total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
