# UVM environment 1 - ALU

**Date:** 2026-08-05
**DUT:** `rtl/core/alu.sv` (RV32I ALU with integrated branch comparison)
**Simulator:** Altair DSim 2026.0.0, UVM Accellera:1800.2:UVM:2020.3.1
**Licence note:** produced under the DSim free individual licence, which is
discontinued 2026-09-01 (see ADR-0002). Reproducible only before 2026-09-02.

## Result

| Test | Transactions | Mismatches | Functional coverage |
|---|---|---|---|
| `alu_smoke_test` | 519 | 0 | 93.81% |
| `alu_full_test` | 30019 | 0 | **100.00%** |

Per-coverpoint, full test - every one at 100.00%:
`cp_op`, `cp_branch_op`, `cp_a_class`, `cp_b_class`, `cp_shamt`, `cp_b_ge_32`,
`cp_result_zero`, `x_op_operands` (343 bins), `x_op_branch`.

PROJECT_INSTRUCTIONS 5.3 target is >= 90% of defined bins. **Met at 100%.**

## Exact commands

    source $HOME/AltairDSim/2026/shell_activate.bash
    export DSIM_LICENSE=$HOME/metrics-ca/dsim-license.json
    make -f verif/dsim.mk alu                    # smoke,  seed 1,   519 transactions
    make -f verif/dsim.mk alu-full               # full,   seed 1, 30019 transactions
    dcreport -out_dir cov_full alu_alu_full_test_seed1.db

## Environment structure

Agent (driver, monitor, sequencer, config), environment (scoreboard, coverage
collector), layered sequences, two tests. Simulator-agnostic per ADR-0001
portability rules: no vendor pragmas, no simulator `ifdef` in class code, single
shared source list (`verif/files_alu.f`) with flags isolated in `verif/dsim.mk`.

**Reference model** written from the RISC-V unprivileged ISA specification, not
derived from `alu.sv`. A predictor copied from the DUT inherits the DUT's bugs and
agrees with broken hardware.

## Bugs found IN THE TESTBENCH (none in the DUT)

The ALU passed every transaction from the first successful run. All three defects
below were in the verification environment. Recording them because each is a
generalisable lesson for UVM environments 2-7.

### 1. Packages containing only classes are dropped at elaboration

`alu_agent_pkg`, `alu_env_pkg` and `alu_test_pkg` compiled cleanly but did not
appear in the elaborated unit list. Nothing in the design hierarchy imported them,
so they were discarded - and a discarded package never runs the static
initialization that registers its classes with the UVM factory.

Symptom: `UVM_FATAL [INVTST] Requested test from command line +UVM_TESTNAME=... not
found`, which points at the test rather than at the missing import.

Fix: import all three packages in `alu_tb_top`.

### 2. UVM 1.2 API used against a 1800.2-2020 library

`phase.phase_done.set_drain_time()` is the UVM 1.2 idiom. In IEEE 1800.2-2020 the
objection is reached via `phase.get_objection()`. `phase_done` dereferenced as null.

Symptom: `=F:[NullRef] null handle 'phase_done' dereferenced`.

Fix: `phase.get_objection().set_drain_time(this, 100ns)`.

This is precisely the API drift ADR-0001 anticipated when moving from XSim's UVM 1.2
to DSim's 2020.3.1. Any UVM code found online predating ~2020 needs checking.

### 3. Coverage sampled stimulus intent instead of observed behaviour

**The most important of the three.**

`cp_a_class` and `cp_b_class` sat at 14.29% - one bin of seven - regardless of
transaction count. 500 transactions gave 70.07%; 30,000 gave *exactly* 70.07%.
A coverage number that does not move under 60x the stimulus is structurally
unreachable, not under-stimulated.

Cause: the monitor constructs a fresh `alu_seq_item` from pin values. `a_class` and
`b_class` are stimulus metadata that exist only in the sequence item the driver
consumed - they are not on the wires - so they retained their default enum value,
`OPND_ZERO`, on every observed transaction.

Cascade: `x_op_operands` crosses `cp_op` x `cp_a_class` x `cp_b_class`. With two of
three axes pinned to a single bin, only 7 of 343 bins were reachable = 2.04%.

Overall was the mean of the nine coverpoints:
(100 + 100 + 14.29 + 14.29 + 100 + 100 + 100 + 2.04 + 100) / 9 = 70.07%.

Fix: `classify_operand()` in the agent package derives the class from the observed
value. The monitor calls it on `a` and `b` as sampled from the pins.

**Generalisable rule: functional coverage must be derived from what the monitor can
observe, never from what the driver intended.** A coverage model that reads stimulus
metadata measures the testbench, not the DUT.

### 4. Monitor emitted transactions nobody drove

Counts read 528 and 30028 against 519 and 30019 driven - nine extra each run. The
drain time keeps the clock running 100 ns past the final objection, and the monitor
sampled unconditionally on every negedge, re-reading stale pins.

Harmless to correctness here (the DUT is combinational, so re-reading stable inputs
yields the same correct answer) but it inflates transaction and coverage sample
counts, and would be a real defect in an env handed to someone else.

Fix: `drv_toggle`, a testbench-only handshake bit. The driver flips it once per
transaction; the monitor emits only when it changes. A toggle rather than a level so
that two identical back-to-back transactions are still counted separately.

## Coverage model

| Coverpoint | Bins | Purpose |
|---|---|---|
| `cp_op` | 11 | every ALU operation |
| `cp_branch_op` | 7 | every branch comparison form |
| `cp_a_class`, `cp_b_class` | 7 each | zero, one, minus-one, max-pos, min-neg, small (<32), random |
| `cp_shamt` | 7 | shift amounts 0, 1, four mid ranges, 31 |
| `cp_b_ge_32` | 2 | the RV32 shift-truncation case |
| `cp_result_zero` | 2 | zero / nonzero result |
| `x_op_operands` | 343 | `cp_op` x `cp_a_class` x `cp_b_class`, `ignore_bins` on XOR/OR/AND/PASS_B (no signedness) |
| `x_op_branch` | 77 | `cp_op` x `cp_branch_op`, `ignore_bins` where `branch_op != BR_NONE` is unreachable |

Operand classes are weighted by `dist` toward the corners: uniform 32-bit
randomization would hit `32'h8000_0000` roughly once in 4 billion transactions.
`solve a_class before a` preserves the distribution - without it the solver skews
toward whatever satisfies the value constraints most easily.

`32'h8000_0000` matters because it is the one value where `-x == x` in two's
complement; sign-handling bugs surface there and nowhere else.

## Directed corner cases (19, run before random stimulus)

Shift truncation: `SLL 1 by 1`, `by 33`, `by 0xFFFFFFE1` - all must equal `1 << 1`.
SRA vs SRL on `0x80000000 >> 31`. `SLT` vs `SLTU` on `0x80000000` vs `1` and
`0xFFFFFFFF` vs `0`. Overflow at `0x7FFFFFFF + 1` and `0x80000000 - 1`. Branch
comparisons at the sign boundary for all six forms.

Directed first, random second, so a spec bug fails within the first few transactions
with both operands printed rather than surfacing 300 random transactions later.

## DUT verdict

**No bugs found in `rtl/core/alu.sv`.** 30,019 transactions across 100% of the
defined functional coverage space, checked against an independently written
reference model, zero mismatches.

The shift-amount truncation (`b[4:0]`) and the SRA signed cast
(`$unsigned($signed(a) >>> shamt)`) - the two constructs most likely to be wrong -
are both confirmed correct.

## Files

    verif/uvm/agents/alu_agent/alu_if.sv
    verif/uvm/agents/alu_agent/alu_agent_pkg.sv
    verif/uvm/env_alu/alu_env_pkg.sv
    verif/uvm/env_alu/alu_seq_lib.svh
    verif/uvm/tests/alu_test_pkg.sv
    verif/uvm/tests/alu_tb_top.sv
    verif/files_alu.f
    verif/dsim.mk
