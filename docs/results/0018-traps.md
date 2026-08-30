# 0018 — Synchronous traps and mret

**Date:** 2026-08-27
**Milestone:** M3.4a step 5
**DUT:** `rtl/core/rv32_core.sv`, `rtl/core/csr.sv`, `rtl/pkg/rv32_pkg.sv`
**Reference:** Sail RISC-V 0.13.1, config `verif/sail/rv32sky.json`
**Tools:** Verilator 5.050 (v5.050-60-g3d2421f3b), riscv64-unknown-elf-as (GCC 16.1.0)

## Result

| Program | Instructions | Agreement |
|---|---|---|
| t01_alu | 60 | all agree |
| t02_memory | 176 | all agree |
| t03_checksum | 305 | all agree |
| t04_hazards | 80 | all agree |
| t05_csr | 79 | all agree |
| **t06_traps** | **100** | **all agree** |
| **Total** | **800** | **0 divergences** |

Six trap causes implemented and verified: 0 (instruction address misaligned),
2 (illegal instruction), 3 (breakpoint), 4 (load address misaligned),
6 (store address misaligned), 11 (environment call from M-mode), plus `mret`.

Eight mutations injected, seven killed. One survives and is documented below
as unreachable.

## THE HEADLINE: three checks failed to detect what they were written to detect

This milestone's most useful output is not the trap path. It is that three
separate verification mechanisms - two of them written specifically for this
milestone - could not distinguish correct hardware from broken hardware, and
mutation testing found all three.

### 1. The store-suppression sentinel was one word from where the leak lands

`t06_traps.S` was written with an explicit check for the risk that a trapping
store might still reach memory: prime a word with a sentinel, trap on a
misaligned store, read the sentinel back. If the store leaked, the readback
would differ.

**Mutation T2 - poison drops `mem_write` - SURVIVED.**

The store was `sw x8, 0(x7)` with `x7 = 0x1102`. `tcm.sv` indexes
`b_word = b_addr[ADDR_BITS-1:2]`, discarding the low two bits, so a leaked
word store to 0x1102 writes word 0x440 - address **0x1100**. The sentinel was
at 0x1104. The test read a word the leak never touches.

Sentinel moved to 0x1100 and a second check added: a misaligned halfword
store, where `byte_en` is 4'b1100 and only the upper half would be corrupted -
a partial-suppression bug the word case cannot see. T2 then killed, with:

    sail [57] x13 <= 0xc0ffe123    (sentinel intact)
    core [57] x13 <= 0x0000005a    (leaked store data)

**This is the seventh instance of failure mode #1** - a test value landing
where correct and broken implementations agree - and the first where the check
existed specifically to catch the bug it missed. The test was structurally
right and off by one word. Reasoning about "the same region" instead of
reading tcm.sv's indexing is what produced it.

### 2. compare.py cannot tell a short trace from a truncated one

**Mutation T6 - branch outranks trap - reported "84 instructions compared,
all agree"** against a clean core's 100.

`compare.py` FAILs when Sail's trace is shorter than the core's - the fix from
0017. The reverse direction falls into a branch that prints "lengths differ...
expected: the two terminate on different conventions" and passes. That branch
is legitimate: the Verilator harness stops at the 0x8000_0000 store while Sail
continues to the HTIF write, so the core's trace is normally a short prefix.

It cannot distinguish that from a core that diverged into the TCM's NOP fill
and timed out, which is what T6 does - the jalr jumps to 0x1202 instead of
trapping.

### 3. A harness verdict discarded by the layer above it

Diagnosing #2 revealed that `run_lockstep.sh` reads only compare.py's verdict
and discards the Verilator harness's exit status.

**t05_csr and t06_traps had been reporting FAIL from the harness on every run
while the script reported "all agree".** t05 has been in that state since
0017. Both store a checksum to 0x8000_0000 and were run without `--expect`, so
tb_core.cpp applied its default convention - non-zero means FAIL.

    t05_csr: stored value: 0x82a4c825  RESULT: FAIL
    t06_traps: stored value: 0xc2ffe562  RESULT: FAIL

Neither is an RTL defect. The lockstep comparison is PC-and-register-write
against Sail and is unaffected. But "six programs pass" was overstated: the
accurate statement was "six programs agree with Sail; two have an unchecked
harness verdict".

**This is a new failure mode.** Both components worked correctly -
tb_core.cpp reported FAIL loudly, compare.py reported PASS accurately - and
the composition read one and dropped the other. Added to
PROJECT_INSTRUCTIONS section 7 as row 7.

Fixed: `run_lockstep.sh` now captures the harness exit code, carries a
per-program expected-checksum table, and fails on either verdict. Verified
against known-bad data via `NOEXPECT=1`, which blanks the expected values and
must reproduce the failure:

    NOEXPECT=1 ./verif/sail/run_lockstep.sh t05_csr t06_traps
    t05_csr    HARNESS FAIL (lockstep agreed)
    t06_traps  HARNESS FAIL (lockstep agreed)
    exit=1

The `NOEXPECT` hatch exists because the script cd's relative to `$0`: a first
attempt copied it to /tmp, where the relative paths resolved to `/` and it
failed for the wrong reason - reporting the sought result by accident.

## The Sail configuration has two misaligned controls, not one

Traps on misaligned load/store could not be verified until Sail raised them,
and the first configuration edit was on the wrong key.

`memory.regions[].attributes.misaligned_exceptions.load_store` is the
**post-translation, per-region** check. Setting it to
`{"Some": "AlignmentException"}` validated, parsed, and had **no observable
effect**: probe_traps.S produced four traps where six were expected.

The live control is `memory.misaligned.exceptions.load_store` - a **global**
setting, a peer of `regions` rather than a child. Sail's own default config
documents the distinction:

> These settings control global support for misaligned access so they are
> checked before address translation. `misaligned_fault` in `regions` is
> checked after address translation.

With the global gate at `{"None": null}` the access proceeds and the
per-region attribute is never consulted. Setting the global key produced all
six traps.

**`--print-default-config` honours `--config-override` and emits the resolved
configuration with inline comments.** It is a better source than the schema
for this class of question, and reading it is what settled this. The schema
gives legal values; the resolved config gives semantics.

The region-level setting is retained. It is now correct-but-unreached rather
than wrong: if the global gate ever moves, the regions already agree with it.

## Measured trap behaviour

From `sw/tests/probe_traps.S` under Sail. Every value below is T1 - read from
the trace, not derived from the spec and not from the DUT.

| Cause | Trigger | mcause | mepc | mtval |
|---|---|---|---|---|
| Instruction address misaligned | jalr to 2-mod-4 | 0 | PC of the jump | **target address** |
| Illegal instruction | funct7=0000001 OP | 2 | PC | **instruction word** |
| Breakpoint | ebreak | 3 | PC | **PC** |
| Load address misaligned | lw at 0x1102 | 4 | PC | **effective address** |
| Store address misaligned | sw at 0x1102 | 6 | PC | **effective address** |
| Environment call from M | ecall | 11 | PC | **0** |

`mstatus` on entry: 0x00001800 (MPP=11, MPIE=MIE=0). After mret: 0x00001880.
`csr.sv` already produced exactly this; no CSR-side edit was needed.

**mepc is the trapping PC, never PC+4.** Confirmed six times.

**Sail emits a retirement record for the trapping instruction** - a PC with no
register write. This inverted the planned design; see ADR-0005.

## Implementation

Trap detection in EX, single shared redirect path, trapping instruction
poisoned rather than squashed. Rationale and options in
`docs/decisions/ADR-0005`.

`is_misaligned()` added to rv32_pkg.sv and called by both lsu.sv (MEM) and the
EX trap encoder. Two copies of that case statement would be a latent
divergence: an edit to one would leave a core that traps on a different set of
addresses than it refuses to access.

`id_ex_t` gains a 32-bit `instr` field for mtval on cause 2. ctrl_t is
deliberately not extended - that would shift every field position in
tb_decoder.cpp's macros and its 46-bit width guard.

**Lint caught the unread `instr` field.** 0017 recorded that Verilator does
not warn on unread members of a packed struct, measured on seven new ctrl_t
fields. That finding does not generalise: it warned here, on bits [173:142] of
`id_ex_q`. An unread member of a struct flowing through a module port is a
different case from an unread member of a pipeline-register signal. No lint
suppression was added - the warning was the to-do list, and it cleared when
the trap encoder consumed the field.

## The poison was rewritten and the suite re-run (2026-08-28)

The original poison assigned `ex_mem_q.ctrl <= id_ex_q.ctrl` and then
conditionally overrode three bits, relying on last-assignment-wins within the
`always_ff`. Legal, and it synthesizes to an enable, but section 4.2 prefers
explicit priority over layout-dependent ordering.

Rewritten: an `always_comb` computes `ex_mem_ctrl_d` with the suppression
applied, and the `always_ff` makes one assignment from it. Same hardware, with
the priority a property of the code rather than of statement order.

**All eight mutations were re-run against the rewritten RTL and every verdict
is unchanged.** A mutation result is attached to a specific RTL text; carrying
the old verdicts forward across a rewrite would have been the stale-result
problem section 5.2 exists to prevent, even though the change is
behaviour-preserving. The re-run is what makes "behaviour-preserving" a
measurement rather than a claim.

T1 required a two-part injection against the new form: squashing now means
clearing the struct *and* the valid bit, where before it was one statement.
Same fault, expressed against different code.

## Mutation testing

Each injected into a file verified clean by `grep -c MUTATION`, built with
`make clean`, restored, and re-verified.

All verdicts below re-measured 2026-08-28 against the rewritten poison.

| # | Mutation | Result | Caught by |
|---|---|---|---|
| F | if_stage flush loses ex_redirect_valid (M3.5 fix reverted) | KILLED | t05_csr, shadow csrw at 0x124 retires |
| A | csr_write ungated from id_ex_q.valid | **SURVIVED** | unreachable - see below |
| T1 | ex_mem_q squashed instead of poisoned | KILLED | core trace one short per trap |
| T2 | poison drops mem_write | **SURVIVED, then KILLED** | sentinel at wrong address - see above |
| T3 | trap_epc = id_ex_q.pc + 4 | KILLED | mepc readback, x10 = 0x3c not 0x38 |
| T4 | store reports load cause | KILLED | mcause readback, x9 = 4 not 6 |
| T5 | mtval for cause 2 = PC | KILLED | mtval readback, x11 = 0x38 not 0x02000033 |
| T6 | branch outranks trap | KILLED | HARNESS FAIL - see #2 above |

**F is the important re-run.** Trap and mret are two new sources into the
redirect logic where M3.5's bug lived. F reverts that fix, and its kill after
the change confirms the shared flush mechanism is intact.

**T6 was killed only by the fixed checker.** With the old script it reported
PASS on a truncated trace. It is the mutation the checker fix was found by,
and the first the fix caught.

### Mutation A remains unkillable, with a sharper reason

0017 recorded the csr_write valid-gate as unreachable because the entire
`id_ex_q` struct is zeroed on redirect and stall, so a bubble carries
`csr_write = 0` as well as `valid = 0`.

This milestone introduced the condition the gate was kept as defence against -
a control-bits-only bubble with `valid` still set. A was re-run against it and
still survived.

**The reason is now precise: the poison is on `ex_mem_q` and the gate reads
`id_ex_q`, one stage upstream.** A valid-bit-only bubble in `ex_mem_q` cannot
reach a gate in front of it. The gate stays as defence against a future change
to `id_ex_q` bubbling, and remains a design decision rather than a
verification claim.

## Provenance

Every trap cause, mtval and mstatus value comes from Sail. No value in the
measured-behaviour table was produced by the DUT.

**Two checksums are self-derived**: t05_csr `0x82a4c825` and t06_traps
`0xc2ffe562`. Both are what this core produced. They are recorded here as
expected values because every term folded into them is a value Sail
independently confirmed across 79 and 100 instructions respectively - the
checksum is a hash of already-externally-verified values, not an independent
check. Section 4.5 applies: this is weaker than an external golden value and
is recorded as such.

## Failures and wrong turns

**Two file-edit anchors drawn from chat-pasted copies rather than the file.**
One asserted on hand-counted column alignment in a struct field declaration;
one used a PROJECT_INSTRUCTIONS section that did not exist in the repo copy.
Both aborted with nothing written. The rule is sharper than "anchor on
whitespace-free substrings": **anchors must be derived from the file, not from
a copy of it.** A document pasted into a conversation is a copy, and copies
drift.

**PROJECT_INSTRUCTIONS.md in git was the original 2026-07-29 version.** The
2026-08-21 revision - sections 2.4, 4.5, 5.2 provenance, and the observed
failure-mode table - existed only in the project instructions tab and had
never been committed. Found when an anchor failed against it. Committed in
this milestone.

**A golden copy in /tmp did not survive between sessions.** `cp` failed, the
mutation stayed in the file, and the re-run reproduced the previous result.
`grep -c MUTATION` caught it. Golden copies now go to $HOME. Cause of the /tmp
clearing not established.

**A mutation script aborting on its own guard looked like a failure and was
not** - a second invocation of an already-applied edit. "Assertion fired" and
"edit failed" are not the same event; the diff distinguishes them.

**`.org 0x1400` in the first probe collided with .tohost at 0x1000**, padding
.text to 0x141f. The linker caught it. The handler does not need a fixed
address - `la` from a label lets the linker place it, which also removes the
padding and any dependence on program size.

## Reproducing

    ./verif/sail/run_lockstep.sh t01_alu t02_memory t03_checksum \
      t04_hazards t05_csr t06_traps

Expect six lines, 800 instructions, exit 0.

Trap semantics measurement:

    sail_riscv_sim --rv32 --config-override verif/sail/rv32sky.json \
      --trace-instr --trace-gpr --trace-csr --trace-exception \
      --inst-limit 2000 sw/tests/probe_traps.elf

`probe_traps.S` is deliberately excluded from the regression: it has no
checksum and exists as a measurement record, not a gate.

## Not verified here

- **Interrupts.** No CLINT, no asynchronous entry. M5.
- **mtvec vectored mode.** MODE is WARL and reads 0; synchronous traps go to
  BASE in both modes, so the distinction is untested and currently irrelevant.
- **Nested traps.** No test takes a trap inside a handler.
- **Trap during a load-use stall.** The interaction of `stall` and
  `ex_trap_valid` is not specifically exercised.
- **Structural coverage.** Still unmeasured on the core. M3.7.
