# UVM environment 4 - CSR block, with RAL

**Date:** 2026-08-13
**DUT:** `rtl/core/csr.sv` - M-mode Zicsr, 18 registers
**Simulator:** Altair DSim 2026.0.0, UVM Accellera:1800.2:UVM:2020.3.1
**Licence note:** produced under the DSim free individual licence, discontinued
2026-09-01 (ADR-0002). Reproducible only before 2026-09-02.

## Result

| Test | Errors | Notes |
|---|---|---|
| `uvm_reg_hw_reset_seq` | 0 | all 18 reset values |
| `uvm_reg_bit_bash_seq` | 0 | 9 registers bashed |
| `csr_directed_test` | 0 | suppression, illegal, trap, counters, interrupts |
| `csr_full_test` | 0 | **100.00% functional coverage** |

All eight coverpoints at 100.00%: `cp_addr`, `cp_op`, `cp_read`, `cp_write`,
`cp_illegal`, `cp_ro_write`, `x_addr_op`, `x_read_write`.

## Exact commands

    make -f verif/dsim.mk csr-reset      # uvm_reg_hw_reset_seq
    make -f verif/dsim.mk csr-bash       # uvm_reg_bit_bash_seq
    make -f verif/dsim.mk csr-directed   # directed sequences
    make -f verif/dsim.mk csr            # everything
    make -f verif/dsim.mk check-errors LOG=<log>

## What RAL changes

Envs 1-3 held an ad-hoc reference model in a scoreboard. Here a `uvm_reg_block`
IS the model - it knows every register's address, fields, access policies and
reset values - and a `uvm_reg_predictor` keeps it synchronised with the pins.

**Explicit prediction, not auto.** `set_auto_predict(0)` with the predictor
subscribed to the monitor's analysis port. This DUT changes registers without
RAL asking: traps write `mepc`/`mcause`/`mtval`, `mret` updates `mstatus`, and
the counters increment every cycle. Under auto-predict the model would diverge
the first time a trap fired and every subsequent read would report a false
mismatch.

**The adapter is where a RAL environment usually breaks.** Two details:

- `reg2bus` must take `const ref uvm_reg_bus_op` or it fails to override the
  pure virtual and the class stays abstract.
- A RAL **read** is issued as `CSR_RS` with `wdata = 0` and `do_write = 0` -
  the canonical `CSRRS rd, csr, x0` idiom. Using `CSR_RW` would write whatever
  `wdata` happened to hold, corrupting the register being read. **An adapter
  has to encode the target's access idioms, not just move bits.**

## DUT BUG FOUND BY RAL: misa encoding

`uvm_reg_hw_reset_seq` reported:

    Register "regmodel.misa" value read from DUT (0x40001044)
    does not match mirrored value (0x40001104)

Extension letters map to bits 0..25 as A..Z. The RTL had **bit 6 (G) set and
bit 8 (I) clear** - claiming the core implements the "G" general-purpose
combination and NOT the base integer ISA. The cause was a hand-counted 26-bit
binary literal:

    26'b00_0000_0000_0001_0000_0100_0100    // bits 2, 6, 12 - WRONG

Rewritten as explicit bit positions:

    {2'b01, 4'b0000, 26'd0} | (32'd1 << 2) | (32'd1 << 8) | (32'd1 << 12)

**This is the argument for RAL in one result.** `uvm_reg_hw_reset_seq` is six
lines to invoke and it checked all 18 reset values automatically. A hand-written
directed test would most likely have compared against the same wrong constant,
copied from the RTL.

It is also the argument for writing the reference model from the spec: the RTL
constant and the RAL constant were written independently and disagreed. Had the
RAL model reused the RTL's value, this would have shipped.

## NOT A BUG: bit_bash vs RISC-V read-only semantics

`uvm_reg_bit_bash_seq` initially reported 256 errors, all
`Status was UVM_NOT_OK when writing` on `mvendorid`, `marchid`, `mimpid`,
`mhartid` - 4 registers x 32 bits x 2 passes.

Reading `uvm_reg_bit_bash_seq.svh` settled it: the sequence skips a bit only
when `dc_mask` is set, which comes from `get_compare() == UVM_NO_CHECK` or a
write-only access type - **not** from an `RO` policy. RO fields are bashed
deliberately, and the sequence expects the write to return `UVM_IS_OK` with the
value unchanged.

That is the bus convention where "read-only" means "writes are silently
dropped". **RISC-V is stricter:** address bits [11:10] == 2'b11 marks a CSR
read-only and writing one is an ILLEGAL INSTRUCTION. The adapter reports that
as `UVM_NOT_OK` and the sequence flags it.

The DUT is correct; the sequence encodes a different convention. Excluded from
bit-bash only via `NO_REG_BIT_BASH_TEST`, still covered by `hw_reset` and by
`csr_illegal_seq` which asserts each write raises illegal.

Note `misa` (0x301) is NOT excluded - bits [11:10] == 2'b00 there, so it is
read-only by implementation choice rather than architecturally, and the RTL
ignores writes silently, exactly as bit-bash expects. Same RAL modelling,
different address range, different DUT behaviour.

**Generalisable: a built-in RAL sequence encodes assumptions about your bus,
and those assumptions can be wrong for your protocol.** The right response is
to exclude it where it does not apply and cover that behaviour directly - not
to weaken the DUT or lie in the adapter. Reporting `UVM_IS_OK` for an illegal
write would have made bit-bash pass while hiding a spec requirement.

This recurs at M5: the SoC's peripheral registers WILL follow the bus
convention, so identically-modelled registers behave differently depending on
which bus they sit behind.

## WARL fields modelled RO, not RW

`mtvec.MODE`, `mepc[0]` and `mstatus.MPP` accept any write and read back a
fixed legal value. Modelling them `RW` would make bit-bash write a 1, read
back 0, and report a failure - when the DUT is doing exactly what the spec
demands.

`mstatus` also declares explicit reserved fields ([2:0], [6:4], [10:8],
[31:13]) as RO with reset 0. Without them bit-bash would try writing bit 20 and
expect it to stick. Naming every field is tedious and is the only way the
automated sequences work.

## Counters excluded from automated sequences

`mcycle`, `mcycleh`, `minstret`, `minstreth` change on their own. Every
automated RAL sequence assumes a register holds what you wrote until you write
again. Excluded via `NO_REG_TESTS`; tested by `csr_counter_seq` instead, which
checks free-running behaviour, retire-gated increment, and the 64-bit rollover
across the `mcycleh` boundary.

Resource string verified against
`uvm/2020.3.1/src/reg/sequences/uvm_reg_hw_reset_seq.svh:109` rather than
recalled.

## Directed tests RAL cannot reach

- **Read suppression** (`rd == x0`): rdata must be zero, state untouched
- **Write suppression** (`rs1 == x0`): `CSRRS` with a full set-mask must NOT
  modify - not "write the unchanged value", but no write at all
- **Illegal writes** to read-only CSRs and to unimplemented addresses
- **Trap priority**: a trap concurrent with a software write to `mepc` must
  win. Getting this backwards corrupts `mepc` under interrupt load, which is
  close to impossible to debug from software
- **mret**: MIE <= MPIE, MPIE <= 1
- **Interrupt masking**: `irq_pending` requires MIE and `mie` and `mip`

Coverage gap found and closed: `x_addr_op` sat at 64.81% because RAL traffic
only ever issues `CSR_RW` (writes) and `CSR_RS` (reads) - `CSR_RC` cells stayed
empty. Those cells are reachable, not structurally impossible, so the answer was
directed stimulus (`csr_sweep_seq`), not `ignore_bins`. 100% after.

## Files

    rtl/core/csr.sv
    verif/uvm/agents/csr_agent/csr_if.sv
    verif/uvm/agents/csr_agent/csr_agent_pkg.sv     (includes the adapter)
    verif/uvm/ral/csr_ral_pkg.sv
    verif/uvm/env_csr/csr_env_pkg.sv
    verif/uvm/env_csr/csr_seq_lib.svh
    verif/uvm/tests/csr_test_pkg.sv
    verif/uvm/tests/csr_tb_top.sv
    verif/files_csr.f
