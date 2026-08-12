# RV32-SKY

A RISC-V RV32IMC_Zicsr CPU and minimal SoC, taken from SystemVerilog RTL to a
DRC/LVS-clean GDSII on the open-source SkyWater 130 nm PDK, verified with a
UVM methodology.

Solo project. Final-year undergraduate work, started July 2026.

## Why this exists

Two goals, ranked:

1. **Deep, demonstrable SystemVerilog and UVM skill.** Verification is roughly
   60-70% of real chip development effort and the most hireable skill in the
   industry.
2. **A genuine RTL-to-GDSII flow.** Not just RTL - a real layout, timing-closed
   across process corners, DRC and LVS clean.

Everything here is measured, dated, and reproducible from a recorded command.
Numbers without a source are not reported.

## Current status

| Milestone | Status |
|---|---|
| M0 - Toolchain bring-up | **Complete** |
| M1 - Leaf blocks standalone | ALU, mul/div and register file complete; CSR pending |
| M2 - UVM environments 1-4 | Envs 1 (ALU), 2 (mul/div) and 3 (register file) complete, all at 100% functional coverage |
| M3 - RV32I core integration | Not started |
| M4-M9 | Not started |

### Results so far

**M0 smoke design** - a SystemVerilog counter exercising `typedef enum`, packed
`struct`, package import and `interface`/`modport`, taken to GDSII to prove the
language strategy survives synthesis.

| Metric | Value |
|---|---|
| Post-PnR instance area | 1,333.78 um^2 |
| Standard cells | 92 |
| Worst setup slack @ 50 MHz | 12.165 ns |
| DRC / LVS / antenna | Clean |

**M1 ALU** - RV32I ALU with integrated branch comparison, hardened standalone
through a registered harness.

| Metric | Value |
|---|---|
| Post-PnR instance area | 27,705.3 um^2 |
| Standard cells | 1,811 |
| Worst setup slack @ 50 MHz | 6.747 ns |
| Implied critical path | 13.25 ns (~75 MHz) |
| DRC / LVS / antenna | Clean |

**M1 muldiv** - RV32M multiply/divide: radix-4 sequential multiplier,
restoring divider, full valid/ready handshake.

| Metric | Value |
|---|---|
| Compute cycles, minimum | 2 (special-case early exit) |
| Compute cycles, maximum | 34 (full restoring divide) |

**M2 UVM environment 1** - ALU verification against a reference model written
from the RISC-V specification.

| Metric | Value |
|---|---|
| Transactions | 30,019 |
| Mismatches | **0** |
| Functional coverage | **100.00%** (9 coverpoints, incl. a 343-bin cross) |

**M2 UVM environment 2** - multiply/divide verification with a multi-cycle
valid/ready protocol, response sequences and back-pressure.

| Metric | Value |
|---|---|
| Transactions | 34,029 |
| Mismatches | **0** |
| Functional coverage | **100.00%** (9 coverpoints) |
| Back-pressure test | 2,000 transactions, 0 errors, no deadlock |

**M1 register file** - 32 x 32-bit, 2 read ports, 1 write port, x0 hardwired.

| Metric | Value |
|---|---|
| Post-PnR instance area | 147,663 um^2 |
| Sequential cells | 992 (x0 costs no storage) |
| Timing | Closes 50 MHz, zero setup/hold violations |

**M2 UVM environment 3** - register file, with read-during-write collisions as
the primary target.

| Metric | Value |
|---|---|
| Transactions | 25,097 |
| Read/write collisions | 6,009 |
| Mismatches | **0** |
| Functional coverage | **100.00%** (11 coverpoints) |

Full detail, with caveats and open issues, in [`docs/results/`](docs/results/).

## The language strategy

"SystemVerilog" is really two languages sharing a keyword set. The synthesizable
subset (`logic`, `always_ff`, `enum`, `struct`, `interface`) becomes gates. The
verification subset (`class`, `rand`, `constraint`, `covergroup`, UVM) never does.

This project uses both, kept strictly apart:

    rtl/    compiled by Yosys AND simulators -> synthesizable SV only
    verif/  compiled by simulators only      -> full SV + UVM, SVA allowed

That boundary is what makes the approach work. `rtl/` uses only immediate
assertions guarded by `` `ifndef SYNTHESIS ``; full SVA lives in `verif/assertions/`
as bind files. No Verilog-2005 is ever hand-written.

Confirmed empirically at M0: yosys-slang accepted every construct above on the
first attempt, no fallback needed.

## Toolchain

| Purpose | Tool | Version |
|---|---|---|
| Flow orchestration | LibreLane (not OpenLane) | v3.0.5 |
| PDK | sky130A via ciel | hash `8afc8346a57fe1ab7934ba5a6056ea8b43078e71` |
| Synthesis | Yosys with the slang frontend | `USE_SLANG: true` |
| Place & route, STA | OpenROAD, OpenSTA | bundled |
| DRC / LVS | Magic, KLayout, Netgen | bundled |
| UVM simulation | Altair DSim | 2026.0.0, UVM 2020.3.1 |
| Lint & fast simulation | Verilator | 5.050 (built from source) |
| Host | Ubuntu 22.04.5 on WSL2 | 20 threads, 10 GiB |

The PDK version is pinned deliberately. Changing it invalidates every prior area
and timing result.

## Repository layout

    docs/           context, working agreement, ADRs, results
    rtl/            synthesizable SystemVerilog (pkg, core, mem, soc, interfaces)
    verif/          UVM environments, assertions, formal, compliance
    flow/           LibreLane configs, constraints, synthesis harnesses
    sw/             bootrom, crt0, linker scripts, benchmarks
    tools/          version ledger, setup

## How decisions are recorded

Every non-trivial decision gets an
[Architecture Decision Record](docs/decisions/) with the options considered, the
evidence, and the consequences. ADRs are never deleted - when a decision is
reversed, a new ADR supersedes the old one and both stay.

[ADR-0001](docs/decisions/ADR-0001-uvm-simulator-selection.md) selected Altair DSim
over Vivado XSim, and explicitly recorded vendor-continuity risk with a review
trigger. Two days later that trigger fired: Altair discontinued free on-prem DSim
licensing effective 2026-09-01.
[ADR-0002](docs/decisions/ADR-0002-dsim-window-and-milestone-reorder.md) records the
response.

Facts carry an evidence tier: T1 empirical (we ran it), T2 primary source,
T3 secondary, T4 inference, T5 recollection. Anything at T4 or T5 is labelled as
such. This matters in open-source EDA, where tooling changed hands recently
(Efabless -> FOSSi, OpenLane -> LibreLane, Synlig -> Slang) and most tutorials are
stale.

## Reproducing a result

Each file in `docs/results/` records the exact command, tool versions, and PDK hash.
For example, the ALU hardening:

    ~/librelane-devshell-x86_64.AppImage
    cd flow/alu && librelane config.yaml

And the ALU UVM regression:

    source $HOME/AltairDSim/2026/shell_activate.bash
    make -f verif/dsim.mk alu-full

## Non-goals

No fabrication - signoff-clean GDSII is the finish line. No analog or
mixed-signal. No commercial EDA in the implementation path.

## Licence

To be decided before M9.
