# M3.7 / 0029 PROBE - does the write-suppression term in csr.sv matter for a
# write to the LOW half? Not a gate test and not in the regression set.
#
# WHY THIS EXISTS. Mutation M3 (drop `&& !writes_minstret`) SURVIVED all four
# probes on 2026-10-19. HYPOTHESIS (T4, from reading csr.sv): since C3 the
# writing instruction's increment and its write land in the SAME clock edge.
# The increment assigns all 64 bits, the write then assigns [31:0], and the
# later nonblocking assignment wins for those bits. So for a write to the low
# half the term only matters when the increment would CARRY into [63:32] -
# and probe_minstret_write wrote 100 over a count of 3, where it cannot.
# Failure mode #1: a test value where the correct and the mutated design
# agree. Mine.
#
# THE DISCRIMINATING VALUE. W1 sets the low half to 0xffffffff; W2 writes the
# low half again WHILE it is 0xffffffff. Counted (the mutant), W2's increment
# carries and the high half becomes 1. Not counted, the high half stays 0.
#
# PREDICTIONS, written before the run:
#   x5 = minstreth after W2:  Sail 0 | committed core 0 | M3 mutant 1
#   x6 = minstret  after W2:  7 everywhere (5, then beq and csrr x5 counted)
    .section .text
    .globl _start
_start:
    addi  x3, x0, -1            # 0xffffffff
    addi  x4, x0, 5
    beq   x0, x0, d0            # drain
    nop                         # squashed
    nop                         # squashed
d0:
    csrw  minstret, x3          # W1: low = 0xffffffff
    csrw  minstret, x4          # W2: runs while low == 0xffffffff
    beq   x0, x0, d1            # drain
    nop                         # squashed
    nop                         # squashed
d1:
    csrr  x5, minstreth         # THE MEASUREMENT
    csrr  x6, minstret

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
