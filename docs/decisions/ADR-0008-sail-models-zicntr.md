# ADR-0008: Sail models Zicntr so the counters can be lockstep-checked
**Date:** 2026-10-19
**Status:** Accepted

## Context

`verif/sail/rv32sky.json` disabled 76 extensions so that the reference model
matches the core exactly; a permissive model is a weak reference. Zicntr was
one of them.

M3.7 stage 2 (docs/results/0028) found five uncovered lines in `csr.sv`: no
program had ever read `minstret` or written any counter. The reason was not
the one `t05_csr.S` gives ("Sail has no model of this pipeline" - true of
`mcycle`, not of `minstret`, which is architectural). MEASURED 2026-10-17
(T1, `sw/tests/probe_minstret.S`): with Zicntr disabled, Sail does not
implement `minstret` at all. `csrr x5, minstret` trapped as an illegal
instruction (mcause 2, mtval 0xb02022f3). No counter could be checked against
Sail in any program.

With that one key flipped, in a temporary copy (T1, 2026-10-17):
- Sail accepted the configuration; no validation error, CLINT still disabled.
- The six regression programs still agreed and passed: 6 of 6, 800
  instructions, identical to the baseline.
- Sail then measured three conformance bugs in the core's `minstret`
  (docs/results/0029).

## Options considered

1. **Keep Zicntr disabled; check the counters some other way** - e.g. against
   a retirement count taken from the core's own trace. Pros: config stays an
   exact match. Cons: the expected values would be derived from the DUT and
   hand-written spec reading, which is the self-derived-golden category
   PROJECT_INSTRUCTIONS 4.5 says is provisional; and the write and trap
   semantics (H1b, H1c in 0029) would have no reference at all.
2. **Enable Zicntr in Sail; leave the core as it is.** Pros: an independent
   reference for every M-mode counter, at the cost of one key. Cons: Sail
   then also models the user aliases `cycle`, `time`, `instret` and their high
   halves, which the core does not implement.
3. **Implement full Zicntr in the core.** Pros: exact match. Cons: `time`
   needs a timer source, which is the CLINT at M5; scope creep now.

## Decision

Option 2.

## Rationale

The mismatch in option 2 can only produce FALSE DIVERGENCES, and loud ones: a
program that reads `cycle` makes the core trap where Sail does not, and
lockstep stops at that instruction. It cannot produce a false agreement - the
direction that matters, because the failure this project fears is a check
that cannot fail. Option 1's failure direction is the opposite: an expected
value derived from the DUT agrees with the DUT's bugs. Option 2 is the
measured one: 800 of 800 unchanged.

## Consequences

- Every counter read and write in a lockstep program is now checked against
  Sail, including trap and write semantics.
- `mcycle`'s low half still cannot appear in a lockstep program: the cycle
  count depends on the pipeline, and Sail's legitimately differs. Programs may
  read `mcycleh` only where both models must agree (after a carry).
- No test program may touch `cycle`, `time` or `instret` (0xC00-0xC02,
  0xC80-0xC82) until the core implements them.
- Revisit at M5: with the CLINT in place, implementing the user aliases makes
  the config an exact match again, and this ADR is superseded.
