# M3.7 stage 2 PROBE - is mie WARL? Not a gate test and not in the regression
# set; it exists to settle one hypothesis.
#
# HYPOTHESIS (RTL side T1, read; Sail side T5)
#   csr.sv:185 stores all 32 bits written to mie. With misa = RV32I and no S
#   or U mode, the only implemented interrupt-enable bits are MSIE (3), MTIE
#   (7) and MEIE (11), and a WARL mie reads the rest back as zero.
#
# WHY NOTHING HAS SEEN THIS
#   t05_csr.S writes 0x808 - legal bits only, exactly where a 32-bit register
#   and a 3-bit register agree (failure mode #1). mie_q has 62 of 64 toggle
#   points uncovered.
#
# PREDICTION, written before the run
#   x2: core 0xffffffff; Sail 0x00000888, or some other subset of the bits.
#   Any Sail value other than 0xffffffff confirms the hypothesis. If Sail also
#   returns 0xffffffff, it is wrong, and mie_q's toggle points are ordinary
#   test targets.
#
# mstatus.MIE is cleared FIRST and read back. Sail asserts mip.MTIP with the
# CLINT disabled (t05_csr.S header, docs/results/0017); MTIE set with MIE = 1
# would take a timer interrupt on the model and not on the core, and the
# divergence would be about interrupts, not about mie.
    .section .text
    .globl _start
_start:
    csrci mstatus, 8            # MIE = 0 before anything is armed
    csrr  x1, mstatus           # readback: bit 3 must be 0 (both models)
    addi  x3, x0, -1
    csrw  mie, x3               # all ones
    csrr  x2, mie               # THE MEASUREMENT
    csrw  mie, x0               # disarm before anything else happens
    csrr  x4, mie

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
