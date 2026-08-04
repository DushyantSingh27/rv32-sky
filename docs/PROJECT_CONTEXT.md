# PROJECT CONTEXT — RV32 CPU on SkyWater 130nm

**Working title:** `RV32-SKY` *(placeholder — rename when you pick a real name)*
**Owner:** Solo project. Not affiliated with the Semiconductor Chip Design Club.
**Document created:** 2026-07-29
**Last updated:** 2026-07-30 (D2 resolved; see ADR-0001)
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
- **No commercial EDA dependency in the implementation path.** Free-tier commercial tools are permitted in the *verification* path only (see §4.3).
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

### 2.3 Why this works now (verified 2026-07-29)

Mainline Yosys uses the sv-elab and slang libraries to support a synthesizable subset of SystemVerilog IEEE 1800-2017/2023. LibreLane 3.x exposes this through a `USE_SLANG: true` configuration flag (it replaced the older Synlig-based path). This means synthesizable SystemVerilog goes straight into the implementation flow without a conversion step.

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
| **Testbench** | Full SV + UVM 2020.3.1 | Altair DSim (free individual licence) | Real UVM: agents, sequencers, drivers, monitors, scoreboards, RAL, functional coverage, constrained random. Exactly the skill set interviews probe. |
| **Fast regression** | C++ / SV | Verilator | 100–1000× faster than an event-driven UVM simulator. Runs full benchmarks, Spike lockstep, and bulk directed tests. |
| **Formal** | SV (immediate assertions) | SymbiYosys + riscv-formal | Mathematical proof of ISA conformance. Catches bugs random testing never reaches. |

### 2.5 The two constraints this creates

**Constraint A — SVA does not work in the synthesis/formal path.**
yosys-slang supports plain `assert()`, `assume()`, and `cover()` statements but does **not** support SVA (`property`/`sequence` blocks). SVA support is estimated to be a year or two out.

*Mitigation — the two-tier assertion rule:*
- Assertions **inside RTL modules** (`rtl/`) must be *immediate* assertions only, wrapped in `` `ifndef SYNTHESIS `` guards. These work in Verilator, DSim, and SymbiYosys.
- Assertions using **full SVA** live in separate bind files under `verif/assertions/` and are only ever loaded by DSim. Never compiled by Yosys.
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

## 3. Architecture — Proposed Baseline

> **Status: PROPOSED, pending confirmation.** See §8 for the open decisions that gate this.

### 3.1 ISA

**RV32IMC_Zicsr** — 32-bit base integer, multiply/divide, compressed instructions, CSR access.

- **I** — mandatory base.
- **M** — needed for any real benchmark (CoreMark, Dhrystone).
- **C** — roughly halves code size. Critical because on-die memory is severely limited (see §5.2). Also adds real decoder complexity, which is good verification material.
- **Zicsr** — required for traps, interrupts, and performance counters.

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
| Register file | 32×32-bit, 2 read / 1 write | Implementation via flip-flops or ORRAM — decide with area data at Milestone 6. |
| Privilege | M-mode only initially; M+U as a stretch | S-mode + Sv32 MMU is a scope doubler. See §8, Decision D1. |
| Reset | Async assert, sync deassert; single clock domain | No CDC infrastructure needed. Any added clock domain requires an explicit documented synchronizer. |

### 3.3 Memory subsystem

| Level | Plan |
|-------|------|
| Register file | Flip-flop based (or ORRAM if area demands) |
| I-cache | 2 KB, direct-mapped, 16-byte lines. *Phase 2 feature.* |
| D-cache | 2 KB, direct-mapped, write-through with 4-entry write buffer. *Phase 2 feature.* Write-through is substantially simpler to verify than write-back. |
| Tightly-coupled memory | 4–8 KB unified TCM as the Phase 1 memory. Simpler than caches; gets the core running sooner. |
| Main memory | External, over QSPI. Not on-die. |
| Boot ROM | Small synthesized ROM, ~256 bytes |

**Verified constraint (2026-07-29):** the SKY130 PDK ships only three pre-built SRAM configurations — 8×1024, 32×256, and 32×512. OpenRAM can generate custom sizes but has a practical ceiling around 4 KB; 8 KB and 16 KB configurations exist but present implementation problems. This directly caps how much on-die memory is realistic and is the reason the `C` extension is mandatory.

**SRAM options to evaluate at Milestone 6:**
1. Pre-built sky130 macros — silicon-proven, easiest. Note: sky130 SRAM blocks use a different DRC ruleset because of optical proximity shrinking of the SRAM transistors, so Magic DRC requires a documented workaround.
2. OpenRAM — custom sizes, ≤4 KB practical.
3. Sram22 — newer Rust-based sky130 compiler with pre-generated macros.
4. **ORRAM** — released July 2026, now part of the OpenROAD project. Standard-cell-based, supports arbitrary word sizes and counts, mask granularity, multi-port reads, and column muxing, achieving ~28,000 bits/mm² on sky130hd — roughly 2× the density of DFFRAM. Needs no special DRC handling, which makes it attractive for the register file and small structures.

### 3.4 SoC integration

- **Bus:** Wishbone B4 (lighter and better supported in the open-source ecosystem than AXI). *Optional pivot:* AXI4-Lite if a UVM AXI VIP proves more valuable for skill-building — see §8, Decision D3.
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

> All entries verified 2026-07-29 unless marked otherwise. **Re-verify before relying on any of this.**

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
- Synlig → Slang: set `USE_SLANG: true`.
- "The great FP_ removal" — many floorplan variables lost their `FP_` prefix. Check the Variable Migration Guide.
- Tilde (`~`) paths are rejected by the CLI. Use absolute paths or `$HOME`.
- DRT antenna repair is enabled by default.

### 4.2 Implementation stack

| Purpose | Tool | Notes |
|---------|------|-------|
| Flow orchestration | **LibreLane 3.x** | **Installed: v3.0.5 via AppImage (`librelane-devshell-x86_64.AppImage`), 2026-07-30, smoke test passing.** Enter the environment by running the AppImage; leave with `exit`. Nix and Docker are the alternatives. Pip-only install is unsupported upstream. Requires `libfuse2` on Ubuntu 22.04 (undocumented upstream). Not OpenLane. |
| PDK management | **ciel** | Pins PDK version by hash — record the hash. |
| Synthesis | **Yosys** + **abc** | slang frontend via `USE_SLANG: true` |
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
| **UVM simulation** | **Altair DSim 2026** | Free Individual License | Ships **UVM 2020.3.1** (IEEE 1800.2-2020). Functional coverage collected by default into a sqlite3 database (`metrics.db`); `-no-fcov` disables. SVA supported except `accept_on`/`reject_on`/`sync_accept_on`/`sync_reject_on`; **singly-clocked assertions only**; `expect property` unsupported; unsupported SVA is a compile-time error, not a silent no-op. **Single concurrent simulation** on the free tier. **License expires every 90 days** and must be revoked then regenerated. Activate with `source $HOME/AltairDSim/<version>/shell_activate.bash` and `export DSIM_LICENSE=$HOME/metrics-ca/dsim-license.json`. See ADR-0001. |
| Fallback UVM simulation | Vivado XSim 2025.2 | Free (Standard Edition, pre-2026.1 only) | **Not installed — contingency only.** UVM 1.2 only; assertion coverage unsupported; ~60 GB install. From Vivado 2026.1 the free Standard Edition was replaced by "Vivado BASIC", whose "limited simulation and debug support" is **unquantified**. See ADR-0001. |
| Fast RTL simulation | **Verilator** | Open source | The regression workhorse. **Do not attempt UVM here** — UVM support is an active but incomplete Antmicro/CHIPS Alliance effort, currently at the "enabling UVM Cookbook samples" stage. |
| Event-driven sim | **Icarus Verilog** | Open source | Quick sanity checks |
| Python testbenches | **cocotb** + **pyuvm** | Open source | Complements UVM; not a substitute for learning real UVM |
| Formal | **SymbiYosys (sby)** + **riscv-formal** | Open source | Highest value-per-effort tool in the entire project |
| Compliance | **RISCOF** + **riscv-arch-test** | Open source | Official architectural test suite |
| Golden model | **Spike** | Open source | Lockstep co-simulation reference |
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
| **L1 — Fast regression** | Directed tests, benchmarks, Spike lockstep co-simulation | Verilator | Every commit, CI |
| **L2 — UVM** | Constrained-random block-level and core-level environments with functional coverage | Altair DSim | Nightly + before every milestone gate |
| **L3 — Formal** | ISA conformance proof, protocol properties, deadlock freedom | SymbiYosys + riscv-formal | Weekly + before every milestone gate |
| **L4 — Compliance** | Official RISC-V architectural tests | RISCOF | Before every milestone gate |

### 5.2 UVM environments to build

These are the skill-building deliverables. Each is a self-contained, reusable environment.

| # | Environment | UVM concepts exercised |
|---|-------------|------------------------|
| 1 | **ALU** | First env. Agent, driver, monitor, sequencer, sequences, scoreboard, basic covergroups. Deliberately simple so you learn the structure, not the DUT. |
| 2 | **Multiplier/Divider** | Multi-cycle handshake protocol, response sequences, corner-case constraints (signed/unsigned, overflow, div-by-zero) |
| 3 | **Register File** | Multi-port, read-during-write hazards, x0 hardwiring |
| 4 | **CSR block** | **UVM RAL** — register model, `uvm_reg`, frontdoor/backdoor access, built-in register sequences. Major industry skill. |
| 5 | **Wishbone/AXI VIP** | Reusable bus agent, protocol checkers, master and slave modes |
| 6 | **Cache** | Layered sequences, cache-state coverage crosses, hit/miss/eviction scenarios |
| 7 | **Full core** | **Portfolio centerpiece.** Instruction-stream generator agent (constrained-random RISC-V programs), memory-model agent, Spike-reference scoreboard, coverage on instruction types × hazard types × pipeline states. |

**Discipline note:** environments 1–6 run fast enough in DSim to be practical. Environment 7 will be slow — use it for targeted coverage closure, and run bulk regression in Verilator (L1). Note that the DSim free tier permits only **one concurrent simulation**, so UVM regressions are serial; budget seed counts accordingly.

### 5.3 Coverage targets

| Metric | Target | Measured by |
|--------|--------|-------------|
| Line/toggle coverage | ≥95% on RTL | Verilator `--coverage` |
| Functional coverage | ≥90% of defined bins | DSim, via the `metrics.db` coverage database |
| riscv-formal | All checks passing, bounded depth ≥20 | SymbiYosys |
| RISCOF compliance | 100% pass on RV32IMC_Zicsr suite | RISCOF |
| Scan fault coverage | ≥90% | ATPG report |

A verification plan (`vplan`) mapping every ISA feature and microarchitectural mechanism to specific coverage bins is a **required deliverable at Milestone 2**, not an afterthought.

---

## 6. Repository Structure

```
rv32-sky/
├── README.md
├── docs/
│   ├── PROJECT_CONTEXT.md        # this file
│   ├── PROJECT_INSTRUCTIONS.md   # working agreement
│   ├── decisions/                # ADR-0001.md, ADR-0002.md, ...
│   ├── vplan/                    # verification plan
│   └── results/                  # timing, area, coverage, benchmark reports
├── rtl/
│   ├── pkg/                      # SV packages: opcodes, params, typedefs
│   ├── core/                     # pipeline stages, hazard unit, CSR, ALU, mul/div
│   ├── mem/                      # caches, TCM, memory interfaces
│   ├── soc/                      # bus fabric, peripherals, top level
│   └── interfaces/               # SV interface definitions
├── verif/
│   ├── uvm/
│   │   ├── common/               # base classes, shared sequences
│   │   ├── agents/               # per-protocol agents
│   │   ├── env_alu/ env_csr/ ... # one dir per environment (§5.2)
│   │   └── tests/
│   ├── assertions/               # SVA bind files — DSim ONLY, never read by Yosys
│   ├── verilator/                # C++ testbenches, Spike lockstep harness
│   ├── formal/                   # riscv-formal config, sby scripts
│   └── compliance/               # RISCOF config
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

---

## 7. Milestones

Each milestone ends with a working, demonstrable artifact and a written result. No milestone is "done" until its gate criteria pass.

| # | Milestone | Gate criteria |
|---|-----------|---------------|
| **M0** | **Toolchain bring-up** | COMPLETE 2026-08-01. LibreLane + ciel + sky130A installed. `USE_SLANG` confirmed empirically. SystemVerilog counter exercising `typedef enum`, packed struct, package import and `interface`/`modport` reached GDSII, DRC/LVS clean. DSim ran a UVM hello-world with covergroup; coverage merge characterised. Versions, PDK hash and licence expiry recorded. |
| **M1** | **Leaf blocks, standalone** | ALU, radix-4 sequential multiplier/divider, 32x32 register file, and CSR block written as independent modules. Each lints clean, each synthesises through LibreLane with `USE_SLANG: true`, each has recorded area and slack. Authored SDC written. No pipeline yet. |
| **M2** | **UVM envs 1-4** | Envs 1 (ALU), 2 (mul/div), 3 (register file), 4 (CSR with full RAL) complete - each with agent, scoreboard, coverage collector, config object, layered sequences. vplan written. Coverage >= 90% of defined bins per block. Scheduled inside the DSim licence window per ADR-0002. |
| **M3** | **RV32I core integration** | Leaf blocks assembled into the 5-stage pipeline. RISCOF RV32I passing in Verilator. Spike lockstep working. riscv-formal integrated and passing. CI running L0+L1 on every commit. |
| **M4** | **RV32IMC_Zicsr complete** | Traps, interrupts, CSRs, compressed decode. Full RISCOF pass. |
| **M5** | **SoC integration** | Bus fabric + UART + QSPI + GPIO + timer. Boots from simulated SPI flash, prints over UART. UVM env 5 complete. |
| **M6** | **Performance features** | Branch predictor, caches. Before/after CoreMark/MHz measured and documented. UVM envs 6-7 complete. |
| **M7** | **First hardening** | Full SoC through LibreLane to GDSII. Timing closed at 50 MHz, all corners. DRC/LVS clean. Area and Fmax recorded. |
| **M8** | **DFT + signoff** | Scan insertion, ATPG, fault coverage >= 90%. IR drop analysis. Antenna clean. Final signoff report. |
| **M9** | **Documentation & release** | Full writeup, results tables, reproducible build instructions, public repo. |

**Stretch (only if M0–M8 land comfortably):** debug module + OpenOCD, `A` extension, `Zbb`, M+U privilege, custom accelerator.

---

## 8. Open Decisions

These gate the plan and need answers before detailed work begins. Each has a recommended default so work is never blocked.

| ID | Decision | Options | Recommended default | Impact |
|----|----------|---------|--------------------|--------|
| **D1** | Linux capability? | (a) M-mode only (b) M+U (c) M+S+U with Sv32 MMU | **(a) for M1–M6, revisit at M7** | Largest single scope fork. Option (c) roughly doubles the project. |
| **D2** | UVM simulator | (a) Vivado XSim (b) Questa free tier (c) Altair DSim free individual license | **RESOLVED 2026-07-30 — (c) DSim primary, XSim documented fallback. See ADR-0001.** | Affects §5.2 environments, §5.3 coverage flow, §7 M0 gate. |
| **D3** | Bus protocol | (a) Wishbone B4 (b) AXI4-Lite | **(b) AXI4-Lite** — an AXI UVM VIP is far more valuable for employability than a Wishbone one, and the goal is skill-building | Affects peripheral design and UVM env 5. |
| **D4** | Register file implementation | (a) Flip-flops (b) ORRAM | **Defer to M6, decide with area data** | Area/timing tradeoff. |
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
| LibreLane 3.x uses Slang (not Synlig); `USE_SLANG: true` | 2026-07-29 | VLSIDA chip-tutorials LibreLane migration notes |
| Mainline Yosys uses sv-elab + slang for synthesizable SV IEEE 1800-2017/2023 | 2026-07-29 | YosysHQ/yosys README |
| yosys-slang supports immediate `assert`/`assume`/`cover` but **not SVA**; SVA ~1–2 years out | 2026-07-29 | povik/sv-elab Discussion #75 |
| Vivado XSim ships precompiled UVM 1.2; `-L uvm` for standalone; `xcrg` for coverage; assertion coverage unsupported | 2026-07-29 | AMD UG900 (2025.2), community repo |
| Vivado 2026.1+ replaced the free ML Standard Edition with "Vivado BASIC"; described as having limited simulation and debug support | 2026-07-29 | AMD licensing FAQ, AMD "Buy Vivado" page |
| DSim integrates UVM 2020.3.1; full SystemVerilog 2023 and VHDL 2008 support | 2026-07-29 | Altair HyperWorks 2025.1 product page |
| DSim Free Individual License: individual use only, single concurrent simulation, administered from the DSim Cloud Portal | 2026-07-29 | Altair DSim KB, "Licensing" (modified 7 Jan 2026) |
| DSim licenses are valid 90 days; only one valid at a time; must revoke before regenerating; usable on multiple machines but one at a time | 2026-07-30 | Altair DSim KB, "Licensing" |
| DSim license manual install path on Linux: `$HOME/metrics-ca/dsim-license.json`; DSim Studio not required | 2026-07-30 | Altair DSim KB, "Licensing" |
| DSim activation: `source $HOME/AltairDSim/<version>/shell_activate.bash`; `dsim --version` works without a license; `dsim hello.sv` requires one | 2026-07-30 | Altair DSim Getting Started 2026 (PDF) |
| DSim collects functional coverage by default into sqlite3 `metrics.db`; `-no-fcov` disables | 2026-07-29 | Altair DSim KB, "Coverage Options" |
| DSim SVA: `accept_on`/`reject_on`/`sync_accept_on`/`sync_reject_on` unsupported, all other property and sequence operators supported; unsupported elements are compile-time errors | 2026-07-29 | Altair DSim KB, "Known Issues" |
| DSim supports singly-clocked assertions only; multi-clocked flagged as error; `expect property` unsupported | 2026-07-29 | Altair DSim KB, "Major Release Highlights" |
| **T1 (empirical):** LibreLane v3.0.5 installed via AppImage on Ubuntu 22.04.5 WSL2; `librelane --smoke-test` passed | 2026-07-30 | Own tool run |
| **T1 (empirical):** LibreLane AppImage requires `libfuse2` on Ubuntu 22.04 — not stated in the upstream AppImage install docs | 2026-07-30 | Own tool run |
| LibreLane AppImage is the upstream-recommended simplest install for Linux/WSL; pip-only install explicitly unsupported | 2026-07-30 | librelane.readthedocs.io installation docs |
| **T1 (empirical):** `USE_SLANG` exists in LibreLane 3.0.5 — `bool`, `default=False`, deprecated alias `USE_SYNLIG`; companion `SLANG_ARGUMENTS` (`Optional[List[str]]`) | 2026-07-31 | Installed package source, `librelane/steps/pyosys.py` |
| **T1 (empirical):** LibreLane 3.0.5 synthesis step is `steps/pyosys.py` (Yosys Python API), not a Tcl script | 2026-07-31 | Installed package source |
| **T1 (empirical):** PDK pinned at sky130 version `8afc8346a57fe1ab7934ba5a6056ea8b43078e71`, dated 2025.07.14; variants sky130A and sky130B present; ciel v2.4.0 | 2026-07-30 | `ciel ls --pdk-family sky130` |
| Upstream describes the Slang frontend as not as battle-tested as the default Yosys frontend | 2026-07-31 | `USE_SLANG` variable description, installed source |
| Verilator UVM support incomplete; active Antmicro/CHIPS Alliance effort | 2026-07-29 | chipsalliance.org, verilator/uvm repo (updated June 2026) |
| SKY130 ships only 8×1024, 32×256, 32×512 SRAM configs; OpenRAM practical ceiling ~4 KB | 2026-07-29 | "Macro Memory Cell Generator for SKY130 PDK" |
| sky130 SRAM macros need a different DRC ruleset due to optical proximity shrink | 2026-07-29 | OpenLane OpenRAM tutorial docs |
| ORRAM released July 2026, part of OpenROAD; ~28,000 bits/mm² on sky130hd, ~2× DFFRAM | 2026-07-29 | arXiv:2607.12244 |

**Unverified — must check before relying on:**
- **Existence and exact spelling of `USE_SLANG` in the installed LibreLane v3.0.5 build.** T3 only. Gates all of §2. M0 gate item.
- **Whether yosys-slang accepts SystemVerilog `interface`/`modport` in the synthesis path.** The yosys-slang README lists interfaces among missing features; that text may predate the sv-elab merge. §2.4 and `rtl/interfaces/` depend on this. Tested deliberately in the M0 smoke design.
- **Whether DSim coverage databases can be merged across runs.** Required for §5.3 coverage closure. M0 gate item.
- **Whether the DSim Free Individual License permits publishing testbench code and simulation results in a public repository.** Gates the M8 public release. ADR-0001 follow-up #2.
- DSim UVM RAL backdoor access behaviour. Required for §5.2 environment 4; check at M3.
- Scope of the "limited simulation and debug support" in Vivado BASIC (2026.1+). Only matters if the XSim fallback is ever needed.
- Questa Intel Starter Edition / Siemens student licensing terms and line limits. No longer blocking — tracked in ADR-0001 as a contingency.
- Specific Fmax and area figures for sky130 (all numbers in §3.5 are estimates from general community experience, not measured)
- Sram22 current maintenance status
- Whether ORRAM is production-ready or still experimental

---

## 10. Glossary

| Term | Meaning |
|------|---------|
| **ADR** | Architecture Decision Record — a short doc capturing one decision, its options, and its rationale |
| **ATPG** | Automatic Test Pattern Generation — generates manufacturing test vectors |
| **CTS** | Clock Tree Synthesis |
| **DFT** | Design for Test |
| **DRC / LVS** | Design Rule Check / Layout vs Schematic |
| **GDSII** | The final layout database format sent to a foundry |
| **PDK** | Process Design Kit |
| **PDN** | Power Distribution Network |
| **RAL** | Register Abstraction Layer (UVM) |
| **SDC** | Synopsys Design Constraints — timing constraint format |
| **STA** | Static Timing Analysis |
| **SVA** | SystemVerilog Assertions |
| **TCM** | Tightly Coupled Memory |
| **VIP** | Verification IP — a reusable verification component |
| **vplan** | Verification plan — feature-to-coverage traceability matrix |
