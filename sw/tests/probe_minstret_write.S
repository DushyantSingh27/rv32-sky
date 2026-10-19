# M3.7 stage 2 PROBE (H1c) - what does minstret read right after a write?
# Not a gate test and not in the regression set; it settles one question.
# Needs Sail with Zicntr enabled: run by run_s2c.sh under a TEMPORARY config.
#
# THE QUESTION. The spec says only "Any CSR write takes effect after the
# writing instruction has otherwise completed" (privileged ISA, Hardware
# Performance Monitor; T2). Whether the WRITING instruction's own retirement
# is then counted on top of the written value is not stated there. Sail's
# answer is the reference, so there is NO Sail prediction: this is a
# measurement, and the minstret fix is designed against it.
#
# ISOLATION FROM H1. The write sits behind a taken branch, so no older
# instruction is in flight when it lands, and R1 is drained the same way.
# R0 follows the write directly, so the write itself is in MEM when R0 reads.
#
# CORE PREDICTIONS (T4, from the current RTL):
#   W  in EX sets minstret_q[31:0] = 100; it then retires in WB -> 101
#   R0 (x5): reads in EX the cycle after W                     core 100
#   R1 (x6): 100 + W + R0 + beq, each counted at its WB         core 103
# SAIL, either of:
#   R0 100, R1 102   the write is final; W's own retirement is not counted
#   R0 101, R1 103   W's retirement is counted after the written value
    .section .text
    .globl _start
_start:
    addi  x3, x0, 100
    beq   x0, x0, d0            # drain: nothing older in flight at the write
    nop                         # squashed
    nop                         # squashed
d0:
    csrw  minstret, x3          # W
    csrr  x5, minstret          # R0: immediately after W
    beq   x0, x0, d1            # drain
    nop                         # squashed
    nop                         # squashed
d1:
    csrr  x6, minstret          # R1

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
