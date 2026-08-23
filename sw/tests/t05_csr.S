# M3.4a gate test: Zicsr read/write path, no traps.
#
# WHY EVERY WRITE HAS A READBACK. Lockstep compares (pc, rd, value). A CSR
# write is invisible to that comparison - `csrw mscratch, x6` writes no
# register, so both Sail and the core produce rd=None and agree no matter what
# landed in the CSR. Only a readback into a GPR puts the CSR's contents where
# the comparison can see them.
#
# This is the same failure shape as M3.5: a check that cannot distinguish
# correct hardware from broken hardware. The four csrrw-with-x0 vectors that
# mutation 1 killed at decode time are precisely the ones lockstep cannot see
# without a readback.
#
# EXCLUDED: mcycle, mcycleh, minstret, minstreth (counters - Sail has no model
# of this pipeline) and mip (Sail asserts MTIP with the CLINT disabled; the
# core ties irq_timer low). See docs/results/0017.
#
# Forwarding is live (M3.3), so no NOP padding.
    .section .text
    .globl _start
_start:
    addi  x31, x0, 0            # checksum accumulator

    # ---- basic write/readback on mscratch ----
    lui   x1, 0xABCDE
    addi  x1, x1, 0x123         # 0xABCDE123
    csrw  mscratch, x1
    csrr  x2, mscratch
    xor   x31, x31, x2

    # ---- CSRRS sets bits, CSRRC clears them ----
    addi  x3, x0, 0x0F0
    csrs  mscratch, x3          # csrrs x0, mscratch, x3
    csrr  x4, mscratch
    xor   x31, x31, x4
    csrc  mscratch, x3
    csrr  x5, mscratch          # back to 0xABCDE123
    xor   x31, x31, x5

    # ---- THE ASYMMETRY. csrrw with rs1=x0 MUST still write.
    #      Under the rule csr.sv originally documented ("rs1 != x0"), this
    #      write does not happen and mscratch keeps 0xABCDE123. The readback
    #      is what makes the difference visible. ----
    csrw  mscratch, x0          # csrrw x0, mscratch, x0 - writes ZERO
    csrr  x6, mscratch          # must be 0
    addi  x6, x6, 17            # 17 if cleared, huge otherwise
    add   x31, x31, x6

    # ---- csrrwi with uimm=0 also writes ----
    csrwi mscratch, 31          # write 31
    csrr  x7, mscratch
    add   x31, x31, x7
    csrwi mscratch, 0           # uimm=0 STILL writes
    csrr  x8, mscratch          # must be 0
    addi  x8, x8, 23
    add   x31, x31, x8

    # ---- csrrs with rs1=x0 must NOT write. Prime with a known value first,
    #      then a read-only-style access must leave it alone. ----
    lui   x9, 0x5A5A5
    csrw  mscratch, x9
    csrrs x10, mscratch, x0     # read, no write
    xor   x31, x31, x10
    csrrsi x11, mscratch, 0     # read, no write
    xor   x31, x31, x11
    csrr  x12, mscratch         # still 0x5A5A5000
    xor   x31, x31, x12

    # ---- rd=x0 suppresses the delivered read but not the write ----
    addi  x13, x0, 0x2C
    csrrw x0, mscratch, x13     # writes, delivers nothing
    csrr  x14, mscratch         # must be 0x2C
    add   x31, x31, x14

    # ---- other writable CSRs. mtvec MODE is WARL, reads back 00. ----
    # 0x1803, NOT 0x2003. The TCM is 8 KB (0x0-0x1FFF), so 0x2000 is one byte
    # past the end. An earlier version used 0x2003; when the mie/mstatus block
    # below armed the timer interrupt, Sail vectored to mtvec and took an
    # instruction access fault at 0x2000, then looped on it forever. Sail
    # stopped at 59 of 77 instructions and compare.py reported PASS over the
    # prefix - see docs/results/0017. MODE bits are still non-zero so the WARL
    # masking is exercised.
    lui   x15, 0x1
    addi  x15, x15, 0x403       # 0x1403 - low bits must read back as 0
    csrw  mtvec, x15
    csrr  x16, mtvec            # must be 0x1400
    xor   x31, x31, x16

    # mepc bit 0 is WARL, reads back 0.
    lui   x17, 0x4
    addi  x17, x17, 0x5         # 0x4005
    csrw  mepc, x17
    csrr  x18, mepc             # must be 0x4004
    xor   x31, x31, x18

    lui   x19, 0x11111
    csrw  mcause, x19
    csrr  x20, mcause
    xor   x31, x31, x20

    lui   x21, 0x22222
    csrw  mtval, x21
    csrr  x22, mtval
    xor   x31, x31, x22

    # mstatus: only MIE (bit 3) and MPIE (bit 7) are writable here, and MPP
    # reads back 2'b11. Writing all-ones then reading back exercises the mask.
    addi  x23, x0, -1
    csrw  mstatus, x23
    csrr  x24, mstatus
    xor   x31, x31, x24

    # 0x808 = MSIE | MEIE. Bit 7 (MTIE) is deliberately NOT set: Sail asserts
    # mip.MTIP even with the CLINT disabled, so arming MTIE while mstatus.MIE
    # is set takes a timer interrupt on the model and not on the core. The
    # write/readback check is unaffected - the point is the mask, not the bits.
    lui   x2, 0x1
    addi  x2, x2, -2040         # 0x808
    csrw  mie, x2
    csrr  x25, mie
    xor   x31, x31, x25

    # ---- read-only CSRs. misa must be 0x40000100 (RV32I only). ----
    csrr  x26, misa
    xor   x31, x31, x26
    csrr  x27, mvendorid        # 0
    add   x31, x31, x27
    csrr  x28, mhartid          # 0
    add   x31, x31, x28

    # ---- A CSR WRITE IN THE SHADOW OF A TAKEN BRANCH.
    #      The integration gates csr_write on id_ex_q.valid, on the reasoning
    #      that ex_redirect_valid clears the ARRIVING instruction, not the one
    #      executing. That reasoning is unverified inference - this makes it
    #      measurable. The csrw here is two instructions behind a taken branch,
    #      inside the squash window that M3.5's bug lived in.
    #
    #      If a squashed csrw writes anyway, mscratch holds 0xDEAD0 and the
    #      readback diverges from Sail. ----
    addi  x29, x0, 99
    csrw  mscratch, x29         # known good value
    beq   x0, x0, past          # unconditionally taken
    lui   x30, 0xDEAD0
    csrw  mscratch, x30         # MUST NOT execute
    csrw  mscratch, x30         # MUST NOT execute
past:
    csrr  x30, mscratch         # must still be 99
    add   x31, x31, x30

    # ---- terminate. HTIF first so Sail stops, then the Verilator address. ----
    lui   x22, 0x1              # 0x1000 = tohost
    slli  x23, x31, 1
    ori   x23, x23, 1
    sw    x23, 0(x22)

    lui   x30, 0x80000
    sw    x31, 0(x30)
halt:
    sw    x23, 0(x22)
    sw    x0,  4(x22)
    beq   x0, x0, halt
