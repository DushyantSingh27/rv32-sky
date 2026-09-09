# PROJECT CONTEXT — RV32 CPU on SkyWater 130nm

**Working title:** `RV32-SKY` *(placeholder — rename when you pick a real name)*
**Owner:** Solo project. Not affiliated with the Semiconductor Chip Design Club.
**Document created:** 2026-07-29
**Last updated:** 2026-09-09 — reconciliation of two divergent lineages. The 2026-08-21 revision (Sail, ACT4, M3.0–M3.7 renumbering, §10 status) existed only in the project tab and was never committed; the committed copy was `f9fb2bc` plus the four corrections in `9da48af`. Neither was a superset. This document is the merge, plus M3.4a completion, the DSim shutdown, ADR-0006, and env 7.
**Document status:** Living document. Update it whenever a decision changes.
**Purpose:** This file is the single source of truth for *what* is being built and *why*. It is pasted into every build chat so no context is lost between sessions.

---

## 1. Project Definition

### 1.1 One-line statement

Design, verify, and physically implement a RISC-V CPU and minimal SoC on the open-source SkyWater 130nm PDK, taking it the full distance from SystemVerilog RTL to a DRC/LVS-clean GDSII, using an industry-standard UVM verification methodology.

### 1.2 Primary goals, ranked

| # | Goal | Why it is ranked here |
|---|------|----------------------|
| 1 | **Build deep, demonstrable SystemVerilog + UVM skill** | This is the stated personal objective. Verification is ~60–70% of real chip development effort and is the most hireable skill in the industry. |
| 2 | **Complete a genuine RTL-to-GDSII flow** | Proves end-to-end capability, not just RTL. Very few students have a real GDSII. |
| 3 | **Produce a defensible, documented artifact** | A well-documented repo with coverage reports and timing signoff is worth more than a bigger undocumented design. |
| 4 | **Build architectural judgment** | Understanding *why* a microarchitectural choice was made, with data to back it. |

### 1.3 Explicit non-goals

- **No fabrication.** Signoff-clean GDSII is the finish line. No shuttle submission, no tapeout costs.
- **No analog/mixed-signal.** No PLL, no ADC, no custom SRAM bitcell design.
- **No commercial EDA dependency in the implementation path.** Free-tier commercial tools were permitted in the *verification* path only; as of ADR-0006 the project has no commercial tool dependency anywhere.
- **Not a club project.** No team coordination, no teaching overhead, no scope compromises for group skill levels.

### 1.4 Timeline context

- Final year of undergraduate study begins **August 2026**.
- This project must survive alongside coursework, placements, and other commitments.
- **Implication:** the plan must be milestone-based with working intermediate artifacts, not a monolith that only pays off at the end. Every milestone ends with something that runs.

---

## 2. THE LANGUAGE STRATEGY (Core Decision)

This is the most important section of this document. Read it before writing any line of code.

### 2.1 The key insight

"SystemVerilog" is really **two languages sharing a keyword set**:

| | **Synthesizable SV (RTL subset)** | **Verification SV (class subset)** |
|---|---|---|
| **Constructs** | `logic`, `always_ff`, `always_comb`, `always_latch`, packed/unpacked structs, `enum`, `typedef`, `package`, `interface`/`modport`, parameterized modules, `unique`/`priority case` | `class`, `virtual`, `rand`/`randc`, `constraint`, `covergroup`, `mailbox`, `semaphore`, virtual interfaces, `fork/join`, SVA (`property`/`sequence`) |
| **Becomes gates?** | Yes | Never |
| **Who consumes it** | Yosys/slang → OpenROAD → GDSII | Simulator only |
| **This project uses it for** | The entire DUT | The entire testbench |

Treating these as separate layers is what makes the win/win possible. They never compete for the same tool.

### 2.2 The decision

> **All RTL is written in synthesizable SystemVerilog (IEEE 1800-2017). All verification is written in full SystemVerilog with UVM. No Verilog-2005 is ever hand-written.**

### 2.3 Why this works now

Mainline Yosys uses the sv-elab and slang libraries to support a synthesizable subset of SystemVerilog IEEE 1800-2017/2023. LibreLane 3.x exposes this through a `USE_SLANG` configuration flag (it replaced the older Synlig-based path). This means synthesizable SystemVerilog goes straight into the implementation flow without a conversion step.

Historically this was not true — OpenLane required you to run `sv2v` first — which is why most tutorials you will find online tell you to write Verilog-2005. **Those tutorials are out of date on this specific point.**

> **Status note (2026-07-31) — CONFIRMED (T1):** LibreLane v3.0.5 is installed, smoke test passing. `USE_SLANG` was confirmed by reading the installed package source at `librelane/steps/pyosys.py`:
>
> ```
> Variable("USE_SLANG", bool, default=False, deprecated_names=["USE_SYNLIG"])
> ```
>
> **The default is `False`.** It must be set explicitly in `flow/config.yaml` or synthesis silently uses the default Yosys frontend and rejects the SystemVerilog — a failure that looks like a language problem but is a config problem. A companion variable `SLANG_ARGUMENTS` passes flags to the frontend. Consumed at `librelane/scripts/pyosys/synthesize.py`. LibreLane 3.0.5 drives Yosys via its Python API (`pyosys`), so OpenLane-era material referencing `yosys.py` or Tcl synthesis scripts does not apply.

### 2.4 The win/win, stated plainly

| Layer | Language | Tool | What you gain |
|-------|----------|------|---------------|
| **RTL** | Synthesizable SV-2017 | Yosys + slang, via LibreLane | Type safety (`enum` state machines, `struct` bundles), `interface`s instead of 40-port module headers, `package`s for shared parameters. Code looks like industry RTL, not a textbook exercise. |
| **Testbench** | Full SV + UVM 2020.3.1 | **Verilator 5.050** (ADR-0006; was Altair DSim until its shutdown) | Real UVM: agents, sequencers, drivers, monitors, scoreboards, RAL, constrained random. Exactly the skill set interviews probe. Functional coverage is the one casualty — see §5.3. |
| **Fast regression** | C++ / SV | Verilator | 100–1000× faster than an event-driven UVM simulator. Runs full benchmarks, Sail lockstep, and bulk directed tests. Same binary as the UVM path. |
| **Formal** | SV (immediate assertions) | SymbiYosys + riscv-formal | Mathematical proof of ISA conformance. Catches bugs random testing never reaches. |

### 2.5 The two constraints this creates

**Constraint A — SVA does not work in the synthesis/formal path.**
yosys-slang supports plain `assert()`, `assume()`, and `cover()` statements but does **not** support SVA (`property`/`sequence` blocks). SVA support is estimated to be a year or two out.

*Mitigation — the two-tier assertion rule:*
- Assertions **inside RTL modules** (`rtl/`) must be *immediate* assertions only, wrapped in `` `ifndef SYNTHESIS `` guards. These work in Verilator and SymbiYosys.
- Assertions using **full SVA** live in separate bind files under `verif/assertions/` and are never compiled by Yosys. **Note: Verilator's SVA support is narrower than DSim's was.** Anything written against DSim's SVA capability must be re-checked before it is relied on.
- **Never** put an SVA `property` block inside a file that Yosys will read.

**Constraint B — slang's synthesizable subset is a subset.**
It will reject some legal SystemVerilog. Upstream itself describes the Slang frontend as *"not as battle-tested as the default Yosys frontend"*, so treat this constraint as likely to bite rather than theoretical. If a construct is rejected, resolve it in this order:

1. Rewrite the RTL in a simpler, more clearly synthesizable style. *(Usually correct — if slang struggles, real synthesis tools often produce surprising hardware too.)*
2. Try `SLANG_ARGUMENTS` (LibreLane variable, `Optional[List[str]]`) to pass a frontend flag that accepts the construct. Cheap, reversible, leaves the RTL untouched.
3. Fall back to `sv2v` for that file, producing generated Verilog-2005 as a build artifact.
4. Only if all three fail, restructure the module.

**Every escalation past step 1 gets logged** in `docs/results/` with the construct, the file, and which rung resolved it. That log is the empirical map of slang's real limits, and it is worth more than any documentation on the subject.

> **Empirical result (T1, 2026-08-01):** the M0 smoke design exercised `package` +
> `import pkg::*` in a module header, `typedef enum` FSM, packed `struct`,
> `interface` + `modport`, `always_ff`/`always_comb`, `unique case`, and an immediate
> assertion under `` `ifndef SYNTHESIS ``. **All accepted by yosys-slang on the first
> attempt.** No `SLANG_ARGUMENTS` needed, no `sv2v` fallback. The escalation ladder was
> never invoked. Design reached GDSII DRC/LVS clean. See
> `docs/results/0001-smoke-counter.md`.
>
> Constraint B remains a real risk for more complex RTL, but the constructs this
> project's coding standards mandate are confirmed working.

`sv2v` stays installed as a permanent escape hatch. It is never the default path, and its output is a build artifact that is **never** committed or hand-edited.

---

## 3. Architecture

> **Status as of 2026-09-09:** §3.1 (ISA) and §3.2 (microarchitecture) are **implemented and verified** through the RV32I + Zicsr + M-mode-trap core — see §10. §3.3 (memory), §3.4 (SoC) and §3.5 (physical) remain **PROPOSED**. See §8 for the open decisions that still gate them.

### 3.1 ISA

**Target: RV32IMC_Zicsr** — 32-bit base integer, multiply/divide, compressed instructions, CSR access.

- **I** — mandatory base.
- **M** — needed for any real benchmark (CoreMark, Dhrystone).
- **C** — roughly halves code size. Critical because on-die memory is severely limited (see §3.3). Also adds real decoder complexity, which is good verification material.
- **Zicsr** — required for traps, interrupts, and performance counters.

> **Implemented as of 2026-09-09 (M3.4a):** **RV32I + Zicsr + M-mode trap entry**, plus `Zifencei` accepted as a legal no-op (single hart, in-order, no I-cache, no store buffer). `M` and `C` are **not** implemented — `muldiv.sv` is verified standalone (UVM env 2) but is not in `rtl/files.f` and not instantiated. No `A`, no S/U privilege, no CLINT, no interrupt controller. `verif/sail/rv32sky.json` is configured to match this surface exactly, and a permissive reference model is deliberately avoided: if Sail modelled an extension the core rejects, the resulting divergence would be a configuration artifact rather than a bug.
>
> **`verif/compliance/rv32sky/rv32sky.yaml` does NOT yet match this.** It still declares only `I, Zifencei` and its comments assert that `csr.sv` is absent from `files.f` and that trap detection is M4. Both are false. See §10 standing risks — this is the M3.4b gate.

**Deferred, to be reconsidered at Milestone 5:** `A` (atomics), `Zbb` (bit manipulation).
**Rejected:** `F`/`D` (floating point) — large area on 130nm, heavy verification burden, low demonstration value relative to cost.

### 3.2 Microarchitecture

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Pipeline | 5-stage in-order: IF / ID / EX / MEM / WB | Well-understood, good Fmax/complexity balance at 130nm, extensively documented in literature so you can compare against known results. |
| Hazards | Full forwarding (EX→EX, MEM→EX) + load-use interlock | Skipping forwarding costs ~30% CPI for negligible area saving. |
| Branch handling | Phase 1: static backward-taken/forward-not-taken. Phase 2: bimodal predictor, 64-entry BTB with 2-bit saturating counters. | Phase 2 gives a clean before/after measurement — excellent for the writeup and for coverage-driven verification. |
| Multiplier | Radix-4 sequential (2 bits/cycle, ~17 cycles) | A single-cycle 32×32 multiplier is almost certainly the critical path on sky130. Sequential first; optimize only if timing data justifies it. |
| Divider | Restoring, 1 bit/cycle (~33 cycles) | Division is rare in target workloads. Not worth area. |
| Register file | 32×32-bit, 2 read / 1 write | Implementation via flip-flops or ORRAM — decide with area data at Milestone 6. See D4, which now has data. |
| Privilege | M-mode only initially; M+U as a stretch | S-mode + Sv32 MMU is a scope doubler. See §8, Decision D1. |
| Reset | Async assert, sync deassert; single clock domain | No CDC infrastructure needed. Any added clock domain requires an explicit documented synchronizer. |

### 3.3 Memory subsystem

| Level | Plan |
|-------|------|
| Register file | Flip-flop based (or ORRAM if area demands) |
| I-cache | 2 KB, direct-mapped, 16-byte lines. *Phase 2 feature.* |
| D-cache | 2 KB, direct-mapped, write-through with 4-entry write buffer. *Phase 2 feature.* Write-through is substantially simpler to verify than write-back. |
| Tightly-coupled memory | 4–8 KB unified TCM as the Phase 1 memory. Simpler than caches; gets the core running sooner. **Implemented: 8 KB at `0x0000_0000` (`rtl/mem/tcm.sv`).** PC resets to zero with no reset-vector logic. Peripheral window at `0x8000_0000` — bit 31 makes the peripheral test one gate. |
| Main memory | External, over QSPI. Not on-die. |
| Boot ROM | Small synthesized ROM, ~256 bytes |

**Verified constraint (2026-07-29):** the SKY130 PDK ships only three pre-built SRAM configurations — 8×1024, 32×256, and 32×512. OpenRAM can generate custom sizes but has a practical ceiling around 4 KB; 8 KB and 16 KB configurations exist but present implementation problems. This directly caps how much on-die memory is realistic and is the reason the `C` extension is mandatory.

**SRAM options to evaluate at Milestone 6:**
1. Pre-built sky130 macros — silicon-proven, easiest. Note: sky130 SRAM blocks use a different DRC ruleset because of optical proximity shrinking of the SRAM transistors, so Magic DRC requires a documented workaround.
2. OpenRAM — custom sizes, ≤4 KB practical.
3. Sram22 — newer Rust-based sky130 compiler with pre-generated macros.
4. **ORRAM** — released July 2026, now part of the OpenROAD project. Standard-cell-based, supports arbitrary word sizes and counts, mask granularity, multi-port reads, and column muxing, achieving ~28,000 bits/mm² on sky130hd — roughly 2× the density of DFFRAM. Needs no special DRC handling, which makes it attractive for the register file and small structures.

### 3.4 SoC integration

- **Bus:** see §8, Decision D3 — **still open.** Recommended default AXI4-Lite.
- **Peripherals:** UART (16550-lite), QSPI master, GPIO, timer/CLINT, PWM.
- **Debug:** RISC-V Debug Module + JTAG DTM. *Phase 3.* This is the single feature that most separates a student core from a usable one.
- **Interrupts:** CLINT for timer/software; PLIC only if peripheral count justifies it.

### 3.5 Physical implementation

| Aspect | Target |
|--------|--------|
| Standard cell library | `sky130_fd_sc_hd` (high density) |
| Supply | 1.8 V core |
| Target Fmax | 50 MHz commit, 100 MHz stretch |
| Corners | ss_100C_1v60, tt_025C_1v80, ff_n40C_1v95 — all must pass |
| DFT | Scan chain insertion + ATPG, fault coverage reported |
| Signoff | DRC clean (Magic + KLayout), LVS clean (Netgen), antenna clean, no setup/hold violations at any corner |

---

## 4. Toolchain

> All entries verified on the date shown. **Re-verify before relying on any of this.** The 2026-09-01 DSim shutdown is the worked example of why: a tool that was primary on 2026-08-21 was gone ten days later.

### 4.1 Critical tooling context — read this

The open-source ASIC flow changed hands recently and most online tutorials are stale:

- **Efabless shut down in early 2025.** They made OpenLane and ran the ChipIgnite shuttles.
- **OpenLane 1.x is frozen** — critical bugfixes only, maintained so old tapeouts can be reproduced. Explicitly **not recommended for new designs**.
- **OpenLane 2 was forked and renamed LibreLane**, now maintained by the FOSSi Foundation. Version 3.0 released March 2026. Repo moved from `efabless/openlane2` to `librelane/librelane`.
- **PDK management is via `ciel`** (successor to Volare), defaulting to `$HOME/.ciel`.
- Install paths are **AppImage** (single file, simplest, works under WSL2), **Nix** with the FOSSi binary cache, or **Docker**. Pip-only installation is explicitly unsupported upstream. Requires Python 3.10+.

**Practical consequence:** when following any YouTube tutorial or blog post, assume the tool names are wrong. Config files are largely backwards-compatible, but `librelane` is the command, not `openlane`.

**Known LibreLane 3.x migration gotchas** (if adapting OpenLane 2.3-era material):
- Python 3.10+ required.
- Synlig → Slang: set `USE_SLANG: true`. **Default is `False`** — see §2.3.
- "The great FP_ removal" — many floorplan variables lost their `FP_` prefix. Check the Variable Migration Guide.
- Tilde (`~`) paths are rejected by the CLI. Use absolute paths or `$HOME`.
- DRT antenna repair is enabled by default.

### 4.2 Implementation stack

| Purpose | Tool | Notes |
|---------|------|-------|
| Flow orchestration | **LibreLane 3.x** | **Installed: v3.0.5 via AppImage (`librelane-devshell-x86_64.AppImage`), 2026-07-30, smoke test passing.** Enter the environment by running the AppImage; leave with `exit`. Nix and Docker are the alternatives. Pip-only install is unsupported upstream. Requires `libfuse2` on Ubuntu 22.04 (undocumented upstream). Not OpenLane. |
| PDK management | **ciel v2.4.0** | Pins PDK version by hash — record the hash. |
| Synthesis | **Yosys** + **abc** | slang frontend via `USE_SLANG: true`; driven through the `pyosys` Python API at `librelane/steps/pyosys.py` |
| Place & route | **OpenROAD** | Floorplan, PDN, placement, CTS, routing |
| STA | **OpenSTA** | Multi-corner |
| DRC / extraction | **Magic**, **KLayout** | Run both; KLayout is generally stricter |
| LVS | **Netgen** | |
| Circuit checks | **CVC** | Floating gates, ESD |
| Memory generation | **ORRAM** / **OpenRAM** / **Sram22** | Evaluate at Milestone 6 |
| SV→V fallback | **sv2v** | Escape hatch only |

### 4.3 Verification stack

| Purpose | Tool | Licensing | Notes |
|---------|------|-----------|-------|
| **UVM simulation** | **Verilator 5.050** (built from source) | Open source | **PRIMARY SIMULATOR since 2026-09-06 (ADR-0006).** Runs UVM 2020.3.1 — factory, phasing, reporting, constrained randomization all verified. Invocation requires `--vpi` **and** `$UVM_SRC/dpi/uvm_dpi.cc` on the command line, or the link fails on undefined DPI/VPI symbols. `uvm_dpi.cc` has no vendor conditionals, so no `-D` define is needed. **LIMITATION: covergroups declared inside a class silently return 0.00%** from `get_inst_coverage()` — no warning, `sample()` returns normally. Module-scope covergroups work correctly. `get_coverage()` (type-level) returns 0.00% at any scope. Since class scope is UVM's idiom, functional coverage is currently unavailable for every environment — see §5.3. |
| Fast RTL simulation | **Verilator 5.050** | Open source | The regression workhorse. Sail lockstep, directed tests, structural coverage. Same binary as the UVM path above. |
| ~~UVM simulation~~ | ~~**Altair DSim 2026.0.0**~~ | **DEAD — DSim Cloud shut down 2026-09-01. See ADR-0006 and `docs/results/0019`.** | Retained for historical reference only; every result in `docs/results/0002`–`0010` was produced with it and is **unreproducible**. Shipped UVM 2020.3.1 (IEEE 1800.2-2020), functional coverage into a sqlite3 `metrics.db`, SVA except `accept_on`/`reject_on`/`sync_accept_on`/`sync_reject_on`, singly-clocked assertions only. Not a licence expiry — the licence *server* is gone, so the on-premises install cannot validate. |
| ~~Fallback UVM simulation~~ | ~~Vivado XSim~~ | — | **Ruled out 2026-09-06.** Pre-2026.1 ML Standard Edition remains usable by existing users and was technically viable; declined by the owner. From 2026.1 the free tier became "Vivado BASIC" with limited XSim simulation; full simulation starts at the paid CORE tier. |
| ~~Fallback UVM simulation~~ | ~~Questa Intel/Altera Starter~~ | — | **Ruled out 2026-09-06.** The free licence excludes `randomize`, `randcase`, `randsequence` and `covergroup` outright — not a line limit. The documented workaround is `-nocvg` plus replacing `randomize()` with `$random`, which removes constrained-random and functional coverage, i.e. the two things the project is for. |
| Event-driven sim | **Icarus Verilog** | Open source | Quick sanity checks |
| Python testbenches | **cocotb** + **pyuvm** | Open source | Complements UVM; not a substitute for learning real UVM |
| Formal | **SymbiYosys (sby)** + **riscv-formal** | Open source | Highest value-per-effort tool in the entire project |
| Compliance | **ACT4** (`riscv-arch-test`) | Open source | **RISCOF is deprecated (verified 2026-08-20); ACT4 replaces it.** Needs a UDB config, `rvmodel_macros.h`, and a linker script. Dependencies via `mise`. |
| Golden model | **Sail RISC-V 0.13.1** | Open source | **In use since M3.5, not Spike.** Sail is the official executable RISC-V formal model, so a disagreement is authoritative rather than arguable. Binary at `~/src/sail-riscv-bin/bin/sail_riscv_sim`; config override at `verif/sail/rv32sky.json`. |
| Waveforms | **GTKWave** / **Surfer** | Open source | Surfer is the more modern option |
| Linting | **Verilator `--lint-only`**, **slang** | Open source | Run on every commit |

### 4.4 Software stack

- `riscv-gnu-toolchain` (or LLVM) targeting `rv32imc`, with newlib
- Custom linker script and startup assembly
- Benchmarks: Dhrystone, CoreMark, Embench-IoT
- **Headline metric: CoreMark/MHz** — this is the number people compare across cores

---

## 5. Verification Strategy

### 5.1 The five-layer model

Each layer catches a different class of bug. None is redundant.

| Layer | What | Tool | Runs when |
|-------|------|------|-----------|
| **L0 — Lint** | Style, width mismatches, inferred latches, unused signals | Verilator `--lint-only`, slang | Every commit, pre-push hook |
| **L1 — Fast regression** | Directed tests, benchmarks, **Sail lockstep co-simulation** | Verilator | Every commit, CI |
| **L2 — UVM** | Constrained-random block-level and core-level environments | **Verilator** (was DSim) | Nightly + before every milestone gate |
| **L3 — Formal** | ISA conformance proof, protocol properties, deadlock freedom | SymbiYosys + riscv-formal | Weekly + before every milestone gate |
| **L4 — Compliance** | Official RISC-V architectural tests | **ACT4** | Before every milestone gate |

### 5.2 UVM environments to build

These are the skill-building deliverables. Each is a self-contained, reusable environment.

| # | Environment | UVM concepts exercised | State |
|---|-------------|------------------------|-------|
| 1 | **ALU** | First env. Agent, driver, monitor, sequencer, sequences, scoreboard, basic covergroups. Deliberately simple so you learn the structure, not the DUT. | Complete (DSim) |
| 2 | **Multiplier/Divider** | Multi-cycle handshake protocol, response sequences, corner-case constraints (signed/unsigned, overflow, div-by-zero) | Complete (DSim) |
| 3 | **Register File** | Multi-port, read-during-write hazards, x0 hardwiring | Complete (DSim) |
| 4 | **CSR block** | **UVM RAL** — register model, `uvm_reg`, frontdoor/backdoor access, built-in register sequences. Major industry skill. | Complete (DSim) |
| 5 | **Wishbone/AXI VIP** | Reusable bus agent, protocol checkers, master and slave modes | Blocked on D3 |
| 6 | **Cache** | Layered sequences, cache-state coverage crosses, hit/miss/eviction scenarios | Not started |
| 7 | **Full core** | **Portfolio centerpiece.** Instruction-stream generator agent (constrained-random RISC-V programs), memory-model agent, Sail-reference scoreboard, coverage on instruction types × hazard types × pipeline states. | **Running under Verilator, ahead of its M5 slot.** See §10. |

**Discipline note.** Env 7 is slower than the block environments — use it for targeted scenarios, and run bulk regression in Verilator directly (L1). The DSim free-tier "one concurrent simulation" restriction that shaped earlier planning no longer applies; Verilator parallelises freely with `-j 0`, so seed counts are bounded by wall clock rather than by licence.

### 5.3 Coverage targets

Revised 2026-09-06 (ADR-0006) after the DSim shutdown removed functional coverage, and 2026-09-09 to fix which metric is primary.

| Metric | Target | Measured by |
|--------|--------|-------------|
| **Sail lockstep agreement** | **100% across a defined instruction × hazard space — PRIMARY quality metric** | `verif/sail/run_lockstep.sh` |
| Mutation kill rate | **Gate: ≥95%.** Reported as a raw count with every survivor documented and justified, never as a bare percentage | mutation suite |
| Line coverage | ≥95% on `rtl/core` | Verilator `--coverage-line` |
| Toggle coverage | ≥90% on `rtl/core` | Verilator `--coverage-toggle` |
| Functional coverage | **Under investigation — see ADR-0006.** Class-scope covergroups return 0.00% under Verilator; a module/interface-scope re-hosting probe is pending. Reverts to *unmeasurable* only if that probe fails | pending `cg4.sv` |
| riscv-formal | All checks passing, bounded depth ≥20 | SymbiYosys |
| ACT4 compliance | 100% pass on the **declared** ISA subset | ACT4 |
| Scan fault coverage | ≥90% | ATPG report |

**Why Sail is primary and mutation is only a gate.** The mutation set is authored by the same person who authored the RTL and the tests, so it cannot contain a mutation for a bug class not yet imagined. This is not hypothetical: 23 mutations, four test programs and 100% functional coverage on four environments all missed the M3.5 branch-squash bug, which Sail caught immediately. Sail is the only check in the project that is not downstream of the author's own model of the design. A self-authored metric must not be the headline one. Report kill rate as *n killed of m*, because at m≈30 a percentage implies a precision the sample size does not support.

A verification plan (`vplan`) mapping every ISA feature and microarchitectural mechanism to specific coverage bins was a required deliverable at Milestone 2 and exists (174 rows). Its functional-coverage traceability is suspended pending the probe above.

---

## 6. Repository Structure

```
rv32-sky/
├── README.md
├── docs/
│   ├── PROJECT_CONTEXT.md        # this file
│   ├── PROJECT_INSTRUCTIONS.md   # working agreement
│   ├── decisions/                # ADR-0001.md ... ADR-0006.md
│   ├── vplan/                    # verification plan
│   └── results/                  # timing, area, coverage, benchmark reports
├── rtl/
│   ├── files.f                   # SINGLE source list, all consumers
│   ├── pkg/                      # SV packages: opcodes, params, typedefs
│   ├── core/                     # pipeline stages, hazard unit, CSR, ALU, mul/div
│   ├── mem/                      # caches, TCM, memory interfaces
│   ├── soc/                      # bus fabric, peripherals, top level
│   └── interfaces/               # SV interface definitions
├── verif/
│   ├── uvm/
│   │   ├── common/               # base classes, shared sequences
│   │   ├── agents/               # per-protocol agents
│   │   ├── env_alu/ env_csr/ env_core/ ...
│   │   └── tests/
│   ├── assertions/               # SVA bind files — never read by Yosys
│   ├── verilator/                # C++ testbenches, Verilator regression
│   ├── sail/                     # rv32sky.json + run_lockstep.sh
│   ├── formal/                   # riscv-formal config, sby scripts
│   └── compliance/rv32sky/       # ACT4 / UDB config
├── sw/
│   ├── bootrom/  crt0/  linker/  benchmarks/  tests/
├── flow/
│   ├── config.yaml               # LibreLane config
│   ├── constraints/              # SDC
│   ├── macros/                   # SRAM LEF/GDS/LIB
│   └── scripts/
├── tools/                        # setup scripts, version pinning
└── ci/
```

**Rule:** `rtl/` is compiled by *both* Yosys and simulators. `verif/` is compiled by simulators *only*. This boundary is what keeps the language strategy (§2) working. Do not violate it.

**`rtl/files.f` is the single source list** consumed by the Verilator harnesses, the lint script, and LibreLane. Adding a module means editing that file and nothing else. The alternative — one list per consumer — already cost a build failure when `hazard_unit.sv` was added to the lint command but not to the core harness's Makefile.

---

## 7. Milestones

Each milestone ends with a working, demonstrable artifact and a written result. No milestone is "done" until its gate criteria pass.

| # | Milestone | Gate criteria |
|---|-----------|---------------|
| **M0** ✅ | **Toolchain bring-up** | LibreLane + ciel + sky130A installed; `USE_SLANG` confirmed empirically. A **SystemVerilog** counter exercising `typedef enum`, packed struct, package import and `interface`/`modport` goes RTL→GDSII, DRC/LVS clean. UVM hello-world with a covergroup runs. Versions and PDK hash recorded. |
| **M1** ✅ | **Leaf blocks, RTL + hardening** | Four blocks (ALU, mul/div, register file, CSR) written, verified, and each hardened independently to DRC/LVS-clean GDSII with area and timing recorded. |
| **M2** ✅ | **UVM environments 1–4** | Four environments at 100% functional coverage. `vplan` written. Every environment mutation-tested. *(Achieved under DSim; see the provenance caveat in §10.)* |
| **M3** 🔄 | **RV32I core integration** | Split into sub-stages below. |
| — M3.0 ✅ | Core toolchain | Build and lint infrastructure; `rtl/files.f` as single source list. |
| — M3.1 ✅ | Decoder + `imm_gen` | 4,592 checks against `riscv64-unknown-elf-as`; 8 mutations, 8 caught. |
| — M3.2 ✅ | Core bring-up | Three test programs executing end to end; 8 mutations, 8 caught. |
| — M3.3 ✅ | Forwarding + interlocks | Three forwarding paths, load-use interlock; 7 mutations, 7 caught. |
| — M3.5 ✅ | **Sail lockstep** | 621 instructions across four programs, every PC and register write agreeing with the RISC-V formal model. |
| — M3.4a ✅ | **Zicsr + M-mode traps** | `csr.sv` instantiated and in `files.f`; `OP_SYSTEM` decoded; `mret`; misaligned load/store raising cause 4/6, matching Sail. Step 5 `ex_mem_q` poison rewritten to explicit combinational priority (`ex_mem_ctrl_d`); 8 mutations re-run against the rewritten RTL, every verdict unchanged. **Pulled forward out of M4 because ACT4's UDB config cannot declare `Sm` without it** (`docs/results/0016`). |
| — M3.4b ⏭ | **ACT4 compliance** | **Next.** Update `verif/compliance/rv32sky/rv32sky.yaml` to declare `Sm` and `Zicsr` and correct its stale comments; HTIF decode in `core_tb_top.sv`; `SIZE_BYTES(262144)` override. `rvmodel_macros.h` and linker script done. |
| — M3.6 ⏳ | riscv-formal | Bounded ISA conformance proof. |
| — M3.7 ⏳ | CI + structural coverage | L0+L1 on every commit; line/toggle coverage via Verilator. |
| **M4** ⏳ | **RV32M/C, then SoC integration** | M and C extensions integrated (traps moved out to M3.4a). Bus fabric + UART + QSPI + GPIO + timer. Boots from simulated SPI flash, prints over UART. UVM env 5 complete. Requires D3 decided. |
| **M5** | **Performance features** | Branch predictor, caches. Before/after CoreMark/MHz measured and documented. UVM envs 6–7 complete. *(Env 7 already running — see §10.)* |
| **M6** | **First hardening** | Full SoC through LibreLane to GDSII. Timing closed at 50 MHz, all corners. DRC/LVS clean. Area and Fmax recorded. |
| **M7** | **DFT + signoff** | Scan insertion, ATPG, fault coverage ≥90%. IR drop analysis. Antenna clean. Final signoff report. |
| **M8** | **Documentation & release** | Full writeup, results tables, reproducible build instructions, public repo. |

**Stretch (only if M0–M8 land comfortably):** debug module + OpenOCD, `A` extension, `Zbb`, M+U privilege, custom accelerator.

---

## 8. Open Decisions

These gate the plan and need answers before detailed work begins. Each has a recommended default so work is never blocked.

| ID | Decision | Options | Recommended default | Impact |
|----|----------|---------|--------------------|--------|
| **D1** | Linux capability? | (a) M-mode only (b) M+U (c) M+S+U with Sv32 MMU | **(a) — in force and implemented.** S and U are disabled in the Sail config so the model matches the core. Not formally closed; revisit at M7. | Largest single scope fork. Option (c) roughly doubles the project. |
| **D2** | UVM simulator | (a) Vivado XSim (b) Questa free tier (c) Altair DSim (d) Verilator | **RESOLVED 2026-09-06 — (d) Verilator. Supersedes the 2026-07-30 resolution of (c). See ADR-0006.** DSim's licence server shut down; Questa's free tier excludes `randomize` and `covergroup`; XSim pre-2026.1 was viable but declined. | Cost: functional coverage (§5.3). Benefit: no commercial dependency anywhere in the project. |
| **D3** | Bus protocol | (a) Wishbone B4 (b) AXI4-Lite | **STILL OPEN.** Recommended default remains **(b) AXI4-Lite** — an AXI UVM VIP is far more valuable for employability, and skill-building is goal #1. **Needs deciding before M4.** No ADR written either way. | Affects peripheral design and UVM env 5. |
| **D4** | Register file implementation | (a) Flip-flops (b) ORRAM | **EVALUATE ORRAM AT M6 — area data now exists.** The flip-flop implementation measures 147,663 µm² for 992 bits (~6,700 bits/mm²) against ORRAM's reported ~28,000 bits/mm², and is the largest block in the design. A 2R1W flip-flop register file is fundamentally fanout-heavy: 559 max-slew violations remain after a mux-tree restructure halved them. See `docs/results/0007-regfile-standalone.md`. | Area/timing tradeoff, now evidenced. |
| **D5** | Differentiator feature | Accelerator / superscalar / `Zbb` / trace unit | **Defer to M5** | Don't commit before you know your area and timing headroom. |
| **D6** | Project name | — | — | Cosmetic but do it before the repo goes public. |

---

## 9. Verified Facts Ledger

Per working rule #1, every non-obvious factual claim in this document is logged here with its verification date. **Anything older than ~3 months should be re-verified before you act on it.**

| Fact | Verified | Source |
|------|----------|--------|
| Efabless shut down early 2025; OpenLane 1.x frozen, not recommended for new designs | 2026-07-29 | The-OpenROAD-Project/OpenLane README |
| OpenLane 2 → LibreLane under FOSSi Foundation; v3.0 released March 2026 | 2026-07-29 | fossi-foundation.org blog, PyPI |
| LibreLane repo moved to `librelane/librelane`; PDK manager is `ciel`; Python 3.10+; Nix install path | 2026-07-29 | VLSIDA chip-tutorials, PyPI |
| Mainline Yosys uses sv-elab + slang for synthesizable SV IEEE 1800-2017/2023 | 2026-07-29 | YosysHQ/yosys README |
| yosys-slang supports immediate `assert`/`assume`/`cover` but **not SVA**; SVA ~1–2 years out | 2026-07-29 | povik/sv-elab Discussion #75 |
| Upstream describes the Slang frontend as not as battle-tested as the default Yosys frontend | 2026-07-31 | `USE_SLANG` variable description, installed source |
| **T1 (empirical):** `USE_SLANG` exists in LibreLane 3.0.5 — `bool`, `default=False`, deprecated alias `USE_SYNLIG`; companion `SLANG_ARGUMENTS` (`Optional[List[str]]`) | 2026-07-31 | Installed package source, `librelane/steps/pyosys.py` |
| **T1 (empirical):** LibreLane 3.0.5 synthesis step is `steps/pyosys.py` (Yosys Python API), not a Tcl script | 2026-07-31 | Installed package source |
| **T1 (empirical):** LibreLane v3.0.5 installed via AppImage on Ubuntu 22.04.5 WSL2; `librelane --smoke-test` passed | 2026-07-30 | Own tool run |
| **T1 (empirical):** LibreLane AppImage requires `libfuse2` on Ubuntu 22.04 — not stated in the upstream AppImage install docs | 2026-07-30 | Own tool run |
| LibreLane AppImage is the upstream-recommended simplest install for Linux/WSL; pip-only install explicitly unsupported | 2026-07-30 | librelane.readthedocs.io installation docs |
| **T1 (empirical):** PDK pinned at sky130 version `8afc8346a57fe1ab7934ba5a6056ea8b43078e71`, dated 2025.07.14; variants sky130A and sky130B present; ciel v2.4.0 | 2026-07-30 | `ciel ls --pdk-family sky130` |
| **T1 (empirical):** yosys-slang accepted `package`+`import`, `typedef enum` FSM, packed `struct`, `interface`+`modport`, `unique case`, guarded immediate assertion — first attempt, no escalation | 2026-08-01 | M0 smoke design, `docs/results/0001` |
| **T1 (empirical):** synthesizable SystemVerilog reaches clean GDSII through the installed LibreLane 3.0.5 — four leaf blocks hardened | 2026-08-08 | M1 results in `docs/results/` |
| SKY130 ships only 8×1024, 32×256, 32×512 SRAM configs; OpenRAM practical ceiling ~4 KB | 2026-07-29 | "Macro Memory Cell Generator for SKY130 PDK" |
| sky130 SRAM macros need a different DRC ruleset due to optical proximity shrink | 2026-07-29 | OpenLane OpenRAM tutorial docs |
| ORRAM released July 2026, part of OpenROAD; ~28,000 bits/mm² on sky130hd, ~2× DFFRAM | 2026-07-29 | arXiv:2607.12244 |
| **RISCOF is deprecated; ACT4 (`riscv-arch-test`) replaces it** | 2026-08-20 | riscv-arch-test repo. Invalidates the compliance rows written 2026-07-29 |
| Sail RISC-V 0.13.1 used as golden model instead of Spike | 2026-08-19 | Own install and run |
| **T1 (empirical):** Sail HTIF requires *both* 64-bit halves of `tohost` written inside the halt loop; a single store is ignored and produced a 10.5 GB trace | 2026-08-20 | Own tool run |
| **T1 (empirical):** test data at `0x1000` collides with the HTIF `tohost` window — Sail reads it as a command and resets. Moved to `0x1100` | 2026-08-20 | Own tool run. Would have broken every ACT4 test identically |
| **T1 (empirical):** UDB rejects `MXLEN`, `PHYS_ADDR_WIDTH`, `M_MODE_ENDIANNESS`, `MISALIGNED_LDST` when `Sm` is not declared — "Parameter is not defined by this config … Failing condition: `Sm>=0` false". They are Sm-scoped | 2026-08-21 | Own tool run, `docs/results/0016` |
| **T1 (empirical):** Sail's **global** `memory.misaligned.exceptions` is checked *before* address translation and therefore before the per-region `misaligned_exceptions` attribute. Left at the default `{"None": null}`, a misaligned `sw`/`lw` executes; `probe_traps.S` showed four traps where six were expected | 2026-08-27 | Own tool run. Region-level setting alone is not sufficient |
| **T1 (empirical):** a Sail region override **replaces** the `regions` array rather than merging into it — the CLINT and interrupt generator defaults at `0x2000000` / `0xC000000` cease to exist and must be explicitly disabled | 2026-08-27 | Own tool run, `verif/sail/rv32sky.json` |
| **T1 (empirical):** Sail's `V` extension is gated by a `support_level` string, not a `supported` boolean — a sweep disabling 76 extensions silently missed it, leaving Zve\*f/Zve\*d implied against disabled F and D | 2026-08-27 | Own tool run |
| **T1 (empirical):** Sail's validator rejects a coherent cacheable `MainMemory` region with `misaligned_atomicity_granule_size_exp` below 4 while `Zama16b` is enabled, even when the value is otherwise inert | 2026-08-27 | Own tool run |
| **T1 (empirical):** with Sv32 disabled, Sail requires `physaddr_bits: 32`, not the default 34 | 2026-08-27 | Own tool run |
| **T1 (empirical):** Altair DSim Cloud shut down 2026-09-01; the on-premises install validates against that server and is unusable | 2026-09-02 | Own tool run: `=F:[UsageMeter] License not obtained: Altair DSim Cloud has been shut down as of September 1st 2026.` |
| **T1 (empirical):** `dsim --version` is NOT a valid option — `=E:[InvalidOption]`. The version appears in the run banner instead. Corrects the 2026-07-30 activation note | 2026-09-02 | Own tool run |
| **T1 (empirical):** Verilator 5.050 elaborates and runs UVM 2020.3.1 — banner, factory, phasing, reporting, `randomize()`, `UVM_ERROR : 0`. Needs `--vpi` and `uvm_dpi.cc`; `uvm_dpi.cc` has no vendor conditionals so no `-D` define is required | 2026-09-06 | Own tool run, M0 smoke test |
| **T1 (empirical):** Verilator 5.050 covergroups declared INSIDE A CLASS return 0.00% from `get_inst_coverage()`, silently. Module-scope returns correctly. Isolated in a 3-file probe with no UVM: module 100.00%, class 0.00%, identical coverpoint and stimulus | 2026-09-06 | Own tool run, `cg3.sv`. Rules out `option.per_instance`, `type_option.merge_instances` and `--coverage-user`, each tested separately |
| **T2:** Questa Intel/Altera FPGA Starter Edition free licence excludes `randomize`, `randcase`, `randsequence` and `covergroup` — not a line limit. Documented workaround is `-nocvg` plus replacing `randomize()` with `$random` | 2026-09-06 | Intel/Altera community, Siemens-confirmed |
| **T2:** Vivado free tier became "BASIC" at 2026.1 with limited XSim simulation; full simulation starts at the paid CORE tier. Pre-2026.1 ML Standard Edition remains usable by existing users | 2026-09-06 | AMD licensing pages |
| **T1 (empirical):** UVM RAL backdoor `hdl_path` access worked on DSim | 2026-08-10 | M2 env 4. **Not re-established under Verilator** — see unverified list |
| ~~Verilator UVM support incomplete; active Antmicro/CHIPS Alliance effort~~ | ~~2026-07-29~~ | **SUPERSEDED 2026-09-06 — measured wrong in both directions.** UVM runs; covergroups in class scope do not. |
| ~~DSim free on-premises tier discontinued 2026-09-01~~ | ~~2026-08-03~~ | **UNDERSTATED.** The whole licence server went, not the free tier. |

**Unverified — must check before relying on:**

- **Whether UVM RAL backdoor access works under Verilator.** Established on DSim only. Blocks any re-derivation of env 4 and all peripheral RAL at M4.
- **Whether a covergroup declared in an `interface` and sampled from class context via a virtual interface handle registers hits under Verilator.** Gates §5.3 functional coverage. `cg4.sv` probe designed, not run.
- **Verilator's SVA subset.** `verif/assertions/` was written against DSim's capability. Unchecked against Verilator.
- **`bundle` version mismatch in the ACT4 setup:** `bundle --version` reports 2.6.9 while `.mise.toml` pins 4.0.18. Unresolved; may block M3.4b.
- **UDB `partially configured` crash** reported upstream, not yet resolved.
- **Whether env 1–4 results can be reproduced at all.** Their toolchain no longer exists for anyone. See §10.
- Sram22 current maintenance status.
- Whether ORRAM is production-ready or still experimental.
- Specific Fmax and area figures for the full SoC (all numbers in §3.5 are estimates from general community experience, not measured).

---

## 10. Current Status — 2026-09-09

> This is the live snapshot. Everything above describes intent; this section describes fact.

**Roughly 50% complete** (T4 — effort-weighted estimate, not a measurement).

**Repo:** `github.com/DushyantSingh27/rv32-sky` · local `~/dev/rv32-sky` · SSH over port 443 (college network blocks 22). HEAD `9da48af`, working tree clean, all pushed.
**Host:** WSL2 Ubuntu 22.04.5, 20 cores, ~15.7 GB RAM, ~920 GB storage.

### Elaborated design surface

Read from `rtl/files.f`, which is the single source list for every consumer:

```
rtl/pkg/rv32_pkg.sv
rtl/core/alu.sv      rtl/core/regfile.sv   rtl/core/decoder.sv
rtl/core/imm_gen.sv  rtl/core/if_stage.sv  rtl/core/lsu.sv
rtl/core/hazard_unit.sv                    rtl/core/csr.sv
rtl/mem/tcm.sv       rtl/core/rv32_core.sv
```

**RV32I + Zicsr + M-mode trap entry**, `Zifencei` as a legal no-op. 8 KB TCM at `0x0000_0000`, peripheral window at `0x8000_0000`. **`muldiv.sv` is verified standalone but is not in the list and not instantiated** — no `M`. No `C`, no `A`, no S/U, no CLINT, no interrupt controller.

### Verification results

| Environment | Transactions | Mismatches | Functional coverage |
|---|---|---|---|
| Env 1 — ALU | 30,019 | 0 | 100.00% (9 coverpoints, incl. a 343-bin cross) |
| Env 2 — mul/div | 34,029 (+2,000 back-pressure) | 0 | 100.00% (9 coverpoints) |
| Env 3 — register file | 25,097 (6,009 R/W collisions) | 0 | 100.00% (11 coverpoints) |
| Env 4 — CSR / RAL | `hw_reset` 18 regs, `bit_bash`, `access` | 0 | 100.00% (8 coverpoints) |
| **Total** | **89,145** | **0** | — |

> **Provenance (required note, `docs/results/0013`–`0014` style).** Every figure in this table was produced by Altair DSim, whose licence server was withdrawn on 2026-09-01. **These results are unreproducible — not merely by us, but by anyone.** They are retained because deleting them would misrepresent what M2 established, and because the recorded commands, seeds and `metrics.db` schema remain in `docs/results/0004`, `0005`, `0008` and `0010`. Under PROJECT_INSTRUCTIONS §5.3 ("if we cannot reproduce a result, we do not report it") they are reported *with this caveat attached*, and must carry it into any public writeup at M8. Envs 1–3 are cheap to re-derive under Verilator if the §5.3 covergroup probe succeeds; env 4 additionally needs RAL backdoor access, which is unverified on Verilator.

`vplan`: 174 rows — 90 Covered, 10 Partial, 71 Deferred, 2 Waived, 1 Failing. Functional-coverage traceability suspended pending the probe.

**Env 7 (full-core UVM) is running under Verilator.** 740 retirements across `t02`–`t06`, 0 invariant violations, `UVM_ERROR : 0`, every count matching Sail exactly. `docs/results/0020`. `t01_alu` is deliberately excluded: its pass path contains no branch, so the control-flow invariants would go untested and the scoreboard correctly reports as much rather than passing vacuously.

There is no make target yet — `files_core.f` paths do not resolve under Verilator. Current invocation:

```
verilator --binary --timing --vpi --coverage-user -Wno-fatal \
  +incdir+$UVM_SRC +incdir+$V/uvm/env_core -CFLAGS "-I$UVM_SRC/dpi" \
  $UVM_SRC/uvm_pkg.sv $UVM_SRC/dpi/uvm_dpi.cc <rtl> <verif> \
  --top-module core_uvm_tb_top -j 0 -o env7
```

**Sail lockstep: 800 instructions across six programs, every PC and register write agreeing.**

**Mutations: 31 injected, 30 killed, 1 documented unreachable.** The survivor is mutation `A` in the M3.4a step-5 rewrite, unreachable by construction. The step-5 rewrite moved `ex_mem_q` poisoning to explicit combinational priority (`ex_mem_ctrl_d`); all eight mutations were re-run against the rewritten RTL and every verdict was unchanged — `F` and `T1`–`T6` killed, `A` still unreachable.

### Hardened blocks

| Block | Area | Cells | Setup slack @ 50 MHz |
|---|---|---|---|
| M0 counter | 1,333.78 µm² | 92 | 12.165 ns |
| ALU | 27,705.3 µm² | 1,811 | 6.747 ns (13.25 ns critical path) |
| Register file | 147,663 µm² | 992 sequential | Closes, zero violations |

### Bugs found, by the method that found them

| Bug | Found by |
|---|---|
| `misa` extension encoding (G set, I clear) | `uvm_reg_hw_reset_seq` — automatic |
| Misaligned `sw`/`lw` executing instead of trapping under the reference model | `probe_traps.S` — four traps where six were expected |
| **One instruction per taken branch retiring instead of being squashed, with its register write landing** | **Sail lockstep** |

The third is the important entry. **23 mutations, four test programs and 100% functional coverage on four environments all missed it.** Measured directly: with the fix reverted, the checksum test reports PASS and lockstep reports DIVERGED. Cause was a registered redirect leaving the squash signal and the PC redirect one cycle apart, with IF still fetching in between; fixed by squashing `if_id` on either signal. Four wrong fixes preceded the right one, each moving the symptom by exactly one instruction.

**The conclusion to carry forward:** self-derived golden values cannot catch a bug that corrupts the golden value itself. Every checksum before M3.5 was self-derived. An independent reference model is not redundancy on top of good coverage — it is a different category of check. This is why §5.3 now ranks Sail above mutation kill rate. `docs/results/0013` and `0014` carry provenance notes recording that they predate this fix.

### Next

**M3.4b — ACT4 compliance.** Repo cloned at `~/src/riscv-arch-test`, dependencies installed via `mise`. Blocking work, in order:

1. Rewrite `verif/compliance/rv32sky/rv32sky.yaml` — declare `Sm` and `Zicsr`, restore the Sm-scoped params, and correct the `description:` and the stale comments (see standing risks).
2. HTIF decode in `core_tb_top.sv`.
3. `SIZE_BYTES(262144)` override.

`rvmodel_macros.h` and the linker script are done. Well-positioned otherwise: Sail works, HTIF terminates cleanly, and the `0x1000` collision that would have broken every compliance test identically is already fixed.

Then M3.6 riscv-formal · M3.7 CI + structural coverage · M4 RV32M/C and SoC · full-chip hardening.

Env 7 follow-on work, not gating M3.4b: driveable memory for constrained-random instruction streams; Sail as an online predictor rather than a post-hoc comparison.

### Standing risks

- **`verif/compliance/rv32sky/rv32sky.yaml` describes a core that no longer exists.** It declares `I, Zifencei` only, its `description:` says "No CSRs, no traps", and its comments assert that `csr.sv` is absent from `files.f` and that trap detection is M4 — all false since M3.4a. `verif/sail/rv32sky.json` carries the same drift in one comment ("Zicsr … wired in at M4") while its `misaligned` block is current. **ACT4 generates its test set from the UDB declaration**, so running it against the current yaml would emit no CSR or trap tests and pass cleanly while testing none of M3.4a — a green result that cannot distinguish the current core from the pre-M3.4a one. This is observed failure mode #1 at document scale. Fix before any ACT4 run.
- **Functional coverage is unavailable pending the `cg4.sv` probe.** If the probe fails, §5.3 loses the metric permanently and env 7's instruction × hazard × pipeline-state crosses become unreportable.
- **UVM RAL backdoor access is unverified on Verilator.** Blocks env 4 re-derivation and all peripheral RAL at M4.
- **`verif/assertions/` was written against DSim's SVA subset** and has not been checked against Verilator's.
- **No structural coverage measured yet.** §5.3 wants ≥95% line and ≥90% toggle on `rtl/core`. Scheduled M3.7.
- **D3 (bus protocol) undecided** and needed before M4.
- **muldiv has no flush port.** A ~34-cycle divide must be cancellable on a branch mispredict. Adding the input forces an env 2 re-verification pass — which, without functional coverage, would not currently reach its original standard.
- **This document diverged from git for three weeks** (2026-08-08 → 2026-09-06) while M1–M3.5 all landed. Only `f9fb2bc` and `9da48af` ever touched it. Update it in the same commit as the work, not afterwards.

---

## 11. Glossary

| Term | Meaning |
|------|---------|
| **ACT4** | The current RISC-V architectural compliance test framework, replacing RISCOF |
| **ADR** | Architecture Decision Record — a short doc capturing one decision, its options, and its rationale |
| **ATPG** | Automatic Test Pattern Generation — generates manufacturing test vectors |
| **CTS** | Clock Tree Synthesis |
| **DFT** | Design for Test |
| **DRC / LVS** | Design Rule Check / Layout vs Schematic |
| **GDSII** | The final layout database format sent to a foundry |
| **HTIF** | Host-Target Interface — the `tohost`/`fromhost` convention used to terminate a simulation |
| **PDK** | Process Design Kit |
| **PDN** | Power Distribution Network |
| **RAL** | Register Abstraction Layer (UVM) |
| **Sail** | The official executable formal model of the RISC-V ISA; this project's golden reference |
| **SDC** | Synopsys Design Constraints — timing constraint format |
| **Sm** | The UDB extension name for RISC-V M-mode privilege; gates the M-mode CSR parameters |
| **STA** | Static Timing Analysis |
| **SVA** | SystemVerilog Assertions |
| **TCM** | Tightly Coupled Memory |
| **UDB** | RISC-V Unified Database — the machine-readable ISA config ACT4 generates tests from |
| **VIP** | Verification IP — a reusable verification component |
| **vplan** | Verification plan — feature-to-coverage traceability matrix |
