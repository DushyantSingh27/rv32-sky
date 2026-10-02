# 0020 — UVM env 7 running under Verilator

**Date:** 2026-09-06
**Simulator:** Verilator 5.050 (v5.050-60-g3d2421f3b) — see ADR-0006
**UVM:** Accellera 1800.2 UVM 2020.3.1
**DUT:** full `rv32_core` + TCM, RV32I + Zicsr + synchronous traps

## Result

| Program | Retirements observed | Redirects | Invariant violations | Sail lockstep |
|---|---|---|---|---|
| t02_memory | 176 | 3 | 0 | 176 |
| t03_checksum | 305 | 2 | 0 | 305 |
| t04_hazards | 80 | 2 | 0 | 80 |
| t05_csr | 79 | 1 | 0 | 79 |
| t06_traps | 100 | 14 | 0 | 100 |
| **Total** | **740** | **22** | **0** | **740** |

`UVM_ERROR : 0` on every run. Functional coverage reports **0.00%** — the
Verilator class-scope covergroup limitation, ADR-0006.

**Every retirement count matches Sail exactly.** The UVM monitor observes the
core through the trace port and counts retirements; Sail lockstep compares an
offline trace against the formal model. Two unrelated mechanisms arriving at
the same number for all five programs is a real cross-check, not a
restatement - a monitor mis-sampling `trace_valid` would show up immediately
as a count mismatch.

## t01_alu is excluded, and the reason is the check working

t01_alu takes no branch on its pass path - it is NOP-padded and every check is
straight-line. The scoreboard therefore reports:

    ZERO redirects observed - the control-flow invariants are UNTESTED

That is correct behaviour, mirroring env 3's zero-collision check
(docs/results/0008): a run that never exercised an invariant should not report
success. t01 is not a valid stimulus for this environment and is excluded
rather than the check being weakened to accommodate it.

## Three scoreboard defects, all found by running it

The core is verified against Sail at 800 instructions, so a violation here was
always more likely to be a checker defect than a design bug. All three were.

### 1. The illegal-redirect check read the wrong instruction's opcode

Fired twice per loop iteration on t04. The trace:

    @260000  pc=0x48  OPC_BRANCH  FLOW_SEQUENTIAL
    @300000  pc=0x40  OPC_OPIMM   FLOW_REDIRECT   <- flagged

`flow` is a property of the ARRIVING instruction, and the check read
`t.opc` - the arriving opcode. The instruction that caused the redirect is
`prev_pc`'s. The branch at 0x48 retires, then 0x40 retires as its target, and
the `addi` at 0x40 was blamed for a redirect the branch caused.

Fixed by carrying `prev_opc` in the sequence item. The 40,000 ps gap between
those two retirements is the three-cycle registered branch penalty, visible
in the trace and consistent with the design.

### 2. Any instruction can redirect if it TRAPS

Fired 4 times on t06_traps. A misaligned load or store vectors to `mtvec`
from an `OPC_LOAD`/`OPC_STORE`, and the original invariant allowed only
branch, jump and SYSTEM.

Fixed by tracking `mtvec` from the DUT boundary and accepting any redirect to
it as a trap entry. What remains checkable is the non-trap case: a redirect
that is neither a branch/jump/SYSTEM nor a jump to `mtvec`.

Required adding `mtvec` to the sequence item - caught by grepping the agent
before rebuilding rather than by a compile error.

### 3. The x0-write check flagged correct hardware, and was removed

Fired on `addi x0, x0, 999` at pc=0x104 - the instruction t03 and t04
deliberately contain to test that x0 never forwards (docs/results/0014).

`trace_rd_we` reports the writeback stage's ATTEMPT to write x0. The register
file discards it, verified across 25,097 transactions in env 3. The trace port
cannot observe architectural x0 state, so the invariant is not measurable from
this vantage point.

**Removed rather than weakened.** A check that cannot see what it claims to
check is worse than no check: it either fires on correct hardware or is
softened until it fires on nothing.

## A fourth defect: the monitor ran past program termination

The first t04 run reported **90** retirements against Sail's 80, and scored
two halt-loop retirements as invariant violations.

The test dropped its objection at the terminating store but the monitor kept
sampling through the 200 ns drain time, observing the halt loop's `sw`/`sw`/
`beq` repeating. Architecturally the program is over at the store; anything
after it is the testbench watching a machine that has finished.

Fixed with a `done` flag in the agent config, set by the test and checked by
the monitor. Drain time is for letting the last real transaction land, not
for deciding when the program ended.

## Build cost

| Item | Value |
|---|---|
| Walltime | 75-99 s |
| Generated C++ files | 2,525 |
| Source processed | 71.98 MB |
| Intermediates | 85.35 MB |
| Threads | 20 (`-j 0`) |

Dominated by C++ compilation of the UVM library, not by the design. Cached in
`obj_dir` afterwards.

## Verilator limitations encountered

**Class-scope covergroups return 0.00%** (ADR-0006). `core_coverage`'s
covergroup is retained in source, reporting 0.00%, so it works the day
upstream fixes it - same principle as routing `mem_misaligned_o` to the
boundary rather than suppressing it.

**Cross bin exclusions are unsupported.** Verilator emits COVERIGN warnings
for `binsof`, `intersect`, `&&` in select expressions, and explicit cross
bins. `ignore_bins` on a cross is silently dropped. This compounds the
class-scope limitation: even at module scope the cross exclusions in envs 1-3
would not apply.

**A comment beginning with the tool's name is parsed as a pragma.** A line
reading `// Verilator harness does. The same image is...` failed elaboration
with `BADVLTPRAGMA: Unknown verilator comment`. Cost one build. Noted in the
source at the site.

## What this environment checks, and what it does not

Unchanged from docs/results/0019: the scoreboard holds ARCHITECTURAL
INVARIANTS, not a reference model. It cannot tell a correct `add` from a wrong
one. What it checks is a different category - properties true of any correct
RV32I core regardless of what the program computes:

- every retired PC is 4-byte aligned
- every retired PC is inside the loaded image
- a redirect comes from a branch, jump or SYSTEM instruction, or is a trap
  entry to `mtvec`
- a store or branch never writes a register
- a memory write comes only from a store
- at least one redirect occurred, or the control-flow invariants are untested

**The honest claim remains "structural UVM environment with invariant
checking", not "verified core".** The verification claim rests on Sail
lockstep and the mutation suite.

## Reproducing

### PROVENANCE NOTE added 2026-10-02 — the original block below could not be run

The command recorded here on 2026-09-06 was not runnable by anyone, including
its author. `~/work/env7` is outside the repo; `$UVM_SRC` and `$V` were never
set in any shell; `<rtl files>` and `<verif files>` are placeholders. There was
no committed UVM build recipe anywhere in the project — `verif/dsim.mk` is the
dead Altair one and nothing replaced it after ADR-0006.

So the figures in this file, and PROJECT_CONTEXT section 10's headline
**740 retirements, 0 invariant violations**, rested on a command that did not
exist. Section 5.3: a result that cannot be reproduced is not reported.

Found 2026-10-02 while looking for `cg3.sv`, which turned out not to exist
either. See `docs/results/0027`.

**The sources were never the problem.** `~/work/env7` holds only `coverage.dat`
and `obj_dir`; every source file is committed under `verif/uvm/`. Only the
recipe was missing.

**RE-MEASURED 2026-10-02** from `verif/uvm/env_core/Makefile`, built on the new
shared include `verif/uvm/uvm.mk`:

| Program | Retirements | Redirects | Violations | 2026-09-06 |
|---|---|---|---|---|
| t02_memory | 176 | 3 | 0 | 176 / 3 |
| t03_checksum | 305 | 2 | 0 | 305 / 2 |
| t04_hazards | 80 | 2 | 0 | 80 / 2 |
| t05_csr | 79 | 1 | 0 | 79 / 1 |
| t06_traps | 100 | 14 | 0 | 100 / 14 |
| **Total** | **740** | **22** | **0** | **740 / 22** |

`UVM_ERROR : 0` on every run. Every figure matches to the unit, **including the
redirect counts**, which nothing in a build recipe could influence. 2,525
generated C++ files, matching this file's original build-cost table exactly.

Functional coverage still reads 0.00%: `core_coverage`'s covergroup is
class-scope, and re-hosting it under ADR-0007's coverage-interface pattern is
M2 recovery work, not part of this.

The figures in this file stand, and now from a command in version control.

### The command, as it actually is

    cd ~/dev/rv32-sky/verif/uvm/env_core
    make all
    make run HEX=../../../sw/tests/t02_memory.hex

    # the full set
    for p in t02_memory t03_checksum t04_hazards t05_csr t06_traps; do
      make run HEX=../../../sw/tests/$p.hex
    done

`t01_alu` is excluded deliberately — see above. The Makefile asserts Verilator
is 5.050 and that the UVM tree is present before building; both guards exist
because the matching failure has happened (`docs/results/0026`, `0027`).

### The original block, retained

Kept rather than deleted: it is the evidence for the finding above, and section
5.2 says an earlier record gets a note rather than a silent correction.

    cd ~/work/env7
    verilator --binary --timing --vpi --coverage-user -Wno-fatal \
      +incdir+$UVM_SRC +incdir+$V/uvm/env_core \
      -CFLAGS "-I$UVM_SRC/dpi" \
      $UVM_SRC/uvm_pkg.sv $UVM_SRC/dpi/uvm_dpi.cc \
      <rtl files> <verif files> \
      --top-module core_uvm_tb_top -j 0 -o env7

    ./obj_dir/env7 +UVM_TESTNAME=core_run_test +HEX=<program>.hex

Both `uvm_dpi.cc` and `--vpi` are required or the link fails on undefined
DPI and VPI symbols.

## Not verified

- **Functional coverage.** 0.00% by tool limitation, not by lack of stimulus.
- **Constrained-random instruction streams.** The stimulus is five
  hand-written programs. A generator agent writing instructions through a
  virtual interface needs the TCM replaced by a driveable model - the
  specified next step, unchanged from 0019.
- **Sail as an online predictor.** The scoreboard holds invariants; value
  checking is still the offline lockstep flow.
