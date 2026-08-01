# M0 smoke design — RTL to GDSII

**Date:** 2026-08-01
**Run:** `flow/runs/RUN_2026-08-01_14-51-42`
**Design:** `smoke_top` — 3-state FSM + 8-bit counter, driven through an SV interface

## Tool and PDK versions
| Item | Value |
|---|---|
| LibreLane | v3.0.5 (AppImage) |
| PDK | sky130A, ciel v2.4.0, hash `8afc8346a57fe1ab7934ba5a6056ea8b43078e71` (2025.07.14) |
| Standard cells | `sky130_fd_sc_hd` |
| Verilator (lint) | 5.050 2026-07-01 rev v5.050-60-g3d2421f3b |
| Host | Ubuntu 22.04.5 WSL2, 20 threads, 10 GiB RAM |

## Exact command
    ~/librelane-devshell-x86_64.AppImage
    cd ~/dev/rv32-sky/flow && librelane config.yaml

Config: `flow/config.yaml`, `USE_SLANG: true`, `CLOCK_PERIOD: 20` (50 MHz),
`FP_CORE_UTIL: 40`, `PL_TARGET_DENSITY_PCT: 50`.

## PRIMARY FINDING — the language strategy holds

yosys-slang accepted **every** SystemVerilog construct PROJECT_CONTEXT section 2
depends on, first attempt, with no `SLANG_ARGUMENTS` and no `sv2v` fallback:

| Construct | File | Result |
|---|---|---|
| `package` + `import pkg::*` in module header | `rtl/pkg/smoke_pkg.sv` | ACCEPTED |
| `typedef enum logic [1:0]` FSM | `rtl/pkg/smoke_pkg.sv` | ACCEPTED |
| packed `struct` | `rtl/pkg/smoke_pkg.sv` | ACCEPTED |
| **`interface` + `modport`** | `rtl/interfaces/smoke_if.sv` | **ACCEPTED** |
| `always_ff` / `always_comb` | `rtl/core/smoke_counter.sv` | ACCEPTED |
| `unique case` with `default` | `rtl/core/smoke_counter.sv` | ACCEPTED |
| immediate `assert` under `` `ifndef SYNTHESIS `` | `rtl/core/smoke_counter.sv` | ACCEPTED (correctly excluded) |

The interface question was the largest open risk in the project. Section 2.4's claim
that interfaces replace wide module headers is confirmed empirically. `rtl/interfaces/`
stays in the repository structure.

Section 2.5 Constraint B escalation ladder was **never invoked** — rung 0.

## Signoff results
| Check | Result |
|---|---|
| Magic DRC | PASS |
| KLayout DRC | PASS |
| Netgen LVS | PASS — circuits match uniquely, 81 devices / 83 nets both sides |
| Antenna | PASS |
| Setup violations | none, all corners |
| Hold violations | none, all corners |
| Max slew / max cap | none |
| Power grid violations | 0 (VPWR and VGND) |

## Timing — actual slack

| Corner | Setup slack (ns) | Hold slack (ns) |
|---|---|---|
| min_ss_100C_1v60 (slow) | 12.165 | 0.906 |
| nom_tt_025C_1v80 | 14.034 | 0.322 |
| min_tt_025C_1v80 | 14.047 | 0.320 |
| nom_ff_n40C_1v95 | 14.754 | 0.110 |
| min_ff_n40C_1v95 (fast) | 14.762 | 0.109 |

Setup is worst at the slow corner and hold at the fast corner, as expected.

**Supported claim:** 50 MHz closes with no setup or hold violations at any corner,
with >= 12.16 ns setup margin and >= 0.109 ns hold margin.

**Implied Fmax (T4 inference, NOT measured):** at the slow corner the critical path is
20 - 12.165 = 7.835 ns, implying ~128 MHz. This assumes the critical path is unchanged
under a tighter constraint, which is not guaranteed — synthesis optimises differently
against different targets. A real Fmax requires sweeping `CLOCK_PERIOD` downward until
timing fails. **Do that for the ALU at M1.** LibreLane ships a `SynthesisExploration`
flow which may automate it; its actual behaviour is unverified.

## Area
| Metric | Value (um^2) |
|---|---|
| Synthesis chip area | 570.5472 |
| Post-PnR instance area | 1333.78 |
| Core area | 1333.78 |
| Die area | 2905.12 |
| — standard cells | 977.187 |
| — sequential cells | 289.027 |
| — combinational (multi-input) | 270.259 |
| — timing repair buffers | 240.23 |
| — clock buffers | 147.642 |
| — fill cells | 356.592 |
| — tap cells | 18.768 |
| Instance utilization | 73.26% |

## Cell counts
| Class | Count |
|---|---|
| Standard cells (post-PnR) | 92 |
| Sequential | 11 |
| Multi-input combinational | 31 |
| Fill | 113 |
| Tap | 15 |
| Synthesis cell count | 45 |

## Routing and power
| Metric | Value |
|---|---|
| Global route wirelength | 2159 |
| Detailed route wirelength | 1283 |
| Longest wire | 56.58 |
| Total power | 9.8396e-05 |
| — internal | 8.3159e-05 |
| — switching | 1.5235e-05 |
| — leakage | 1.5426e-09 |

## OBSERVATION — Yosys re-encoded the FSM

The RTL declares a 3-state enum (2 bits) plus an 8-bit counter = 10 flops expected.
Synthesis produced **11** sequential cells: 10 x `dfrtp_2` (reset) + 1 x `dfstp_2` (set).

Consistent with **one-hot FSM re-encoding**: 3 one-hot state bits + 8 counter bits = 11.
In one-hot, `ST_IDLE` = `3'b001`, so exactly one flop must initialise to 1, requiring a
set-type flop.

**Inference (T4), not confirmed by reading the Yosys log.** Confirmable by inspecting
the synthesis log for the `fsm` pass, or the post-synthesis netlist.

**Consequence for M1 onward:** enum encodings written in RTL are not guaranteed to
survive to gates. Where an encoding must be preserved — externally visible status
registers, formal properties referencing encoded values, safety-critical FSMs — it must
be constrained explicitly, not assumed.

## CAVEATS — do not cite these results without them

1. **No SDC file was supplied.** `PNR_SDC_FILE` and `SIGNOFF_SDC_FILE` were unset;
   OpenROAD used its generic fallback derived from `CLOCK_PERIOD`. Timing closed, but
   against fallback constraints, not authored ones. **Writing real SDC is an M1 task.**
2. Fmax is inferred, not measured. See the timing section.
3. **Two floating nets** reported by `[RSZ-0020]` during `RepairDesignPostGPL`.
   Unresolved. Plausibly a by-product of one-hot re-encoding leaving an unused bit, but
   **this is speculation (T5)**. LVS matches uniquely and DRC is clean, so not a
   correctness problem here. Investigate if the count grows at M1 — floating nets in an
   ALU would indicate a real bug.
4. `VSRC_LOC_FILES` unset, so IR drop figures are approximate. Irrelevant here (no
   fabrication), relevant at M7.
5. `[GPL-0302] Target density 0.5000 is too low for the available free area` — expected
   for a design this small.

## Viewing this run in a GUI
From inside the LibreLane devshell, in `flow/`:

    librelane -f openinopenroad --last-run config.yaml   # placement, routing, timing paths
    librelane -f openinklayout  --last-run config.yaml   # GDSII layer view
    librelane -f openinmagic    --last-run config.yaml   # interactive DRC

WSLg renders these as Windows windows with no extra configuration. Confirmed working
2026-08-01.

## Reproducibility
Reproducible from the recorded command with the pinned PDK hash. Per
PROJECT_INSTRUCTIONS 5.3, this satisfies the reproducibility requirement.

## M0 GATE: COMPLETE
All criteria pass.
