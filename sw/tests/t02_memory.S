# M3.2 gate test 2: taken branches, loads and stores.
#
# Written after mutation testing showed t01 could not detect:
#   - branch redirect disabled  (t01 never takes a branch on the pass path)
#   - load writeback broken     (t01 contains no loads)
#
# THREE NOPs between dependent pairs. No forwarding until M3.3.
#
# DATA LIVES AT 0x1000, WELL CLEAR OF THE CODE.
# An earlier version used address 256 (0x100), which is INSIDE the instruction
# stream. The store overwrote a NOP, the fetch unit later read 0xdeadbeef back
# as an instruction, and 0xdeadbeef's low bits happen to encode a JAL - which
# produced a jump to an impossible odd address. The core behaved correctly; a
# unified TCM has no protection between code and data.
# The program is 0x2b8 bytes, so 0x1000 is comfortably clear of it.
    .section .text
    .globl _start
_start:
    # ---- TAKEN forward branch ----
    addi  x1, x0, 5
    nop
    nop
    nop
    addi  x2, x0, 5
    nop
    nop
    nop
    beq   x1, x2, taken1     # MUST be taken
    nop
    nop
    nop
    addi  x30, x0, 1         # must NOT execute
    beq   x0, x0, fail

taken1:
    # ---- TAKEN backward branch, a 3-iteration loop ----
    addi  x3, x0, 3          # counter
    nop
    nop
    nop
    addi  x4, x0, 0          # accumulator
loop:
    addi  x4, x4, 7          # x4 += 7
    nop
    nop
    nop
    addi  x3, x3, -1
    nop
    nop
    nop
    bne   x3, x0, loop       # taken twice, then falls through
    nop
    nop
    nop
    addi  x10, x0, 21        # 3 * 7
    nop
    nop
    nop
    bne   x4, x10, fail      # x4 must be 21

    # ---- STORE then LOAD, word ----
    nop
    nop
    nop
    # 0x1100, NOT 0x1000. The linker reserves 0x1000-0x10ff for HTIF
    # (tohost at 0x1000, fromhost at 0x1008). Test data there made Sail read it
    # as an HTIF command and reset the machine.
    lui   x5, 0x1
    nop
    nop
    nop
    addi  x5, x5, 0x100      # 0x1100 = test data area
    nop
    nop
    nop
    nop
    nop
    nop
    lui   x6, 0xDEADC        # 0xDEADC000
    nop
    nop
    nop
    addi  x6, x6, -273       # 0xDEADBEEF
    nop
    nop
    nop
    sw    x6, 0(x5)
    nop
    nop
    nop
    lw    x7, 0(x5)          # must read back 0xDEADBEEF
    nop
    nop
    nop
    bne   x7, x6, fail

    # ---- BYTE store and unsigned load ----
    nop
    nop
    nop
    addi  x8, x0, 0xAB       # 0xFFFFFFAB after sign extension of the immediate
    nop
    nop
    nop
    sb    x8, 4(x5)          # writes 0xAB to byte lane 0 of word 1
    nop
    nop
    nop
    lbu   x9, 4(x5)          # zero-extended: 0x000000AB
    nop
    nop
    nop
    addi  x10, x0, 0xAB
    nop
    nop
    nop
    andi  x10, x10, 0xFF     # 0x000000AB
    nop
    nop
    nop
    bne   x9, x10, fail

    # ---- SIGNED byte load of the same location ----
    nop
    nop
    nop
    lb    x11, 4(x5)         # sign-extended: 0xFFFFFFAB
    nop
    nop
    nop
    addi  x12, x0, -85       # 0xFFFFFFAB
    nop
    nop
    nop
    bne   x11, x12, fail

    # ---- BYTE LANE: store to a non-zero offset ----
    nop
    nop
    nop
    addi  x13, x0, 0x42
    nop
    nop
    nop
    sb    x13, 10(x5)        # byte lane 2 of word 2
    nop
    nop
    nop
    lbu   x14, 10(x5)
    nop
    nop
    nop
    bne   x14, x13, fail

    # ---- HALFWORD store and signed load ----
    nop
    nop
    nop
    lui   x15, 0xFFFF0       # 0xFFFF0000
    nop
    nop
    nop
    addi  x15, x15, -1       # 0xFFFEFFFF
    nop
    nop
    nop
    sh    x15, 16(x5)        # stores 0xFFFF
    nop
    nop
    nop
    lh    x16, 16(x5)        # sign-extended: 0xFFFFFFFF
    nop
    nop
    nop
    addi  x17, x0, -1
    nop
    nop
    nop
    bne   x16, x17, fail

    # ---- HALFWORD unsigned load of the same location ----
    nop
    nop
    nop
    lhu   x18, 16(x5)        # zero-extended: 0x0000FFFF
    nop
    nop
    nop
    lui   x19, 0x10          # 0x00010000
    nop
    nop
    nop
    addi  x19, x19, -1       # 0x0000FFFF
    nop
    nop
    nop
    bne   x18, x19, fail

pass:
    lui   x20, 0x80000
    nop
    nop
    nop
    sw    x0, 0(x20)
    nop
    nop
    nop
halt:
    # HALT LOOP = TOHOST WRITE LOOP.
    #
    # tohost is 64-bit and Sail's HTIF distinguishes 4-byte from 8-byte writes:
    # a single sw is ignored (sail-riscv issue #218 reports three writes being
    # needed). ACT's own generated tests solve this by writing tohost inside
    # the halt loop, which is what this does. Both halves are written so the
    # full 64-bit value is seen.
    lui   x22, 0x1              # 0x1000 = tohost
    addi  x23, x0, 1            # bit 0 set = completion, 1 = pass
    sw    x23, 0(x22)           # low word
    sw    x0,  4(x22)           # high word
    beq   x0, x0, halt

fail:
    lui   x20, 0x80000
    nop
    nop
    nop
    addi  x21, x0, 1
    nop
    nop
    nop
    sw    x21, 0(x20)
    nop
    nop
    nop
    beq   x0, x0, halt
