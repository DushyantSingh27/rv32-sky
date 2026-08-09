# UVM environment 2 - multiply/divide

**Date:** 2026-08-09
**DUT:** `rtl/core/muldiv.sv` (wrapper), `mul_unit.sv`, `div_unit.sv`
**Simulator:** Altair DSim 2026.0.0, UVM Accellera:1800.2:UVM:2020.3.1
**Licence note:** produced under the DSim free individual licence, discontinued
2026-09-01 (ADR-0002). Reproducible only before 2026-09-02.

## Result

| Test | Transactions | Mismatches | Functional coverage |
|---|---|---|---|
| `md_smoke_test` | 529 | 0 | 93.17% |
| `md_full_test` | 34,029 | 0 | **100.00%** |
| `md_backpressure_test` | 2,000 | 0 | - |

All nine coverpoints at 100.00%: `cp_op`, `cp_a_class`, `cp_b_class`,
`cp_divisor_zero`, `cp_signed_overflow`, `cp_latency`, `cp_backpressure`,
`x_op_operands`, `x_op_latency`.

Zero RTL assertion firings across every run.

## MEASURED - compute latency

| | Cycles |
|---|---|
| Minimum | **2** (special-case early exit) |
| Maximum | **34** (full restoring divide) |

34 = 32 restoring iterations + IDLE + DONE, matching the microarchitecture in
PROJECT_CONTEXT 3.2 and confirming the ~33-cycle estimate recorded there.
The minimum of 2 is the divide-by-zero and signed-overflow path, which exits
from `DIV_IDLE` without iterating.

These are compute cycles (accept to `valid_o` rising), excluding testbench
back-pressure. Total latency including stalls reached 45.

## Exact commands

    source $HOME/AltairDSim/2026/shell_activate.bash
    export DSIM_LICENSE=$HOME/metrics-ca/dsim-license.json
    make -f verif/dsim.mk muldiv          # smoke,          529 transactions
    make -f verif/dsim.mk muldiv-full     # full,        34,029 transactions
    make -f verif/dsim.mk muldiv-bp       # back-pressure, 2,000 transactions
    dcreport -out_dir cov_md_full muldiv_md_full_test_seed1.db

## What made this environment harder than env 1

Env 1's DUT was combinational: one transaction per clock. Here a transaction
spans 2 to 34 cycles behind a full valid/ready handshake on both sides.

- The **driver blocks**: assert `valid_i`, wait for `ready_o`, wait again for
  `valid_o`, optionally withhold `ready_i`, only then call `item_done`.
- The **monitor tracks the protocol independently** rather than following the
  driver - it detects the accept edge (`valid_i && ready_o`), counts cycles to
  delivery, and derives both compute latency and whether back-pressure occurred.
  This is what makes it work in a passive agent, and unchanged at M3 when the
  real pipeline drives this block.
- **Response sequences** (PROJECT_CONTEXT 5.2's named skill target for env 2):
  the driver returns the completed item via `item_done(rsp)` so a sequence can
  choose its next stimulus from the observed result.
- **Back-pressure** is testbench-controlled. ~20% of transactions stall by
  default; a dedicated test stalls every one.

## Reference model

Written from the RISC-V unprivileged ISA specification, "M" Standard Extension.
Not derived from the RTL.

Divide by zero - RISC-V returns defined values, it does **not** trap:

| | `DIV` | `DIVU` | `REM` | `REMU` |
|---|---|---|---|---|
| divisor = 0 | `-1` | `2^32-1` | dividend | dividend |

Signed overflow, `-2^31 / -1` (result does not fit in 32 bits):
`DIV` returns `-2^31`, `REM` returns `0`.

Sign rule: the quotient takes the XOR of the operand signs; **the remainder
takes the sign of the dividend**. `-7 % 2 = -1`, `7 % -2 = +1`.

29 directed corner cases cover all of the above plus the four MULH variants at
the sign boundaries, run before any random stimulus so a spec bug fails in the
first few transactions with both operands printed.

## Bugs found IN THE TESTBENCH (none in the DUT)

### 1. X propagation through an unpopulated response object

**The most instructive bug so far, because the failure signature pointed at the
DUT while the cause was in the testbench.**

158 mismatches, all multiply operations, all reporting
`a=0xxxxxxxxx b=0x00000000 : expected 0xxxxxxxxx, got 0x00000000`.

The tell is **X in the expected column**. A genuine arithmetic bug produces two
concrete, different values. X in the reference model's output means the model
received garbage - so the stimulus was garbage, not the DUT.

Cause: `md_chain_seq` uses `get_response(rsp)` and feeds `rsp.result` back as
the next dividend. The driver cloned the request to build the response but
never wrote the observed result into it - the driver only reads `ready_o` and
`valid_o` from the interface. `rsp.result` therefore held its uninitialised
value, which for `logic [31:0]` is X. Once X entered `carry` it propagated
through every subsequent iteration.

Fix: capture `req.result = cfg.vif.drv_cb.result;` in the driver before
cloning, and guard the chain sequence with `$isunknown()` regardless.

**Generalisable rule: a response object is only as good as what the driver puts
in it.** UVM hands back exactly what was cloned and issues no warning. Response
sequences are env 2's skill target and this is the trap they set.

Note: the RTL's own immediate assertion `assert(!$isunknown(result))` in
`muldiv.sv` fired on every one of these transactions - concrete payoff for the
two-tier assertion rule in PROJECT_CONTEXT 2.5.

### 2. Latency measurement conflated DUT work with testbench stalling

`cp_latency` originally sampled total latency (accept to delivery), which
includes back-pressure. The `slow` bin `[41:$]`, written as "investigate
anything landing here", filled during normal operation because back-pressure of
up to 10 cycles pushed legitimate transactions past 41.

A bin that fires on normal operation is a broken alarm.

Fix: the monitor now records `compute_cycles` (accept to `valid_o` rising)
separately from `latency` (accept to delivery). Coverage samples the former.
Back-pressure keeps its own coverpoint.

### 3. Cross containing cells the design cannot produce

`x_op_latency` plateaued at 75.00% - 24 of 32 cells, exactly one hole per
operation. Multiplies cannot reach `div_range` (no early-exit path, always
6-20 cycles); divides cannot land in `mul_range` (they either exit immediately
or run all 32 iterations).

Fix: four `ignore_bins` clauses naming each impossible combination. Coverage
went to 100%. Same class of finding as env 1's frozen 70.07% - a plateau that
does not move with more stimulus is structural, not under-stimulation.

### 4. Coverage bin semantics: `bins` vs `ignore_bins` vs `illegal_bins`

Once `x_op_latency` was fixed, `cp_latency` fell to 75% - the `slow` bin
`[41:$]` was now permanently empty, because the DUT's true maximum is 34.

The bin exists to catch pathological behaviour: a divider that fails to
terminate, a state machine that hangs. **An empty error-detector bin is a
passing result, not a coverage gap.**

- `bins` - could never be filled without provoking a failure, permanently
  capping coverage. Wrong.
- `ignore_bins` - excludes it, but implies the value is impossible. It is not
  impossible, just pathological. Wrong.
- `illegal_bins` - removes it from the denominator **and** raises a runtime
  error if ever hit. Correct.

**Distinction worth keeping: most bins answer "did we test this?" (empty =
untested). A few answer "did this go wrong?" (empty = healthy). Mixing both
kinds in one covergroup makes the percentage meaningless.**

`illegal_bins` confirmed working in DSim 2026.0.0 (T1).

## Coverage model

| Coverpoint | Purpose |
|---|---|
| `cp_op` | all 8 RV32M operations |
| `cp_a_class`, `cp_b_class` | 7 operand classes each, derived in the monitor from observed values |
| `cp_divisor_zero` | the spec-defined div-by-zero case, gated on divide ops |
| `cp_signed_overflow` | `-2^31 / -1`, gated on `DIV`/`REM` |
| `cp_latency` | compute cycles: immediate, mul_range, div_range, illegal beyond 40 |
| `cp_backpressure` | whether the result handshake was stalled |
| `x_op_operands` | 8 x 7 x 7 = 392 cells |
| `x_op_latency` | catches a divide finishing in multiply time or vice versa; 4 `ignore_bins` for impossible cells |

## DUT verdict

**No bugs found in `mul_unit.sv`, `div_unit.sv` or `muldiv.sv`.**

34,029 transactions at 100% functional coverage against an independently written
reference model, plus 2,000 transactions with every result handshake stalled -
zero mismatches, zero assertion firings, no deadlock in the wrapper FSM.

Both spec traps confirmed correct: divide-by-zero returns defined values rather
than trapping, and `-2^31 / -1` returns the dividend for `DIV` and zero for
`REM`. The remainder's sign follows the dividend.

## Files

    rtl/core/mul_unit.sv
    rtl/core/div_unit.sv
    rtl/core/muldiv.sv
    verif/uvm/agents/muldiv_agent/muldiv_if.sv
    verif/uvm/agents/muldiv_agent/muldiv_agent_pkg.sv
    verif/uvm/env_muldiv/muldiv_env_pkg.sv
    verif/uvm/env_muldiv/muldiv_seq_lib.svh
    verif/uvm/tests/muldiv_test_pkg.sv
    verif/uvm/tests/muldiv_tb_top.sv
    verif/files_muldiv.f
