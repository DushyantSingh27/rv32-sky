# t07_counters - M3.7 regression program: the counters and the WARL/WLRL CSRs.
# docs/results/0029. Lockstep-checked against Sail (Zicntr enabled, ADR-0008).
#
# WHY THIS PROGRAM EXISTS. Structural coverage (docs/results/0028) found five
# csr.sv lines no program reached: no read of minstret, no write to any
# counter. Probes then measured four conformance bugs in exactly that code
# (0029). The probes settle one question each and are not in the regression;
# this program keeps every one of those cases checked on every run.
#
# EVERY READ IS PLACED WHERE A PLAUSIBLE-WRONG DESIGN DIFFERS (failure mode
# #1). The wrong design each section discriminates against is named in it.
# probe_minstret_write.S is the counter-example: it wrote 100 over a count of
# 3, where the mutated design agrees, and mutation M3 survived it.
#
# THE CHECK IS LOCKSTEP. compare.py compares every (pc, rd, value) against
# Sail. The program stores 0 to test control on completion, so the harness
# verdict means "ran to the end"; the values are Sail's to judge. No golden
# value in this file is derived from the core.
#
# NEVER READ: mcycle's low half (pipeline-dependent; Sail's legitimately
# differs) and cycle/time/instret (0xC00-0xC02: the core does not implement
# them, ADR-0008). mcycle is observed only through mcycleh after a carry,
# where both models must agree.
#
# PREDICTED RISKS, written before the first run (T4/T5):
#   R1  x21 (mcycleh after the carry) = 6. The first version assumed Sail
#       advances mcycle at least once per instruction and gave 24
#       instructions of margin over 16. REFUTED 2026-10-19: Sail read 5.
#       MEASURED (sw/tests/probe_mcycle.S, T1): Sail's mcycle advanced 6
#       over 12 instructions, half the instruction rate; consistent with
#       t07's first run (about 12 over 25, short of the 16 needed). Now 8 to
#       carry and 40 instructions: holds while Sail advances mcycle at least
#       once per 5 instructions.
#   R2  x24 (mcause after writing -1). mcause is WLRL; Sail stored 0x11111000
#       verbatim in t05_csr.S, so -1 is predicted to read back as written.
#   R3  x27 (mtvec after writing 0xfffffffc). MODE = 00, so predicted to read
#       back as written.
    .section .text
    .globl _start
_start:
    csrci mstatus, 8            # MIE = 0 throughout: Sail asserts MTIP (0017)

    # ---- 1. minstret behind a full pipeline (H1) ----
    # Wrong design: counting in WB reads 2 short here (two addi in MEM/WB).
    addi  x1, x0, 1
    addi  x2, x0, 2
    addi  x3, x0, 3
    csrr  x5, minstret

    # ---- 2. a write to the low half while it holds 0xffffffff (M3) ----
    # Wrong design: counting the writer carries into the high half -> x7 = 1.
    addi  x6, x0, -1            # 0xffffffff, reused below
    csrw  minstret, x6
    csrw  minstret, x2          # written while low == 0xffffffff
    csrr  x7, minstreth         # 0
    csrr  x8, minstret

    # ---- 3. writes to minstreth (H1d); all 32 high bits up and down ----
    # Wrong design: counting the minstreth writer in the low half -> x9 + 1.
    csrw  minstreth, x6
    csrr  x9, minstret
    csrr  x10, minstreth        # 0xffffffff
    csrw  minstreth, x0
    csrr  x11, minstreth        # 0

    # ---- 4. natural carry out of the low half ----
    # Wrong design: a 32-bit counter, or a broken carry -> x13 = 0.
    addi  x12, x0, -3           # 0xfffffffd
    csrw  minstret, x12
    nop
    nop
    nop
    nop
    nop
    csrr  x13, minstreth        # 1
    csrr  x14, minstret

    # ---- 5. a trapping instruction does not retire (H1b) ----
    # Wrong design: counting the ecall -> x17 one higher.
    la    x15, handler
    csrw  mtvec, x15
    csrr  x16, minstret
    ecall
    csrr  x17, minstret

    # ---- 6. mcycle carry, seen only through mcycleh (R1) ----
    # Wrong design: a 32-bit cycle counter, or a broken carry -> x21 = 5.
    csrw  mcycleh, x6           # all high bits up ...
    csrw  mcycleh, x0           # ... and down
    addi  x19, x0, -8           # 0xfffffff8: 8 to carry (R1)
    addi  x20, x0, 5
    csrw  mcycle, x19
    csrw  mcycleh, x20
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    csrr  x21, mcycleh          # 6

    # ---- 7. mie is WARL ----
    # Wrong design: storing all 32 bits -> x22 = 0xffffffff, not 0x888.
    csrw  mie, x6
    csrr  x22, mie
    csrw  mie, x0
    csrr  x23, mie

    # ---- 8. mcause (R2), mtvec (R3), mscratch: all ones, then zero ----
    csrw  mcause, x6
    csrr  x24, mcause
    csrw  mcause, x0
    csrr  x25, mcause
    addi  x26, x0, -4           # 0xfffffffc, MODE = 00
    csrw  mtvec, x26
    csrr  x27, mtvec
    csrw  mtvec, x0
    csrr  x27, mtvec
    csrw  mscratch, x6
    csrr  x28, mscratch
    csrw  mscratch, x0
    csrr  x29, mscratch

    # ---- 9. a console write: the peripheral strobe falls before the end ----
    lui   x30, 0x80000
    addi  x31, x0, 0x4b         # 'K'
    sw    x31, 4(x30)           # 0x8000_0004, console

    # ---- terminate: HTIF for Sail, then the Verilator address ----
    lui   x28, 0x1              # 0x1000 = tohost
    addi  x29, x0, 1
    sw    x29, 0(x28)
    sw    x0, 0(x30)            # 0x8000_0000, test control: 0 = ran to the end
halt:
    sw    x29, 0(x28)
    sw    x0,  4(x28)
    beq   x0, x0, halt

    # Placed after the halt loop so execution never falls into it.
handler:
    csrr  x18, mepc
    addi  x18, x18, 4           # skip the ecall
    csrw  mepc, x18
    mret
