# ADR-0001: UVM Simulator Selection

**Date:** 2026-07-29
**Status:** Superseded by ADR-0002 (2026-07-31)
**Amended:** 2026-07-30 — added 90-day license expiry consequence; recorded that DSim Studio is not required
**Supersedes:** the recommended default of `PROJECT_CONTEXT.md` §8, Decision D2
**Amends:** `PROJECT_INSTRUCTIONS.md` §4.4 rule 1 (UVM version); `PROJECT_CONTEXT.md` §4.3, §7 (M0 gate)

---

## Context

Goal 1 of this project (`PROJECT_CONTEXT.md` §1.2) is deep, demonstrable SystemVerilog + UVM
skill. The UVM simulator is therefore the single most load-bearing tool choice in the project:
it determines which UVM API surface is learned, whether functional and assertion coverage can
be measured against the §5.3 targets, and how fast the L2 layer of the §5.1 verification model
can run.

The original D2 recommended default was Vivado XSim, chosen because it was free and shipped a
precompiled UVM library. Two facts discovered during M0 planning invalidated that reasoning.

**1. Vivado's free tier changed in June 2026.** With the 2026.1 release, AMD moved the Vivado
Design Suite to a tiered licensing model. The free Vivado ML Standard Edition was replaced by
"Vivado BASIC", a free annually-renewed subscription described by AMD as coming with *limited
simulation and debug support*. The scope of that limitation is not stated and remains
**unverified**. Basing the entire L2 verification layer on an unquantified license restriction
is an unacceptable single point of failure.

**2. A better free option exists.** Altair DSim (formerly Metrics Design Automation, acquired
by Altair in July 2024) offers a free individual on-premises license and ships UVM 2020.3.1 —
the IEEE 1800.2-2020 release, two generations ahead of XSim's UVM 1.2.

**Constraints bounding this decision:**

- Solo, non-commercial, individual use (§1.3 — explicitly not a club project).
- Free or free-tier tools only; free-tier commercial tools permitted in the verification path
  (§1.3).
- Student-grade bandwidth and disk. Vivado requires roughly 60 GB of free disk space.
- Linux or WSL2 host (§8 standing assumptions).
- Nothing is fabricated; there is no foundry-mandated signoff simulator.

---

## Options considered

### 1. Vivado XSim 2025.2 (the last release with free ML Standard Edition)

- **Pros:** Verified available today. Ships precompiled UVM. Well-documented in AMD UG900.
  Large body of community material. Known-good with the `-L uvm` standalone flow.
- **Cons:** UVM 1.2 only — a deprecated API generation. Assertion coverage explicitly
  unsupported, which directly undercuts §2.5's strategy of pushing all SVA into
  `verif/assertions/` bind files. ~60 GB install for a simulator we want ~1 GB of. Pins us to
  a superseded Vivado release whose long-term download availability is not guaranteed. Slow
  relative to modern simulators.

### 2. Vivado 2026.1 with Vivado BASIC license

- **Pros:** Current release, actively supported, free.
- **Cons:** "Limited simulation and debug support" is undefined in the published material.
  Could restrict runtime, design size, or UVM support outright. Adopting it means gambling
  Goal 1 on an unread restriction. Same ~60 GB install cost.

### 3. Questa Intel Starter Edition / Siemens student tier

- **Pros:** Best-in-class debug UX. Industry-standard; direct interview relevance.
- **Cons:** Licensing terms and line limits **unverified** (already flagged as unverified in
  §9 of the context document). Historically line-limited in ways that break large UVM
  environments. Depends on a third-party (Intel) redistribution that has been withdrawn before.

### 4. Altair DSim, free individual license — **CHOSEN**

- **Pros:** UVM 2020.3.1 (IEEE 1800.2-2020). Full SystemVerilog 2023 and VHDL 2008 support.
  Functional coverage collected by default into a sqlite3 database. Broad SVA support with
  documented, explicit exclusions — unsupported SVA constructs are compile-time errors rather
  than silent no-ops. Small install relative to Vivado. Unaffected by the Vivado licensing
  change.
- **Cons:** Free tier permits a **single concurrent simulation** — no parallel regression.
  Singly-clocked assertions only; `expect property` unsupported. Vendor-continuity risk
  following the Altair acquisition. Smaller community and less tutorial material than Vivado.

### 5. Verilator + cocotb/pyuvm only, no commercial simulator

- **Pros:** Fully open source, fastest, no licensing risk at all.
- **Cons:** Does not satisfy Goal 1. Verilator's UVM support is an incomplete
  Antmicro/CHIPS Alliance effort (§4.3). pyuvm is a complement, not a substitute for real
  SystemVerilog UVM. **Rejected on goal grounds, not technical ones.**

---

## Decision

1. **Altair DSim, free individual license, is the primary UVM simulator** for all §5.2
   environments and the §5.1 L2 layer.
2. **Vivado XSim is a documented fallback, not an installed dependency.** Vivado is removed
   from the M0 gate criteria entirely. It is installed only if DSim fails the hello-world UVM
   test or if its licence terms prove incompatible with a public repository.
3. **Testbench portability is mandatory from the first line of testbench code** (see
   Consequences → enforceable rules below).
4. **UVM version target changes from 1.2 to 2020.3.1** (IEEE 1800.2-2020).
5. Verilator remains the L1 regression workhorse. This ADR does not change §5.1.

---

## Rationale

**UVM version is the dominant factor.** UVM 1.2 dates from the 2011 Accellera lineage;
2020.3.1 implements IEEE 1800.2-2020, which is what current industry environments are built
against. Since the entire justification for this project's verification emphasis is
employability (§1.2), learning `uvm_reg`, phasing, and factory idioms against the current
standard rather than a deprecated one is a direct gain against the primary goal. Choosing XSim
would mean learning an API surface and then unlearning parts of it.

**Coverage measurability.** §5.3 sets a functional coverage target of ≥90% of defined bins, and
a `vplan` is a required M2 deliverable. XSim's documented lack of assertion coverage support
means one of the two functional-coverage mechanisms in SystemVerilog would have been
unmeasurable. DSim collects functional coverage by default.

**Fail-loud SVA behaviour.** DSim flags unsupported SVA elements as compile-time errors. A
property that is silently ignored is indistinguishable from a property that always passes — the
most dangerous failure mode in assertion-based verification. Explicit rejection is worth more
than broader silent support.

**The excluded SVA features do not bind us.** The unsupported set is
`accept_on` / `reject_on` / `sync_accept_on` / `sync_reject_on`, plus multi-clocked assertions
and `expect property`. §3.2 commits to a single clock domain with no CDC infrastructure, so
multi-clocked properties have no legitimate use in this design. The abort operators are used
almost exclusively for reset-abort idioms that can be expressed with a disable-iff clause
instead.

**Practical cost.** Dropping Vivado removes roughly 60 GB of download and install from the M0
critical path. On student bandwidth this is the difference between M0 taking a day and M0
taking a week, and §7's tool-chasing failure mode is a live risk in this project.

### Evidence

| Claim | Tier | Source | Verified |
|---|---|---|---|
| DSim integrates UVM 2020.3.1; full SystemVerilog 2023 and VHDL 2008 support | T2 | Altair HyperWorks 2025.1 product page | 2026-07-29 |
| Free Individual License exists; individual use only; single concurrent simulation; administered via DSim Cloud Portal | T2 | Altair DSim Knowledge Base, "Licensing" (page dated Jan 2026) | 2026-07-29 |
| Functional coverage collected by default; written to sqlite3 database (`metrics.db`); `-no-fcov` disables | T2 | Altair DSim KB, "DSim Coverage Options" | 2026-07-29 |
| SVA: `accept_on`/`reject_on`/`sync_accept_on`/`sync_reject_on` unsupported; all other property and sequence operators supported; unsupported elements are compile-time errors | T2 | Altair DSim KB, "DSim Known Issues" | 2026-07-29 |
| Only singly-clocked assertions supported; multi-clocked flagged as error; `expect property` unsupported | T2 | Altair DSim KB, "Major Release Highlights" | 2026-07-29 |
| Altair signed agreement to acquire Metrics Design Automation | T2 | Altair press release, July 2024 | 2026-07-29 |
| Vivado 2026.1+ replaces free ML Standard with Vivado BASIC; "limited simulation and debug support" | T2 | AMD Licensing FAQ; AMD "Buy Vivado" page | 2026-07-29 |
| Vivado requires ~60 GB free disk | T3 | GMU ECE545 Vivado Linux install guide (2024) | 2026-07-29 |

**Resolved since first drafting (2026-07-30):**

- DSim Linux activation and licensing mechanics are documented in the *Altair DSim Getting Started
  2026* guide and the DSim KB "Licensing" article: activate with
  `source $HOME/AltairDSim/<version>/shell_activate.bash`, then
  `export DSIM_LICENSE=$HOME/metrics-ca/dsim-license.json`. `dsim --version` works without a
  license; running a design requires one.
- **DSim Studio is not required.** The KB documents manual license installation: generate the
  license in the DSim Cloud Portal, download `dsim-license.json`, and place it at
  `$HOME/metrics-ca/dsim-license.json`. The Altair License Manager is only relevant to the paid
  Altair Units path. Command line is one of the two officially supported on-prem usage models.
- Licenses are valid 90 days; one at a time; revoke before regenerating; usable on multiple
  machines but only one may run DSim at a time.

**Explicitly unverified at time of writing — must be closed during M0:**

- Whether the Free Individual License permits publishing simulation results and testbench code
  in a public repository (Goal 3 depends on this).
- DSim Linux install mechanics, current version string, and whether CLI-only operation works
  without DSim Studio / VS Code.
- Whether coverage databases can be **merged across runs**. Required for §5.3 coverage closure.
  If merging is unsupported, the coverage strategy needs rework.
- UVM RAL backdoor access behaviour (required for §5.2 environment 4).
- Whether the older "Major Release Highlights" statement about a limited subset of property
  operators has been superseded by the broader support described in "Known Issues". The two
  KB pages appear to describe different points in time; Known Issues is treated as current.

---

## Consequences

### Makes easier

- Learning the current UVM standard rather than a deprecated one.
- Measuring both covergroup-based and assertion-based functional coverage against §5.3.
- M0 completion — roughly 60 GB less to download, one fewer account-gated mega-installer.
- Writing SVA in `verif/assertions/` with confidence that unsupported constructs will be
  rejected loudly rather than ignored.

### Makes harder

- **UVM regression is serial.** The free tier runs one simulation at a time. Nightly regression
  wall-clock time becomes a real planning constraint, especially for §5.2 environment 7 (full
  core). Seed counts and test lists must be budgeted accordingly, and bulk random regression
  stays on Verilator (L1) as §5.1 already specifies.
- Less community tutorial material than Vivado. More time reading the DSim manual, less time
  copying from blog posts. Given §7's stale-tutorial failure mode, this is arguably neutral.
- **The license expires every 90 days.** Only one license may be valid at a time, and a new one
  can only be generated after revoking the current one. Across a project running from August 2026
  into 2027 this means roughly four renewals. An expired license presents as a tool failure rather
  than a clear licensing message, so the expiry date is recorded in `tools/versions.md` and a
  calendar reminder is set. This is a debugging trap worth pre-empting.
- An Altair One account is required before a license can be generated. This is an external
  dependency with its own approval latency and is tracked as an explicit, separately-gated M0
  step.

### Forecloses

- Nothing structurally. Because the portability rules below are adopted from day one, migrating
  to XSim or Questa later costs a new `.mk` file and a UVM-version compatibility review, not a
  testbench rewrite.

### Enforceable portability rules (added to `PROJECT_INSTRUCTIONS.md` §4.4)

These are what make the fallback real rather than aspirational:

1. No vendor-specific pragmas, attributes, or system tasks anywhere in `verif/`.
2. No simulator-conditional `` `ifdef `` inside UVM class code. If a tool difference must be
   absorbed, it is absorbed in the build files, not the testbench.
3. One shared source-list file (`verif/files.f` or equivalent) consumed by every simulator
   makefile. Per-simulator makefiles (`dsim.mk`, `xsim.mk`, ...) contain invocation flags only.
4. No dependency on UVM 1.2-only APIs, so the environment can degrade to an XSim fallback where
   practical.
5. Coverage post-processing reads from an exported, tool-neutral intermediate wherever possible,
   so a simulator change does not invalidate the `vplan` traceability required at M2.

### Follow-up actions

| # | Action | Gate |
|---|---|---|
| 1 | Create Altair One account (**done 2026-07-30**); generate Free Individual License from the DSim Cloud Portal, record expiry date | Before DSim install |
| 2 | Read and record the DSim EULA position on public publication of results | Before repo goes public (M8); ideally M0 |
| 3 | Hello-world UVM test passing under DSim, version recorded | M0 gate |
| 4 | Confirm coverage database merge across runs | M2 (blocks §5.3 strategy) |
| 5 | Confirm UVM RAL backdoor access | M3 (blocks §5.2 env 4) |
| 6 | Re-verify Vivado BASIC terms only if DSim path fails | Contingency |
| 7 | Renew license before each 90-day expiry; update `tools/versions.md` | Recurring |

### Review trigger

Revisit this ADR if: the free individual license is withdrawn or materially changed; serial
regression becomes the binding constraint on milestone progress; or Questa's student licensing
terms are verified and prove less restrictive.
