# M3.7 stage 2 PROBE - when does a csrr see minstret? Not a gate test and not
# in the regression set; it exists to settle one hypothesis.
#
# HYPOTHESIS (T4, from reading the RTL on 2026-10-17)
#   csr.sv is read in EX: csr_addr is id_ex_q.imm (rv32_core.sv:350).
#   minstret counts in WB: instr_retired is mem_wb_q.valid (rv32_core.sv:372).
#   So a csrr minstret misses every OLDER instruction still in MEM or WB at the
#   moment it executes. Sail counts every instruction retired before it.
#
# WHY NOTHING HAS SEEN THIS
#   No program reads minstret (csr.sv:114 has zero line coverage, 2026-10-17).
#   t05_csr.S excludes all four counters because "Sail has no model of this
#   pipeline" - true of mcycle, not of minstret, which is architectural. The
#   one counter read that does happen, minstreth, is 0 in both models.
#   A self-checking DELTA between two reads would also miss it: both reads are
#   short by the same amount. Only an independent model sees the absolute value.
#
# PREDICTIONS, written before the run
#   read A (x5): the pipeline is drained by a taken branch first. A taken branch
#                costs two cycles (rv32_core.sv:15), so MEM and WB hold bubbles
#                when A executes.                     -> core AGREES with Sail
#   read B (x6): three straight-line ALU instructions ahead, so MEM and WB hold
#                two of them when B executes.         -> core = Sail - 2
#   compare.py's VERDICT stops at the first divergence, but Sail and the core
#   each run this program to completion on their own, so both traces carry A
#   and B whatever happens; the run script reads both values from both logs.
#   A is placed first so that compare.py's verdict, if it diverges at all,
#   diverges where the hypothesis says it should.
#   In numbers, if both models start minstret at 0 (Sail's start value: T5):
#     A: Sail 3 (addi, addi, beq), core 3
#     B: Sail 7 (those + csrr A + three addi), core 5
#   The DIFFERENCE is the prediction; the absolute values depend on that start.
#
# WHAT EACH OUTCOME MEANS
#   A agrees, B is Sail - 2   hypothesis confirmed
#   A agrees, B agrees        hypothesis wrong; something closes the gap
#   A diverges                a different model of the bug is needed
#   Sail writes no x5 at A    Sail TRAPPED on csrr minstret: it treats the CSR
#                             as unimplemented. verif/sail/rv32sky.json sets
#                             Zicntr "supported": false; whether Sail gates
#                             minstret on that is T5.
#                             A configuration question, not a core result -
#                             stop and re-plan.
#   B differs by other than 2 the in-flight model is wrong; record the value
#
# No mcycle read anywhere: the cycle count is pipeline-dependent and Sail's
# differs for a legitimate reason (t05_csr.S header, docs/results/0017).
    .section .text
    .globl _start
_start:
    addi  x1, x0, 1
    addi  x2, x0, 2
    beq   x0, x0, drained       # taken; the two slots behind it are squashed
    addi  x3, x0, 99            # squashed, never retires
    addi  x3, x0, 98            # squashed, never retires
drained:
    csrr  x5, minstret          # read A: pipeline drained
    addi  x7, x0, 7
    addi  x8, x0, 8
    addi  x9, x0, 9
    csrr  x6, minstret          # read B: x8 in WB, x9 in MEM

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
