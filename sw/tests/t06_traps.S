# M3.4a gate test: synchronous traps and mret.
#
# Six causes, each verified against Sail: 0 (instruction address misaligned),
# 2 (illegal instruction), 3 (breakpoint), 4 (load misaligned),
# 6 (store misaligned), 11 (ecall from M-mode).
#
# EVERY TRAP CSR IS READ BACK INTO A GPR. Lockstep compares (pc, rd, value);
# a correct mcause that no instruction reads is invisible to it. Same rule
# t05_csr was written around.
#
# THE STORE-SUPPRESSION CHECK. A test that only reads mcause cannot tell
# "trap taken, store suppressed" from "trap taken, store landed anyway".
# 0x1104 is primed with a known value, the misaligned store to 0x1102 traps,
# and 0x1104 is read back - it must be unchanged. That is the check that
# proves ex_mem_q poisoning suppresses the memory request.
#
# mtvec is set from a LABEL. An earlier probe used `.org 0x1400`, which padded
# .text to 0x141f and collided with .tohost at 0x1000.
#
# mstatus.MIE stays 0 and mie.MTIE is never set: Sail asserts mip.MTIP with
# the CLINT disabled, and arming both takes a timer interrupt the core cannot
# (docs/results/0017).
#
# Forwarding is live (M3.3), so no NOP padding.
    .section .text
    .globl _start
_start:
    addi  x31, x0, 0            # checksum accumulator

    la    x1, trap_handler
    csrw  mtvec, x1
    csrr  x2, mtvec             # readback - MODE bits read 0
    xor   x31, x31, x2

    addi  x3, x0, 0             # trap counter

    # ---- prime memory for the store-suppression check ----
    # 0x1100 is the test data area; 0x1104 holds a sentinel that a leaked
    # misaligned store to 0x1102 would corrupt.
    # SENTINEL AT 0x1100, NOT 0x1104.
    #
    # tcm.sv indexes b_word = b_addr[12:2] - the low two bits are DISCARDED.
    # A leaked word store to 0x1102 therefore writes word 0x440, which is
    # address 0x1100. An earlier version put the sentinel at 0x1104 and
    # mutation T2 (mem_write not suppressed) SURVIVED: the leak landed one
    # word away from where the test was looking. Seventh instance of a test
    # value landing where correct and broken implementations agree.
    lui   x4, 0x1
    addi  x4, x4, 0x100         # 0x1100
    lui   x5, 0xC0FFE
    addi  x5, x5, 0x123         # 0xC0FFE123 - differs from 0x5A in every lane
    sw    x5, 0(x4)             # [0x1100] = sentinel
    lw    x6, 0(x4)             # confirm it landed
    xor   x31, x31, x6

    # ---- cause 2: illegal instruction. mtval = the instruction word. ----
here_ill:
    .word 0x02000033            # mul x0,x0,x0 - RV32M, illegal until M4
    add   x31, x31, x9          # mcause from the handler
    add   x31, x31, x11         # mtval - must be 0x02000033

    # ---- cause 3: ebreak. mtval = the PC. ----
here_ebrk:
    ebreak
    add   x31, x31, x9
    sub   x12, x11, x10         # mtval - mepc: must be 0 for ebreak
    add   x31, x31, x12

    # ---- cause 11: ecall. mtval = 0. ----
here_ecall:
    ecall
    add   x31, x31, x9
    add   x31, x31, x11         # must contribute 0

    # ---- cause 6: misaligned STORE to 0x1102. ----
    addi  x7, x4, 2             # 0x1102 - halfword-aligned only
    addi  x8, x0, 0x5A
here_st:
    sw    x8, 0(x7)             # traps; must NOT reach memory
    add   x31, x31, x9          # mcause - must be 6
    add   x31, x31, x11         # mtval - must be 0x1102

    # THE SUPPRESSION CHECK. A leaked word store to 0x1102 writes word 0x440
    # = address 0x1100 with byte_en 4'b1111, replacing the sentinel entirely.
    lw    x13, 0(x4)
    xor   x31, x31, x13         # must still be 0xC0FFE123

    # SECOND SUPPRESSION CHECK, halfword. byte_en is 4'b1100 for a misaligned
    # sh, so only the UPPER half would be corrupted - a partial-suppression
    # bug the word case above cannot see. Also exercises is_misaligned at
    # MEM_H rather than only MEM_W.
    addi  x18, x0, 0x7B
here_sh:
    sh    x18, 1(x4)            # 0x1101 - odd, misaligned for a halfword
    add   x31, x31, x9          # mcause - must be 6
    add   x31, x31, x11         # mtval - must be 0x1101
    lw    x19, 0(x4)
    xor   x31, x31, x19         # sentinel STILL intact

    # ---- cause 4: misaligned LOAD from 0x1102. ----
here_ld:
    lw    x14, 0(x7)            # traps; x14 must NOT be written
    add   x31, x31, x9          # mcause - must be 4
    add   x31, x31, x11         # mtval - must be 0x1102

    # ---- cause 0: instruction address misaligned. mtval = the target. ----
    # jalr masks bit 0 only, so bit 1 survives and 0x1202 is 2-mod-4.
    lui   x15, 0x1
    addi  x15, x15, 0x202
here_jalr:
    jalr  x16, 0(x15)           # traps INSTEAD of jumping; x16 not written
    add   x31, x31, x9          # mcause - must be 0
    add   x31, x31, x11         # mtval - must be 0x1202

    # ---- mret returned correctly six times ----
    add   x31, x31, x3          # trap count - must be 6

    # ---- terminate ----
    lui   x28, 0x1              # 0x1000 = tohost
    slli  x29, x31, 1
    ori   x29, x29, 1
    sw    x29, 0(x28)
    lui   x27, 0x80000
    sw    x31, 0(x27)
halt:
    sw    x29, 0(x28)
    sw    x0,  4(x28)
    beq   x0, x0, halt

    # ---- trap handler ----
    # Placed after the halt loop so execution never falls into it. Leaves
    # mcause in x9, mepc in x10 and mtval in x11 for the caller to fold into
    # the checksum, then skips the faulting instruction and returns.
trap_handler:
    csrr  x9,  mcause
    csrr  x10, mepc
    csrr  x11, mtval
    addi  x3,  x3, 1
    addi  x17, x10, 4           # skip the faulting instruction
    csrw  mepc, x17
    mret
