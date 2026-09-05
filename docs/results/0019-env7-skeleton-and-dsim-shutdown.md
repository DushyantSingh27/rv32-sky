# 0019 — UVM env 7 skeleton, and the DSim shutdown

**Date:** 2026-09-02
**Status:** Env 7 written and NEVER COMPILED. Altair DSim Cloud shut down
2026-09-01, one day before this session.

## The headline

    =F:[UsageMeter] License not obtained: Altair DSim Cloud has been shut
    down as of September 1st 2026.

Not the free tier discontinued - the licence server itself is gone, and the
on-premises installation validates against it. DSim is unusable.

Measured 2026-09-02 22:03 IST. The ALU environment ran successfully the same
day at 19:23 (69 transactions, UVM_ERROR : 0, coverage collected), so either
the shutdown landed between those runs or the earlier one used a cached
lease. Not investigated - the outcome is the same.

**Consequence:** UVM env 7 exists as source and has never been compiled. No
claim in this file about it being correct, and none should be made.

## What ADR-0002 predicted, and what actually happened

ADR-0002 recorded the free on-premises tier ending 2026-09-01 and required
every UVM result to be captured before then. `tools/versions.md` records the
owner's decision of 2026-07-31 to proceed on DSim rather than migrate, with
Claude's noted disagreement about post-deadline availability.

Envs 1-4 were captured in time and their results stand (docs/results/0004,
0005, 0008, 0010 - 89,145 transactions, 100% functional coverage on four
environments). Env 7, named in PROJECT_CONTEXT 5.2 as the portfolio
centerpiece, was not started until 2026-09-02.

The disagreement resolved against the decision. Recording it because
5.2 requires failure history, and a documented wrong call is worth more in
the final writeup than a silent one.

## What was built

Five files, ~650 lines, structurally complete and never elaborated:

| File | Lines | Contents |
|---|---|---|
| `verif/uvm/agents/core_agent/core_if.sv` | 51 | Observation interface, negedge clocking block |
| `verif/uvm/agents/core_agent/core_agent_pkg.sv` | 210 | Sequence item, opcode classifier, passive monitor, agent |
| `verif/uvm/env_core/core_env_pkg.sv` | 250 | Scoreboard, coverage collector, env |
| `verif/uvm/tests/core_test_pkg.sv` | 124 | Base test with hex loader, run test |
| `verif/uvm/tests/core_uvm_tb_top.sv` | 111 | DUT + TCM + interface wiring |

Plus `verif/files_core.f` and a `core` target in `verif/dsim.mk`.

### Design: passive by construction

The instruction stream is pre-generated into a hex image and loaded by the
TCM at time zero, so there is nothing to drive at simulation time. The agent
is `UVM_PASSIVE` - a monitor with no driver and no sequencer.

That is a legitimate UVM configuration rather than a stub, and it is a
structure envs 1-4 do not show, all four being active. The alternative -
an agent writing instructions through a virtual interface at runtime, which
is closer to what PROJECT_CONTEXT 5.2 describes - needs the TCM replaced by
a model with a testbench write port. Specified as the next step, not built.

The retirement trace port already existed: built at M3.2 for Sail lockstep
(docs/results/0013), which is why this environment has something real to
observe rather than needing DUT changes first.

### What the scoreboard checks, and what it does not

**It holds INVARIANTS, not a reference model.** It cannot tell a correct
`add` from a wrong one. Sail lockstep does that offline; wiring Sail in as an
online predictor is the expensive part and is not in this skeleton.

What it checks is a different category - properties true of any correct RV32I
core regardless of what the program computes:

- x0 is never delivered a non-zero value at writeback
- every retired PC is 4-byte aligned
- every retired PC is inside the loaded image
- control flow leaves `pc+4` only from a branch, jump, or SYSTEM instruction
- a store or branch never writes a register
- a memory write comes only from a store

These are invisible to a data-flow checksum, which is the method every result
before M3.5 relied on. A retirement stream that writes x0 or jumps to an
address no instruction could target is broken whatever value lands in the
accumulator. Mutation T6 manifested exactly as execution running off into the
TCM's NOP fill, which the out-of-image check would catch directly.

The scoreboard also errors on **zero redirects observed**, mirroring env 3's
zero-collision check: a run that never took a branch never tested the
control-flow invariants and should not report success.

**The honest claim is "structural UVM environment with invariant checking",
not "verified core".** Stated here so the environment does not imply more
than it checks.

### Coverage

Opcode class, control-flow state (first / sequential / redirect), register
write, memory write, and x0-as-destination. Two crosses: opcode x flow, which
is the "instruction type x pipeline state" cross PROJECT_CONTEXT 5.2 names,
at the resolution the retirement port makes available; and opcode x
register-write, which would catch a decoder granting `reg_write` to an
instruction that must not have it.

`OPC_OTHER` - an unrecognised opcode retiring - is an `illegal_bins`, not a
coverage target. Same distinction as env 2's pathological-latency bin: most
bins answer "did we test this?", a few answer "did this go wrong?".

Unreachable cross cells are excluded explicitly: only branches, jumps and
SYSTEM instructions can precede a redirect, so every other opcode crossed
with redirect is impossible by construction. Naming them means any remaining
hole is a genuine gap.

## A dead-code defect, caught before compiling

The first version of `core_uvm_tb_top.sv` mirrored the program image into a
module-scope array and then failed to deliver it to the agent - a second
`initial` block pushed the words into a local queue and set an unrelated
dummy value into the config db.

It would have compiled cleanly and left `core_agent_cfg.image` empty, so
`instr_at()` would return NOP for every PC, every instruction would classify
as `OPC_OTHER`, and the coverage report would have looked plausible while
measuring nothing.

Caught by reading the file before compiling rather than by any tool. Fixed by
having the TEST read the hex file directly: a static array in module scope
cannot be handed to a UVM object by reference, and routing it through the
config db needs a wrapper for no gain. The test and the TCM now read the same
file, so the monitor's instruction lookup and the DUT's memory cannot
disagree.

**This is failure mode #1 in a new place** - not a test value landing where
implementations agree, but a measurement apparatus that reports a number
while measuring nothing.

## Known duplication

`verif/files_core.f` repeats the RTL list from `rtl/files.f` rather than
including it: `files.f` carries repo-relative paths and DSim resolves `-F`
contents relative to the `.f` file's own directory. This is exactly the
two-file-lists problem that `rtl/files.f` was created to solve at M3.3
(docs/results/0014), reintroduced under a tool constraint. A generator is the
fix; recorded rather than silently accepted.

## Corrections to the record

**`dsim --version` is not a valid option.** PROJECT_CONTEXT section 9 records
it as working without a licence. Measured 2026-09-02:

    =E:[InvalidOption] Invalid command-line option '--version'.

The version is reported in the run banner instead. A T5 claim in the verified
facts ledger that measured wrong.

## Not verified

**Everything in this file about env 7 is structural.** The environment has
never been elaborated, never compiled, never run. No coverage number, no
transaction count, no scoreboard result exists for it. The two constructs
most likely to fail on first compile are the `ref logic [31:0] img []`
argument in `load_image()` and the `$fscanf` format string; neither has been
tested.

## Next

The simulator question decides everything. Three options, to be resolved in
an ADR rather than here:

1. Freeze env 7 as source and document it as unbuilt
2. Port to Verilator + cocotb/pyuvm - running environment, real coverage, but
   not SystemVerilog UVM and so not the skill PROJECT_CONTEXT 1.2 ranks first
3. Obtain an alternative SystemVerilog UVM simulator - Questa Intel Starter,
   or a Siemens student licence through the university

Option 3 is the only one preserving goal #1 as stated, and is cheap to
investigate relative to committing to option 2.
