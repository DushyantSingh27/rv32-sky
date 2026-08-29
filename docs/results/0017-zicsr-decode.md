# 0017 — Zicsr decode, misa correction, decoder harness repair

## PROVENANCE NOTE (added 2026-08-27)

Part 2 records "t05_csr 79 instructions, all agree" as a verified result.
**The lockstep half of that claim holds; the harness half was never checked.**

t05_csr stores a checksum to 0x8000_0000 and was run without `--expect`, so
tb_core.cpp applied its default convention - non-zero means FAIL - and
reported `RESULT: FAIL (code 0x82a4c825)` on every run from the day it was
written. `run_lockstep.sh` read only compare.py's verdict and discarded the
harness's exit status, so the failure was invisible.

**The conclusions here stand.** Every PC and register write in t05_csr does
agree with Sail, and mutations 1-4 and B/C/D/F were killed by that
comparison, which is unaffected. But "all agree" described one of two checks.

Found 2026-08-27 while diagnosing why mutation T6 reported PASS on a
truncated trace. Both verdicts are now checked and expected checksums are
recorded per program in run_lockstep.sh. See docs/results/0018.


**Date:** 2026-08-23
**Milestone:** M3.4a step 3a–3d
**Tools:** Verilator 5.050 (v5.050-60-g3d2421f3b), Sail RISC-V 0.13.1,
riscv64-unknown-elf-as (GCC 16.1.0)
**Status:** decode verified. NOT yet integrated — csr.sv is still absent from
rtl/files.f and nothing consumes the new ctrl_t fields.

## Result

| Metric | Before | After |
|---|---|---|
| Decoder checks | 4,592 | 6,624 |
| Reference cases | 221 | 241 |
| Illegal-encoding cases | 608 | 613 |
| Failures | 0 | 0 |
| ctrl_t width | 38 bits | 46 bits |

Mutations: 4 injected, 4 killed.

## misa — measured, not assumed

MISA_VALUE advertised C (bit 2) and M (bit 12). Neither is implemented: C
never reaches the decoder (instr[1:0] != 2'b11 is rejected) and M is caught by
the funct7 check. misa is architecturally readable, so `csrr rd, misa` puts it
into a GPR that Sail lockstep compares directly.

Measured rather than reasoned. Sail reports:

    misa = 0x40000100
    ISA string = rv32i_zicsr_zifencei_zvl32b_zvl64b_zvl128b_zvl256b_ssstateen_smstateen

Command:

    sail_riscv_sim --rv32 --config-override verif/sail/rv32sky.json \
      --print-isa-string

MISA_VALUE corrected to {2'b01, 30'd0} | (32'd1 << 8) = 0x40000100. The
hypothesis had been that C might need disabling in rv32sky.json — the config
disables Zca/Zcf/Zcd/Zcb/Zcmop but never C itself. The ISA string shows no C,
so no config change was needed. Worth recording that the check was cheap and
the guess would have been wrong in a non-obvious direction.

## Sail sets mip.MTIP with the CLINT disabled

The same probe showed, between instructions:

    CSR mip (0x344) <- 0x00000080

Bit 7 is MTIP. rv32sky.json sets clint.supported = false and disables the
simple_interrupt_generator. Nothing is taken from it — mstatus.MIE is zero out
of reset — but mip is architecturally readable, and after integration the
core's mip is driven by irq_timer, which is tied to zero. A `csrr rd, mip`
would then read 0x00000000 on the core and 0x00000080 on Sail.

Cause not investigated. Consequence recorded: mip joins the lockstep exclusion
list.

**CSRs excluded from lockstep comparison, with reasons:**

| CSR | Reason |
|---|---|
| mcycle, mcycleh | csr.sv increments every cycle; Sail has no model of this pipeline |
| minstret, minstreth | same, retirement-gated |
| mip | Sail asserts MTIP with the CLINT disabled; core ties irq_timer low |

All five are legitimate model differences, not bugs. Nine of the fourteen
implemented CSRs remain comparable.

## Four info CSRs confirmed at zero

mvendorid, marchid, mimpid, mhartid all read 0x00000000 under Sail with no
exception raised (--trace-exception was enabled specifically to distinguish a
trap from a successful read of zero). csr.sv:113-116 returning zero for all
four is correct. Previously an assumption; now measured.

## The stale-map guard could not fail

tb_decoder.cpp carried a guard whose comment read "If ctrl_t changes, THIS
MUST CHANGE". It drove instr to all-ones and checked rs1_addr == 0x1f.

rs1_addr, rs2_addr and rd_addr are adjacent and ALL read 0x1f under all-ones.
Any 5-bit window anywhere in that 15-bit region passes. When ctrl_t grew from
38 to 46 bits, the guard passed while 1,771 of 4,592 checks failed.

This is failure mode #1 — test values landing where correct and broken
implementations agree — occurring inside the one mechanism written specifically
to prevent it. The guard was not weak; it was untestable. It had never been
exercised because ctrl_t had never changed.

Replaced with `add x11, x17, x28`: rs1=17, rs2=28, rd=11 are three distinct
values, so any shift moves at least one. A separate check on bit 45 catches a
width change that preserves relative field order.

Symptom worth noting for diagnosis: the stale macro read rs1_addr as 2 where
17 was expected. Small, plausible, in-range garbage — not an obvious zero or
all-ones. A field-map error does not announce itself.

## Asymmetric CSR write suppression

csr.sv:33 documents csr_write as "rs1 != x0, or uimm != 0" for every form.
That is correct for CSRRS/CSRRC/CSRRSI/CSRRCI and WRONG for CSRRW/CSRRWI,
which write unconditionally.

Consequence if implemented as documented: `csrw mscratch, x0` — the idiomatic
CSR-zeroing sequence, assembling to `csrrw x0, mscratch, x0` — performs no
write. The CSR keeps its old value and the instruction retires cleanly.

Every CSR write with a non-x0 source decodes identically under both rules. A
vector set without an x0 source cannot distinguish them. The ACT4 preambles
write mtvec; if they use a non-x0 source, the bug would have survived all of
M3.4.

The decoder implements the spec rule. csr.sv's comment is still wrong and is
an integration-step fix.

## Mutation testing

Each mutation injected into a file verified clean (`grep -c MUTATION` = 0), run
with `make clean` first, then restored and re-verified.

| # | Mutation | Result | Killed by |
|---|---|---|---|
| 1 | csr_write = (rs1 != x0) — drops RW-always | KILLED, 4 failures | csrrw x5/x0,mscratch,x0; csrrwi x5/x0,mscratch,0 |
| 2 | rs1_used = 1'b1 on immediate forms | KILLED, assertion abort | decoder.sv:302 immediate assertion |
| 3 | rs1/rd zero check removed from SYSTEM | KILLED, 2 failures | literal encodings 0x000000f3, 0x00108073 |
| 4 | csr_read = 1'b1 | KILLED, 4 failures | four vectors with rd == x0 |

Mutation 1 is the one this vector set exists for. It fails exactly the four
vectors with an x0 or zero source and nothing else.

Mutation 3 was killed ONLY by the two literal encodings — `ecall` with rd=x1
and `ebreak` with rs1=x1 — which the assembler will not emit and which had to
be hand-written into bad_opcodes. wfi, sret and funct3=100 were already illegal
via other paths. Omitting the literals as "the assembler covers this" would
have let M3 survive.

## Failures and wrong turns

**Mutation stacking — two invalid runs.** The restore step between mutations
was `cp`, which is silent on success. When it did not run, M2's edit persisted
into M3 and M4. Both aborted on M2's assertion at decoder.sv:302 before
reaching their own checks. The runs looked like kills; they were not.

Detected by the abort message naming an assertion neither M3 nor M4 touches.
Fixed by adding `grep -c MUTATION` before and after every injection and an
`assert 'MUTATION' not in s` inside each injection script. A silent restore in
a mutation loop is failure mode #2 wearing a different hat.

**RTL assertions mask subsequent checks.** An immediate assertion in rtl/
calls $stop on first violation, so the harness reports nothing after it. M2's
kill was valid but it meant M3 and M4 could not report their own results at
all. Assertions and check-counting harnesses interact badly under mutation;
run mutations one at a time and read the abort line before the summary.

**`rm -f` on the binary does not force RTL re-elaboration.** After the macro
fix, Verilator reported "Built from 0.000 MB sources in 0 modules" — only the
C++ recompiled. Mutation runs must use `make clean`. This is failure mode #4
and it was avoided by reading the build log rather than trusting the rebuild.

**Five wrong Sail flags in a row.** --trace=step, --instruction-limit, --config
(where --config-override was needed), and two others were recalled rather than
read. --trace-step exists but means "blank line between steps", not "trace each
step" — a half-remembered name that resolves to a real but different flag.
Settled by reading --help and by reading verif/sail/run_lockstep.sh, which had
the working invocation on disk the whole time.

**Predicted failure counts were wrong twice.** M4 was predicted to produce 3
failures and produced 4 — csrrwi x0,mscratch,0 also has rd == x0. Verilator was
predicted to emit UNUSED warnings on the seven new ctrl_t fields and emitted
none: it does not warn on unread members of a packed struct. That second one
matters beyond bookkeeping — **lint cannot detect an unconsumed ctrl_t field**,
so if the integration step forgets to wire csr_imm into the wdata mux, the core
silently uses rs1_data for the immediate forms and lint stays green. That has
to be caught by lockstep.

**`cat -n` output is not safe as a match pattern.** A python3 edit asserted 0
matches on the -march line because the line-number column padding was read as
source indentation. The assertion caught it and nothing was written. Anchor on
whitespace-free substrings.

## Reproduce

    cd verif/verilator/decoder && make clean && make ref && make run

Expect: 241 reference cases, 613 illegal cases, 6,624 checks, 0 failures.

## Provenance

Decoder expectations are derived from the RISC-V spec by hand, not from the
encoding and not from the RTL. Encodings come from riscv64-unknown-elf-as.
misa and the info-CSR values come from Sail. No value in this file was produced
by the DUT.

Not yet verified: nothing here exercises the decoder inside the pipeline. The
new ctrl_t fields are produced but unconsumed. Integration and Sail lockstep
are the next steps, and until they pass, this file records a verified DECODE,
not a verified CORE.

---

# Part 2 — Integration (step 3e)

**Date:** 2026-08-24
**Status:** CSR read/write path integrated and verified under Sail lockstep.
No traps — trap_valid, mret and the irq_* pins are tied off.

## Result

| Program | Instructions | Agreement |
|---|---|---|
| t01_alu | 60 | all agree |
| t02_memory | 176 | all agree |
| t03_checksum | 305 | all agree |
| t04_hazards | 80 | all agree |
| t05_csr | 79 | all agree |
| **Total** | **700** | **0 divergences** |

The first four are unchanged from M3.5 (621), so the EX result mux and the
csr.sv instantiation disturbed nothing.

## Placement

CSR access sits in EX. csr_addr is id_ex_q.imm[11:0] — imm_gen runs on FMT_I
for every SYSTEM encoding and sign extension leaves bits [11:0] intact, so no
ctrl_t field was needed (36 flops saved across three pipeline registers).

csr_rdata is muxed over ex_alu_result before ex_mem_q. Forwarding, WB_ALU and
the trace port then work unchanged: a CSR read is indistinguishable from an ALU
result to everything downstream.

Four outputs routed to the module boundary rather than lint-suppressed —
csr_illegal_o, mtvec_o, mepc_o, irq_pending_o. Same rule the file already
applied to mem_misaligned_o: a detected-but-unhandled condition belongs at the
boundary, not silently dropped inside.

## A false PASS, and the compare.py hole that produced it

t05_csr's first lockstep run reported "59 instructions compared, all agree".
The core retired 77. Sail had stopped at 59.

compare.py compared min(len(sail), len(core)) and, when the lengths differed,
printed an explanatory note and passed. The note was written for the case where
the CORE's trace is a prefix of Sail's — legitimate, because Sail terminates on
the HTIF write and the Verilator harness stops earlier at 0x8000_0000. The
reverse case, Sail shorter than the core, is never legitimate and was not
distinguished.

Sail had trapped. The tail of the trace showed a repeating loop:

    mcause = 1 (instruction access fault), mepc = mtval = 0x2000

**Cause was the test program, not the RTL.** t05 wrote all-ones to mstatus
(setting MIE) and all-ones to mie (setting MTIE bit 7). Sail asserts mip.MTIP
even with the CLINT disabled — recorded in Part 1 of this file — so the machine
took a timer interrupt, vectored to mtvec = 0x2000, and faulted on the fetch.
0x2000 is one byte past the 8 KB TCM.

The core has no trap path yet, ignored all of it, and ran to completion.

Two lessons, both recorded because they generalise:

- **Excluding a CSR from COMPARISON does nothing about a CSR that changes
  CONTROL FLOW.** mip was on the exclusion list in Part 1 of this same file,
  and the test that armed it was written three steps later.
- **A prefix comparison passes over the window it did not reach.** compare.py
  now FAILs when Sail is shorter than the core. The fix was verified against the
  known-bad logs before being trusted: it reports FAIL on the exact data that
  had reported PASS. The dead code that previously sat at that line was an
  abandoned attempt at the same check.

Test fixed: mtvec 0x2003 -> 0x1403 (in TCM, MODE bits still non-zero so WARL
masking is exercised), mie all-ones -> 0x808 (MSIE|MEIE, no MTIE).

A second, smaller error on the same edit: 0x1803 was tried first and rejected
by the assembler, because addi's immediate is a signed 12-bit field with a
maximum of 2047. The comment above that instruction explained the memory-map
reasoning in detail and said nothing about the immediate range. A thorough
comment on one property is no guard on the property beside it.

## Mutation testing — 6 injected, 5 killed, 1 unkillable

Each injected into a file verified clean by `grep -c MUTATION`, built with
`make clean`, then restored and re-verified.

| # | Mutation | Result | Caught by |
|---|---|---|---|
| A | csr_write ungated from id_ex_q.valid | **SURVIVED** | — see below |
| B | wdata mux ignores csr_imm | KILLED | csrwi readback: x7 = 0xabcde1d3, expected 0x1f |
| C | result mux removed | KILLED | first csrr: x2 = 0, expected 0xabcde123 |
| D | csr_read tied low | KILLED | identical failure to C |
| E | csr_op_e reordered so CSR_NONE != 2'b00 | SURVIVED (by design — see below) |
| F | if_stage flush loses ex_redirect_valid (M3.5 fix reverted) | KILLED | shadow csrw at 0x124 retired |

**C and D are indistinguishable.** Both produce byte-identical divergence
output. t05 cannot tell a broken result mux from a suppressed read — each is
caught, but the diagnosis would require a second measurement.

## Mutation A: the valid gate is unreachable, and my explanation of it was wrong

Mutation A survived. The code comment claimed the gate guards against a '0
bubble decoding as CSR_NONE by accident of the enum encoding.

Mutation E tested that directly: reorder csr_op_e so CSR_NONE = 2'b01, making a
zeroed bubble decode as CSR_RW. It passed. A+E together — enum reordered AND
the gate removed — also passed.

A $display probe on id_ex_q resolved it. Every CSR instruction reaching EX has
valid = 1, and the two shadow csrw instructions at 0x124 and 0x128 never appear
at all. rv32_core.sv clears the ENTIRE id_ex_q struct on redirect and on stall,
so a bubble carries csr_write = 0 as well as valid = 0, and csr.sv:142 requires
csr_write.

**The gate is unreachable under the current squash mechanism and no test can
kill its removal.** It is kept as defence against a future change to
valid-bit-only bubbling, which trap entry may introduce. That is now what the
comment says. It is not claimed as verified.

The general point: a guard can be correct, cheap, and worth keeping while being
untestable. Recording which is which is the difference between a verification
claim and a design decision.

## What the branch-shadow block actually tests

Written to measure the valid gate. It does not — mutation A proves that. What it
does test is the M3.5 squash mechanism: mutation F reverted that fix and t05
diverged at exactly the right instruction, the core retiring the shadow csrw at
0x124 where Sail proceeds to 0x12c.

The block earns its place. The claim attached to it was wrong.

## Provenance

Every expected value comes from Sail. No golden value in this part was produced
by the DUT. The five programs' agreement is over 700 instructions of PC and
register-write comparison.

**Not verified here:** csr_illegal (produced, unconsumed), the trap path (tied
off), and any CSR whose value differs legitimately between core and model —
mcycle, mcycleh, minstret, minstreth, mip. Nine of fourteen CSRs are compared.
