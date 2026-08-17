# M3.2: RV32I core bring-up

**Date:** 2026-08-17
**DUT:** `rtl/core/rv32_core.sv` plus `if_stage`, `lsu`, `tcm`, and the four
verified leaf blocks from M1
**Method:** hand-written assembly executed in Verilator, checked by mutation

## Result

| Program | Cycles | Retired | Verdict |
|---|---|---|---|
| `t01_alu` — arithmetic, logic | 56 | 48 | PASS |
| `t02_memory` — taken branches, loads, stores | 189 | 175 | PASS |
| `t03_checksum` — data-checked, golden `0x00fe396c` | 250 | 238 | PASS |

**Eight mutations injected, eight caught.**

Retirement rate is close to one instruction per cycle in steady state, so the
pipeline is genuinely pipelined rather than stalling.

## Scope

**No hazard handling.** No forwarding, no load-use interlock. Test programs
carry three NOPs between dependent instructions. That scaffold is removed at
M3.3.

Deliberate: PROJECT_INSTRUCTIONS section 7 names big-bang integration as a
failure mode. Building the pipeline and the hazard unit together means a failing
program has eleven possible causes. Gating on a NOP-padded program proves the
datapath first, so M3.3's failures can only be hazard failures.

The muldiv is not instantiated — RV32M decode is M4 per ADR-0003.

## Design decisions

**Memory map.** 8 KB TCM at `0x0000_0000`, so the PC resets to zero with no
reset-vector logic. Peripherals at `0x8000_0000`: bit 31 makes "is this a
peripheral?" a single-bit test rather than a range comparison.

**Test termination.** A store to `0x8000_0000` ends the run. For t01/t02 the
convention is zero = pass; t03 stores a checksum compared against a golden
value via `--expect`.

**Dual-port TCM.** Free in simulation. sky130's pre-built SRAMs are
SINGLE-port, so M7 needs either arbitration between fetch and data, or the
I-cache from PROJECT_CONTEXT 3.3 Phase 2. Recorded as deferred, not solved.

**Combinational memory reads.** Register-file behaviour, not SRAM behaviour. A
real sky130 SRAM returns data the following cycle, which changes the pipeline:
IF would need its address a cycle earlier and loads an extra stage or a stall.
Another M7 problem.

**Branches resolve in EX**, because the ALU carries the comparison
(PROJECT_CONTEXT 3.2). The redirect is REGISTERED before reaching `if_stage`,
costing a 3-cycle penalty instead of 2 — see the honest note below.

## BUG: the test program overwrote its own code

t02 initially used address 256 (`0x100`) for data. **That is inside the
instruction stream.** `sw x6, 0(x5)` overwrote a NOP with `0xdeadbeef`, and the
fetch unit later read it back as an instruction. `0xdeadbeef`'s low bits encode
a JAL, producing a jump to `0xfffdb6ea` — an odd address, which the `if_stage`
alignment assertion caught.

The core behaved correctly throughout. A unified TCM has no protection between
code and data; this is the same reason real cores need `FENCE.I` for
self-modifying code.

**Consequence for M5:** the linker script must place `.data` clear of `.text`,
and ACT4's linker script needs the same care.

### Five wrong hypotheses before the right one

Diagnosis took five round trips: pseudo-instruction expansion, truncated hex
image, a Verilator evaluation-order hazard, a registered-redirect fix, and only
then the actual cause.

**The decisive clue was available immediately.** An odd redirect target is
arithmetically impossible from either target expression — `ex_jalr_target` masks
bit 0, and `ex_branch_target` adds an always-even B-immediate to a word-aligned
PC. That should have pointed straight at "the inputs are not what I think",
not at the redirect logic.

One `$display` on the decoder's input settled in a single round what four rounds
of reasoning did not.

### The registered redirect is a fix for a misdiagnosis

`redirect_valid`/`redirect_pc` are now registered before reaching `if_stage`.
This was added believing there was an evaluation-order hazard between the
combinational redirect and `if_stage`'s sequential logic. **There was not.**

It is kept because it is defensible on its own merits — no dependence on
evaluation order, at the cost of a 3-cycle branch penalty instead of 2. Revisit
at M6 with the branch predictor, when branch cost actually matters. The RTL
comment records the same history.

## MUTATION TESTING

Eight faults, all caught. Four required extending the test programs first.

| # | Mutation | Caught by | Note |
|---|---|---|---|
| M1 | ALU operand B mux inverted | t01 | TCM range assertion |
| M2 | branch redirect never fires | **t03 only** | see below |
| M3 | load writeback returns the address | t02, t03 | |
| M5 | LBU sign-extends | t02, then t03 after fix | |
| M6 | byte enables ignore the offset | t02, t03 | |
| M7 | halfword load ignores the offset | **t03 only** | |
| M8 | halfword store ignores the offset | **t03 only** | |
| M9 | SRAI decoded as SRLI | t03 after fix | |
| M10 | ALU operand A mux ignores `alu_src_a_pc` | t03 after fix | |

### FINDING: a branch-checked program cannot detect broken branches

M2 survived t02 entirely. Every check in t02 is `bne ..., fail` — so disabling
branch redirects broke every check AND the jump to the failure handler
simultaneously. The program reported PASS while executing a different
instruction sequence.

t03 exists because of this. Each computed value is folded into an accumulator
with XOR and ADD, and the accumulator is stored to the test-control address.
**Correctness flows through DATA, not control flow.** A wrong result anywhere
produces a wrong stored value. The loop's effect is visible in the checksum
rather than in where execution goes.

### FINDING: four test-value gaps of the same shape

| Gap | Why the values could not distinguish |
|---|---|
| B-immediate bit 11 (M3.1) | every branch offset had bit 11 equal to the sign bit |
| Halfword offset | every halfword access was word-aligned, so offset bit 1 was zero |
| SRAI | shifted `x0`, and zero is invariant under both shift types |
| LBU vs LB | every loaded byte had bit 7 clear, so both extensions agree |

**All four have the same shape: the DUT computes a function of its inputs, and
the chosen inputs land where two different functions agree.** Coverage of the
OPERATION was complete; coverage of the DISTINGUISHING INPUT was not.

This is the discipline the UVM operand classes already encoded — envs 1-3
weighted `0x8000_0000` and `0xFFFF_FFFF` precisely because those are where
signed and unsigned diverge. Applying it to constrained-random stimulus and then
not applying it to hand-written assembly is the mistake.

**Relevant to M3.3:** a forwarding path that returns the STALE value is only
detectable when the stale and fresh values differ. Test programs must ensure
they do.

### FINDING: a surviving mutant is ambiguous

M9 survived twice. The second time was not a test gap — the `sed` used
`0,/pattern/s//` which replaces only the FIRST match, and `arith_shift ? ALU_SRA
: ALU_SRL` appears twice: line 79 under `OP_OP` (register-register SRA) and line
108 under `OP_OPIMM` (SRAI). t03 uses `srai`, so the mutation landed in a path
the test never exercises.

**A surviving mutant means either the test cannot detect the fault, or the fault
was not where you thought you put it.** I had been assuming the former every
time. Mutation scripts need to verify WHERE they mutated, not just that they
mutated something.

## Tooling problems worth recording

**`ld` needs `-m elf32lriscv`.** The toolchain is `riscv64-unknown-elf-*`; the
assembler honours `-march=rv32i -mabi=ilp32` but the LINKER has no such flags
and defaults to `elf64-littleriscv`, failing with "ABI is incompatible with that
of the selected emulation". The original `build.sh` hid this behind
`ld ... 2>/dev/null || ld ...`, so the failure was invisible.

**Exported DPI needs `svSetScope`.** Loading the TCM via `export "DPI-C"` aborts
with "scope wasn't set" unless the C side calls `svSetScope` with the instance
path first. Replaced with `$readmemh` driven by a `+HEX=` plusarg — no scope
machinery, universally supported.

**Make did not rebuild on RTL change.** Mutation runs silently reused a stale
binary, producing bit-identical results across four different mutations. Fixed
by deleting the binary before each run. Third occurrence of this failure class
in the project, after the SDC `.replace()` no-ops and the
`MAX_FANOUT_CONSTRAINT` sweep.

**Harness bug: sign overloading.** `result` was an `int` initialised to -1
meaning "not assigned", and `if (result < 0)` reported TIMEOUT. A checksum of
`0xeffe3c3e` is negative as a signed int, so a correct run was reported as a
timeout. Replaced with a separate `done` flag.

## Lint findings: same warning, three correct responses

`UNUSEDSIGNAL` appeared four times across M3.1 and M3.2:

| Case | Response | Why |
|---|---|---|
| `imm_gen` ignoring the opcode | narrow the port | no business with those bits |
| `lsu` ignoring `addr[31:2]` | narrow the port | no business with those bits |
| `tcm` ignoring the upper address | **detect and report** | those bits mean "out of range" |
| `if_pc_plus4` | **delete** | genuinely duplicated logic |
| `mem_misaligned` | **route out** | deferred feature, must stay visible |

The tool says the same thing every time. Whether it is a design smell or an
interface mismatch is a judgement no tool makes for you. The TCM's out-of-range
detection — added because of one of these warnings — later caught mutation M1.

## Not verified

- **Hazards.** No forwarding, no interlock. Programs are NOP-padded. M3.3.
- **Instruction-level RV32M.** The muldiv is disconnected. M4.
- **Misaligned access traps.** `mem_misaligned_o` is produced and unconsumed.
- **Illegal instruction traps.** `ctrl.illegal` is produced and unconsumed.
- **Independent reference.** The golden checksum is what a core passing all
  eight mutations produces, not an externally derived value. M3.5's Sail
  lockstep supersedes this.

## Reproducing

    cd sw/tests && ./build.sh t03_checksum.S
    cd verif/verilator/core
    make run HEX=../../../sw/tests/t03_checksum.hex EXPECT=0x00fe396c
