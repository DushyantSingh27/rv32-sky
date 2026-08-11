# M1: muldiv standalone hardening

**Date:** 2026-08-11
**Design:** `rtl/core/muldiv.sv` + `mul_unit.sv` + `div_unit.sv`
**Run:** `flow/muldiv/runs/RUN_2026-08-11_18-50-12` (20 ns), plus a CLOCK_PERIOD sweep

## Tool and PDK versions
| Item | Value |
|---|---|
| LibreLane | v3.0.5 (AppImage) |
| PDK | sky130A, ciel v2.4.0, hash `8afc8346a57fe1ab7934ba5a6056ea8b43078e71` (2025.07.14) |
| Standard cells | `sky130_fd_sc_hd` |
| Constraints | `flow/constraints/block.sdc` (authored - see caveats) |

## Exact command

    ~/librelane-devshell-x86_64.AppImage
    cd ~/dev/rv32-sky/flow/muldiv && librelane config.yaml

Config: `USE_SLANG: true`, `CLOCK_PORT: clk`, `CLOCK_PERIOD: 20`,
`FP_CORE_UTIL: 40`, `PL_TARGET_DENSITY_PCT: 50`, `MAX_FANOUT_CONSTRAINT: 6`,
`PNR_SDC_FILE` and `SIGNOFF_SDC_FILE` both `../constraints/block.sdc`.

## HEADLINE RESULT

**The muldiv closes timing at 23 ns (43.5 MHz) at all corners.** It does not
close at 50 MHz standalone.

CLOCK_PERIOD sweep, worst setup slack at `max_ss_100C_1v60` (the worst corner):

| Target | Frequency | Worst slack (ns) | Setup violations | Closes |
|---|---|---|---|---|
| 20 ns | 50.0 MHz | -0.860 | 252 | no |
| 22 ns | 45.5 MHz | -0.915 | 7 | no |
| **23 ns** | **43.5 MHz** | **+0.085** | **0** | **yes** |
| 24 ns | 41.7 MHz | +1.085 | 0 | yes |
| 26 ns | 38.5 MHz | closes | 0 | yes |
| 28 ns | 35.7 MHz | closes | 0 | yes |

Margin at 23 ns is 0.085 ns - under 0.4%. **24 ns (41.7 MHz) is the sensible
operating point** if this block is ever hardened alone for real.

### IMPORTANT: the tool optimizes to the target, not beyond it

Slack at `max_ss_100C_1v60` across the sweep: -0.915 (22 ns), +0.085 (23 ns),
+1.085 (24 ns). Each additional nanosecond of budget yields exactly one
nanosecond of slack - so the critical path is **frozen at 22.915 ns** in all
three runs.

OpenROAD's resizer stops working a path once it meets the goal. At the 20 ns
target the implied path was 20.86 ns; at 22 ns it became 22.91 ns. The tool
made the path *longer* when given more room.

**Consequence: "achieved Fmax" from a sweep is a property of the design AND the
effort the tool applied, not a physical property of the RTL.** The supported
claim is "closes at 43.5 MHz", NOT "cannot exceed 43.5 MHz". A more aggressive
target with more optimization effort would likely produce a shorter path.

## Critical path

From post-PnR STA at `min_ss_100C_1v60`:

    Startpoint: _5772_  ->  u_div.b_mag[0] (net)
    Chain: or4_2 -> or4_2 -> or4_2 -> or4_2 -> or4_2 -> or4_2 ...

The **divider**, not the multiplier. The launch flop drives `b_mag[0]` - the
registered divisor magnitude - into the 33-bit restoring subtract
(`rem_shifted - divr_q`). The `or4_2` chain is the ripple carry propagating
through that subtraction.

The multiplier's 64-bit accumulator, which was the prior suspect, does not
appear on the critical path at all.

## Area and cells (20 ns run)

| Metric | Value |
|---|---|
| Instance area | 99,710.6 um^2 |
| Standard cells | 5,340 |
| Sequential cells | 578 |
| Timing repair buffers | 573 |
| Utilization | 57.5% |
| Hold WNS | 0 (no violations, any corner) |
| Max slew violations | 43 (slow corners only) |
| Max cap violations | 2 |

### Comparison across blocks

| | ALU harness | muldiv | Ratio |
|---|---|---|---|
| Instance area | 27,705 um^2 | 99,711 um^2 | 3.6x |
| Standard cells | 1,811 | 5,340 | 2.9x |
| Sequential cells | 104 | 578 | 5.6x |

The muldiv is the largest block in the design so far and the pipeline's timing
bottleneck. The ALU closes 50 MHz comfortably; the muldiv does not.

## THREE FAILED OPTIMIZATIONS

Recorded with numbers because negative results are results. Each was measured,
not assumed.

### 1. Authored SDC - constraints manufactured violations

Replacing OpenROAD's fallback SDC with an authored one took setup violations
from 183 to **503**, and register-to-register violations from 4 to **32**.

Cause: the first authored SDC used `set_clock_uncertainty` at 5% of period
(1.0 ns), which subtracts from *every* register-to-register path. Meanwhile the
input delay was set to 20% of period (4.0 ns) - **identical to the fallback it
replaced**, so port paths did not change at all. Net effect: strictly tighter
constraints, more violations, no new information.

Revised to 0.25 ns absolute uncertainty (CTS skew and jitter are a fixed
physical quantity on sky130, not a fraction of the clock period), 10% I/O delay,
and 0.02 pF output load. The 0.05 pF load in the first version had produced
max-cap violations that were purely a constraint artifact.

**Lesson: constraints are part of the design.** A timing report measures the RTL
against numbers you chose. Three arbitrary constraint values produced 320
violations that reflected nothing about the multiplier.

Also: OpenSTA is not Synopsys DC. `remove_from_collection` does not exist and
the first SDC failed to parse. Every SDC tutorial online assumes DC or PrimeTime;
the open-source tools implement a subset.

### 2. Merging the divider's comparator into its subtract - REVERTED

`div_unit.sv` computed `rem_shifted - divr_q` and `rem_shifted >= divr_q` as
separate expressions, synthesising to two parallel 33-bit carry chains on the
same operands. The comparison looks redundant: if `rem_shifted >= divr_q` the
subtraction does not borrow, so the borrow-out is exactly `!rem_ge`.

Widening to 34 bits and reading bit 33 as the comparison result:

| | Before | After |
|---|---|---|
| WNS @ `max_ss_100C_1v60` | -0.860 ns | **-1.264 ns** |
| Standard cells | 5,340 | 5,307 |

**Worse by 0.404 ns for 33 fewer cells. Reverted.**

Removing one of two parallel chains made the remaining chain one bit deeper, and
on a ripple structure **depth is what costs time, not the number of chains**.
Two shallower chains in parallel beat one deeper chain.

The finding is recorded as a comment in `div_unit.sv` so the apparently
redundant comparator is not "optimized" again later.

### 3. MAX_FANOUT_CONSTRAINT sweep - no effect whatsoever

Hypothesis, open since the ALU harden: `MAX_FANOUT_CONSTRAINT: 6` forces long
chains of weak buffers, and relaxing it would let the tool use fewer, stronger
ones. The ALU's critical path had spent ~5.5 ns in seven `clkdlybuf4s25_1` cells
before reaching any logic.

Four hardens at 6, 10, 16 and 24, four distinct run directories:

| Fanout limit | WNS | Setup vio | Max slew | Area | Cells | Repair buffers |
|---|---|---|---|---|---|---|
| 6 | -0.8597 | 252 | 43 | 99,710.6 | 5,340 | 573 |
| 10 | -0.8597 | 252 | 43 | 99,710.6 | 5,340 | 573 |
| 16 | -0.8597 | 252 | 43 | 99,710.6 | 5,340 | 573 |
| 24 | -0.8597 | 252 | 43 | 99,710.6 | 5,340 | 573 |

**Bit-identical across all four.** `MAX_FANOUT_CONSTRAINT` has no effect on this
design - OpenROAD's resizer is already meeting a tighter internal target than 6.

Consequence for the ALU result in `docs/results/0003`: the buffer chains on that
critical path were the resizer's own **timing repair**, not fanout compliance.
The proposed fanout optimization recorded there is withdrawn.

## RTL change that WAS kept: registering the operands

Both units originally computed their special cases and magnitude negations
combinationally from the input ports, feeding the FSM's start decision in the
same cycle. In the divider that meant `div_by_zero` (a 32-bit OR reduction) and
two 32-bit conditional negations sat on the input path.

Added a `LOAD` state to each unit that registers `a`, `b` and `op` first.

| | Before | After |
|---|---|---|
| Setup violations | 503 | 252 |
| Register-to-register violations | 32 | 252 |
| Multiply latency | 17 cycles | 18 cycles |
| Divide latency | 34 cycles | 35 cycles |
| Instance area | 85,280 um^2 | 99,711 um^2 |

**All port-path violations eliminated** - the 252 remaining are entirely
register-to-register, meaning internal logic. Area rose 17% (136 added flops).

Verification: 34,029 transactions, 0 mismatches, immediately after restructuring
both state machines. Env 2 paid for itself here.

## Caveats

1. Constraints are **estimates for standalone characterisation**, not signoff
   constraints. Input/output delay at 10% of period assumes operands arrive from
   an adjacent on-die block. Real numbers depend on the pipeline floorplan.
2. Achieved frequency is tool-effort dependent - see the target-tracking section.
3. 43 max-slew violations and 2 max-cap violations persist at slow corners.
   Not investigated; unchanged by the fanout sweep.
4. **2 floating nets** (`RSZ-0020`) - same count as the smoke design and the ALU,
   across three completely different designs. Confirmed a flow artifact.
5. `DRT-0120`: net139 has 103 pins, flagged as potentially impacting routing
   performance. Not investigated.
6. Standalone harden with no floorplan context. At M7 this block sits inside the
   SoC with real placement and real SDC; these numbers will shift.

## Verdict

The multiply/divide unit is functionally correct (env 2: 34,029 transactions,
100% functional coverage, zero mismatches) and closes timing at **43.5 MHz
standalone**, short of the 50 MHz commit target in PROJECT_CONTEXT 3.5.

The limiting path is the divider's 33-bit restoring subtract. Closing 50 MHz
would require splitting that subtract across two cycles - roughly doubling
divide latency to ~67 cycles and adding 5-10% area - which is not justified
before M7, when the block will be re-timed inside a real floorplan against real
constraints.

**Recorded as an open item for M7.**
