# M3.4a step 5 PROBE - measures Sail's trap behaviour. Not a gate test.
#
# Answers four questions no amount of reasoning settles:
#   1. does Sail retire the trapping instruction?
#   2. what does mtval hold for each cause?
#   3. does AlignmentException give cause 4/6?
#   4. does mepc point at the trapping instruction?
#
# Every value is read into a GPR. Lockstep compares (pc, rd, value), so a CSR
# never read back is invisible - the rule from t05_csr.
#
# mtvec IS SET FROM A LABEL, not a fixed address. An earlier version used
# `.org 0x1400` to place the handler, which padded .text out to 0x141f and
# collided with .tohost at 0x1000 - the linker caught it. The handler does not
# need a fixed address; the linker knows where it is.
#
# mstatus.MIE stays 0 and MTIE is never set: Sail asserts mip.MTIP with the
# CLINT disabled, and arming both takes a timer interrupt the core cannot
# (docs/results/0017).
    .section .text
    .globl _start
_start:
    la    x1, trap_handler
    csrw  mtvec, x1
    csrr  x2, mtvec             # readback - proves the write landed

    addi  x3, x0, 0             # trap counter

    # ---- cause 2: illegal instruction ----
    # 0x02000033 is `mul x0, x0, x0` - funct7=0000001, illegal until M4.
here_ill:
    .word 0x02000033
    addi  x20, x0, 1            # marker: execution resumed here

    # ---- cause 3: ebreak ----
here_ebrk:
    ebreak
    addi  x21, x0, 2

    # ---- cause 11: ecall from M-mode ----
here_ecall:
    ecall
    addi  x22, x0, 3

    # ---- cause 6: misaligned STORE ----
    # 0x1102 is halfword-aligned only; a word store there is misaligned.
    lui   x4, 0x1
    addi  x4, x4, 0x102
    addi  x5, x0, 0x5A
here_st:
    sw    x5, 0(x4)
    addi  x23, x0, 4

    # ---- cause 4: misaligned LOAD ----
here_ld:
    lw    x6, 0(x4)
    addi  x24, x0, 5

    # ---- cause 0: instruction address misaligned ----
    # jalr masks bit 0 only, so bit 1 survives and 0x1202 is 2-mod-4.
    lui   x7, 0x1
    addi  x7, x7, 0x202
here_jalr:
    jalr  x8, 0(x7)
    addi  x25, x0, 6

    # ---- terminate ----
    add   x26, x3, x0           # final trap count into a GPR
    lui   x28, 0x1              # 0x1000 = tohost
    addi  x29, x0, 1
    sw    x29, 0(x28)
    lui   x27, 0x80000
    sw    x0, 0(x27)
halt:
    sw    x29, 0(x28)
    sw    x0,  4(x28)
    beq   x0, x0, halt

    # ---- trap handler ----
    # Placed after the halt loop so execution never falls into it. Reads the
    # three trap CSRs into GPRs, bumps mepc past the faulting instruction, and
    # returns. x9-x12 are rewritten each trap, so the trace carries one
    # (rd, value) triple per CSR per trap.
trap_handler:
    csrr  x9,  mcause
    csrr  x10, mepc
    csrr  x11, mtval
    addi  x3,  x3, 1
    addi  x10, x10, 4           # skip the faulting instruction
    csrw  mepc, x10
    csrr  x12, mepc             # readback - confirms the write landed
    mret
