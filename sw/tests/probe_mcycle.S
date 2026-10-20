# M3.7 / 0029 PROBE - how does Sail advance mcycle? Not a gate test and not in
# the regression set. It is EXPECTED to diverge from the core: mcycle's low
# half is pipeline-dependent. Only Sail's values are the measurement.
#
# WHY. t07_counters (2026-10-19) wrote mcycle = 0xfffffff0, mcycleh = 5, ran
# 24 nops and read mcycleh: core 6, Sail 5. Risk R1 in t07's header assumed
# Sail advances mcycle at least once per instruction; 25 instructions would
# then have carried. They did not, so R1 is REFUTED (T1). The rate is unknown.
#
# MEASUREMENT: Sail's mcycle and minstret, read side by side at two points
# ten nops apart. No prediction: the deltas are the answer.
#   mcycle delta 0         Sail does not advance mcycle at all
#   mcycle delta = minstret delta   one per instruction (contradicts t07)
#   anything else          recorded as measured
    .section .text
    .globl _start
_start:
    csrr  x5, mcycle            # A
    csrr  x6, minstret          # A
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
    csrr  x7, mcycle            # B
    csrr  x8, minstret          # B

    # ---- terminate: HTIF for Sail, then the Verilator address ----
    lui   x28, 0x1              # 0x1000 = tohost
    addi  x29, x0, 1
    sw    x29, 0(x28)
    lui   x27, 0x80000
    sw    x0, 0(x27)
halt:
    sw    x29, 0(x28)
    sw    x0,  4(x28)
    beq   x0, x0, halt
