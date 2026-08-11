# M1: register file standalone hardening

**Date:** 2026-08-11
**Design:** `rtl/core/regfile.sv` - 32 x 32-bit, 2 read ports, 1 write port
**Runs:** `RUN_2026-08-11_23-03-05` (flat mux), `RUN_2026-08-11_23-35-43` (mux tree)

## Tool and PDK versions
| Item | Value |
|---|---|
| LibreLane | v3.0.5 (AppImage) |
| PDK | sky130A, hash `8afc8346a57fe1ab7934ba5a6056ea8b43078e71` (2025.07.14) |
| Standard cells | `sky130_fd_sc_hd` |
| Constraints | `flow/constraints/block.sdc` (authored, estimates) |

## Exact command

    ~/librelane-devshell-x86_64.AppImage
    cd ~/dev/rv32-sky/flow/regfile && librelane config.yaml

`USE_SLANG: true`, `CLOCK_PORT: clk`, `CLOCK_PERIOD: 20`, `FP_CORE_UTIL: 40`,
`PL_TARGET_DENSITY_PCT: 50`, `MAX_FANOUT_CONSTRAINT: 6`.

## Result

**Closes 50 MHz with zero setup and zero hold violations at every corner.**
Zero inferred latches. 992 sequential cells - exactly 31 registers x 32 bits,
confirming x0 costs no storage.

The `for` loop reset inside `always_ff` synthesised correctly through
yosys-slang, unrolling to 31 parallel reset connections. One more construct
confirmed working (PROJECT_CONTEXT 2.5).

## FLAT MUX vs MUX TREE

The initial version wrote the read ports as `regs[rs1_addr]`, which synthesises
to a 32-to-1 mux whose select bits reach every mux slice in all 32 bit lanes.

| Metric | Flat mux | Mux tree | Change |
|---|---|---|---|
| Max slew violations | 1,249 | **559** | **-55%** |
| Max cap violations | 35 | 25 | -29% |
| Setup WNS | 0 (closes) | 0 (closes) | - |
| Instance area | 137,322 um^2 | **147,663 um^2** | **+7.5%** |
| Standard cells | 6,801 | 7,938 | +17% |
| Sequential cells | 992 | 992 | - |
| Timing repair buffers | 1,188 | 1,256 | +6% |
| DRT-0120 large nets | 12 | 13 | - |

**Tree kept.** Slew violations are a signal-quality concern - slower transitions
mean higher short-circuit power - and 55% is worth 7.5% area at this stage.

### Diagnosis that led to the change

Post-PnR STA at `min_ss_100C_1v60`, from
`55-openroad-stapostpnr/min_ss_100C_1v60/checks.rpt`:

    Pin              Limit      Slew       Slack
    _3860_/Y         1.496446   1.713161   -0.216715 (VIOLATED)
    _4881_/S         1.500000   1.713512   -0.213512 (VIOLATED)
    _3863_/S         1.500000   1.713509   -0.213509 (VIOLATED)
    ... 1,024 of 1,033 violations on /S pins

**Essentially every violating pin was `/S` - the select input on a mux cell.**
Slack values clustered between -0.2134 and -0.2167, the signature of a small
number of shared driver nets fanning out to many loads. `DRT-0120` confirmed six
nets carrying 103-119 pins each.

The tree splits the read into eight 4-to-1 muxes selected by `addr[1:0]`,
feeding one 8-to-1 selected by `addr[4:2]`. Behaviour is identical - a purely
structural hint.

### FINDING: Yosys honours explicit structural hints

The tree added 1,137 standard cells, so **synthesis did not flatten the
structure back**. This was an open question and the answer matters for M3, where
the pipeline's forwarding and bypass muxes will face the same choice.

Contrast with the `MAX_FANOUT_CONSTRAINT` sweep on the muldiv, which produced
bit-identical results across four values: **structural changes in RTL affect the
netlist; that particular constraint does not.**

### Why 559 violations remain

Unverified (T4): both select signals still span all 32 bit lanes.
`addr[4:2]` reaches eight groups x 32 bits = 256 loads, and the stage-1 select
still crosses the full width. The tree split the data path, not the select
distribution.

Going further means a three-stage tree or replicating the select decode per
bit-lane group - more area for diminishing returns. Not pursued
(PROJECT_INSTRUCTIONS 7, timeboxing). At M7 this block sits in a real floorplan
where placement changes the loading picture entirely.

## Area comparison across blocks

| Block | Instance area | Std cells | Flops |
|---|---|---|---|
| ALU (registered harness) | 27,705 um^2 | 1,811 | 104 |
| muldiv | 99,711 um^2 | 5,340 | 578 |
| **regfile (tree)** | **147,663 um^2** | **7,938** | **992** |

**The register file is the largest block in the design so far** - larger than
the multiplier and divider combined.

## EVIDENCE FOR DECISION D4 (ORRAM vs flip-flops)

992 bits of storage occupy 147,663 um^2 = 0.148 mm^2, which is roughly
**6,700 bits/mm^2**.

PROJECT_CONTEXT 3.3 records ORRAM at ~28,000 bits/mm^2 on sky130hd - about 4x
denser.

**The comparison is not like-for-like (T4).** This figure includes two read
muxes, write decode, timing repair buffers and PnR overhead; ORRAM's density
figure is presumably for the storage array. 7,938 cells around 992 flops means
roughly 7,000 cells of surrounding logic. But even discounting heavily, the gap
is large.

More significant than the raw density: **a flip-flop-based 2R1W register file is
fundamentally fanout-heavy, and RTL restructuring does not fix that.** The tree
halved slew violations and 559 remain. ORRAM is standard-cell-based and would
handle read multiplexing internally.

**Recommendation: evaluate ORRAM for the register file at M6 with this data as
the baseline.** D4 previously read "defer to M6, decide with area data" - the
area data now exists.

## Caveats

1. Constraints are estimates for standalone characterisation, not signoff.
2. 559 max-slew and 25 max-cap violations remain at slow corners. Not
   functional failures - timing closes - but a power and reliability
   consideration at M7.
3. Reset-to-zero on all 31 registers is a deliberate simulation-hygiene choice,
   not standard practice. Real CPUs generally leave the register file
   uninitialised. Revisit at M7 if the reset network costs area.
4. `Warning: There is 1 input port missing set_input_delay. rst_n` - artifact of
   the authored SDC declaring `rst_n` a false path while excluding it from the
   input delay list. Harmless; untidy.
5. **Not yet functionally verified.** UVM env 3 is next. These numbers describe a
   design whose read-during-write and x0 behaviour have not been checked.

## Design decisions recorded

- **x0 has no storage.** `regs[1:31]`, with the read mux returning zero for
  address 0. Structurally incapable of holding a value.
- **Read-first on collision.** No internal bypass; a read colliding with a write
  to the same address returns the pre-write value. Forwarding stays in the
  hazard unit (PROJECT_CONTEXT 3.2), keeping all hazard resolution in one
  auditable module - and surviving a later ORRAM swap, since a compiled memory
  gives whatever read-during-write behaviour it gives.
- **Three independent guards on x0**: write-enable suppression, read-mux
  override, and a runtime assertion. x0 is the most commonly-wrong part of a
  register file.
