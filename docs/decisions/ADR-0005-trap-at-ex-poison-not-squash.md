# ADR-0005: Synchronous traps taken in EX, trapping instruction poisoned not squashed

**Date:** 2026-08-27
**Status:** Accepted

## Context

M3.4a step 5 adds synchronous trap entry (causes 0, 2, 3, 4, 6, 11) and `mret`
to the RV32I+Zicsr pipeline. Two questions had to be answered before any RTL
was written:

1. **At which stage is the trap taken?** This determines how many pipeline
   registers must be squashed, and therefore how much new surface is exposed
   to the M3.5 bug class - a registered redirect whose squash signal and PC
   change drift one cycle apart. That bug took four wrong fixes to find
   (docs/results/0015).
2. **Does the trapping instruction retire?** Sail lockstep compares one record
   per retired instruction. If the core and the model disagree on whether the
   trapping instruction produces a record, every trap misaligns the two traces
   by one and compare.py fails on a design that is architecturally correct.

Question 2 is not answerable by reasoning - both behaviours are defensible.
It was measured.

## Options considered

**1. Trap at EX, squash the trapping instruction.** Clear `ex_mem_q` on trap,
killing the writeback and the memory request in one place. This was the
original plan. *Rejected by measurement.*

**2. Trap at EX, poison the trapping instruction.** Load `ex_mem_q` normally
but force `reg_write`, `mem_read` and `mem_write` low. The instruction
advances to WB and retires with its PC and no writes. *Chosen.*

**3. Trap at MEM.** All causes detectable, including misalignment from
`u_lsu` directly. But the memory request is issued combinationally from
`ex_mem_q`, so a trapping store would already have been presented to the TCM
and would need separate gating. More logic, later detection, no benefit.
*Rejected.*

## Decision

Traps are detected in EX and the trapping instruction is **poisoned, not
squashed**. Trap and `mret` share the single existing redirect path rather
than introducing a parallel one.

## Rationale

**Poisoning is required by the reference model, and this was measured.**
sw/tests/probe_traps.S under Sail 0.13.1 shows the trapping instruction
appearing as a trace record with a PC and no register write:

    [48] [M]: 0x00000040 (0x00022303) lw x6, 0x0(x4)
    trapping from M to M to handle misaligned-load

No `x6 <- ...` line follows. The same holds for the illegal instruction at
[5], the ebreak at [15], and the jalr at [60], whose link register is not
written. The core must therefore emit exactly one retirement record per trap.

Mutation T1 confirms the test distinguishes the two: squashing instead of
poisoning makes the core trace one instruction shorter per trap, and lockstep
diverges at the first trap with Sail's [15] appearing as the core's [14].

**EX is correct because the trap is precise by construction.** In an in-order
pipeline every instruction younger than the trapping one is in ID or IF -
exactly the two stages the branch redirect already squashes - and every
instruction older than it is in MEM or WB and is supposed to complete. No new
squash target is introduced, so the M3.5 bug class gains no new surface.

**Store suppression falls out of the existing valid gate.** `dmem_we` is
`ex_mem_q.valid && ex_mem_q.ctrl.mem_write && !is_periph`. Clearing
`mem_write` in the poison is sufficient. Verified by mutation T2.

**One redirect path, not two.** `ex_redirect_valid` and `ex_redirect_pc` gain
trap and mret as sources rather than being paralleled. The registered
redirect, the `ex_redirect_valid || redirect_valid` flush in if_stage, and the
full-struct clear of `id_ex_q` all apply to traps unchanged. Mutation F -
reverting the M3.5 flush fix - is still killed after the change, confirming
the shared mechanism is intact.

**Trap outranks branch, and that is semantics rather than a tie-break.** A
jalr to a misaligned target traps *instead of* jumping, with mepc = the jump's
PC and mtval = the would-be target. Mutation T6 inverts the priority and is
killed.

## Consequences

**Makes easier:**
- Trap entry reuses verified redirect and flush logic; no new flush mechanism.
- A trapping store cannot reach memory; the existing valid gate handles it.
- Precise exceptions with no reorder or replay machinery.

**Makes harder:**
- The misaligned check is duplicated in position: u_lsu computes it at MEM
  from `ex_mem_q`, the trap encoder at EX from `ex_alu_result`. Mitigated by
  `is_misaligned()` in rv32_pkg.sv - one definition, two call sites.
- `id_ex_t` gains a 32-bit `instr` field for mtval on cause 2. 32 flops in one
  pipeline register. ctrl_t is deliberately not extended, which would shift
  every field position in tb_decoder.cpp.
- The poison is a control-bits-only bubble with `valid` still set, a shape the
  pipeline did not previously contain. Mutation A was re-run against it and
  still survives: the poison is on `ex_mem_q` while the csr_write gate reads
  `id_ex_q`, one stage upstream.

**Forecloses:**
- Nothing for interrupts. Asynchronous entry at M5 reuses the same ports and
  redirect path; only the detection condition differs.
- Native misaligned access support. Reversible, but it would mean reverting
  the Sail config and re-verifying.

## Verification

| # | Mutation | Result |
|---|---|---|
| F | M3.5 flush fix reverted | KILLED |
| A | csr_write valid gate removed | SURVIVED - unreachable, see 0017 |
| T1 | squash instead of poison | KILLED |
| T2 | mem_write not suppressed | KILLED after fixing the test |
| T3 | mepc = PC+4 | KILLED |
| T4 | store reports load cause | KILLED |
| T5 | mtval = PC instead of the instruction word | KILLED |
| T6 | branch outranks trap | KILLED |

800 instructions across six programs agree with Sail.
