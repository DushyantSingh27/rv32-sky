# ADR-0007: Coverage interfaces — functional coverage recovered under Verilator

**Date:** 2026-10-02
**Status:** Accepted
**Amends:** ADR-0006. Its *decision* — Verilator as the UVM simulator — stands
unchanged. One of its *consequences*, "functional coverage is unavailable", is
overturned. ADR-0006 is not superseded and is not edited.

## Context

ADR-0006 accepted the loss of functional coverage on the strength of `cg3.sv`:
a covergroup declared inside a class returns 0.00% from `get_inst_coverage()`
under Verilator 5.050, silently, while a module-scope one returns 100.00%.
Class scope is UVM's required idiom — every coverage collector in this project
declares its covergroup inside a `uvm_subscriber` — so all seven environments
lost the metric at once.

That measurement was correct and has now been reproduced (`0027`). What was
never tested is the middle ground: an **interface**.

Interfaces matter because they are already in the picture. Every UVM component
reaches the DUT through a virtual interface handle delivered by
`uvm_config_db`. If a covergroup declared in an interface accumulates when
sampled through that handle, the collectors can keep their structure and move
only the covergroup.

Measured 2026-10-02, `docs/results/0027`:

| Scope | no UVM (`cg4`) | under UVM (`cg5`) |
|---|---|---|
| module | 100.00 % | 100.00 % |
| class | 0.00 % | 0.00 % |
| **interface, via virtual interface** | **100.00 %** | **100.00 %** |

`cg5` samples from a real `uvm_subscriber` over a `uvm_analysis_port`. Both
probes carry the module and class cases as controls; both reproduced ADR-0006
exactly, so the interface figure is interpretable rather than confounded.

## Options considered

**1. Leave functional coverage unavailable.** Zero work. Rejected: the
measurement says it is available, and section 5.3's own standard is that a
metric is dropped when it cannot be obtained, not when obtaining it is
inconvenient.

**2. Add coverage-only fields to each existing DUT interface**
(`alu_if`, `csr_if`, `core_if`, …) and declare the covergroups there.
Smallest diff. Rejected: those interfaces describe pins. Putting transaction
fields and covergroups in them conflates "what the DUT's boundary is" with
"what we are measuring about it", and every future reader has to work out which
signals are hardware.

**3. A dedicated coverage interface per environment.** CHOSEN. See below.

**4. Wait for upstream.** Antmicro and CHIPS Alliance are actively working on
Verilator's coverage support, and class scope may be fixed in a later release.
Rejected as a *plan* — it is an unbounded wait on someone else's schedule — but
retained as an outcome: if class scope starts working, the collectors' original
covergroups can come back and the coverage interfaces retire.

## Decision

Each environment gains a **coverage interface**, `<env>_cov_if`, instantiated in
the testbench top and passed to the collector through `uvm_config_db` like any
other virtual interface.

It contains:

- the covergroups for that environment
- the fields they sample, written by the collector immediately before `sample()`
- nothing else — no DUT pins, no clocking blocks, no protocol logic

The collector keeps its `uvm_subscriber` structure, its `write()` method and
its place in the environment. Its covergroup declaration moves into the
coverage interface; its `write()` writes the fields and calls
`vif_cov.<cg>.sample()`.

The DUT interfaces are not touched.

## Rationale

**It is a mechanical change, not an architectural one.** The collector's
position, its analysis connection, its build and connect phases and its config
DB usage are all unchanged. Only the covergroup's declaration site moves. That
keeps the environments recognisable as standard UVM, which is goal #1 in
section 1.2 — the structure is what an interview probes, and a non-standard
coverage mechanism would undercut the whole point.

**It separates two things that are not the same.** A DUT interface is a
description of hardware. A coverage interface is a description of what we are
measuring. Option 2 would have merged them permanently to save a file per
environment.

**It is uniform.** One pattern across all seven environments, rather than each
collector working around the limitation in its own way.

**It is reversible.** If upstream fixes class scope, the covergroups move back
and the coverage interfaces are deleted. Nothing else changes.

## Consequences

**Makes easier:**

- Section 5.3 regains functional coverage as a reportable metric.
- Env 7's instruction × hazard × pipeline-state crosses become measurable,
  which is the coverage result the portfolio centrepiece was supposed to
  produce.
- Envs 1–4 become re-derivable under Verilator, which is the only route to
  replacing results that are currently unreproducible by anyone (ADR-0006).

**Makes harder:**

- One extra file per environment, and a second virtual interface in each
  collector.
- The collector writes sampling fields before calling `sample()` rather than
  sampling its own members. Slightly more verbose at the call site.
- **The metric does not return in the form DSim produced it.** `0020` records
  that cross bin exclusions are unsupported under Verilator: `binsof`,
  `intersect` and `&&` in select expressions emit `COVERIGN`, and `ignore_bins`
  on a cross is **silently dropped**. Envs 1–3 used cross exclusions — env 1's
  343-bin cross especially. A re-hosted env 1 will not reach 100% the way it
  did, and the difference is a tool limitation rather than a stimulus gap.
  Section 5.3 states this rather than implying a clean restoration.

**Forecloses:**

- Nothing. The pattern is additive and reversible.

**Not yet established**, and recorded here rather than assumed:

- Whether `get_coverage()` — type-level, across instances — works at interface
  scope. ADR-0006 measured it returning 0.00% even at module scope, and both
  probes read only `get_inst_coverage()`. Any environment with more than one
  collector instance depends on the answer.
- What coverage a re-hosted environment actually reaches, given the cross
  exclusion limitation.
- Whether envs 1–4 still elaborate under Verilator at all. They were last built
  under DSim and nothing has compiled them since.

## Scope

This ADR records the pattern. **Re-hosting the collectors is M2 recovery work
and is not part of M3.7**, which is CI and structural coverage. The order when
it starts: env 7 first, since it is the one already running under Verilator,
then envs 1–4 in the order their results were originally recorded.

Section 7 names scope creep as a failure mode, and a favourable measurement
inviting a large adjacent project mid-milestone is exactly its shape.
