# M3.2 gate test: arithmetic and logic, NOP-padded.
#
# THREE NOPs between every dependent pair. M3.2 has no forwarding and no
# interlock: a result written in WB is not visible to an instruction in ID
# until it has committed. Three NOPs guarantee that. The padding is scaffold,
# removed at M3.3 when forwarding exists.
    .section .text
    .globl _start
_start:
    addi  x1, x0, 10        # x1 = 10
    nop
    nop
    nop
    addi  x2, x0, 20        # x2 = 20
    nop
    nop
    nop
    add   x3, x1, x2        # x3 = 30
    nop
    nop
    nop
    sub   x4, x2, x1        # x4 = 10
    nop
    nop
    nop
    xor   x5, x1, x2        # x5 = 10 ^ 20 = 30
    nop
    nop
    nop
    slli  x6, x1, 2         # x6 = 40
    nop
    nop
    nop
    slt   x7, x1, x2        # x7 = 1
    nop
    nop
    nop

    # Check x3 == 30. Anything else jumps to fail with a code.
    addi  x10, x0, 30
    nop
    nop
    nop
    bne   x3, x10, fail1
    nop
    nop
    nop

    # Check x6 == 40.
    addi  x10, x0, 40
    nop
    nop
    nop
    bne   x6, x10, fail2
    nop
    nop
    nop

pass:
    lui   x20, 0x80000      # x20 = 0x80000000, test control
    nop
    nop
    nop
    sw    x0, 0(x20)        # store 0 = PASS
    nop
    nop
    nop
halt:
    beq   x0, x0, halt

fail1:
    lui   x20, 0x80000
    nop
    nop
    nop
    addi  x21, x0, 1
    nop
    nop
    nop
    sw    x21, 0(x20)
    beq   x0, x0, halt

fail2:
    lui   x20, 0x80000
    nop
    nop
    nop
    addi  x21, x0, 2
    nop
    nop
    nop
    sw    x21, 0(x20)
    beq   x0, x0, halt
