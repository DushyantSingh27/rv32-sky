# ADR-0002: Continue on DSim within the licence window; front-load UVM

**Date:** 2026-07-31
**Status:** Accepted
**Supersedes:** ADR-0001 (retained unmodified as the record of the original decision
and of the risk that subsequently materialised)

## Context

ADR-0001 selected Altair DSim as primary UVM simulator on 2026-07-29, explicitly
recording vendor-continuity risk following the Altair acquisition, and setting a review
trigger for withdrawal or material change of the free individual licence.

That trigger fired two days later. On 2026-07-31 the DSim runtime licence notice
disclosed (T1, observed directly in tool output):

  - Free on-prem DSim licences discontinued 2026-09-01
  - DSim Cloud services discontinued 2026-09-01
  - All DSim Cloud data permanently deleted 2026-10-15

Corroborating (T2): the DSim Studio VS Code extension is published as DEPRECATED with
removal from the Marketplace on 2026-09-01. Altair has been acquired by Siemens, who
own Questa - a direct competitor to a free DSim tier.

The licence issued to this project was created 2026-07-31 and expires 2026-09-02:
33 days, not the 90 days the Altair KB documents. The duration has been truncated to
the discontinuation date.

## Options considered

1. **Switch to Vivado XSim 2025.2 now** - verified available, works offline
   indefinitely, but UVM 1.2 and a ~60 GB install.
2. **Spend up to 2 hours investigating** whether a free DSim feature survives under
   Altair License Manager, whether Altair Student Edition carries DSim entitlement, or
   whether Questa's student tier is viable.
3. **Continue on DSim for the remaining window**, capture all results, publish them
   with the completed project, and accept that DSim will not be re-runnable afterwards.

## Decision

Option 3, by owner decision.

Consequently, milestones are reordered to front-load UVM work into the window: leaf
blocks are built standalone first (new M1), and UVM environments 1-4 are completed
against them (new M2), before pipeline integration (new M3).

## Rationale

The owner's position is that results captured during the window will be published with
the completed project, so re-running DSim afterwards is not required.

Claude recorded a disagreement, once, preserved here rather than in chat:

  - PROJECT_INSTRUCTIONS 5.3 requires every result to be reproducible from a recorded
    command, and states results which cannot be reproduced are not reported. Coverage
    results produced by DSim become non-reproducible on 2026-09-02.
  - UVM environments 5, 6 and 7 fall after the window under any realistic schedule, so
    a second simulator decision is deferred, not avoided.

The owner owns this decision. It is recorded, not relitigated.

The milestone reorder is independently sound regardless of licensing. Block-level
verification before integration is standard practice: debugging a multiplier inside a
five-stage pipeline is substantially harder than debugging it standalone. The reorder
also front-loads the project's highest-ranked goal (deep SystemVerilog and UVM skill,
PROJECT_CONTEXT 1.2 goal 1) rather than deferring it behind RTL work.

## Consequences

### Makes easier
- UVM environments 1-4, the highest-value skill deliverables, are built while the best
  available UVM implementation (2020.3.1) is licensed.
- Each leaf block is verified in isolation, so pipeline integration at M3 starts from
  four known-good components.
- Early standalone synthesis of each block gives real area and timing data long before
  M7 hardening.

### Makes harder
- Deliberately moves toward the big-bang integration failure mode named in
  PROJECT_INSTRUCTIONS 7. Mitigated by requiring full block-level verification at M2
  before any integration. If M1 and M2 slip, the outcome is four verified blocks and no
  CPU - a worse portfolio than a working CPU with one UVM env.
- A simulator decision for UVM envs 5-7 is deferred to a later ADR.
- Coverage results in docs/results/ carry an implicit expiry: reproducible only before
  2026-09-02.

### Forecloses
- Nothing structurally. ADR-0001's portability rules remain in force, so any future
  simulator migration costs a new .mk file rather than a rewrite.

### Follow-up actions

| # | Action | Gate |
|---|---|---|
| 1 | Complete UVM envs 1-4 before 2026-09-02 | M2 |
| 2 | Archive all coverage databases and reports into docs/results/ with dates, seeds and exact commands | Continuous |
| 3 | Decide simulator for UVM envs 5-7 in a new ADR | Before M5 |
| 4 | Record in the M9 writeup that DSim results were produced under a licence since discontinued | M9 |
