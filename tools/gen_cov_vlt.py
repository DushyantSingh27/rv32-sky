#!/usr/bin/env python3
"""
gen_cov_vlt.py -- generate the Verilator coverage exclusion file from the RTL.

M3.7 decision A (docs/results/0028): a line is excluded from structural
coverage EXACTLY when it is excluded from synthesis. Hand-written line ranges
drift silently the moment a file is edited; these are regenerated from the
source on every coverage build, so they cannot.

THE RULE
  Every line of every file in rtl/files.f is evaluated under two
  configurations:
      coverage build : no macros defined
      synthesis      : SYNTHESIS defined (yosys-slang defines it)
  A line compiled in the coverage build but NOT in synthesis is
  simulation-only, and is excluded. A line compiled in neither (an
  `ifdef RISCV_FORMAL block) produces no coverage points and is left alone:
  excluding it would be the plausible-wrong rule ("not SYNTHESIS, therefore
  excluded"), and would be harmless today only by accident.

WHAT MAKES IT REFUSE (exit 2, nothing on stdout)
  - a conditional on any macro other than SYNTHESIS or RISCV_FORMAL: its
    value in either build is unknown, so the rule cannot be applied
  - `define or `undef of SYNTHESIS or RISCV_FORMAL inside the RTL
  - `include: an included file's conditionals would be invisible
  - an unbalanced or out-of-order conditional (stray `else/`elsif/`endif,
    `else twice, `ifdef never closed)

COMMENTS AND STRINGS ARE STRIPPED BEFORE DIRECTIVES ARE FOUND. rtl/core/
regfile.sv:128 mentions `ifndef SYNTHESIS in a comment inside a block; a
scanner that took it as a directive would emit the wrong range.

USAGE
  gen_cov_vlt.py emit  --root <repo>                      > rtl_cov.vlt
  gen_cov_vlt.py check --vlt F --with A.dat --without B.dat
  gen_cov_vlt.py selftest

'check' proves an exclusion file against real coverage data from two builds
of the same harness, one with the .vlt and one without:
  (i)   no point in the WITH data lies inside an excluded range
  (ii)  every excluded range contains at least one point in the WITHOUT
        data -- otherwise (i) holds vacuously for that range
  (iii) the only points the .vlt removed lie inside excluded ranges, and it
        added none
"""

import argparse
import collections
import importlib.util
import pathlib
import re
import sys

KNOWN = ("SYNTHESIS", "RISCV_FORMAL")
CONFIGS = {"cov": frozenset(), "syn": frozenset({"SYNTHESIS"})}
DIRECTIVE = re.compile(r"^\s*`(ifdef|ifndef|elsif|else|endif|define|undef|include)\b\s*(\w+)?")


class Refuse(Exception):
    pass


def strip_comments(text):
    """Blank out // and /* */ comments and string literals, keeping every
    newline, so line numbers are preserved exactly."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join("\n" if ch == "\n" else " " for ch in text[i:j]))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(" " * (min(j + 1, n) - i))
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def sim_only_lines(text, name):
    """Return the sorted line numbers compiled in the coverage build but not in
    synthesis. Raises Refuse on anything the rule cannot decide."""
    lines = strip_comments(text).split("\n")
    # per config: stack of [taken, active, parent_active, seen_else]
    stacks = {c: [] for c in CONFIGS}
    opened = []                                  # (directive, macro, line)
    result = []
    for ln, body in enumerate(lines, 1):
        m = DIRECTIVE.match(body)
        if not m:
            on = {c: all(e[1] for e in stacks[c]) for c in CONFIGS}
            if on["cov"] and not on["syn"]:
                result.append(ln)
            continue
        d, mac = m.group(1), m.group(2)
        where = f"{name}:{ln}"
        if d == "include":
            raise Refuse(f"{where}: `include - conditionals in the included file would be invisible")
        if d in ("define", "undef"):
            if mac in KNOWN:
                raise Refuse(f"{where}: `{d} {mac} inside the RTL changes the rule's inputs")
            continue
        if d in ("ifdef", "ifndef", "elsif") and mac not in KNOWN:
            raise Refuse(f"{where}: `{d} {mac} - unknown macro, its value in each build is not known")
        if d in ("ifdef", "ifndef"):
            for c, defs in CONFIGS.items():
                parent = all(e[1] for e in stacks[c])
                val = (mac in defs) if d == "ifdef" else (mac not in defs)
                stacks[c].append([val, parent and val, parent, False])
            opened.append((d, mac, ln))
            continue
        if not opened:
            raise Refuse(f"{where}: `{d} with no open conditional")
        if d == "endif":
            for c in CONFIGS:
                stacks[c].pop()
            opened.pop()
            continue
        for c, defs in CONFIGS.items():
            top = stacks[c][-1]
            if top[3]:
                raise Refuse(f"{where}: `{d} after `else")
            if d == "else":
                top[1] = top[2] and not top[0]
                top[0] = True
                top[3] = True
            else:  # elsif
                val = mac in defs
                top[1] = top[2] and not top[0] and val
                top[0] = top[0] or val
    if opened:
        d, mac, ln = opened[-1]
        raise Refuse(f"{name}:{ln}: `{d} {mac} is never closed")
    return result


def runs(nums):
    out = []
    for n in nums:
        if out and n == out[-1][1] + 1:
            out[-1][1] = n
        else:
            out.append([n, n])
    return [tuple(r) for r in out]


def rtl_files(root):
    fl = root / "rtl/files.f"
    if not fl.is_file():
        raise Refuse(f"{fl} not found")
    out = []
    for raw in fl.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            out.append(line)
    if not out:
        raise Refuse(f"{fl} lists no files")
    return out


def emit(root):
    body, report = [], []
    for rel in rtl_files(root):
        p = root / rel
        if not p.is_file():
            raise Refuse(f"{rel} is listed in rtl/files.f but does not exist")
        for a, b in runs(sim_only_lines(p.read_text(), rel)):
            body.append(f'coverage_off -file "*{rel}" -lines {a}-{b}')
            report.append(f"  {rel}:{a}-{b}")
    head = ["`verilator_config",
            "// GENERATED by tools/gen_cov_vlt.py from rtl/files.f. Do not edit.",
            "// One line per run of simulation-only RTL: compiled with SYNTHESIS",
            "// undefined, absent with it defined. docs/results/0028, decision A."]
    print("\n".join(head + body))
    print(f"gen_cov_vlt: {len(body)} excluded range(s)", file=sys.stderr)
    print("\n".join(report), file=sys.stderr)


# ----------------------------------------------------------------- check
VLT_LINE = re.compile(r'^coverage_off -file "\*([^"]+)" -lines (\d+)-(\d+)$')


def load_covdat():
    path = pathlib.Path(__file__).resolve().with_name("covdat.py")
    spec = importlib.util.spec_from_file_location("covdat", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def check(vlt, with_dat, without_dat):
    ranges = []
    for raw in pathlib.Path(vlt).read_text().splitlines():
        m = VLT_LINE.match(raw.strip())
        if m:
            ranges.append((m.group(1), int(m.group(2)), int(m.group(3))))
    if not ranges:
        raise Refuse(f"{vlt} contains no coverage_off ranges")
    cd = load_covdat()
    uw, _ = cd.build_union(cd.parse(with_dat))
    uo, _ = cd.build_union(cd.parse(without_dat))

    def hit_range(key):
        f, line = key[0], int(key[1])
        for i, (suf, a, b) in enumerate(ranges):
            if f.endswith(suf) and a <= line <= b:
                return i
        return None

    ok = True
    in_with = [k for k in uw if hit_range(k) is not None]
    print(f"(i)   points inside excluded ranges in the WITH data: {len(in_with)}")
    if in_with:
        ok = False
        for k in in_with[:10]:
            print(f"        {k[0]}:{k[1]} {k[4]} {k[5]}")
    per = collections.Counter(hit_range(k) for k in uo)
    print("(ii)  points per excluded range in the WITHOUT data:")
    for i, (suf, a, b) in enumerate(ranges):
        n = per.get(i, 0)
        print(f"        {suf}:{a}-{b}  {n}{'   <-- EMPTY: (i) is vacuous here' if n == 0 else ''}")
        ok = ok and n > 0
    removed = set(uo) - set(uw)
    added = set(uw) - set(uo)
    stray = [k for k in removed if hit_range(k) is None]
    print(f"(iii) removed by the .vlt: {len(removed)}, of which OUTSIDE every range: "
          f"{len(stray)}; added by the .vlt: {len(added)}")
    for k in stray[:10]:
        print(f"        removed outside a range: {k[0]}:{k[1]} {k[4]} {k[5]}")
    ok = ok and not stray and not added
    print("CHECK " + ("PASS" if ok else "FAIL"))
    return ok


# -------------------------------------------------------------- selftest
SELFTEST = [
    # (name, source, expected sim-only line runs, or "REFUSE")
    ("plain ifndef block",
     "a\n`ifndef SYNTHESIS\nb\nc\n`endif\nd\n", [(3, 4)]),
    ("directive in a // comment is ignored (regfile.sv:128 shape)",
     "`ifndef SYNTHESIS\nx\n// inside `ifndef SYNTHESIS and\ny\n`endif\nz\n", [(2, 4)]),
    ("directive in a /* */ comment is ignored",
     "a\n/*\n`ifndef SYNTHESIS\n*/\nb\n", []),
    ("directive in a string literal is ignored",
     'a\n$display("`ifndef SYNTHESIS");\nb\n', []),
    ("ifdef SYNTHESIS: the else branch is the simulation-only one",
     "`ifdef SYNTHESIS\nsyn\n`else\nsim\n`endif\n", [(4, 4)]),
    ("ifndef SYNTHESIS with else: only the first branch",
     "`ifndef SYNTHESIS\nsim\n`else\nsyn\n`endif\n", [(2, 2)]),
    ("RISCV_FORMAL block alone: compiled in neither build, not excluded",
     "a\n`ifdef RISCV_FORMAL\nf\n`endif\nb\n", []),
    ("ifndef SYNTHESIS nested in RISCV_FORMAL: still not compiled, not excluded",
     "`ifdef RISCV_FORMAL\n`ifndef SYNTHESIS\nx\n`endif\n`endif\n", []),
    ("RISCV_FORMAL nested in ifndef SYNTHESIS: outer lines excluded, inner not",
     "`ifndef SYNTHESIS\ns1\n`ifdef RISCV_FORMAL\nf\n`endif\ns2\n`endif\n", [(2, 2), (6, 6)]),
    ("elsif chain: only the branch live in cov and dead in syn",
     "`ifdef RISCV_FORMAL\nA\n`elsif SYNTHESIS\nB\n`else\nC\n`endif\n", [(6, 6)]),
    ("block moved down one line moves the range with it",
     "a\n\n`ifndef SYNTHESIS\nb\nc\n`endif\nd\n", [(4, 5)]),
    ("never closed", "`ifndef SYNTHESIS\nx\n", "REFUSE"),
    ("stray endif", "x\n`endif\n", "REFUSE"),
    ("else twice", "`ifndef SYNTHESIS\na\n`else\nb\n`else\nc\n`endif\n", "REFUSE"),
    ("unknown macro", "`ifdef FOO\nx\n`endif\n", "REFUSE"),
    ("define SYNTHESIS inside RTL", "`define SYNTHESIS\nx\n", "REFUSE"),
    ("include", '`include "x.svh"\n', "REFUSE"),
]


def selftest():
    bad = 0
    for name, src, want in SELFTEST:
        try:
            got = runs(sim_only_lines(src, "<selftest>"))
        except Refuse as e:
            got = "REFUSE"
            detail = str(e)
        else:
            detail = ""
        ok = got == want
        bad += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {name}: got {got}{'' if ok else f', want {want}'}"
              f"{'  [' + detail + ']' if detail else ''}")
    print(f"SELFTEST {len(SELFTEST) - bad} of {len(SELFTEST)} passed")
    return bad == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["emit", "check", "selftest"])
    ap.add_argument("--root", default=".")
    ap.add_argument("--vlt")
    ap.add_argument("--with", dest="with_dat")
    ap.add_argument("--without", dest="without_dat")
    a = ap.parse_args()
    try:
        if a.cmd == "selftest":
            sys.exit(0 if selftest() else 1)
        if a.cmd == "emit":
            emit(pathlib.Path(a.root).resolve())
            return
        if not (a.vlt and a.with_dat and a.without_dat):
            raise Refuse("check needs --vlt, --with and --without")
        sys.exit(0 if check(a.vlt, a.with_dat, a.without_dat) else 1)
    except Refuse as e:
        print(f"gen_cov_vlt: REFUSED: {e}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
