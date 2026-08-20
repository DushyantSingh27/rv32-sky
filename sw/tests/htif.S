# HTIF termination, included by every test program.
#
# Both Sail and ACT4 end the run on a write to the `tohost` symbol. The
# convention is bit 0 set to signal completion, with the exit code in the
# upper bits: 1 = pass, (code << 1) | 1 = fail.
#
# The Verilator harness uses its own store to 0x8000_0000 instead, so a program
# does BOTH - one binary terminates cleanly under either simulator.

# Write `value` to tohost, then to the Verilator test-control address.
# Clobbers a0 and a1.
.macro TEST_END value
    li    a0, \value
    la    a1, tohost
    sw    a0, 0(a1)             # HTIF: Sail and ACT4 stop here
    li    a1, 0x80000000
    sw    a0, 0(a1)             # Verilator harness stops here
1:  j     1b                    # halt if neither took effect
.endm

# Pass: tohost = 1, and 0 to the Verilator control address.
.macro TEST_PASS
    la    a1, tohost
    li    a0, 1
    sw    a0, 0(a1)
    li    a1, 0x80000000
    li    a0, 0
    sw    a0, 0(a1)
1:  j     1b
.endm
