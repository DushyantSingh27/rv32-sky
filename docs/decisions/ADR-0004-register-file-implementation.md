# ADR-0004: Register file implementation - flip-flops, not a generated macro

**Date:** 2026-08-21
**Status:** Accepted
**Resolves:** PROJECT_CONTEXT.md §8 decision D4, previously deferred to M6.

## Context

D4 asked whether the 32x32 register file should remain flip-flop based or move
to a generated macro (ORRAM, OpenRAM, Sram22). It was scheduled for M6 "decide
with area data". The area data now exists, so the decision is taken early.

Measured, `docs/results/0007` and `0009`:

| Block | Instance area (um^2) | Flops | um^2 per flop |
|---|---|---|---|
| CSR | 48,748 | 319 | 153 |
| muldiv | 99,711 | 578 | 172 |
| regfile | 147,663 | 992 | 149 |

## Options considered

1. **Flip-flops (status quo).** 147,663 um^2 measured, closes 50 MHz at all
   corners, zero inferred latches, verified by UVM env 3 (25,097 transactions,
   6,009 read/write collisions, 100% functional coverage).
2. **ORRAM standard-cell macro.** Reported ~28,000 bits/mm^2 on sky130hd
   (arXiv:2607.12244, T3). Production readiness unverified - open item in
   PROJECT_CONTEXT §9.
3. **Pre-built sky130 SRAM macros.** Single-port only; a 2R1W register file
   cannot be built from one without arbitration.

## Decision

Flip-flops. Revisit only under the joint condition in Consequences.

## Rationale

**The area argument runs the other way and is deliberately not the basis of
this decision.** `0009` establishes that flop-based storage on sky130 costs
roughly 150 um^2 per bit almost independently of surrounding logic - the CSR
block and the register file land within 3% of each other despite entirely
different structures. If cost is dominated by storage rather than by logic,
denser storage is precisely the lever that helps. At ORRAM's reported density
the same 992 bits is roughly 36,000 um^2 (T4: paper figure divided by measured
per-flop cost; ignores port count, access time and macro overhead). An
area-driven decision would favour option 2.

**The binding constraint is the read interface, not density.** `rtl/mem/tcm.sv`
and `rtl/core/regfile.sv` both provide COMBINATIONAL reads. The pipeline is
built on that:

- The register file is read-first: a read colliding with a same-cycle write to
  the same address returns the old value (`0014`). Forwarding exists precisely
  to cover that case, and env 3 verified 6,009 such collisions.
- x0 hardwiring is owned by the register file alone; the hazard unit
  deliberately does not duplicate it (`0014` - "the forwarding logic never asks
  the register file").
- The M3.5 flush fix depends on register-file state surviving a squash;
  `0015` records that flushing it hung the core.

A macro with a registered read port makes RS1/RS2 arrive one cycle later. That
is not a swap - it changes the hazard model, and it invalidates the forwarding
verification, the interlock verification, and UVM env 3.

**Timing of the re-verification cost is decisive.** Env 3 runs on Altair DSim,
whose free on-premises tier is discontinued 2026-09-01 (ADR-0002). Any change
requiring an env 3 re-verification pass must complete before that date or be
re-verified on an unresolved simulator. Spending the remaining window on a
storage swap that the area data does not require is a bad trade against goal #1.

## Consequences

- Register file area is fixed at ~147,663 um^2 for M6 floorplanning. This is
  ~5.3x the ALU and is the largest verified block; floorplan estimates must
  use the measured number, not a density-based one.
- The mux-tree read structure from `0007` is retained (55% fewer slew
  violations for 7.5% more area).
- No dependency on ORRAM maturity, which remains unverified.
- Forecloses nothing: the interface, not the storage, is the reason.

**Revisit condition (both must hold, not either):**
1. M6 floorplanning shows the register file is the binding area constraint; AND
2. A generated macro can provide combinationally-read dual-port access, so the
   pipeline hazard model is unchanged.

If (1) holds and (2) does not, the correct response is a pipeline change with
its own ADR, not a storage swap.
