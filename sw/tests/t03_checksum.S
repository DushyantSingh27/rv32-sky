# M3.2 gate test 3: results checked by DATA, not by control flow.
#
# WHY THIS EXISTS. t02 checks results with `bne ..., fail`. Mutation testing
# showed that disabling branch redirects entirely made t02 still report PASS:
# every check is a conditional branch, so breaking branches breaks every check
# at once, AND breaks the jump to the failure handler. A self-checking program
# whose only failure mechanism is a branch cannot detect broken branches.
#
# Here each computed value is folded into an accumulator with XOR and ADD, and
# the accumulator is stored to the test-control address. A wrong result
# anywhere produces a wrong stored value, so correctness flows through DATA.
# There is exactly one branch on the pass path - the loop - and its effect is
# visible in the checksum rather than in where execution goes.
#
# THREE NOPs between dependent pairs. No forwarding until M3.3.
# Data at 0x1000, clear of the 0x2b8-byte code region.
    .section .text
    .globl _start
_start:
    addi  x31, x0, 0         # x31 = checksum accumulator

    # ---- arithmetic ----
    addi  x1, x0, 10
    nop
    nop
    nop
    addi  x2, x0, 20
    nop
    nop
    nop
    add   x3, x1, x2         # 30
    nop
    nop
    nop
    xor   x31, x31, x3
    nop
    nop
    nop
    sub   x4, x2, x1         # 10
    nop
    nop
    nop
    add   x31, x31, x4
    nop
    nop
    nop
    slli  x5, x1, 3          # 80
    nop
    nop
    nop
    xor   x31, x31, x5
    nop
    nop
    nop
    # SRAI MUST use a NEGATIVE operand. An earlier version shifted x0, and
    # zero shifts to zero under both arithmetic and logical shift - so a
    # decoder that maps SRAI to SRL was undetectable.
    addi  x6, x0, -64        # 0xFFFFFFC0
    nop
    nop
    nop
    srai  x6, x6, 2          # arithmetic: 0xFFFFFFF0.  logical: 0x3FFFFFF0
    nop
    nop
    nop
    add   x31, x31, x6
    nop
    nop
    nop
    sltu  x7, x1, x2         # 1
    nop
    nop
    nop
    add   x31, x31, x7
    nop
    nop
    nop

    # ---- LOOP: three iterations. If the backward branch does not redirect,
    #      x8 ends at 5 instead of 15 and the checksum is wrong. ----
    addi  x9, x0, 3
    nop
    nop
    nop
    addi  x8, x0, 0
loop:
    addi  x8, x8, 5
    nop
    nop
    nop
    addi  x9, x9, -1
    nop
    nop
    nop
    bne   x9, x0, loop
    nop
    nop
    nop
    add   x31, x31, x8       # +15 if the loop ran three times
    nop
    nop
    nop

    # ---- memory: word ----
    # 0x1100, NOT 0x1000. The linker script reserves 0x1000-0x10ff for the
    # HTIF window (tohost at 0x1000, fromhost at 0x1008). Writing test data
    # there made Sail interpret it as an HTIF command and reset the machine -
    # found by lockstep at instruction 34 of t04.
    lui   x10, 0x1
    nop
    nop
    nop
    addi  x10, x10, 0x100    # 0x1100 = test data area
    nop
    nop
    nop
    lui   x11, 0xABCDE
    nop
    nop
    nop
    addi  x11, x11, 0x123    # 0xABCDE123
    nop
    nop
    nop
    sw    x11, 0(x10)
    nop
    nop
    nop
    lw    x12, 0(x10)
    nop
    nop
    nop
    xor   x31, x31, x12
    nop
    nop
    nop

    # ---- byte lanes 0..3 ----
    addi  x13, x0, 0x11
    nop
    nop
    nop
    sb    x13, 4(x10)        # lane 0
    nop
    nop
    nop
    addi  x13, x0, 0x22
    nop
    nop
    nop
    sb    x13, 5(x10)        # lane 1
    nop
    nop
    nop
    addi  x13, x0, 0x33
    nop
    nop
    nop
    sb    x13, 6(x10)        # lane 2
    nop
    nop
    nop
    # Lane 3 carries bit 7 SET so that LB and LBU differ. Every other lane
    # here is positive; an earlier version used 0x44 in every lane, making
    # sign-extension undetectable.
    addi  x13, x0, -85       # 0xFFFFFFAB, low byte 0xAB
    nop
    nop
    nop
    sb    x13, 7(x10)        # lane 3
    nop
    nop
    nop
    lw    x14, 4(x10)        # must be 0x44332211
    nop
    nop
    nop
    xor   x31, x31, x14
    nop
    nop
    nop

    # ---- byte loads from every lane, signed and unsigned ----
    lbu   x15, 7(x10)        # zero-extended: 0x000000AB
    nop
    nop
    nop
    add   x31, x31, x15
    nop
    nop
    nop
    lb    x16, 7(x10)        # sign-extended: 0xFFFFFFAB - MUST differ from x15
    nop
    nop
    nop
    add   x31, x31, x16
    nop
    nop
    nop
    lb    x23, 6(x10)        # 0x33, positive: LB and LBU agree here
    nop
    nop
    nop
    xor   x31, x31, x23
    nop
    nop
    nop

    # ---- HALFWORD AT OFFSET 2. t02 never did this, so a halfword load
    #      that ignores offset bit 1 went undetected. ----
    lui   x17, 0xFEDC0
    nop
    nop
    nop
    addi  x17, x17, 0x765    # 0xFEDC0765
    nop
    nop
    nop
    sw    x17, 8(x10)
    nop
    nop
    nop
    lhu   x18, 8(x10)        # low half:  0x00000765
    nop
    nop
    nop
    xor   x31, x31, x18
    nop
    nop
    nop
    lhu   x19, 10(x10)       # HIGH half: 0x0000FEDC
    nop
    nop
    nop
    xor   x31, x31, x19
    nop
    nop
    nop
    lh    x20, 10(x10)       # signed:    0xFFFFFEDC
    nop
    nop
    nop
    add   x31, x31, x20
    nop
    nop
    nop

    # ---- halfword STORE at offset 2 ----
    addi  x21, x0, 0x5A
    nop
    nop
    nop
    sh    x21, 14(x10)       # upper half of word at 12
    nop
    nop
    nop
    lhu   x22, 14(x10)
    nop
    nop
    nop
    xor   x31, x31, x22
    nop
    nop
    nop

    # ---- AUIPC: the only instruction that feeds PC into the ALU.
    #      Without it a broken alu_src_a_pc mux is undetectable.
    #
    #      An earlier version folded in the DIFFERENCE between two auipc
    #      results and claimed that was position-independent. IT IS NOT: the
    #      difference equals the byte distance between them, so stripping the
    #      NOPs for t04 changed it from 16 to 4 and the checksum differed by 12.
    #
    #      This version compares one auipc against a LABEL, which the linker
    #      resolves to the same address in both programs. The subtraction
    #      yields zero when alu_src_a_pc works and a nonzero value when the
    #      mux feeds rs1 (= x0 = 0) instead of the PC.
here:
    auipc x24, 0             # x24 = address of `here`
    nop
    nop
    nop
    lui   x25, %hi(here)
    nop
    nop
    nop
    addi  x25, x25, %lo(here)   # x25 = address of `here`, computed by the linker
    nop
    nop
    nop
    sub   x26, x24, x25      # 0 if auipc is correct
    nop
    nop
    nop
    addi  x26, x26, 7        # fold a nonzero constant so the term is visible
    nop
    nop
    nop
    add   x31, x31, x26
    nop
    nop
    nop

    # ---- FORWARDING PRIORITY. Two writes to x27 in consecutive cycles, then
    #      a read. EX->EX (producer one ahead) must win over MEM->EX (two
    #      ahead), because it carries the NEWER value. With the priority
    #      inverted the read gets 100 instead of 200.
    #      Added after mutation testing: inverting the priority left the
    #      checksum unchanged, because no earlier sequence wrote one register
    #      twice in a row. ----
    addi  x27, x0, 100
    nop
    nop
    nop
    addi  x27, x0, 200       # second write, one cycle later
    add   x28, x27, x0       # reads x27 - must see 200
    nop
    nop
    nop
    add   x31, x31, x28
    nop
    nop
    nop

    # ---- x0 MUST NEVER FORWARD. Write to x0 (discarded), then read x0
    #      immediately. If the forwarding guard is removed, x0 briefly carries
    #      the discarded value instead of zero.
    #      Added after mutation testing: removing the x0 guard left the
    #      checksum unchanged, because nothing wrote x0 then read it. ----
    addi  x0, x0, 999        # architecturally a no-op
    add   x29, x0, x0        # must be 0
    nop
    nop
    nop
    addi  x29, x29, 3        # 3 if x0 read as zero, 2001 otherwise
    nop
    nop
    nop
    add   x31, x31, x29
    nop
    nop
    nop

    # ---- terminate. HTIF first so Sail stops; then the Verilator address. ----
    # tohost wants bit 0 set to signal completion, so the checksum is shifted
    # left and OR'd with 1. Sail reports it; the Verilator harness reads the
    # unshifted value from 0x80000000.
    lui   x22, 0x1          # 0x1000 = tohost
    nop
    nop
    nop
    slli  x23, x31, 1
    nop
    nop
    nop
    ori   x23, x23, 1
    nop
    nop
    nop
    sw    x23, 0(x22)
    nop
    nop
    nop

    # ---- store the checksum. The harness compares it. ----
    lui   x30, 0x80000
    nop
    nop
    nop
    sw    x31, 0(x30)
    nop
    nop
    nop
halt:
    # See t01 for why the write is inside the loop. x23 already holds
    # (checksum << 1) | 1 from the block above.
    sw    x23, 0(x22)
    sw    x0,  4(x22)
    beq   x0, x0, halt
