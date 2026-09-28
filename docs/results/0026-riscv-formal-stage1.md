# 0026 — riscv-formal stage 1. 43 of 45 checks meaningful, all passing at depth 10.

**Date:** 2026-09-28
**Milestone:** M3.6
**DUT:** `rtl/core/rv32_core.sv` (+ the ten other modules in `rtl/files.f`)
**Harness:** `verif/formal/rv32sky/{wrapper.sv,checks.cfg,Makefile}`, symlinked
into `~/src/riscv-formal/cores/rv32sky/`
**Tools:** Yosys 0.69+152 (`6f876ae0e-dirty`, Clang 21.1.8), SBY v0.69,
boolector, yosys-slang (`slang.so`, bundled), OSS CAD Suite tarball dated
2026-09-26 (742,094,908 bytes). Regressions on Verilator 5.050
(`v5.050-60-g3d2421f3b`), GCC 16.1.0 (`g6afcc4f6d`), Sail RISC-V 0.13.1.
**Commits:** RTL and harness pushed 2026-09-27. Mutation rounds 2026-09-28.
**Status:** Stage 1 complete. Stage 2 (CSR checks) not started.

---

## Result

| | |
|---|---|
| Checks generated | **45** — 37 RV32I instruction models + 8 consistency |
| Checks passing | **45 of 45**, bounded depth 10 |
| Checks **demonstrably able to fail** | **43** |
| Checks proven **vacuous on this core** | **2** — `pc_bwd`, `causal` |
| Unvalidated | **0** |

Unchanged by the RTL changes this milestone required: Sail lockstep **800
instructions, 0 divergences**; ACT4 **47 of 47, exit 0**; decoder harness not
re-run (`decoder.sv` untouched).

**What the 43 mean.** Every RV32I instruction, register-file read consistency,
forward PC continuity, instruction-order uniqueness, illegal-instruction
handling and liveness hold for *any* instruction stream the solver can
construct within 10 cycles, against **unconstrained** instruction and data
memory. Not "for the 800 instructions in six lockstep programs" and not "for
the 47 compliance tests". That is a different category of statement, and it is
the fourth independent one this project has (lockstep, ACT4, the decoder
harness, now formal).

**What they do not mean.** Ten cycles. `mode bmc`, not `prove` — no induction,
so nothing here is unbounded. No CSR checks. No bus checks. No fault model.

---

## What was built

`wrapper.sv` instantiates `rv32_core` as `rvfi_wrapper`, the module name
riscv-formal requires, with `clock`/`reset` ports it also requires.

Two decisions in it carry the whole result:

**`imem_rdata` and `dmem_rdata` are `` `rvformal_rand_reg ``** — unconstrained,
solver-chosen every cycle, with no memory model behind them. This is what makes
the proof a statement about the core.

**`rst_n` is driven as `!reset`.** riscv-formal's reset is active high; ours is
active low. Connected directly, the core would sit in reset for every trace and
all 45 checks would pass with nothing proved. One character between a proof and
a green tick.

The TCM is not in the solver's cone: `rv32_core` exposes imem/dmem as ports and
`core_tb_top` instantiates the memory, so no 1 MB array enters the SMT problem.
That was an open architectural question before the port list was read; it
resolved favourably.

`checks.cfg` reads the RTL through **yosys-slang** in `[script-sources]`, not
through the `read -sv` that `genchecks.py` emits — see the first RTL finding
below.

---

## FINDING 1 — eight use-before-declaration references (T1)

slang, on first contact:

    rv32_core.sv:118:22: error: identifier 'stall' used before its declaration
    rv32_core.sv:177:37: note: declared here

Eight errors, six names: `stall`, `ex_redirect_valid`, `ex_trap_valid`,
`ex_trap_cause`, `ex_trap_tval`, `ex_mem_ctrl_d`.

IEEE 1800-2017 does not permit a reference to a module-scope variable before
its declaration. **Verilator and Yosys both tolerate it**, which is why it
stood from M3.2 through M3.5. `rv32_core` had never been read by slang: the
blocks hardened so far are the M0 counter, the ALU and the register file, never
the core. The first time this file met the standard PROJECT_INSTRUCTIONS §4.2
claims for it, it failed in eight places.

Fixed by hoisting the six declarations into a forward-declaration block after
the pipeline registers. Every reference site unchanged; each original
declaration site keeps a marker comment.

**Rejected alternative:** `read_slang --allow-use-before-declare`, which exists
and would have suppressed all eight. That leaves a flag in a config file
quietly asserting that our RTL is not standard — the same class of artifact
M3.4b spent a week clearing out — and M6 hardening would hit the identical
eight errors.

---

## FINDING 2 — an asynchronous reset that cannot be synthesised (T1)

    rv32_core.sv:243: error: condition cannot be matched to any signal from
                             the event list
        if (!rst_n || ex_redirect_valid) begin
    rv32_core.sv:242: note: asynchronous load pattern implied by edge
                            sensitivity on multiple signals

`always_ff @(posedge clk or negedge rst_n)` promises two asynchronous events.
The reset branch then fired on `ex_redirect_valid`, which is in neither —
describing a flop with an asynchronous clear it is not sensitive to. That is
not hardware.

§4.2 says "Reset: async assert, sync deassert". This was the one place in the
core that did not.

Split into an async `!rst_n` branch and a synchronous `ex_redirect_valid`
clear. **Behaviourally identical** — a redirect only ever took effect at a
clock edge — and measured as such: lockstep 800 and ACT4 47/47 both unchanged
after the change, on Verilator 5.050.

**Both findings would have hit M6 hardening identically.** Neither is caused by
the RVFI work. The value of a fourth tool is partly what it proves and partly
what it refuses to accept.

---

## The 19-failure round, and what it was

First full run: **19 FAIL, 26 PASS.** The failing set partitioned perfectly —
every instruction that does not read rs2, plus `lui`, `auipc` and `jal` which
read neither, plus `reg`.

Two hypotheses fit that partition identically: "instructions not reading rs2"
and "I-, U- and J-format instructions". **The data could not distinguish them**,
and §2.4 says to measure rather than pick the one with a story. The measurement
was the failing assertion's line number:

| Line | Assertion | Failing checks |
|---|---|---|
| `rvfi_insn_check.sv:164` | `assert(rs1_rdata == 0)` under `if (rs1_addr == 0)` | `lui`, `auipc`, `jal` |
| `rvfi_insn_check.sv:167` | `assert(rs2_rdata == 0)` under `if (rs2_addr == 0)` | every I-type, `jalr`, every load |
| `rvfi_reg_check.sv:42` | shadow register-file consistency | `reg` |

The rs2 reading was right; the format reading was the coincidence.

**Cause, mine.** BLOCK3 forced the *address* to zero when a source is unused
but reported the *data* unconditionally:

    rvfi_m_rs2_addr  <= ctrl.rs2_used ? ctrl.rs2_addr : 5'd0;
    rvfi_m_rs2_rdata <= ex_rs2_fwd;                      // unconditional

For an I-type, `instr[24:20]` is immediate bits, so the rs2 read path carries a
value belonging to no register — reported as the contents of x0.

Fixed by gating the data on the *reported address* being nonzero, which also
covers a genuine x0 read. Predicted before the re-run: all 19 turn to PASS,
`reg_ch0` included. **Measured: 45 of 45.** Stating the prediction first
mattered — `reg_ch0` was attributed to the same root cause without direct
evidence, and a partial fix that looked complete is how the M3.5 branch-squash
bug took four attempts.

**No core bug.** Every R-, S- and B-type check passed throughout, which says
the datapath, forwarding, branch resolution and store path satisfied their
specs over free inputs before any of this.

---

## Mutation testing

§4.5: no recorded result is credible until deliberate faults have been injected
and *each one shown to actually fail the test*. 45 of 45 means nothing until
the checks are shown capable of failing.

Injected into a clean tree, restored in a `finally` block, with
`git status --porcelain --untracked-files=no` verifying the restore. Status read
from the **status file, not the exit code**: `expect pass,fail` makes sby
return 0 either way, and taking the exit code as the verdict is the `0018`
composition bug.

| # | Injection | Check | Verdict |
|---|---|---|---|
| F1 | `rvfi_pc_wdata` reports PC+8 | `insn_add_ch0` | **KILLED** |
| F1 | " | `pc_fwd_ch0` | **KILLED** |
| F1 | " | `pc_bwd_ch0` | survived — see below |
| F2 | `ALU_ADD: result = a + b + 1` | `insn_add_ch0` | **KILLED** |
| F3 | `rvfi_order_q` frozen | `unique_ch0` | **KILLED** |
| F4 | illegal instruction never raises cause 2 | `ill_ch0` | **KILLED** |
| F5 | `rvfi_valid` tied low | `liveness_ch0` | **WITHDRAWN — invalid** |
| F5b | `rvfi_order` increments by 2 | `liveness_ch0` | **KILLED** |

**F1 is the one that matters most.** It proves three things at once: the check
discriminates, `rvfi_pc_wdata` is genuinely compared, and **`imem_rdata` is a
free input** — the mutation is only reachable if the solver drives a real `add`
encoding, which it cannot do if the instruction bus is tied. Without that, the
whole run could have been vacuous.

**F2 tests the datapath**, where F1 tested only the RVFI plumbing. First
mutation of `alu.sv` since M1.

**F5 was withdrawn, not survived.** Tying `rvfi_valid` low made the check's
trig-cycle `assume(rvfi_valid[...])` unsatisfiable, so sby reported
`PREUNSAT` / ERROR rather than evaluating the property. The mutation made the
*precondition* unreachable instead of the *property* false. My design error.
Worth noting that sby distinguishes the two — many tools report an
unsatisfiable-assumption run as a pass, which would have entered this table as
a false KILLED.

F5b keeps retirement happening so the assumption stays satisfiable, while
`insn_order + 1` never exists, so `found_next_insn` can never be set.

**`reg` needed no mutation.** The 19-failure round *is* its kill: it failed
with the rs-rdata bug present and passed with it fixed, cause known. A natural
experiment, worth more than a synthetic one.

**Project total: 46 mutations, 43 killed, 3 documented unreachable**
(`0018` A, `0022` M3, `0024` F4), plus one withdrawn as invalidly designed.

---

## TWO CHECKS ARE VACUOUS ON THIS CORE

`pc_bwd` survived F1 while `pc_fwd` died to it. I assumed they were mirror
images and that one fault covered both — failure mode #1 applied to my own
mutation design.

### `pc_bwd` — the assertion is never evaluated (T1)

Probe: replace the assertion body with `assert(1'b0)`, inside its own
`if (expect_pc_valid)` guard. A PASS then means the guard is never true at the
check cycle.

| Probe | Check | Result | |
|---|---|---|---|
| P1 | `pc_fwd_ch0` | **FAIL** | positive control — the probe works |
| P2 | `pc_bwd_ch0` | **PASS** | **the assertion is dead** |

P1 is what makes P2 readable. Without it, a PASS could equally mean the probe
was broken.

Mechanism, from the source: `pc_bwd` captures `expect_pc` from the instruction
at `insn_order + 1`, but the check cycle assumes the instruction at
`insn_order` retires *there*, so its successor cannot have retired earlier.
With `RISCV_FORMAL_CHANNEL_IDX = 0` the check-branch capture loop runs zero
iterations, leaving only the non-check-cycle path — which is always too early.

### `causal` — the flag is unreachable (T1)

`assert(!found_non_causal)` is unguarded, so the `assert(1'b0)` probe would
fail trivially. Different technique: replace the assertion with
`assume(<condition>)` and read PREUNSAT as unreachability.

| Probe | Replacement | Result | |
|---|---|---|---|
| C1 | `assume(1'b1)` | **PASS** | control — no spurious PREUNSAT |
| C2 | `assume(1'b0)` | **ERROR** | control — probe detects unreachability |
| P3 | `assume(found_non_causal)` | **ERROR** | **unreachable** |

`found_non_causal` is set by an instruction whose order is *greater* than
`insn_order` retiring *before* it. At NRET=1 with monotonic order, everything
retiring earlier has a smaller order.

### What this means

Both checks target hazards a **strictly in-order, single-retirement pipeline
cannot express** — out-of-order retirement of a dependent instruction, and
backward PC continuity across a retirement that has not happened yet. They are
built for more permissive microarchitectures.

**Unverified — T4:** this likely holds for any NRET=1 in-order core, not just
ours, which would make it a finding about riscv-formal rather than about
RV32-SKY. Not confirmed against another core; worth reporting upstream.

**The honest count is 43 of 45.** Reporting 45 would be counting two checks
that cannot fail.

---

## THE SIGNATURE THAT MEANT NOTHING

Three checks reported `PASS 0 0` where the other 42 reported `PASS 0 1`:
`ill_ch0`, `liveness_ch0`, `unique_ch0`. I flagged the difference as suspicious
on a 45/45 run and declined to guess what sby's status fields mean.

**All three turned out to be falsifiable** — killed by F4, F5b and F3
respectively. The two that *were* vacuous, `pc_bwd` and `causal`, both showed
the ordinary `PASS 0 1`.

The signature was a red herring, and the real vacuity was somewhere else
entirely. Recorded because the instinct — be suspicious of a clean sweep — was
right while the specific suspicion was wrong, and because measuring instead of
interpreting the status format is what resolved it.

---

## Errors made on the way to this result

Required by §5.2. This is the part that makes the number trustworthy.

**1. `rvfi_mem_addr` reported as a byte address.** riscv-formal under
`RISCV_FORMAL_ALIGNED_MEM` computes `spec_mem_addr = addr & ~3` and positions
the mask *relative to it*; `mem_byte_en` is already word-relative, so the two
disagreed for every halfword and byte access. Caught by **reading
`insns/insn_lh.v` before running anything** — `lh` at offset 2 is the case
where the byte and word readings diverge, and `insn_lw` would have passed under
either.

**2. `rvfi_rs1/rs2_rdata` reported unconditionally.** 19 of 45 checks. Covered
above.

**3. A comment beginning with the word "Verilator", twice.** A comment whose
first word is that tool's name is parsed as a lint pragma, not prose:
`%Error-BADVLTPRAGMA`. I wrote a warning comment about this trap in one fix and
then opened a line with the same word in the next. Both caught by the build,
neither by review. A repo-wide scan now confirms no prose comment in any `.sv`
begins with that word; making it a committed check is a follow-up.

**4. Counts stated from estimation rather than computation, three times.** The
`0025` note predicted at +33 lines and measured +44; a restore check asserted
`grep -c "id_ex_q.pc + 32'd4"` was 1 when 2 is correct (the `fence.i` redirect
from `0024` is the second); a download check asserted a `grep -c` of 1 when the
string also appears in a comment. None caused a wrong result — the first two
were caught by the guards themselves — but §2.1 says numbers are the
highest-risk category and an unlabelled estimate is exactly what it warns
against.

**5. A post-edit guard that matched its own comment.** `fix_reset.py` checked
for surviving `if (!rst_n || ` in the file, and the replacement *comment* quotes
the old condition verbatim to explain the change. The guard refused a correct
edit. It failed in the safe direction — nothing was written — but the
verification runs in that same paste were then testing an unchanged file, which
would have been recorded as evidence for a fix that had not landed.

**6. Cover statements that did not discriminate what I claimed.** `cover
(cnt_insns == 2)` and `cover (rvfi_valid && rvfi_trap)` were written to rule out
a tied `imem_rdata`. They do not: an all-zero instruction stream decodes as
illegal, traps, and retires, so both covers pass on an inert design. F1 settled
the question properly. Failure mode #1, in the test design rather than the test
values.

**7. `rm -rf` of the ACT4 `obj_dir` in a blanket clean.** `run_compliance.sh`
did not build the harness, so the run crashed on a missing binary. That was a
mistake that **exposed a latent hole**: with the binary merely *stale* rather
than absent, the script would have reported 47 of 47 against older RTL and said
nothing. Fixed in a separate commit; `0025` carries a provenance note recording
the re-measurement that followed.

---

## What is NOT verified

- **Depth 10 only.** `mode bmc`. No induction, nothing unbounded. `0025`'s
  inherited note about "depth ≥20" is still unreviewed.
- **No CSR checks.** `csrw`, `csr_ill`, `csrc_*` are stage 2 and need
  `rvfi_csr_*` ports the core does not have.
- **No bus checks, no fault model.** `bus_*` needs `RVFI_BUS_OUTPUTS`
  plumbing; `fault` needs `RISCV_FORMAL_MEM_FAULT`, which this core has no
  concept of.
- **Six instructions have no formal model:** `fence`, `fence.i`, `ecall`,
  `ebreak`, `wfi`, `mret`. None are among the 37. They remain covered only by
  `tb_decoder.cpp`'s hand-written vectors and ACT4's trap tests — the third
  independent instance of the pattern `0025` named.
- **The RVFI path has never been seen by `-Wall`.** Verilator lints it at the
  default warning set only; the ACT4 build uses `-Wall` but with the define
  off, and the formal flow runs Yosys.
- **`checks.cfg`'s file list duplicates `rtl/files.f`** with nothing enforcing
  the match. `-F` would have consumed the list directly but resolves paths
  relative to the list file, and `files.f` holds repo-root-relative paths while
  living in `rtl/`.
- **Whether `pc_bwd`/`causal` vacuity generalises** beyond this core.

---

## Toolchain hazard: the OSS CAD Suite substitutes Verilator

`source ~/src/oss-cad-suite/environment` prepends the suite's `bin` to PATH,
and the suite ships **Verilator 5.053**. Every result in `docs/results/` from
M1 onward was measured with `~/.local/bin/verilator` **5.050**. Nothing
announces the substitution.

Measured 2026-09-27: a regression block run in the suite shell reported
`/home/dushyant/src/oss-cad-suite/bin/verilator` and the error banner read
`?v=5.053`.

It cost nothing that day only because an unrelated pragma error made the run
fail loudly. **A day without that error would have produced a clean 800 and a
clean 47 of 47 measured with a tool no result file names.** Same shape as the
stale-binary problem in `0025`, one layer up.

Mitigation today is a habit: a dedicated terminal for formal work, and a
`which verilator` line before any regression block. A `run_lockstep.sh` /
`run_compliance.sh` assertion is a follow-up.

---

## Reproduce

    # Regressions - plain shell, NOT the OSS CAD Suite one
    cd ~/dev/rv32-sky
    which verilator                       # must be ~/.local/bin/verilator
    ./verif/sail/run_lockstep.sh t01_alu t02_memory t03_checksum \
      t04_hazards t05_csr t06_traps       # 800, exit 0
    ./verif/compliance/rv32sky/run_compliance.sh   # 47 of 47, exit 0

    # Formal - OSS CAD Suite shell
    source ~/src/oss-cad-suite/environment
    cd ~/src/riscv-formal/cores/rv32sky
    make checks                           # 45 checks, all PASS

    # One check
    make one CHECK=insn_add_ch0

Check statuses are in `checks/<name>/status`. **Read the status file, not the
exit code** — `expect pass,fail` makes sby return 0 for both.

---

## Provenance

Every tool flag, config key, section name and column position in `checks.cfg`
and `wrapper.sv` was read from `checks/genchecks.py`, `checks/rvfi_macros.vh`,
`help read_slang` or the relevant `insns/insn_*.v` — not recalled. §2.1: these
are T5 by default, and failure mode #3 had four instances before this
milestone.

Specific reads that changed a decision:

- `genchecks.py:368,627` — `[depth]` is the enable list, not tuning
- `genchecks.py:812-834` — the column semantics of each `[depth]` row
- `genchecks.py:413` — `[script-sources]` exists, which is the slang escape
- `genchecks.py:554` — a missing isa file skips instruction checks **on stderr
  and exits 0**, so the check count must be read, not the exit code
- `insns/insn_lh.v` — word-aligned `spec_mem_addr`, and
  `RISCV_FORMAL_ALIGNED_MEM` being required rather than optional
- `rvfi_macros.vh:3-13` — `` `rvformal_rand_reg `` needs `` `ifdef YOSYS ``
- `rvfi_insn_check.sv:88-89,164,167` — the rs-rdata rules
- `rvfi_liveness_check.sv`, `rvfi_causal_check.sv`, `rvfi_pc_{fwd,bwd}_check.sv`
  — the assume/assert structure behind F5b, P2 and P3

**No value in this file was produced by the DUT.** The spec models are
riscv-formal's; the failing assertion locations are sby's; the mutation
verdicts are status files.

`verilator --lint-only` clean across 12 modules with the define off and on.
