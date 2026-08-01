# Coverage merge behaviour under DSim 2026.0.0

**Date:** 2026-08-01
**Tool:** Altair DSim 2026.0.0 (b:R #c:127 h:14cc828913 os:rocky_8.10)
**UVM:** Accellera:1800.2:UVM:2020.3.1
**Testbench:** verif/uvm/tests/m0_smoke_pkg.sv, m0_smoke_tb_top.sv
**Covergroup:** 16 bins on a 4-bit random value, `option.per_instance = 1`,
`type_option.merge_instances = 1`

## Question
Does cross-run coverage accumulation work, as required by PROJECT_INSTRUCTIONS 5.3
(functional coverage >= 90% of defined bins)?

## Method
Two short runs with different seeds, each too short to reach full coverage, then
merged with `dcmerge` and reported with `dcreport`. A third long single run as control.

Commands (exact, reproducible):

    dsim -uvm 2020.3.1 +incdir+$HOME/AltairDSim/2026/uvm/2020.3.1/src \
      verif/uvm/tests/m0_smoke_pkg.sv verif/uvm/tests/m0_smoke_tb_top.sv \
      -sv_seed 1 -cov-db run1.db +N_ITEMS=6

    dsim ... -sv_seed 77 -cov-db run2.db +N_ITEMS=6

    dcmerge  -out_db merged.db run1.db run2.db
    dcreport -out_dir report_merged merged.db

    dsim ... -sv_seed 5 -cov-db long.db +N_ITEMS=200      # control

## Results

| Run | Seed | Items | Bins hit | Coverage |
|---|---|---|---|---|
| run1 | 1 | 6 | {0,5,7,9,15} = 5/16 | 31.25% |
| run2 | 77 | 6 | {0,3,6,11,14} = 5/16 | 31.25% |
| **merged** | - | 12 | union would be 9/16 | **31.25%** |
| long (control) | 5 | 200 | 16/16 | **100.00%** |

Union of run1 and run2 is {0,3,5,6,7,9,11,14,15} = 9/16 = 56.25% expected.
Merged reported 31.25%.

## Finding

**`dcmerge` does not union coverage bins across databases.** The merged report
contains TWO separate `Instance: cg` blocks with disjoint bin hits; bin counts were
not summed (b[0] appears as 2 in one block and 1 in the other, not 3 in a single
block). The reported figure is the weighted average of the instances, not their
union. The index page confirms both databases were ingested ("2 test(s)").

Within-run accumulation works correctly: 200 items in a single run reached 100.00%.

`type_option.merge_instances = 1` did not change this. That option governs merging
of multiple instances within one simulation, not across databases.

## Consequence for methodology

Coverage closure uses **fewer, longer runs** rather than many short seeded runs.
For block-level environments (UVM envs 1-4: ALU, mul/div, register file, CSR) this
is entirely practical - tens of thousands of transactions in a single simulation
cost seconds for combinational and small sequential blocks.

This becomes a real constraint only at UVM env 7 (full core), where each run is slow
and parallelising across seeds would be the natural approach. Revisit before M6.

The DSim free tier permits only one concurrent simulation in any case, so seed
parallelism was already unavailable.

## Untested hypotheses (first things to try if cross-run merge is needed later)

1. Remove `option.per_instance = 1`. A covergroup without per-instance tracking may
   merge across databases correctly. **Untested.**
2. `dcmerge` may accept undocumented flags; `-help` output is explicitly described as
   "generally available" options only, and `-help-all` / `-helpall` are rejected.
3. Consult DSim coverage documentation properly rather than by experiment.

Timeboxed per PROJECT_INSTRUCTIONS 7 (tool-chasing). Three diagnostic iterations
were spent; the workaround is sufficient for M1-M5.

## M0 gate status
**PASS with documented workaround.** The coverage-merge gate item is resolved: cross-run
merge does not accumulate, single-run accumulation does, and the >= 90% target remains
achievable via the long-run methodology.
