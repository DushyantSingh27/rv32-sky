# M1: ALU standalone hardening

**Date:** 2026-08-04
**Run:** `flow/alu/runs/RUN_2026-08-04_21-31-45`
**Design:** `alu_synth_harness` - RV32I ALU with integrated branch comparison,
wrapped in input/output registers

## Why a harness

The ALU is purely combinational. Hardening it alone gave OpenROAD no clock; it
invented `__VIRTUAL_CLK__` and reported meaningless timing plus phantom setup
violations. The harness flops all inputs and outputs, creating true
register-to-register paths - equivalent to what the EX stage will see in the pipeline.

**Measurement overhead:** the harness contributes 104 flops (2732.62 um^2 at
synthesis). Subtract this when comparing ALU area against other blocks.

## Tool and PDK versions
| Item | Value |
|---|---|
| LibreLane | v3.0.5 (AppImage) |
| PDK | sky130A, ciel v2.4.0, hash `8afc8346a57fe1ab7934ba5a6056ea8b43078e71` (2025.07.14) |
| Standard cells | `sky130_fd_sc_hd` |
| Verilator (lint) | 5.050, zero warnings under `-Wall` |

## Exact command
    ~/librelane-devshell-x86_64.AppImage
    cd ~/dev/rv32-sky/flow/alu && librelane config.yaml

Config: `USE_SLANG: true`, `CLOCK_PORT: clk`, `CLOCK_PERIOD: 20` (50 MHz),
`FP_CORE_UTIL: 40`, `PL_TARGET_DENSITY_PCT: 50`, `MAX_FANOUT_CONSTRAINT: 6`.

## Timing

| Corner | Setup slack (ns) | Hold slack (ns) | Max slew violations |
|---|---|---|---|
| **Overall worst** | **6.7472** | **0.1082** | 97 |
| nom_tt_025C_1v80 | 13.1985 | 0.3210 | 7 |
| nom_ss_100C_1v60 | 7.0543 | 0.8865 | 90 |
| nom_ff_n40C_1v95 | 14.5859 | 0.1099 | 0 |
| min_tt_025C_1v80 | 13.3357 | 0.3186 | 0 |
| min_ss_100C_1v60 | 7.3479 | 0.8818 | 60 |
| max_ss_100C_1v60 | (not captured) | - | 97 |
| max_tt_025C_1v80 | (not captured) | - | 7 |

The overall worst setup slack of 6.7472 ns does not match any corner in the captured
table - the `max_*` corner rows were truncated from the grep output. It most likely
belongs to `max_ss_100C_1v60`. **Re-extract from the full summary before citing the
corner name.**

**Setup violations: 0 at every corner. Hold violations: 0 at every corner.**
The ALU closes 50 MHz across the full corner set.

**Implied Fmax (T4 inference, NOT measured):** critical path = 20 - 6.7472
= **13.25 ns**, implying **~75 MHz**. This assumes the critical path is unchanged under
a tighter constraint, which is not guaranteed - synthesis optimises differently against
different targets, and 20 ns gave it no reason to work hard. A real Fmax figure requires
sweeping `CLOCK_PERIOD` downward until timing fails.

**Consequence for PROJECT_CONTEXT 3.5:** the 50 MHz commit target has comfortable
margin. The 100 MHz stretch target is not reachable with this ALU as constrained. Since
the ALU sits in the EX stage and is likely the pipeline's critical path, this is the
number that will determine core Fmax. Revisit after a proper sweep.

## Area

| Metric | Value (um^2) |
|---|---|
| Synthesis chip area (harness total) | 11188.2304 |
| - of which sequential (104 flops) | 2732.6208 (24.42%) |
| **ALU combinational logic (derived, T4)** | **~8455.61** |
| Post-PnR instance area | 27705.3 |
| Core area | 27705.3 |
| Die area | 33696.8 |
| - standard cells | 16433.3 |
| - multi-input combinational | 8343.0 |
| - fill cells | 11272.1 |
| - timing repair buffers | 3663.51 |
| - sequential | 2732.62 |
| - clock buffers | 1106.06 |
| - tap cells | 472.954 |
| - inverters | 112.608 |
| - antenna cells | 2.5024 |
| Instance utilization | 59.31% |

The ALU-combinational figure is derived by subtracting harness sequential area from
synthesis total. It excludes PnR overhead (fill, taps, repair buffers) and is therefore
a lower bound suitable only for block-to-block comparison, not for area budgeting.

## Cell counts

| Class | Count |
|---|---|
| Total instances | 5192 |
| Standard cells | 1811 |
| Multi-input combinational | 873 |
| Sequential (harness registers) | 104 |
| Timing repair buffers | 368 |
| Clock buffers | 57 |
| Fill cells | 3381 |
| Tap cells | 378 |
| Inverters | 30 |
| Antenna diodes | 1 |

**Dominant cells:** 142 x `mux2_1`, 74 x `nor2_2`, 60 x `nand2_2`, 50 x `or2_2`,
38 x `and2_2`, 22 x `xnor2_2`, 17 x `mux4_2`, 17 x `o211a_2`.

The mux population (142 two-input + 17 four-input) confirms the barrel shifter and the
11:1 result multiplexer as the bulk of the combinational area, as the design predicted.

## Design quality checks

| Check | Result |
|---|---|
| Inferred latches | **0** |
| Synthesis lint errors / warnings | 0 / 0 |
| Disconnected pins | 0 |
| Critical disconnected pins | 0 |
| Unmapped instances | 0 |
| Magic DRC | 0 errors |
| KLayout DRC | 0 errors |
| Netgen LVS (all difference counts) | 0 |
| Antenna violations | 0 (1 diode inserted) |
| Power grid violations | 0 |
| Max cap violations | 0 at every corner |
| **Max fanout violations** | **1 at every corner** |
| **Max slew violations** | **97 worst corner** |
| Unannotated nets | 8 |

## OPEN ISSUE - max slew and max fanout

97 max-slew violations at `max_ss_100C_1v60`, 90 at `nom_ss`, 60 at `min_ss`, 7 at the
typical corners, **0 at every fast corner**. Slow-corner concentration is expected -
transitions are slowest when the process is slow, the supply is low and the die is hot.

**The violations are marginal.** From the `nom_tt` detail report:

    Pin              Limit      Slew       Slack
    _1592_/B         0.750000   0.762687   -0.012687 (VIOLATED)
    _1641_/B         0.750000   0.762686   -0.012686 (VIOLATED)
    _1725_/B         0.750000   0.762655   -0.012655 (VIOLATED)
    _1739_/B         0.750000   0.762649   -0.012649 (VIOLATED)
    fanout158/A      0.750000   0.762641   -0.012641 (VIOLATED)

Worst is 1.7% over limit. All violating pins show near-identical slew, which suggests a
single common cause rather than 97 independent problems.

**Hypothesis (T4, unconfirmed):** the co-occurring single max-fanout violation, plus a
repair cell literally named `fanout158`, points at one high-fanout net - plausibly
`op_q` driving all eleven functional units, or `b_q` feeding both the shifter and the
adder. OpenROAD inserted fanout buffering but did not fully close the slew at the slow
corner.

**Options, in order of preference, none applied yet:**
1. Relax `MAX_FANOUT_CONSTRAINT` from 6. A limit of 6 is aggressive and may be causing
   over-aggressive splitting that hurts slew.
2. Allow more `repair_design` iterations or raise the buffer strength available.
3. Restructure the RTL to reduce fanout on the control signals (e.g. replicate `op_q`).

**Not fixed now, deliberately.** PROJECT_INSTRUCTIONS 7 forbids optimizing before
measuring, and this is the first measurement. Revisit when authored SDC exists, since
the fallback SDC may itself be driving the slew targets.

## Comparison against the M0 smoke counter

| Metric | smoke_top | alu_synth_harness | Ratio |
|---|---|---|---|
| Synthesis area (um^2) | 570.55 | 11188.23 | 19.6x |
| Post-PnR instance area (um^2) | 1333.78 | 27705.3 | 20.8x |
| Standard cells | 92 | 1811 | 19.7x |
| Sequential cells | 11 | 104 | 9.5x |
| Worst setup slack (ns) | 12.165 | 6.747 | - |
| **Implied critical path (ns)** | **7.835** | **13.25** | **1.69x** |
| Detailed route wirelength | 1283 | 49336 | 38.5x |
| Total power (W) | 9.84e-05 | 1.259e-03 | 12.8x |

Both were measured register-to-register at `CLOCK_PERIOD: 20`, so the critical-path
comparison is valid.

## OBSERVATION - no register re-encoding

Expected flop count: `op_q` (4) + `branch_op_q` (3) + `a_q` (32) + `b_q` (32) +
`result_o` (32) + `branch_taken_o` (1) = **104**. Synthesis produced exactly 104.

This refines the M0 observation. Yosys re-encoded the smoke counter's 3-state enum FSM
into one-hot, but left these plain data registers untouched. **Yosys re-encodes state
machines it recognises as such; ordinary pipeline registers are preserved.** The enum
casts `alu_op_e'(op_i)` and `branch_op_e'(branch_op_i)` in the harness were accepted by
yosys-slang without complaint - one more construct confirmed working.

## Routing and power

| Metric | Value |
|---|---|
| Global route wirelength | 72298 |
| Detailed route wirelength | 49336 |
| Longest wire | 509.65 |
| Total power | 1.2593e-03 W (1.26 mW) |
| Routing iterations to converge | 5 (50056 -> 49336) |

## Caveats

1. **No authored SDC.** `PNR_SDC_FILE` and `SIGNOFF_SDC_FILE` unset; OpenROAD used its
   generic fallback. The slew limits driving the violations above come from that
   fallback, not from constraints written for this design. **Writing real SDC remains
   an M1 task and should precede any slew optimization.**
2. Fmax is inferred from slack at a 20 ns constraint, not measured by sweeping.
3. **2 floating nets** (`RSZ-0020`) - identical count to the smoke design, which had
   entirely different RTL. This makes the earlier one-hot-encoding hypothesis unlikely;
   it now looks like a flow artifact rather than a design property. Downgraded from
   "investigate" to "note unless the count scales with design size".
4. 8 unannotated nets at every corner. Unexplained. Low priority.
5. `VSRC_LOC_FILES` unset, so IR drop is approximate. Irrelevant pre-fabrication.

## Reproducibility
Reproducible from the recorded command with the pinned PDK hash. Satisfies
PROJECT_INSTRUCTIONS 5.3.


## CRITICAL PATH IDENTIFIED (2026-08-08)

Extracted from the post-PnR STA report at `min_ss_100C_1v60`:

    Startpoint: _1848_  (rising edge-triggered flip-flop, clk)
    Endpoint:   _1827_  (rising edge-triggered flip-flop, clk)
    Path group: clk, Path type: max

The launch flop drives `b_q[3]` - one bit of the registered `b` operand, which
is a **shift-amount bit** feeding one full stage of the barrel shifter.

**The path is dominated by buffering, not computation.** Seven
`sky130_fd_sc_hd__clkdlybuf4s25_1` delay buffers appear in sequence -
`fanout243`, `fanout240`, `fanout238`, `fanout237`, `fanout221`, `fanout215`,
`fanout212` - consuming roughly 5.5 ns of the ~13.25 ns path before the first
logic gate. Only then does real logic appear: `a21oi_2`, `a221oi_2`,
`o2bb2a_2`, `a211o_2` - the AND-OR-invert cells that synthesis maps a
multiplexer tree to.

### Conclusions

1. **The critical path runs through the barrel shifter, not the adder.** This
   contradicts the common assumption that a 32-bit carry chain dominates an ALU.
   Recorded as a measured result, not folklore.
2. **The dominant cost is fanout buffering.** A shift-amount bit fans out to
   every one of 32 output bits in its shifter stage. OpenROAD inserted a chain
   of weak delay buffers to meet the fanout limit.
3. **Single root cause for three symptoms.** The 97 max-slew violations, the one
   max-fanout violation, and the buffer-dominated critical path are all the same
   high-fanout net.

### Proposed optimization (NOT YET APPLIED)

`MAX_FANOUT_CONSTRAINT: 6` in `flow/alu/config.yaml` is aggressive. Relaxing it
should let the tool use fewer, stronger buffers instead of a long chain of weak
ones - reducing both the buffer delay on this path and the slew violations.

Deferred deliberately: PROJECT_INSTRUCTIONS 7 requires finishing the current
milestone before optimizing, and this is now an evidenced change with a
measurable before/after rather than speculation. Revisit with authored SDC.

**Expected but unverified (T4):** relaxing the fanout limit reduces the critical
path. It could also worsen slew by allowing larger fanout per buffer. The point
of running it is to find out.
