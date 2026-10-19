# M3.7 / 0029 PROBE (H1d) - does a write to MINSTRETH stop the writing
# instruction from incrementing the LOW half? Not a gate test and not in the
# regression set; it settles one question.
#
# C3 (6537eb2) suppresses the increment for writes to either half; that was a
# design guess, labelled T5 in csr.sv. The spec says only that "any CSR write
# takes effect after the writing instruction has otherwise completed" (T2).
# Sail's answer is the reference, so there is NO Sail prediction.
#
# CORE PREDICTION (committed RTL): x5 = 8  (7 written, W_h not counted, beq)
# SAIL, either of:
#   x5 = 8   W_h is not counted either: C3 is right
#   x5 = 9   W_h IS counted in the low half: C3 is wrong for minstreth -
#            stop and re-plan
# x6 = minstreth = 0x10 in every case.
    .section .text
    .globl _start
_start:
    addi  x3, x0, 7
    addi  x4, x0, 0x10
    beq   x0, x0, d0            # drain
    nop                         # squashed
    nop                         # squashed
d0:
    csrw  minstret,  x3         # low = 7
    csrw  minstreth, x4         # W_h
    beq   x0, x0, d1            # drain
    nop                         # squashed
    nop                         # squashed
d1:
    csrr  x5, minstret          # THE MEASUREMENT
    csrr  x6, minstreth

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
