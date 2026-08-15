# ADR-0003: M3 scope and approach — RV32I core integration

**Date:** 2026-08-13
**Status:** Accepted

## Context

M1 and M2 are complete: four leaf blocks (ALU, muldiv, register file, CSR) each
hardened to GDSII and each verified by a UVM environment at 100% functional
coverage, with mutation testing confirming the checkers can fail.

The vplan (`docs/vplan/`) enumerates 71 Deferred features - behaviours whose RTL
does not exist. M3 is where most of them get built. It is the largest milestone
so far and needed a decision record rather than an ad-hoc start.

## Scope

**RV32I only.** The C extension, traps and interrupts are M4 per PROJECT_CONTEXT
section 7. This keeps the decoder to roughly 40 instructions rather than 70, and
keeps trap detection out of a milestone already carrying pipeline integration.

## Decisions

### 1. Reference model: Sail, not Spike

The riscv-arch-test ACTs use the RISC-V Sail model to compute expected results,
so Sail is required regardless. Using Spike for lockstep as well would mean
maintaining two reference models for one core.

Trade-off accepted: Spike is the more common lockstep choice and better
documented for that purpose. Revisit if Sail's stepping interface proves
awkward.

### 2. Decoder verified with directed Verilator tests, not UVM

A decoder is an ideal UVM target - pure combinational, exhaustively checkable.
But PROJECT_CONTEXT section 5.2 does not list a decoder environment, and the
DSim licence expires 2026-09-02 (ADR-0002). The remaining licence time is
reserved for env 7, which section 5.2 calls the portfolio centrepiece.

Directed Verilator tests are adequate here: the decoder's correctness is
checkable by enumeration, and compliance testing at M3.4 exercises it against
the official suite.

### 3. RISC-V software toolchain: prebuilt first, source as fallback

Building `riscv-gnu-toolchain` from source takes up to several hours per the
riscv-arch-test README. A prebuilt toolchain takes minutes but may lack the
`rv32i` multilib or default to rv64.

Approach: install prebuilt, then VERIFY by compiling a trivial program with
`-march=rv32i -mabi=ilp32` and disassembling it. If every instruction is one the
core will implement, the prebuilt is adequate. Fall back to source otherwise.

Note: the ACTs officially support GCC 15/Binutils 2.44 or LLVM/Clang 21, and
only the latest release of each is tested in their CI. A very old prebuilt may
work at M3.2 and fail at M3.4.

## Open question resolved during planning: RISCOF vs ACT4

PROJECT_CONTEXT section 4.3 lists RISCOF + riscv-arch-test as the compliance
path. The riscv-arch-test repository now describes an **ACT4 Framework** with a
different architecture: it selects tests based on DUT capabilities, uses the
Sail model configured to match the DUT to compute expected results, and compiles
those into self-checking ELFs. Top-level commands are `make`, `make tests`,
`make coverage` inside a venv.

RISCOF orchestrates a DUT plugin against a reference plugin externally; ACT4
generates self-checking binaries. These are different flows.

**UNVERIFIED (2026-08-13):** whether RISCOF is deprecated or merely an
alternative. Its documentation is still published (1.24.0) and third-party ports
still use it. Same shape as the OpenLane -> LibreLane trap in section 4.1.

**Resolution: determine this by reading the repository at M3.0, before writing
any plugin.** Do not assume either flow.

## Plan

| Stage | Content | Gate |
|---|---|---|
| M3.0 | RISC-V toolchain, Sail, compliance framework | `rv32i` ELF produced and disassembled correctly |
| M3.1 | Decoder, immediate generation | Directed tests pass; 21 Deferred vplan rows close |
| M3.2 | IF stage, pipeline registers, load/store unit, TCM, core top, Verilator harness | **A hand-written assembly program executes correctly** |
| M3.3 | Forwarding (EX->EX, MEM->EX, **WB->ID**), load-use interlock, branch flush, muldiv flush input | Dependent instruction sequences execute correctly |
| M3.4 | Compliance suite | 100% pass on RV32I |
| M3.5 | Sail lockstep | Register and PC state match per instruction |
| M3.6 | riscv-formal | Bounded depth >= 20 |
| M3.7 | CI | Lint + Verilator regression on every commit |

Env 7 (full-core UVM) follows immediately after. It will almost certainly fall
outside the DSim licence window; ADR-0002 anticipated this.

## Two things carried forward from the vplan

**WB->ID forwarding is MANDATORY, not optional.** Env 3 verified read-first
behaviour on 6,009 collisions: a read colliding with a write to the same address
returns the pre-write value. That means a value written in WB is invisible to an
instruction reading in ID unless forwarded. Without it, programs silently
compute wrong answers. This is the single highest-risk item in M3.3.

**The muldiv has no flush input.** A 35-cycle divide must be cancellable when a
branch mispredicts. The block was designed standalone and has no such port. This
is a design gap the vplan surfaced, and it requires an RTL change plus a
re-verification pass through env 2.

## Consequences

### Makes easier
- Every leaf block is already verified at 100%, so integration bugs should be in
  the glue rather than the blocks.
- The vplan's Deferred rows are a ready-made checklist; M3 is specified rather
  than improvised.

### Makes harder
- M3.2 gates on a hand-written program running BEFORE hazards are added. That is
  deliberate - PROJECT_INSTRUCTIONS section 7 names big-bang integration as a
  failure mode, and a core that executes ten instructions correctly is worth
  more than one that theoretically executes all of them.
- The muldiv flush change invalidates part of env 2's verification and needs a
  re-run.

### Risks

| Risk | Mitigation |
|---|---|
| Toolchain build consumes days | Prebuilt first; start it before RTL work either way |
| RISCOF/ACT4 confusion | Resolve at M3.0 by reading the repo |
| Debugging four blocks at once | They are individually verified; gate M3.2 on a minimal program |
| riscv-formal may not support this core shape (T5) | Timebox per section 7; it gates M3 but does not block M3.4 or M3.5 |
