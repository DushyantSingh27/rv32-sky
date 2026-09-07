# ADR-0006: Verilator as the UVM simulator, accepting no functional coverage

**Date:** 2026-09-06
**Status:** Accepted
**Supersedes:** ADR-0001 (DSim primary, XSim fallback) and ADR-0002 (DSim window)

## Context

Altair DSim Cloud was shut down 2026-09-01. The on-premises install validates
against that server, so DSim is unusable:

    =F:[UsageMeter] License not obtained: Altair DSim Cloud has been shut
    down as of September 1st 2026.

ADR-0001 named Vivado XSim as the documented fallback. That fallback has also
degraded: from Vivado 2026.1 the free tier became "BASIC", with limited XSim
simulation and full simulation starting at the paid CORE tier. Pre-2026.1
Vivado ML Standard Edition remains usable by existing users, but only for as
long as an installer and licence can be obtained.

Envs 1-4 were captured before the deadline (89,145 transactions, 100%
functional coverage, docs/results/0004, 0005, 0008, 0010). Env 7 was not - it
exists as source that has never compiled (docs/results/0019).

## Options considered

**1. Questa Intel/Altera FPGA Starter Edition.** REJECTED by measurement of
the vendor record. The free licence excludes the constructs UVM is built on:
"Unable to checkout verification license - required for testbench features
(randomize, randcase, randsequence, covergroup)". The documented workaround
is `-nocvg` plus replacing `randomize()` with `$random`. That is UVM's class
structure with both of its defining mechanisms removed.

**2. Vivado XSim, pre-2026.1 ML Standard Edition.** Free, Linux, UVM 1.2
precompiled, constrained randomization and functional coverage both work.
Rejected by the project owner. Costs: UVM 1.2 rather than 2020.3.1, assertion
coverage unsupported, ~60 GB install, and an availability window that will
close the way DSim's did.

**3. Verilator 5.050.** CHOSEN. Open source, already installed and pinned,
no licence, no expiry, no server that can be shut down.

## Decision

Verilator 5.050 is the UVM simulator. Functional coverage is accepted as
unavailable and the section 5.3 gate is revised accordingly.

Claude recommended option 2 in addition to option 3, on the grounds that
envs 1-4's coverage results become permanently unreproducible without it.
The owner decided option 3 alone. Disagreement noted once; decision stands.

## Rationale — what was measured

All T1, 2026-09-06.

**Verilator runs UVM 2020.3.1.** Invocation:

    verilator --binary --timing --vpi --coverage-user -Wno-fatal \
      +incdir+$UVM_SRC -CFLAGS "-I$UVM_SRC/dpi" \
      $UVM_SRC/uvm_pkg.sv $UVM_SRC/dpi/uvm_dpi.cc <files> -j 0

The M0 smoke test produces the Accellera 1800.2 UVM 2020.3.1 banner, runs the
factory and phasing, reports through the UVM report server, and exits with
UVM_ERROR : 0. Constrained randomization works - `randomize()` produced
varied values across 16 items.

Build cost: 127 s walltime, 2,057 generated C++ files, 77 MB intermediates,
on 20 threads. Cached afterwards.

Three link failures were worked through, each a build-recipe problem rather
than a capability limit:

| Failure | Cause | Fix |
|---|---|---|
| `uvm_hdl_read`, `uvm_dpi_*` undefined | `uvm_dpi.cc` not compiled | add it to the file list |
| `vpi_*` undefined | VPI runtime not linked | `--vpi` |
| coverage 0.00% | see below | none available |

`uvm_dpi.cc` has no vendor conditionals - it unconditionally includes
`uvm_common.c`, `uvm_regex.cc`, `uvm_hdl.c`, `uvm_svcmd_dpi.c` and
`uvm_hdl_polling.c`. No `-D` define is needed.

**Covergroups declared inside a class do not accumulate.** Isolated in a
three-file probe with no UVM involved (`cg3.sv`): identical coverpoint,
identical stimulus, same run.

    module-scope inst = 100.00%
    class-scope  inst = 0.00%

Ruled out first, each by measurement: `option.per_instance` and
`type_option.merge_instances` (all three variants read 100% in a module),
and `--coverage-user` being absent (adding it changed nothing).

`get_coverage()` - type-level coverage - returns 0.00% even at module scope.

**The failure is silent.** The covergroup constructs, `sample()` returns
normally, `get_inst_coverage()` returns 0.00%, and no warning is issued.
A collector reporting 0.00% reads as "coverage not closed yet" rather than
"coverage not working". Every UVM coverage collector in this project declares
its covergroup inside a `uvm_subscriber`, which is UVM's required idiom, so
this affects envs 1-4 and env 7 alike.

## Consequences

**Makes easier:**
- No licence, no expiry, no vendor server. The failure mode that cost env 7
  cannot recur.
- One simulator for RTL regression, Sail lockstep and UVM.
- Verilator is already pinned in tools/versions.md and used for every
  existing result from M3.1 onward.

**Makes harder:**
- **Functional coverage is unavailable.** Section 5.3's >=90% gate is
  unmeasurable and is replaced (below).
- **Envs 1-4's coverage results are permanently unreproducible.** The 100%
  figures in docs/results/0004, 0005, 0008 and 0010 were produced by a tool
  that no longer exists and cannot be regenerated. Section 5.3 says a result
  that cannot be reproduced is not reported; these are retained with this
  ADR cited, because they were correctly obtained and recorded at the time.
- The vplan's coverage column maps features to bins that nothing measures.
- UVM builds are slow: ~2 minutes for a trivial testbench, dominated by C++
  compilation of the UVM library.

**Forecloses:**
- Nothing permanently. Antmicro and CHIPS Alliance are actively developing
  Verilator's UVM and coverage support; class-scope covergroups may work in a
  later release. Env 7's covergroup is retained in source, reporting 0.00%,
  so it works the day that lands - same principle as routing
  `mem_misaligned_o` to the boundary rather than suppressing it.

## Revised section 5.3 gate

The functional coverage row is replaced:

| Metric | Target | Measured by |
|---|---|---|
| Line coverage | >=95% on `rtl/core` | `verilator --coverage-line` |
| Toggle coverage | >=90% on `rtl/core` | `verilator --coverage-toggle` |
| **Mutation kill rate** | **>=95%, every survivor documented with its reason** | mutation suite |
| Sail lockstep | 100% agreement across all programs | `run_lockstep.sh` |

**Mutation kill rate is the primary quality metric.** The project's own record
argues for it: docs/results/0015 records a real architectural bug surviving
100% functional coverage on four environments, 23 mutations, and four test
programs, caught only by Sail lockstep. This session, mutation T2 survived
because a check written specifically to catch store leakage looked one word
from where the leak lands - a question coverage cannot ask.

A coverage percentage claims code was executed. A mutation kill rate claims
faults would be detected. The second is what verification is for.

**The honest weakness**, recorded rather than glossed: mutation kill rate is
only as good as the mutations written, and has no equivalent of a coverage
hole telling you what you forgot. Coverage answers "what did I not touch";
mutation answers "what would I not catch". Losing the first is a real loss
and the final writeup should say so.

Current standing: 31 mutations across M1-M3.4a, 30 killed, 1 (mutation A)
documented as structurally unreachable with the reason recorded.
