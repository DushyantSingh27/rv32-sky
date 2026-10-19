# M3.7 stage 2 PROBE (H1b) - does a TRAPPING instruction increment minstret?
# Not a gate test and not in the regression set; it settles one hypothesis.
# Needs Sail with Zicntr enabled: run by run_s2c.sh under a TEMPORARY config.
#
# HYPOTHESIS (T4, from reading the RTL on 2026-10-17)
#   instr_retired is mem_wb_q.valid (rv32_core.sv:372). A trapping instruction
#   is POISONED, not squashed: valid is kept so the trace matches Sail's record
#   for it (rv32_core.sv, the ex_mem_q block). So the core counts it. Under the
#   ISA a trapping instruction does not retire, so Sail should not.
#
# ISOLATION FROM H1. Both reads sit behind a taken branch, so MEM and WB hold
# bubbles when they execute. H1 (step 2b, measured) cannot move either value.
#
# PREDICTIONS, written before the run (both models start minstret at 0):
#   R0 (x5): la (2) + csrw + beq                         Sail 4,  core 4
#   R1 (x6): R0 + csrr R0 + handler (4) + beq, NO ecall  Sail 10, core 11
#   core - Sail at R1 = +1: the ecall, counted by the core only.
#
# WHAT EACH OUTCOME MEANS
#   R0 agrees, R1 core = Sail + 1   hypothesis confirmed
#   R0 agrees, R1 agrees            Sail counts the ecall too; hypothesis wrong
#   R0 diverges                     the drain does not isolate H1; stop
    .section .text
    .globl _start
_start:
    la    x1, handler
    csrw  mtvec, x1
    beq   x0, x0, d0            # drain
    nop                         # squashed
    nop                         # squashed
d0:
    csrr  x5, minstret          # R0
    ecall                       # traps; the handler returns to the next line
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

    # Placed after the halt loop so execution never falls into it.
handler:
    csrr  x9, mepc
    addi  x9, x9, 4             # skip the ecall
    csrw  mepc, x9
    mret
