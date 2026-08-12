# UVM environment 3 - register file

**Date:** 2026-08-12
**DUT:** `rtl/core/regfile.sv` - 32 x 32-bit, 2 read ports, 1 write port
**Simulator:** Altair DSim 2026.0.0, UVM Accellera:1800.2:UVM:2020.3.1
**Licence note:** produced under the DSim free individual licence, discontinued
2026-09-01 (ADR-0002). Reproducible only before 2026-09-02.

## Result

| Test | Transactions | Mismatches | Collisions | Functional coverage |
|---|---|---|---|---|
| `rf_smoke_test` | 533 | 0 | 38 | 99.86% |
| `rf_full_test` | 25,097 | 0 | **6,009** | **100.00%** |

All eleven coverpoints at 100.00%: `cp_rs1`, `cp_rs2`, `cp_rd`, `cp_we`,
`cp_rs1_collides`, `cp_rs2_collides`, `cp_same_read`, `cp_write_x0`,
`cp_wdata`, `x_both_collide`, `x_rd_we`.

## Exact commands

    source $HOME/AltairDSim/2026/shell_activate.bash
    export DSIM_LICENSE=$HOME/metrics-ca/dsim-license.json
    make -f verif/dsim.mk regfile        # smoke,    533 transactions
    make -f verif/dsim.mk regfile-full   # full,  25,097 transactions
    dcreport -out_dir cov_rf regfile_rf_full_test_seed1.db

## THE HEADLINE: read-first is verified, not assumed

**6,009 read/write collisions, all returning the pre-write value.**

Read-first is a design CHOICE, not a spec requirement - PROJECT_CONTEXT 3.2
commits to full forwarding in the hazard unit, so the register file deliberately
has no internal bypass (see `docs/results/0007`). A testbench that never
collided would report zero mismatches while verifying nothing about it, and M3's
forwarding logic would then rest on an unverified assumption.

Two mechanisms guard against that:

1. **The scoreboard raises an error if it observes zero collisions.** Absence of
   this coverage is treated as a failure, not a silent gap.
2. **`rf_collision_seq`** forces at least one read port onto the register being
   written in every transaction. Pure randomization collides on roughly 1 in 16
   transactions per port - enough eventually, too sparse to rely on.

The scoreboard's ordering is what actually encodes the behaviour:

    exp_rs1 = model[t.rs1_addr];        // predict from state BEFORE the write
    exp_rs2 = model[t.rs2_addr];
    ...
    if (t.rd_we && t.rd_addr != 0)      // THEN apply the write
      model[t.rd_addr] = t.rd_data;

Swap those two steps and the scoreboard silently encodes write-first, and would
agree with a DUT that bypasses internally. Three lines carrying the whole
design decision.

## x0 verification

x0 is the most commonly-wrong part of any register file. Three independent
checks:

- `cp_write_x0` - x0 as a write target with write enable asserted, covered.
- Directed **write-then-read** sequence: write `0xDEAD_BEEF` then `0xFFFF_FFFF`
  to x0, then read x0 on both ports in later cycles. This targets the specific
  bug of a register file that STORES to entry 0 and masks it on read - such a
  design passes any test that only reads x0 without having written it.
- Runtime assertions inside the RTL (`docs/results/0007`).

The DUT gives x0 no storage at all (`regs[1:31]`), so it is structurally
incapable of holding a value.

## Coverage model

| Coverpoint | Purpose |
|---|---|
| `cp_rs1`, `cp_rs2`, `cp_rd` | all 32 addresses on each port; x0 has its own bin |
| `cp_we` | write enabled and disabled |
| `cp_rs1_collides`, `cp_rs2_collides` | read port targeting the register being written |
| `x_both_collide` | both read ports colliding simultaneously |
| `cp_same_read` | `rs1 == rs2` (e.g. `add x1, x2, x2`) |
| `cp_write_x0` | x0 as write target with we asserted |
| `cp_wdata` | zero, all-ones, 0xAAAA_AAAA, 0x5555_5555, MSB only, LSB only |
| `x_rd_we` | 32 write addresses x 2 enable states |

Data patterns are weighted by `dist` - uniform 32-bit randomization essentially
never produces all-ones or a walking-one value.

## BUG FOUND IN THE TESTBENCH (none in the DUT)

### Monitor emitted a transaction before any stimulus existed

Two mismatches, both at time 50 ns, identical across runs:

    rs1 MISMATCH addr=xx expected 0xxxxxxxxx got 0x00000000

`addr=xx` - the address itself was X, so the model was indexed with an unknown
value. Time 50 ns is exactly when reset releases (clock toggles every 5 ns,
`rst_n` rises after 5 posedges).

Cause: the monitor did `wait (rst_n === 1'b1)` then fell straight into
`@(mon_cb)`. `rst_n` rises on a posedge; the next negedge is 5 ns later, before
the driver has driven anything. The address pins were still X from
initialisation.

Neither side was wrong - the DUT correctly returned zero (its registers are
reset), and the model correctly could not index with X. The monitor sampled a
cycle containing no transaction.

Fix: `$isunknown()` guard on the address and write-enable pins before emitting.

**This is the third variant of the same failure class across three
environments:**

| Env | Symptom | Cause |
|---|---|---|
| 1 (ALU) | 9 phantom transactions per run | Monitor sampled every negedge including drain time |
| 2 (muldiv) | 158 X-propagation mismatches | Driver cloned a response it never populated |
| 3 (regfile) | 2 mismatches at reset release | Monitor sampled before the driver drove |

**Generalisable rule: a monitor must emit only what the DUT was actually asked
to do.** Every one of these looked like a DUT bug on first inspection. In each
case the tell was X or a value the design could not have produced.

## DUT verdict

**No bugs found in `rtl/core/regfile.sv`.**

25,097 transactions at 100% functional coverage against an independently written
reference model, including 6,009 read/write collisions. x0 confirmed hardwired
on both read ports and as a write target. Read-first confirmed on every
collision. Write-enable-low confirmed to leave state untouched.

## Files

    rtl/core/regfile.sv
    verif/uvm/agents/regfile_agent/regfile_if.sv
    verif/uvm/agents/regfile_agent/regfile_agent_pkg.sv
    verif/uvm/env_regfile/regfile_env_pkg.sv
    verif/uvm/env_regfile/regfile_seq_lib.svh
    verif/uvm/tests/regfile_test_pkg.sv
    verif/uvm/tests/regfile_tb_top.sv
    verif/files_regfile.f
