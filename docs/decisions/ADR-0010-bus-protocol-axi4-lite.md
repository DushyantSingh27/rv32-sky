# ADR-0010: The SoC bus is AXI4-Lite
**Date:** 2026-11-05
**Status:** Accepted

## Context

M4 integrates the SoC: bus fabric, UART, QSPI, GPIO and a timer, with UVM env 5 as
the bus's verification IP (PROJECT_CONTEXT §3.4, §5.2, §7). The bus protocol had been
open as Decision D3 since 2026-07-29, with AXI4-Lite as the recommended default and a
note that it had to be decided before M4. Env 5's recorded state was "Blocked on D3".

The core decodes a peripheral window at `0x8000_0000` (bit 31; PROJECT_CONTEXT §3.3).
No peripheral and no bus exist yet, so nothing has been built against either protocol.

Constraints: solo project, no budget, learning value ranks above schedule when the two
conflict (PROJECT_INSTRUCTIONS §8). Skill-building is goal #1 (PROJECT_CONTEXT §1.2).

## Options considered

1. **Wishbone B4.** Pros: the simpler protocol of the two, so less fabric RTL, a
   smaller slave interface on every peripheral, and fewer protocol rules for env 5 to
   check before the SoC boots. Cons: a Wishbone VIP is the less valuable verification
   artefact to have built.
2. **AXI4-Lite.** Pros: env 5 becomes an AXI-family UVM VIP, the bus-agent skill this
   project exists to build. Cons: more to implement and more to check in the fabric,
   every slave and env 5.

How much larger AXI4-Lite is than Wishbone B4 was not measured or read for this ADR
(T5, recollection only). Nothing below depends on the size of the difference. Both
specifications are to be read, not recalled, when env 5 is designed.

## Decision

AXI4-Lite (option 2). Decided by the owner, 2026-11-05.

## Rationale

The evidence is the goal ranking, not a measurement. PROJECT_CONTEXT §1.2 ranks
"deep, demonstrable SystemVerilog + UVM skill" first, env 5 is where the bus turns
into a skill-building deliverable, and the owner's judgement is that an AXI4-Lite VIP
is the more valuable of the two to build and to show. This is the reasoning the
recommended default has carried since 2026-07-29. Nothing was measured to support or
test it, and no comparison of the two protocols' implementation cost on this core
exists.

Wishbone's simplicity is the cost accepted. Nothing in the project's measured record
argues against Wishbone, and on schedule alone the simpler protocol would be the
better choice. Goal #1 is the only reason AXI4-Lite wins.

## Consequences

- **Env 5 is an AXI4-Lite VIP** (PROJECT_CONTEXT §5.2): a reusable agent in master and
  slave modes, with protocol checkers. Its protocol rules are read from Arm's AMBA AXI
  specification when it is designed.
- **Every M4 peripheral (UART, QSPI, GPIO, timer) gets an AXI4-Lite slave interface**,
  and the fabric decodes among them.
- **Whatever the core presents at `0x8000_0000` has to reach the peripherals as an
  AXI4-Lite master.** That adapter is M4 design work and is not specified here.
- **A bus error on a peripheral access is a fault after EX.** PROJECT_CONTEXT §10
  already records that `minstret` relies on nothing faulting after EX (`0029`) and
  names M4 bus faults as one of three things that would break the count. How a bus
  error reaches the core is an M4 decision, and it has to settle that invariant. This
  is not specific to AXI4-Lite: any bus that can report an error raises the same
  question. It is recorded here because this is the first M4 bus decision.
- **More RTL and more verification before the SoC boots** than Wishbone would have
  needed. M4's gate criteria are unchanged.
- **Reversible cheaply only until M4 RTL exists.** After that, a reversal means
  rewriting the fabric, every slave interface and env 5, and would be a new ADR
  superseding this one.
