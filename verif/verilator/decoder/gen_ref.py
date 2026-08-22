#!/usr/bin/env python3
"""
Generate reference decode data using the RISC-V assembler.

The reference is riscv64-unknown-elf-as, NOT a hand-written model. Same
discipline as the UVM scoreboards: a model written by the same person who
wrote the DUT inherits that person's misreadings. Here the encodings come from
the toolchain that compilers actually target.

Emits a C header of {encoding, expected fields} for the Verilator harness.
"""
import subprocess, tempfile, pathlib, sys, re, random

AS      = "riscv64-unknown-elf-as"
OBJDUMP = "riscv64-unknown-elf-objdump"

R_OPS = ["add","sub","sll","slt","sltu","xor","srl","sra","or","and"]
I_OPS = ["addi","slti","sltiu","xori","ori","andi"]
SH_I  = ["slli","srli","srai"]
LOADS = ["lb","lh","lw","lbu","lhu"]
STORES= ["sb","sh","sw"]
BRANCH= ["beq","bne","blt","bge","bltu","bgeu"]

def assemble(lines):
    """Assemble a list of instructions, return their 32-bit encodings in order."""
    with tempfile.TemporaryDirectory() as d:
        src = pathlib.Path(d) / "t.S"
        obj = pathlib.Path(d) / "t.o"
        src.write_text(".text\n.globl _start\n_start:\n" +
                       "\n".join("    " + l for l in lines) + "\n")
        r = subprocess.run([AS, "-march=rv32i_zicsr", "-mabi=ilp32",
                            str(src), "-o", str(obj)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            sys.exit(1)
        r = subprocess.run([OBJDUMP, "-d", "--no-show-raw-insn", "-M", "numeric",
                            str(obj)], capture_output=True, text=True)
        r2 = subprocess.run([OBJDUMP, "-d", str(obj)],
                            capture_output=True, text=True)
        encs = []
        for line in r2.stdout.splitlines():
            m = re.match(r'\s+[0-9a-f]+:\s+([0-9a-f]{8})\s+', line)
            if m:
                encs.append(int(m.group(1), 16))
        return encs

def expected_imm(enc):
    """
    The immediate the RISC-V spec says this encoding carries, computed from the
    ENCODING per the format tables - not from the assembly text, and not from
    the RTL.

    Returned as an unsigned 32-bit value, matching how the DUT drives it.
    """
    op = enc & 0x7f
    def sx(v, bits):
        return v - (1 << bits) if v & (1 << (bits - 1)) else v

    if op in (0x03, 0x13, 0x67, 0x0f, 0x73):            # I-type
        imm = sx((enc >> 20) & 0xfff, 12)
    elif op == 0x23:                                     # S-type
        imm = sx((((enc >> 25) & 0x7f) << 5) | ((enc >> 7) & 0x1f), 12)
    elif op == 0x63:                                     # B-type
        raw = (((enc >> 31) & 1) << 12) | (((enc >> 7) & 1) << 11) | \
              (((enc >> 25) & 0x3f) << 5) | (((enc >> 8) & 0xf) << 1)
        imm = sx(raw, 13)
    elif op in (0x37, 0x17):                             # U-type, NOT sign-extended
        return enc & 0xfffff000
    elif op == 0x6f:                                     # J-type
        raw = (((enc >> 31) & 1) << 20) | (((enc >> 12) & 0xff) << 12) | \
              (((enc >> 20) & 1) << 11) | (((enc >> 21) & 0x3ff) << 1)
        imm = sx(raw, 21)
    else:                                                # R-type, no immediate
        return 0
    return imm & 0xffffffff


def main():
    rnd = random.Random(20260813)
    cases = []          # (asm_text, encoding, expected_imm)

    def add(lines):
        encs = assemble(lines)
        assert len(encs) == len(lines), \
            f"expected {len(lines)} encodings, got {len(encs)}"
        for l, e in zip(lines, encs):
            cases.append((l, e, expected_imm(e)))

    # Register-register: every op, randomised registers.
    add([f"{op} x{rnd.randrange(32)}, x{rnd.randrange(32)}, x{rnd.randrange(32)}"
         for op in R_OPS for _ in range(4)])

    # Register-immediate, including the sign-extension boundaries.
    imms = [0, 1, -1, 2047, -2048, 5, -5]
    add([f"{op} x{rnd.randrange(32)}, x{rnd.randrange(32)}, {i}"
         for op in I_OPS for i in imms])

    # Shift-immediate: 0, 1, 31 are the interesting shift amounts.
    add([f"{op} x{rnd.randrange(32)}, x{rnd.randrange(32)}, {s}"
         for op in SH_I for s in (0, 1, 15, 31)])

    # Upper immediate.
    add([f"lui x{rnd.randrange(32)}, {v}"   for v in (0, 1, 0xFFFFF, 0x12345)])
    add([f"auipc x{rnd.randrange(32)}, {v}" for v in (0, 1, 0xFFFFF, 0x12345)])

    # Loads and stores, offsets at the sign boundary.
    offs = [0, 4, -4, 2047, -2048]
    add([f"{op} x{rnd.randrange(32)}, {o}(x{rnd.randrange(32)})"
         for op in LOADS for o in offs])
    add([f"{op} x{rnd.randrange(32)}, {o}(x{rnd.randrange(32)})"
         for op in STORES for o in offs])

    # Branches. Offsets must be even; use a local label at a known distance.
    #
    # The offsets below MUST include values where immediate bit 11 differs from
    # the sign bit (bit 12), i.e. +2048..+4094 or -4096..-2050. Without them, a
    # decoder that sources bit 11 from instr[31] instead of instr[7] produces
    # identical results and the bug is invisible.
    #
    # Found by mutation testing 2026-08-17: the original set (4, 8, -4, 2044,
    # -2048) had bit 11 == sign bit in every case, and that mutation SURVIVED.
    for op in BRANCH:
        for off in (4, 8, -4, 2044, -2048, 2048, 3000, 4094, -2050, -4096):
            lines = []
            if off > 0:
                lines.append(f"{op} x1, x2, .+{off}")
            else:
                lines.append(f"{op} x1, x2, .{off}")
            add(lines)

    # Jumps. Same rule: J-type bit 11 comes from instr[20], not instr[31], so
    # the set needs offsets where bit 11 and the sign bit (bit 20) differ.
    for off in (4, 8, -4, 1048572, -1048576, 2048, 4096, -2050, 524288, -524290):
        add([f"jal x{rnd.randrange(32)}, .+{off}" if off > 0
             else f"jal x{rnd.randrange(32)}, .{off}"])
    add([f"jalr x{rnd.randrange(32)}, {o}(x{rnd.randrange(32)})"
         for o in (0, 4, -4, 2047, -2048)])

    # System and fence.
    add(["ecall", "ebreak", "fence", "fence.i", "mret"])

    # ------------------------------------------------------------------
    # Zicsr. Every vector here exists because correct and plausible-wrong
    # decoders DISAGREE on it. Vectors where they agree are not listed.
    #
    # THE CENTRAL CASE - `csrrw x5, mscratch, x0` and its immediate form.
    # CSRRW/CSRRWI write UNCONDITIONALLY; CSRRS/CSRRC write only when
    # rs1/uimm is non-zero. csr.sv:33 documents the rs1-based rule for every
    # form, which would make `csrw mscratch, x0` - the idiomatic CSR-zeroing
    # sequence - perform no write at all. Every CSR write with a NON-x0
    # source decodes identically under both rules, so a vector set without an
    # x0 source cannot see the difference.
    #
    # csrrs with rs1=x0 is the mirror: it must NOT write. A decoder that
    # writes unconditionally for all six forms passes every csrrw vector and
    # fails only here.
    #
    # mcycle (0xB00) and mhartid (0xF14) have bit 11 set, so their addresses
    # sign-extend negative through imm_gen. imm[11:0] must still carry the
    # address - this is what makes a csr_addr field in ctrl_t unnecessary.
    # ------------------------------------------------------------------
    add([
        # CSRRW: writes always, reads only when rd != x0
        "csrrw  x5, mscratch, x6",      # both read and write
        "csrrw  x0, mscratch, x6",      # rd=x0: no read, write STILL happens
        "csrrw  x5, mscratch, x0",      # rs1=x0: write STILL happens
        "csrrw  x0, mscratch, x0",      # neither: write STILL happens
        # CSRRS: reads always, writes only when rs1 != x0
        "csrrs  x5, mscratch, x6",      # read and write
        "csrrs  x5, mscratch, x0",      # rs1=x0: NO write
        "csrrs  x0, mscratch, x6",      # rd=x0: write, no delivered read
        # CSRRC: same write rule as CSRRS
        "csrrc  x5, mscratch, x6",
        "csrrc  x5, mscratch, x0",      # rs1=x0: NO write
        # Immediate forms: uimm occupies rs1's field but is NOT a register,
        # so rs1_used must be 0 or the hazard unit forwards into an immediate.
        "csrrwi x5, mscratch, 15",
        "csrrwi x5, mscratch, 0",       # uimm=0: CSRRWI writes ANYWAY
        "csrrwi x0, mscratch, 0",
        "csrrsi x5, mscratch, 31",      # max uimm, all five bits set
        "csrrsi x5, mscratch, 0",       # uimm=0: NO write
        "csrrci x5, mscratch, 1",
        "csrrci x5, mscratch, 0",       # uimm=0: NO write
        # High CSR addresses: bit 11 set, sign-extends negative through imm_gen
        "csrrs  x5, mcycle, x0",        # 0xB00
        "csrrs  x5, mhartid, x0",       # 0xF14
        "csrrw  x5, mtvec, x6",         # 0x305, the ACT4 preamble writes this
    ])

    out = pathlib.Path(__file__).parent / "ref_cases.h"
    with out.open("w") as f:
        f.write("// GENERATED by gen_ref.py - do not edit.\n")
        f.write("// Encodings produced by riscv64-unknown-elf-as, an\n")
        f.write("// independent reference. Regenerate with: make ref\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write("typedef struct { uint32_t enc; uint32_t imm;"
                " const char *asm_text; } ref_case_t;\n\n")
        f.write("static const ref_case_t ref_cases[] = {\n")
        for txt, enc, imm in cases:
            f.write(f'    {{0x{enc:08x}u, 0x{imm:08x}u, "{txt}"}},\n')
        f.write("};\n\n")
        f.write(f"static const int n_ref_cases = {len(cases)};\n")
    print(f"wrote {len(cases)} reference cases to {out}")

if __name__ == "__main__":
    main()
