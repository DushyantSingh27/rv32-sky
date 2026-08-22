# 0017 — Zicsr decode, misa correction, decoder harness repair

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
