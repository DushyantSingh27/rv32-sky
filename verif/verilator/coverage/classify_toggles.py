#!/usr/bin/env python3
"""Classify every UNCOVERED toggle point in rtl/core. docs/results/0028.

PROJECT_CONTEXT 5.3 keeps unreachable toggle points IN the denominator: the
toggle number is reported as measured, and every point it misses is accounted
for here, with the source line that explains it. This file is that account.

  classify_toggles.py <merged.dat>  > docs/results/0028-uncovered-toggles.tsv

reads the merged data run_coverage.sh writes (verif/verilator/coverage/
obj_dir_cov/merged.dat), takes the union across instances exactly as the
gate does (tools/covdat.py build_union), and matches every uncovered rtl/core
toggle point against RULES below.

It FAILS (exit 1) if any uncovered point matches no rule or more than one, or
if any rule matches nothing. So a new uncovered point cannot go unexplained,
and a rule whose reason has gone away cannot linger. TSV on stdout; a summary
per class on stderr.

BASIS, per class:
  construction  the bit is a constant in the RTL; the cited line makes it so
  tied          driven by a port the core ties off until M5 (no CLINT)
  proved        formal proof that the value never occurs (verif/formal/...)
  bounded       a bounded proof (depth 20 from reset) plus the cited RTL;
                NOT unbounded - see 0028
  stimulus      reachable; no program in the regression set reaches it
"""
import importlib.util, os, re, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__))
COVDAT = os.path.join(HERE, "..", "..", "..", "tools", "covdat.py")

PC_SIGS = [("if_stage.sv", s) for s in ("pc", "if_id.pc", "pc_d", "pc_plus4", "pc_q")] + \
          [("rv32_core.sv", s) for s in ("imem_addr", "if_id.pc", "id_ex_q.pc", "ex_mem_q.pc",
                                         "mem_wb_q.pc_plus4", "if_pc")] + \
          [("csr.sv", "trap_epc")]
LO, HI = {0, 1}, set(range(19, 32))
ALL32 = set(range(32))
BOTH = ("0->1", "1->0")

# (class, basis, [(file, signal)], bits or None for a scalar, directions, why)
RULES = [
  ("PC_ALIGN", "bounded", PC_SIGS + [("csr.sv", "trap_epc_lsb_unused")], LO, BOTH,
   "every PC is 4-byte aligned: a misaligned branch/jump target traps (rv32_core.sv:440) "
   "and mtvec/mepc low bits are masked (csr.sv:201,219,223); pc_bmc PASS depth 20, "
   "pc_prove UNKNOWN (verif/formal/core_props)"),
  ("PC_HIGH", "stimulus", PC_SIGS, HI, BOTH,
   "no program in the regression set fetches at or above 0x80000 (512 KB); reachable"),
  ("TVEC_EPC_LSB", "construction",
   [("csr.sv", "mtvec_q"), ("csr.sv", "mepc_q"), ("csr.sv", "mtvec_o"), ("csr.sv", "mepc_o"),
    ("rv32_core.sv", "mtvec_o"), ("rv32_core.sv", "mepc_o")], LO, BOTH,
   "reset 0 and every write masks [1:0] to zero (csr.sv:201,219,223)"),
  ("CAUSE_HIGH", "construction", [("csr.sv", "trap_cause"), ("rv32_core.sv", "ex_trap_cause")],
   set(range(4, 32)), BOTH,
   "every cause is a literal below 16: 0,2,3,4,6,11 (rv32_core.sv:436-462)"),
  ("IRQ_TIED", "tied",
   [("csr.sv", "irq_timer"), ("csr.sv", "irq_software"), ("csr.sv", "irq_external"),
    ("csr.sv", "irq_pending"), ("rv32_core.sv", "irq_pending_o")], None, BOTH,
   "interrupt pins tied to 1'b0 until the M5 CLINT (rv32_core.sv:366-368, csr.sv:239)"),
  ("MIP", "tied", [("csr.sv", "mip")], ALL32, BOTH,
   "mip is the three tied-off pins and 29 constant zeros (csr.sv:83-88)"),
  ("MIE_WARL", "construction", [("csr.sv", "mie_q")], ALL32 - {3, 7, 11}, BOTH,
   "only MSIE/MTIE/MEIE are writable (csr.sv:217, MIE_WRITABLE rv32_pkg.sv:118-121; 0029)"),
  ("MSTATUS_CONST", "construction", [("csr.sv", "mstatus")], ALL32 - {3, 7, 11, 12}, BOTH,
   "only MIE (3) and MPIE (7) are stored; every other bit is a constant (csr.sv:91-96)"),
  ("MSTATUS_MPP", "construction", [("csr.sv", "mstatus")], {11, 12}, ("1->0",),
   "MPP is the constant 2'b11 (csr.sv:95) and never falls; its rise is hit, by "
   "Verilator's zero-initialised start (T4, not measured)"),
  ("IMM_ZERO", "construction", [("imm_gen.sv", "imm_b"), ("imm_gen.sv", "imm_j")], {0}, BOTH,
   "B- and J-immediate bit 0 is a literal zero (imm_gen.sv:38,44)"),
  ("IMM_U_LOW", "construction", [("imm_gen.sv", "imm_u")], set(range(12)), BOTH,
   "U-immediate bits [11:0] are a literal zero (imm_gen.sv:41)"),
  ("JALR_LSB", "construction", [("rv32_core.sv", "ex_jalr_target")], {0}, BOTH,
   "JALR clears bit 0 (rv32_core.sv:405)"),
  ("MISALIGNED_O", "proved", [("rv32_core.sv", "mem_misaligned_o")], None, BOTH,
   "a misaligned access traps in EX and is poisoned before MEM; mis_prove PASS, unbounded "
   "(verif/formal/core_props)"),
]

POINT = re.compile(r"^(?P<sig>.*?)(?:\[(?P<bit>\d+)\])?:(?P<dir>0->1|1->0)$")


def load_covdat():
    spec = importlib.util.spec_from_file_location("covdat", COVDAT)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def matches(rule, fname, sig, bit, d):
    _cls, _basis, sigs, bits, dirs, _why = rule
    if d not in dirs or not any(fname.endswith("/" + f) and sig == s for f, s in sigs):
        return False
    return bit is None if bits is None else (bit is not None and bit in bits)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    cd = load_covdat()
    union, _ = cd.build_union(cd.parse(sys.argv[1]))
    total = hit = 0
    rows, unmatched, multi = [], [], []
    used = collections.Counter()
    for (f, l, _n, _page, t, o), c in union.items():
        if "rtl/core/" not in f or t != "toggle":
            continue
        total += 1
        if c:
            hit += 1
            continue
        m = POINT.match(o)
        if not m:
            sys.exit(f"FATAL: cannot parse toggle point name {o!r} ({f}:{l})")
        bit = int(m["bit"]) if m["bit"] is not None else None
        hits = [r for r in RULES if matches(r, f, m["sig"], bit, m["dir"])]
        if not hits:
            unmatched.append((f, l, o))
            continue
        if len(hits) > 1:
            multi.append((f, l, o, [r[0] for r in hits]))
            continue
        r = hits[0]
        used[r[0]] += 1
        rows.append((f.split("rtl/core/")[-1], int(l), m["sig"],
                     "" if bit is None else bit, m["dir"], r[0], r[1]))

    print("file\tdecl_line\tsignal\tbit\tdirection\tclass\tbasis")
    for row in sorted(rows, key=lambda r: (r[0], r[1], r[2], -1 if r[3] == "" else r[3], r[4])):
        print("\t".join(str(x) for x in row))

    err = sys.stderr
    print(f"rtl/core toggle: {hit} / {total} hit, {total - hit} uncovered", file=err)
    for cls, basis, _s, _b, _d, why in RULES:
        print(f"  {cls:<14} {basis:<12} {used[cls]:>4}  {why}", file=err)
    stale = [r[0] for r in RULES if not used[r[0]]]
    for f, l, o in unmatched:
        print(f"UNMATCHED  {f}:{l}  {o}", file=err)
    for f, l, o, cl in multi:
        print(f"AMBIGUOUS  {f}:{l}  {o}  {cl}", file=err)
    for s in stale:
        print(f"STALE RULE {s}: matches no uncovered point", file=err)
    if unmatched or multi or stale:
        print(f"NOT CLASSIFIED: {len(unmatched)} unmatched, {len(multi)} ambiguous, "
              f"{len(stale)} stale rule(s)", file=err)
        sys.exit(1)
    print(f"CLASSIFIED: {len(rows)} of {total - hit} uncovered rtl/core toggle points, "
          f"{len(RULES)} classes", file=err)


if __name__ == "__main__":
    main()
