# 0029 — Structural coverage found four CSR conformance bugs that every other check had passed

**Dates:** 2026-10-17 to 2026-10-20
**Milestone:** M3.7 stage 2 (found while classifying the uncovered points of docs/results/0028)
**DUT:** `rtl/core/csr.sv`, `rtl/core/rv32_core.sv`, `rtl/pkg/rv32_pkg.sv`
**Reference:** Sail RISC-V 0.13.1, `verif/sail/rv32sky.json`
**Tools:** Verilator 5.050 (`v5.050-60-g3d2421f3b`, `~/.local/bin`, the
`tools/guards.mk` pin); `riscv64-unknown-elf-as/ld` via `sw/tests/build.sh`;
ACT4 via `verif/compliance/rv32sky/run_compliance.sh`; riscv-formal with Yosys
0.69+152 (`6f876ae0e-dirty`) and SBY from the OSS CAD Suite (0026).
**Commits:**

| Commit | What |
|---|---|
| `f9fce38` | fix(rtl): mie is WARL - only MSIE, MTIE and MEIE are writable |
| `8889787` | verif(sail): model Zicntr so the counters can be lockstep-checked (ADR-0008) |
| `6537eb2` | fix(rtl): minstret counts at EX, excludes traps and the writing instruction |
| `2018941` | verif: kill M3, measure H1d (minstreth write semantics) - csr.sv comment only |
| `238ca54` | test: t07_counters joins the regression set |

**Status:** Four bugs fixed and mutation-tested. Regression green. One known-stale
model left deliberately unchanged (env 4, below).

---

## Result

| # | Bug | Measured against Sail | Fix |
|---|---|---|---|
| H2 | `mie` stored all 32 bits; it is WARL | `csrw mie, -1` then read: Sail `0x00000888`, core `0xffffffff` | `f9fce38` |
| H1 | a `csrr minstret` missed older instructions still in MEM/WB | read behind three ALU instructions: Sail 7, core 5 | `6537eb2` |
| H1b | a trapping instruction was counted | after an `ecall` and its handler: Sail 10, core 11 | `6537eb2` |
| H1c | the instruction writing `minstret` was counted on top of the written value | write 100, read two instructions later: Sail 102, core 103 | `6537eb2` |

Before these were found, the core passed **all** of the following:
lockstep against Sail (6 programs, 800 instructions), ACT4 (47 of 47),
riscv-formal (45 of 45, 0026), the decoder harness (6,882 checks), and 100%
functional coverage on four UVM environments.

**Why each check missed them.** Every one verified what it was exercised on,
and nothing exercised this:

- **Lockstep:** no program read `minstret` or wrote any counter.
  `t05_csr.S` excluded all four counters because "Sail has no model of this
  pipeline" - true of `mcycle`, not of `minstret`, which is architectural. The
  real reason they could not be checked was different and was invisible:
  with `Zicntr` disabled in our Sail config, Sail does not implement `minstret`
  at all (measured below). `t05_csr.S` wrote `mie = 0x808`, legal bits only,
  where a 3-bit and a 32-bit register agree.
- **riscv-formal:** the CSR checks (`csrw`, `csr_ill`, `csrc_*`) were never
  enabled (`checks.cfg`, Stage 2 absent).
- **ACT4:** none of its 47 tests read `minstret` at all - `csr.sv`:114 had
  zero line coverage across the merged ACT4 runs (0028, step 7). The one
  suite known to arm `mie`, `InterruptsSm`, is excluded (0023,
  `run_compliance.sh`).
- **Env 4 (UVM, CSR block alone):** drives `instr_retired` as a pin, so the
  pipeline timing of the real core was outside its scope; and its register
  model declared `mie` fully read-write (below).

**What found them:** M3.7 structural coverage (0028) left five `csr.sv` lines
uncovered - line 114 (read `minstret`) and 194-197 (write each counter half) -
and 62 of `mie_q`'s 64 toggle points. Classifying those points meant asking
what would reach them; the probes below are the answers.

---

## Measurements

Every probe is in `sw/tests/`, committed with the fix it is evidence for. Each
settles one question; its header carries the prediction, **written before the
run**. All values T1.

| Probe | Run | Question | Prediction | Sail | Core before fix | Core after |
|---|---|---|---|---|---|---|
| `probe_mie` | 2026-10-17 | is `mie` WARL? | core `0xffffffff`, Sail a subset | `0x888` | `0xffffffff` | `0x888` (`f9fce38`) |
| `probe_minstret` | 2026-10-17 | read A (pipeline drained by a taken branch) / read B (two older instructions in MEM/WB) | Sail 3/7, core 3/5 | Zicntr **off**: **traps** (mcause 2, mtval `0xb02022f3`); Zicntr on: 3/7 | 3/5 | 3/7 |
| `probe_minstret_trap` | 2026-10-17 | does a trapping `ecall` count? | Sail 10, core 11 | 4/**10** | 4/**11** | 4/10 |
| `probe_minstret_write` | 2026-10-17 | read right after `csrw minstret` | core 100/103; Sail either 100/102 or 101/103 | 100/**102** | 100/**103** | 100/102 |
| `probe_minstret_carry` | 2026-10-19 | does the write-suppression term matter for a low-half write? (why M3 survived) | Sail 0, core 0, M3 mutant 1 | 0 | - | 0; M3 1 |
| `probe_minstreth_write` | 2026-10-19 | H1d: does writing `minstreth` stop the low half's increment? | no Sail prediction; core 8 | **8** | - | 8 |
| `probe_mcycle` | 2026-10-19/20 (log undated) | how does Sail advance `mcycle`? | no prediction | **6** over 12 instructions | - | 12 over 12 |

**Zicntr, measured before it was changed** (2026-10-17, temporary copy of the
config, one key flipped): Sail accepted the configuration with the CLINT still
disabled, and the six regression programs still agreed and passed - 6 of 6,
800 instructions, identical to the baseline. Recorded in ADR-0008.

**Isolation.** Each `minstret` probe drains the pipeline with a taken branch
before its read, so H1 cannot move the H1b/H1c values. A taken branch costs two
cycles here (`rv32_core.sv`:15), so MEM and WB hold bubbles at the read.

**Sail's `mcycle` rate** - half the instruction rate in the one window
measured - is recorded, not explained (T5 for the cause). Both models are
right: the spec says `mcycle` counts cycles, and a model has none. Only the
64-bit carry is compared.

---

## The fixes

**`f9fce38` - mie.** `MIE_WRITABLE` in `rv32_pkg.sv`, built from the
`IRQ_*_BIT` names, and `csr.sv` writes `wval & MIE_WRITABLE`.

**`8889787` - Sail models Zicntr (ADR-0008).** One key in `rv32sky.json`, with
a comment. The documented mismatch: Sail also models `cycle`/`time`/`instret`
(0xC00-0xC02, 0xC80-0xC82), which the core does not. A program touching them
diverges loudly; it cannot make a wrong core look right. Revisit at M5.

**`6537eb2` - minstret.** Counted as an instruction **leaves EX**, valid and
not trapping, instead of from `mem_wb_q.valid` in WB:

    rv32_core: .instr_retired (id_ex_q.valid && !ex_trap_valid)
    csr:       if (instr_retired && !writes_minstret) minstret_q <= minstret_q + 64'd1;

A `csrr` reads in EX, so every older instruction has already left EX and been
counted (H1). `!ex_trap_valid` excludes trapping instructions (H1b).
`writes_minstret` - a write to either half - excludes the writing instruction
(H1c, H1d).

**It rests on two invariants**, recorded in `csr.sv` and carried as standing
risks:
1. nothing faults after EX - true today (no access faults; misaligned accesses
   trap in EX); M4 bus faults or M5 interrupts in MEM would break it;
2. every instruction occupies EX for exactly one cycle - true today; a
   multi-cycle `muldiv` at M4 would count once per cycle.

**Why the write-suppression term mostly does nothing** (found by M3 surviving,
explained by `probe_minstret_carry`). Since `6537eb2` the writing instruction's
increment and its write land on the same clock edge. The increment assigns all
64 bits, the write then assigns `[31:0]`, and the later nonblocking assignment
wins for those bits. So for a low-half write the term matters only when the
increment would **carry** into `[63:32]`. For a `minstreth` write it is what
stops the low half incrementing (H1d). Both cases now have a killing test.

---

## Gates

| Commit | Gate (all passed) |
|---|---|
| `f9fce38` | `probe_mie` agrees; lockstep 6 of 6, 800; decoder harness 6,882 checks, 0 failures; ACT4 47 of 47 |
| `8889787` | lockstep 6 of 6, 800; `probe_mie` agrees; **before-fix controls**: the three `minstret` probes diverge under the committed config |
| `6537eb2` | all four probes agree; lockstep 6 of 6, 800; decoder 6,882/0; ACT4 47 of 47 |
| `2018941` | diff asserted comment-only (13 lines, 0 not comments); lockstep 6 of 6, 800; all six probes agree; M3c killed |
| `238ca54` | t07 agrees, 104 instructions; M0-M5 each make t07 diverge; lockstep **7 of 7, 904**; `run_coverage.sh` COMPLETE, 55 runs |

**riscv-formal at `2018941`** (2026-10-19, OSS CAD Suite shell): 45 of 45 PASS,
53 s wall, RTL link checked to resolve to `~/dev/rv32-sky/rtl`. A regression
result only: no check reads `minstret` or `mie`. The log carries 111 "Latch
inferred" warnings, all in riscv-formal's own checker
(`rvfi_insn_check.sv:133`, its loop variable; 37 instruction checks x 3) and
none in our RTL. `238ca54` changes no RTL, so neither formal nor ACT4 was
re-run for it.

---

## Mutations

Each reverts one part of the fixes on a clean committed tree, is restored with
`git checkout`, and the tracked tree is asserted clean afterwards.

| # | Mutation | Killed by | Verdict |
|---|---|---|---|
| M0 | `mie` mask removed | `probe_mie`; t07 | KILLED |
| M1 | `instr_retired = mem_wb_q.valid` (count in WB again) | all three `minstret` probes; t07 | KILLED |
| M2 | `instr_retired = id_ex_q.valid` (count traps) | `probe_minstret_trap` only; t07 | KILLED |
| M3 | `&& !writes_minstret` removed | **survived all four probes** (2026-10-19); then `probe_minstret_carry`; t07 | KILLED, second round |
| M3b | suppression for `CSR_MINSTRET` only | `probe_minstreth_write` | KILLED |
| M3c | suppression for `CSR_MINSTRETH` only | `probe_minstret_carry` | KILLED |
| M4 | `mcycle` incremented as 32 bits (no carry) | t07 (`mcycleh` 5 vs 6) | KILLED |
| M5 | `minstret` incremented as 32 bits (no carry) | t07 (`minstreth` 0 vs 1) | KILLED |

M1's three-way kill and M2's single kill together show the probes isolate their
defects: each reverts a different part, and the probe set says which.

---

## t07_counters

`sw/tests/t07_counters.S` keeps every case above checked on every run, each
read placed where a plausible-wrong design differs - the wrong design is named
in the source beside each section. Lockstep is the check; the program stores 0
on completion and no golden value is derived from the core. It never reads
`mcycle`'s low half or `cycle`/`time`/`instret`.

Its header listed three predicted risks before the first run:

| Risk | Prediction | Outcome |
|---|---|---|
| R1 | Sail advances `mcycle` at least once per instruction, so 24 instructions after writing `0xfffffff0` carry | **REFUTED** 2026-10-19: Sail `mcycleh` 5, core 6. `probe_mcycle` then measured half rate. Section 6 now writes `0xfffffff8` and allows 40 instructions: holds at one increment per 5 instructions. |
| R2 | Sail stores `mcause = -1` as written (WLRL) | held: `0xffffffff` in both |
| R3 | `mtvec = 0xfffffffc` reads back as written | held |

---

## Coverage, before and after

`rtl/core`, `run_coverage.sh`, Verilator 5.050:

| | `a68a279` (2026-10-17) | `238ca54` (2026-10-20) | §5.3 target |
|---|---|---|---|
| Line | 221/238 = 92.86% | 227/239 = 94.98% | ≥95% |
| Branch | 68/72 = 94.44% | 68/72 = 94.44% | ≥95% |
| Toggle | 7,881/8,970 = 87.86% | 8,246/8,972 = 91.91% | ≥90% |

`csr.sv`: line 38/43 → 44/44; toggle 788/1,410 → 1,117/1,412. The denominators
grew by one line and two toggle points: the new `writes_minstret`. The 12
uncovered lines left are exactly the 12 classified unreachable in 0028; the
branch gap is the four decoder sub-encodings, not yet addressed. Both are
0028's to close.

---

## Known stale, deliberately not changed

- **Env 4's register model** (`verif/uvm/ral/csr_ral_pkg.sv`): `mie` is
  `csr_reg_rw` (all 32 bits RW, now wrong); `misa` reset `0x4000_1104`
  ("C, I, M"; the core is `0x40000100`); `mepc` models only bit 0 read-only
  (the core forces `[1:0]`, `MEPC_LSB_ZEROS = 2`). Env 4 has had no runnable
  recipe since the DSim shutdown (ADR-0006) - only env 7 and the coverage probe
  have Verilator recipes - and editing a model that cannot be run would be an
  unverified change. Belongs with the deferred ADR-0007 re-hosting.
- **`csr.sv` header comment** still says "mepc[0] (reads 0, IALIGN=16 with the
  C extension)"; the code and `rv32_pkg.sv` are right (IALIGN=32).

## Observations

- **HTIF exit codes lose bit 31.** t03-t06 write `(checksum << 1) | 1` to
  tohost, and Sail prints the code shifted back: `0x82a4c825` → `0x02a4c825`,
  `0xc2ffe562` → `0x42ffe562` (seen 2026-10-17). Lockstep never uses the code,
  so nothing is affected, but it cannot serve as a checksum for any program
  whose checksum has bit 31 set.
- **Sail asserts `mip.MTIP`** in every trace (`CSR mip <- 0x00000080`), as
  0017 recorded. Every probe and t07 clear `mstatus.MIE` first.

---

## My errors on the way

Recorded per §5.2: the wrong turns are part of the result.

1. **A test value where the correct and mutated designs agree** - failure mode
   #1, in a probe I designed. `probe_minstret_write` wrote 100 over a count of
   3, where no carry can happen, so mutation M3 survived all four probes. Found
   only because the mutation round ran.
2. **An edit helper that was not atomic** - failure mode #2, inside the tool
   meant to prevent it. A test re-run before delivery: the `rv32_pkg.sv` anchor
   still matched after the first run, so the second inserted `MIE_WRITABLE`
   twice, then failed on `csr.sv` - a corrupted package behind a loud error.
   Fixed before delivery: every file is checked before any is written, and an
   edit whose replacement is already present is refused.
3. **t07 risk R1** - I assumed Sail advances `mcycle` once per instruction. It
   was written down as a risk before the run, which is why the divergence
   was read in minutes rather than debugged.
4. **The env 4 question was framed around a DSim licence**, from an August
   snapshot of PROJECT_CONTEXT; the project had moved to Verilator for UVM
   (ADR-0006). The read of `verif/uvm` settled it.
5. **A wrong claim in a probe header, corrected before the run:** I first
   wrote that `compare.py` stopping at a divergence meant read B would go
   unread. Both models run to completion; only the verdict stops. The run
   script reads both traces.

---

## Standing risks added

- The two `minstret` invariants above - **M4 must revisit both** before any
  fault source after EX or any multi-cycle EX operation.
- ADR-0008's mismatch: no program may touch `cycle`/`time`/`instret` until the
  core implements them.
- Sail's `mcycle` rate is measured once, unexplained. t07 allows a 2.5x margin
  over it.

---

## Reproduce

    # plain shell (NOT the OSS CAD Suite one - 0026)
    cd ~/dev/rv32-sky
    make -f tools/guards.mk check-verilator
    bash verif/sail/run_lockstep.sh                  # 7 of 7, 904 instructions
    for p in probe_mie probe_minstret probe_minstret_trap probe_minstret_write \
             probe_minstret_carry probe_minstreth_write; do
      bash verif/sail/run_lockstep.sh $p; done       # each 1 of 1
    bash verif/compliance/rv32sky/run_compliance.sh  # 47 of 47
    bash verif/verilator/coverage/run_coverage.sh    # COMPLETE, 55 runs

    # probe_mcycle is NOT a lockstep program (mcycle's low half differs by
    # design): run Sail and the core trace separately and compare the deltas.

The mutation and gate scripts were run from `~/scratch/m37/` and are not
committed; their logic is described above and every number in this file came
from their logs.
