# 0027 — Functional coverage is recoverable. And three UVM results were not reproducible.

**Date:** 2026-10-02
**Milestone:** M3.7 preparatory; resolves an open item carried since ADR-0006 (2026-09-06)
**DUT:** none — this measures the simulator, not the design
**Harness:** `verif/verilator/cov_probe/cg4.sv`, `verif/uvm/cov_probe_uvm/cg5.sv`
**Tools:** Verilator 5.050 (`v5.050-60-g3d2421f3b`), Accellera UVM 2020.3.1
**Status:** Both questions answered. Three reproducibility gaps found and two closed.

---

## Result

| Scope | `cg4` (no UVM) | `cg5` (under UVM) |
|---|---|---|
| **A** module | 100.00 % | 100.00 % |
| **B** class | 0.00 % | 0.00 % |
| **C** interface, sampled through a virtual interface | **100.00 %** | **100.00 %** |

`cg5` samples from a real `uvm_subscriber`, driven over a `uvm_analysis_port`,
with the interface handle delivered by `uvm_config_db` — the exact path every
coverage collector in this project already uses. `UVM_ERROR : 0`.

**A covergroup declared in an interface accumulates. Functional coverage is
recoverable.**

### What this does NOT say

**The class-scope limitation still stands.** B is 0.00% in both probes.
Verilator has not been fixed upstream; what exists is a workaround that happens
to fit UVM's idiom, because collectors already hold a virtual interface.

**The metric does not come back in the form DSim produced it.** `0020` records
a second limitation that re-hosting does not touch: cross bin exclusions are
unsupported — Verilator emits `COVERIGN` for `binsof`, `intersect` and `&&` in
select expressions, and `ignore_bins` on a cross is **silently dropped**. Envs
1–3 used cross exclusions; env 1's 343-bin cross especially. A re-hosted env 1
will not reach 100% the way it did under DSim, and section 5.3 must say so
rather than implying a clean restoration.

The decision this result enables — a dedicated coverage interface per
environment — is **ADR-0007**.

---

## Experiment design

Three covergroups per probe, **one variable**: where the covergroup is
declared. Identical coverpoint (4-bit, 16 explicit bins), identical stimulus
(the same 16 values in the same order), identical explicit `.sample()` from the
same call site at the same instant, identical `option.per_instance`.

Scopes A and B are **controls**, reproducing the two numbers ADR-0006 rests on.
If they had not reproduced, C would have been uninterpretable — and in `cg5`'s
case the difference would have been UVM itself rather than the covergroup's
scope. They reproduced exactly in both probes.

`cg4` has no UVM in it, deliberately, matching `cg3`. `cg5` adds UVM and
nothing else. Testing both at once would have made a failure unattributable —
the same discipline that made `insn_lh` rather than `insn_lw` the right file to
read at M3.6.

---

## THREE RESULTS WERE NOT REPRODUCIBLE

Looking for `cg3.sv` to copy its structure turned up something larger. Section
5.3: *every result must be reproducible from a recorded command; if we cannot
reproduce a result, we do not report it.*

### 1. `cg3.sv` does not exist

`find . -name "cg[0-9]*"` returns nothing. ADR-0006 and the section 9 ledger
both record its numbers — module 100.00%, class 0.00% — and **those numbers are
the entire justification for dropping functional coverage from section 5.3.**
The source that produced them was gone.

**Closed.** `cg4.sv` reproduces both data points and is committed.

### 2. `docs/results/0020`'s reproduce block cannot be run

    cd ~/work/env7
    verilator ... +incdir+$UVM_SRC +incdir+$V/uvm/env_core ... <rtl files> <verif files>

`~/work/env7` is outside the repo. `$UVM_SRC` is unset in the shell. `$V` is
undefined. `<rtl files>` and `<verif files>` are placeholders.

So the env 7 result in PROJECT_CONTEXT section 10 — **740 retirements, 0
invariant violations** — rests on a command nobody can run, including its
author.

**Closed, same day.** `~/work/env7` holds only `coverage.dat` and `obj_dir`;
the sources are all committed under `verif/uvm/`, so env 7 was built in a
scratch directory from repo files. Only the recipe was missing.

`verif/uvm/env_core/Makefile`, on the shared `verif/uvm/uvm.mk`, reproduces it:
**740 retirements, 22 redirects, 0 invariant violations across t02–t06**, every
per-program figure matching 2026-09-06 to the unit, including the redirect
counts. 2,525 generated C++ files, matching `0020`'s original build-cost table
exactly. `0020` now carries a provenance note with the comparison.

### 3. There was no committed UVM build recipe at all

`find verif -name "Makefile" -o -name "*.mk"` found recipes for the core
harness, the decoder harness, ACT4 and formal — and `verif/dsim.mk`, which is
the dead Altair one. **Nothing replaced it after ADR-0006.**

Every other flow in this project has a committed recipe. The Verilator UVM flow
was brought up in a hurry after the DSim shutdown and never got one, which is
why (1) and (2) both happened and why neither was noticed for three weeks.

**Closed.** `verif/uvm/uvm.mk` carries `UVM_SRC`, the flag set from `0020` and
ADR-0006, and two guards. Per PROJECT_INSTRUCTIONS 4.4 the per-environment
makefiles carry only `TOP`, `SRCS` and a test name.

---

## The UVM library was inside the dead vendor install

    /home/dushyant/AltairDSim/2026/uvm/2020.3.1/src/uvm_pkg.sv

Accellera's reference UVM, not an Altair artifact — the licence server's death
does not touch it. But every UVM build depended on a path inside an install
whose only reason to exist is gone. A tidy-up would have broken env 7 silently.

**Relocated** (copied, not moved) to `~/src/uvm-2020.3.1`, alongside the other
pinned tools.

| | |
|---|---|
| Path | `~/src/uvm-2020.3.1` |
| `UVM_SRC` | `~/src/uvm-2020.3.1/src` — the **src** directory |
| Size | 5.2 MB |
| `md5sum src/uvm_pkg.sv` | `3f35dfbc73ec285cc799d88bfd9849d6` |

The md5 is recorded because "UVM 2020.3.1" does not distinguish Accellera's
copy from a vendor's patched one, and this copy came out of a vendor tree.

---

## Guards added

Both encode a failure that has actually happened.

**Verilator version.** `uvm.mk` and the `cov_probe` makefile both assert
`verilator --version` is exactly 5.050 and refuse to build otherwise, naming
the OSS CAD Suite as the likely cause. `0026` records the near-miss: sourcing
the suite substitutes 5.053 silently, and a day without an unrelated error
would have produced clean numbers measured with a tool no result file names.

This is the first of the three guards M3.7 is meant to deliver; the other two
(the comment-pragma scan, the `checks.cfg` ↔ `files.f` match) remain to do.

**UVM tree.** `uvm.mk` asserts both `$(UVM_SRC)/uvm_pkg.sv` and
`$(UVM_SRC)/dpi/uvm_dpi.cc` exist before building, naming the `src/dpi/` vs
`dpi/` distinction in the error. See below for why.

---

## Error made on the way

**I constructed the DPI path instead of reading it.** The first relocation
check tested `~/src/uvm-2020.3.1/dpi/uvm_dpi.cc` and failed. The DPI sources
live at `src/dpi/`, which ADR-0006's own recipe implies — it uses both
`$UVM_SRC/uvm_pkg.sv` and `$UVM_SRC/dpi/uvm_dpi.cc`, so `UVM_SRC` must be the
`src` directory. The information was in the document I was holding.

Fourth instance this fortnight of asserting something computable rather than
computing it (`0026` records three). The `check-uvm` target exists so this one
cannot recur silently.

---

## What is NOT verified

- **That a re-hosted collector reaches the same coverage as under DSim.**
  Cross bin exclusions are unsupported, and envs 1–3 relied on them. The
  re-hosting work will measure what is actually reachable.
- **That `get_coverage()` — type-level — works at interface scope.** ADR-0006
  measured it returning 0.00% at module scope. Both probes read
  `get_inst_coverage()` only. If type-level coverage is still broken, merging
  across instances may not work, which matters for any environment with more
  than one collector instance.
- ~~Whether env 7 rebuilds from a committed recipe.~~ **RESOLVED 2026-10-02:**
  it does, and reproduces all five programs exactly. See the provenance note in
  `0020`.
- **Whether envs 1–4 still elaborate under Verilator at all.** They were last
  built under DSim. Nothing has compiled them since.

---

## Reproduce

    # Both probes require the PINNED Verilator 5.050. The makefiles assert it.
    cd ~/dev/rv32-sky/verif/verilator/cov_probe   && make run
    cd ~/dev/rv32-sky/verif/uvm/cov_probe_uvm     && make run

`cg4` builds in ~2 s. `cg5` takes ~87 s on the first build — 2,313 generated C++
files, 22.5 MB of output, dominated by compiling the UVM library — and is
cached afterwards.

---

## Provenance

No value here was produced by the DUT; there is no DUT. Every figure is a
`get_inst_coverage()` return printed by the probe that produced it.

The flag set in `uvm.mk` was taken from `docs/results/0020`'s reproduce block
and ADR-0006's rationale section, not reconstructed. `UVM_SRC`'s meaning was
derived from those same two documents after the error recorded above.

ADR-0006's two measured data points were **re-measured, not assumed**, and both
reproduced to the hundredth. That matters more than the new result: it means
the decision ADR-0006 made was correctly grounded, and only its consequence
changes.
