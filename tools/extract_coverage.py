#!/usr/bin/env python3
"""
Extract covergroups, coverpoints, crosses and bins from the UVM environments.

The vplan's coverage column is GENERATED, not hand-written: a traceability
matrix that drifts from the code asserts a link that may no longer exist.

But a generated document is only better than a hand-written one if the
generator is verified. This script therefore carries EXPECTED per-environment
counts taken from the actual DSim coverage reports, and FAILS if what it parses
disagrees. Three earlier revisions each silently got something wrong - array
bins, multi-line coverpoints, and range bins - and each looked plausible in the
output table. Adding an environment must force a re-check.

Usage:  python3 tools/extract_coverage.py
        python3 tools/extract_coverage.py --json
"""
import re, sys, json, pathlib

ENV_DIRS = {
    "env1_alu":     "verif/uvm/env_alu",
    "env2_muldiv":  "verif/uvm/env_muldiv",
    "env3_regfile": "verif/uvm/env_regfile",
    "env4_csr":     "verif/uvm/env_csr",
}

# Coverpoints + crosses per environment, from the dcreport output recorded in
# docs/results/0004, 0005, 0008 and 0010. Update ONLY alongside a real change.
EXPECTED = {
    "env1_alu": 9, "env2_muldiv": 9, "env3_regfile": 11, "env4_csr": 8,
}

# Bin counts for a few coverpoints whose true size is known from the dcreport
# output. A second guard: the coverpoint count above catches dropped
# coverpoints, these catch mis-counted bins.
# BIN COUNTING WAS REMOVED, 2026-08-13.
#
# Four revisions of this script each produced a plausible-looking bin count
# that was wrong in a new way: array bins counted as one, multi-line
# coverpoints dropped entirely, ranges expanded when they should not have
# been, and finally a count of 40 for a coverpoint with 3 bins whose source
# I could no longer trace through the regex.
#
# Regex is the wrong tool for counting SystemVerilog bins - the grammar has
# too many forms (b, b[], b[N], ranges, defaults, wildcards, with-clauses).
# A real fix needs an actual SV parser, which is disproportionate here.
#
# What this script still does correctly, and self-checks: identify every
# coverpoint and cross per environment, and name every ignore_bins /
# illegal_bins exclusion. Those are the structural facts the vplan needs.
#
# Authoritative BIN COUNTS come from dcreport output, recorded in
# docs/results/0004, 0005, 0008 and 0010. The vplan cites those.

CG_RE = re.compile(r'covergroup\s+(\w+)\s*(?:\([^)]*\))?\s*;(.*?)endgroup', re.S)

# re.S is REQUIRED: coverpoint expressions legitimately span lines, e.g.
#   cp_signed_overflow: coverpoint
#     ((cg_a == 32'h8000_0000) && (cg_b == 32'hFFFF_FFFF))
#     iff (cg_op inside {MD_DIV, MD_REM}) {
# Without it the coverpoint is dropped and its bins are attributed to the
# preceding one.
CP_RE    = re.compile(r'(\w+)\s*:\s*coverpoint\s+(.*?)(?:\{|;)', re.S)
CROSS_RE = re.compile(r'(\w+)\s*:\s*cross\s+([^;{]+)', re.S)

# Non-greedy RHS: `bins no = {0}; bins yes = {1};` on one line is TWO
# declarations, not one.
BIN_RE = re.compile(
    r'(bins|illegal_bins|ignore_bins|wildcard\s+bins)\s+'
    r'(\w+)\s*(\[[^\]]*\])?\s*=\s*(.*?);', re.S)

RANGE_RE = re.compile(r'\[\s*([^\]:]+)\s*:\s*([^\]]+)\s*\]')

def _int(tok):
    """Parse a SystemVerilog integer literal, or None."""
    tok = tok.strip()
    m = re.fullmatch(r"(?:\d+)?'([hdbo])([0-9a-fA-F_]+)", tok)
    if m:
        base = {'h':16, 'd':10, 'b':2, 'o':8}[m.group(1)]
        try: return int(m.group(2).replace('_',''), base)
        except ValueError: return None
    if re.fullmatch(r'\d+', tok): return int(tok)
    return None

def bin_count(suffix, rhs):
    """How many bins does one declaration create?

    bins b     = {0}          -> 1
    bins b     = {[21:40]}    -> 1   (one bin covering a range)
    bins b[4]  = {[2:30]}     -> 4   (fixed array size)
    bins b[]   = {[1:31]}     -> 31  (one bin per value)
    bins b[]   = {A, B, C}    -> 3
    """
    if suffix is None:
        return 1                                  # plain scalar bin
    inner = suffix[1:-1].strip()
    if inner.isdigit():
        return int(inner)                         # bins b[4] = {...}
    if inner != '':
        return 1                                  # unrecognised suffix form
    m = re.search(r'\{(.*)\}', rhs, re.S)
    if not m:
        return 1
    body = m.group(1)
    # Ranges expand ONLY under an empty [] suffix. `bins b[] = {[1:31]}` is 31
    # separate bins; `bins b = {[21:40]}` is ONE bin covering a range. Getting
    # this backwards made cp_latency read 40 when it has 3.
    # Split on top-level commas, then expand [a:b] ranges.
    parts, depth, cur = [], 0, ''
    for ch in body:
        if ch in '{[': depth += 1; cur += ch
        elif ch in '}]': depth -= 1; cur += ch
        elif ch == ',' and depth == 0: parts.append(cur); cur = ''
        else: cur += ch
    if cur.strip(): parts.append(cur)
    # inner == '' means an EMPTY [] suffix: one bin per value, ranges expanded.
    # Any other case reached here is a plain scalar bin, already handled above.
    total = 0
    for part in parts:
        r = RANGE_RE.search(part)
        if r:
            lo, hi = _int(r.group(1)), _int(r.group(2))
            total += (hi - lo + 1) if (lo is not None and hi is not None
                                       and hi >= lo) else 1
        else:
            total += 1
    return total

def parse_file(path):
    text = path.read_text()
    out = []
    for cg_name, body in CG_RE.findall(text):
        marks = []
        for m in CP_RE.finditer(body):
            marks.append((m.start(), "cp", m.group(1), ' '.join(m.group(2).split())))
        for m in CROSS_RE.finditer(body):
            marks.append((m.start(), "cross", m.group(1), ' '.join(m.group(2).split())))
        # A cross also matches nothing in CP_RE and vice versa, but comments
        # mentioning "coverpoint" can produce spurious hits - drop any whose
        # name is not a plain identifier at a statement start.
        marks = [m for m in marks if re.fullmatch(r'cp_\w+|x_\w+', m[2])]
        marks.sort()
        cps, crosses = [], []
        for i, (pos, kind, name, expr) in enumerate(marks):
            end = marks[i+1][0] if i+1 < len(marks) else len(body)
            chunk = body[pos:end]
            bins = [{"kind": k.strip(), "name": n, "count": bin_count(sfx, rhs)}
                    for k, n, sfx, rhs in BIN_RE.findall(chunk)]
            n_bins = sum(b["count"] for b in bins if b["kind"] == "bins")
            entry = {"name": name, "expr": expr, "bins": bins, "n_bins": n_bins}
            (crosses if kind == "cross" else cps).append(entry)
        out.append({"covergroup": cg_name, "file": str(path),
                    "coverpoints": cps, "crosses": crosses})
    return out

def main():
    result, failures = {}, []
    for env, d in ENV_DIRS.items():
        p = pathlib.Path(d)
        found = []
        if p.exists():
            for f in sorted(p.rglob("*.sv")) + sorted(p.rglob("*.svh")):
                found.extend(parse_file(f))
        result[env] = found
        n = sum(len(cg["coverpoints"]) + len(cg["crosses"]) for cg in found)
        exp = EXPECTED.get(env)
        if exp is not None and n != exp:
            failures.append(f"{env}: parsed {n} coverpoints+crosses, expected {exp}")


    if "--json" in sys.argv:
        print(json.dumps(result, indent=2))
    else:
        for env, cgs in result.items():
            print(f"\n{'='*68}\n{env}\n{'='*68}")
            for cg in cgs:
                print(f"\ncovergroup {cg['covergroup']}   [{cg['file']}]")
                for cp in cg["coverpoints"]:
                    print(f"    coverpoint {cp['name']:<20}")
                    for b in cp["bins"]:
                        if b["kind"] != "bins":
                            print(f"        {b['kind']:<14} {b['name']}")
                for x in cg["crosses"]:
                    print(f"    cross      {x['name']:<20} <- {x['expr'][:40]}")
                    for b in x["bins"]:
                        if b["kind"] != "bins":
                            print(f"        {b['kind']:<14} {b['name']}")

    if failures:
        print("\n" + "!"*68)
        print("SELF-CHECK FAILED - parser output disagrees with recorded reports:")
        for f in failures: print("  " + f)
        print("!"*68)
        sys.exit(1)
    print("\nself-check: OK (coverpoint+cross counts match recorded reports)")

if __name__ == "__main__":
    main()
