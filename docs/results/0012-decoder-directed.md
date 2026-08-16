# M3.1: RV32I decoder — directed verification

**Date:** 2026-08-17
**DUT:** `rtl/core/decoder.sv`, `rtl/core/imm_gen.sv`
**Method:** directed Verilator tests (ADR-0003 decision 2 — not UVM, reserving
DSim licence time for env 7)

## Result

| Metric | Value |
|---|---|
| Reference cases from the assembler | 221 |
| Illegal-instruction cases | 608 |
| Total checks | **4,592** |
| Failures | **0** |
| Mutations injected | 8 |
| Mutations caught | **8** (one only after extending the test set) |

## The reference is the RISC-V assembler

`gen_ref.py` assembles real RV32I instructions with `riscv64-unknown-elf-as`
and extracts their encodings via `objdump`. The harness feeds each encoding to
the DUT and checks the decode against expectations parsed from the **assembly
mnemonic**, independently of the RTL.

This is a stronger reference than anything used in M1/M2. Envs 1–4 compared
against models written from the spec by the same person who wrote the RTL — a
real risk, and env 4 proved it: the `misa` constant in the RTL and in the RAL
model were written independently and disagreed, and the RAL one was right.

Here the reference is the assembler that GCC and every RISC-V compiler targets.
If the decoder agrees with it, it agrees with the tool that generates the
programs this core will actually run.

Toolchain: `gcc-riscv64-unknown-elf` 10.2.0, `binutils` 2.35.1, invoked with
`-march=rv32i -mabi=ilp32`. The `rv32i/ilp32` multilib is present.

## Coverage of the case set

| Category | Cases | Targets |
|---|---|---|
| Register-register | 40 | all 10 R-type ops, randomised registers |
| Register-immediate | 42 | 6 ops x immediates 0, ±1, ±5, 2047, −2048 |
| Shift-immediate | 12 | `slli`/`srli`/`srai` at shift 0, 1, 15, 31 |
| Upper immediate | 8 | `lui`/`auipc` at 0, 1, 0xFFFFF, 0x12345 |
| Loads | 25 | 5 ops x offsets 0, ±4, 2047, −2048 |
| Stores | 15 | 3 ops x same offsets |
| Branches | 30 | 6 ops x offsets ±4, 8, 2044, −2048 |
| Jumps | 10 | `jal` at ±4, 8, ±1 MB; `jalr` at offset extremes |
| System / fence | 4 | `ecall`, `ebreak`, `fence`, `fence.i` |

Immediates cluster at the **sign boundaries** — 2047 and −2048 are the extremes
of a 12-bit signed field, and ±1 MB exercises the J-format's 20-bit split.

## Illegal-instruction detection

608 cases:

- **600 random encodings with `instr[1:0] != 2'b11`** — every RV32I opcode ends
  in `2'b11`; anything else is a 16-bit compressed instruction, which is M4.
- **8 directed bad opcodes** — unallocated majors (`0x0b`, `0x2b`, `0x5b`,
  `0x7b`), RV64-only `LD`/`SD` funct3 encodings, an unallocated branch funct3,
  and an OP with `funct7=0000001` (RV32M, which is M4 per ADR-0003).

## MUTATION TESTING

Per `docs/results/0011`, a checker that has never failed is a hypothesis. Three
faults injected, each a single-bit `funct3`/`funct7` distinction a careless
decoder gets wrong:

| Mutation | Failures | Verdict |
|---|---|---|
| `SRA` decoded as `SRL` (drop the `funct7[5]` test) | 4 | **CAUGHT** |
| `LBU` decoded as signed | 5 | **CAUGHT** |
| `BGE` decoded as `BGEU` | 5 | **CAUGHT** |

Counts match the case set exactly — 4 `srai` cases, 5 `lbu` cases, 5 `bge`
cases. Clean runs before and after; no mutants remain.

**These three are invisible without checking `alu_op` and `branch_op`.** The
first version of the harness checked only the boolean control signals and
passed all 3,478 checks while being unable to distinguish `ADD` from `XOR`. The
mutation discipline caught that gap before it was recorded as a result.

## Design decisions verified

- **`shamt_valid`**: for `SRLI`/`SRAI` the `funct7` field doubles as upper
  shift-amount bits, and RV32 requires `instr[31:26]` to be zero. `slli x1, x2, 32`
  is an illegal instruction, not a shift by 32. Distinct from the ALU's `b[4:0]`
  truncation, which handles a *register* shift amount at runtime.
- **Jump targets are not computed here.** `JAL`/`JALR` set `wb_sel = WB_PC4` so
  the ALU produces the link value; the target goes to the IF stage. This keeps
  the ALU — already the second-longest measured path — out of branch resolution.
- **`FENCE` decodes as a legal no-op.** Single hart, in-order, no store buffer,
  so memory is already sequentially consistent. A deliberate implementation
  choice, not an omission.
- **x0 writes are not suppressed in the decoder.** The register file discards
  them, verified across 25,097 transactions in env 3. One guard in one place —
  mutation testing showed redundant guards can hide a missing one.
- **`imm_gen` takes `instr[31:7]`, not the full word.** Bits [6:0] are the
  opcode and the format arrives as `fmt` from the decoder. Narrowing the port
  makes the dependency explicit: deciding format inside `imm_gen` would fail to
  compile rather than silently duplicating decode logic.

## Verilator note: packed struct flattening

Verilator flattens a packed struct output into one wide value —
`VL_OUT64(&ctrl,37,0)`, 38 bits — rather than named members. **Packed structs
pack MSB-first**: the first declared field occupies the highest bits, so
`rs1_addr` is `[37:33]` and `illegal` is bit 0.

The harness extracts fields with macros and carries a startup guard: drive
`instr = 0xffffffff`, confirm `rs1_addr` reads `0x1f`, abort with a clear
message otherwise. If `ctrl_t` gains a field, every bit position shifts and the
guard fires immediately rather than producing thousands of confusing
mismatches.

## Immediate generation — combined with the decoder

`imm_gen` is tested through `decode_top.sv`, a verification wrapper that wires
decoder and `imm_gen` as the pipeline will. Combined rather than standalone
because `fmt` is a decoder output: supplying it by hand would leave the
decoder-to-`imm_gen` connection unverified, and that connection is exactly where
a format mismatch would hide.

Expected immediates are computed in `gen_ref.py` from the ENCODING per the
spec's format tables — a second independent implementation of the bit
scrambling, in Python. Weaker independence than the encodings themselves (which
come from the assembler), but the assembler does not hand back the immediate as
a number, so some reimplementation is unavoidable. A disagreement means one of
two independent readings is wrong, adjudicated against the spec.

### MUTATION TESTING — five faults, and one SURVIVED

| Mutation | Failures | Verdict |
|---|---|---|
| B-type bit 11 from `instr[31]` instead of `instr[7]` | **0** | **SURVIVED** |
| J-type bit 11 from `instr[31]` instead of `instr[20]` | 2 | caught |
| B-type bit 0 not hardwired zero | 30 | caught |
| S-type immediate not sign-extended | 6 | caught |
| U-type immediate sign-extended (it must not be) | 6 | caught |

**The B-type bit-11 mutation produced zero failures.** Bit 11 of a B immediate
is the ±2048 boundary, and the mutation only changes the result when `instr[7]`
and `instr[31]` differ — that is, when bit 11 and the sign bit disagree.

The original branch offsets were 4, 8, −4, 2044, −2048. In every one of them
bit 11 equals the sign bit:

| Offset | Sign (bit 12) | Bit 11 | Differ? |
|---|---|---|---|
| 4, 8 | 0 | 0 | no |
| −4 | 1 | 1 | no |
| 2044 | 0 | 0 | no |
| −2048 | 1 | 1 | no |

To separate them requires an offset in +2048…+4094 (positive, bit 11 set) or
−4096…−2050 (negative, bit 11 clear). The B immediate spans ±4096, so those are
perfectly legal — the test set simply never generated one.

**Fix:** branch offsets extended to include 2048, 3000, 4094, −2050, −4096;
jump offsets likewise. Re-tested: the B mutation now produces **30** failures
(6 branch ops × 5 new offsets) and the J mutation **4**.

### Why this gap is harder to find than the env 3 one

Env 3's surviving mutant (`docs/results/0011`) was a REDUNDANCY problem — the
DUT had two independent x0 guards and removing one left the effect invisible
through the ports. Here nothing was wrong with the checker, the reference, or
the plumbing. **The test VALUES were insufficient.** 3,997 checks passing
against an external reference, correct wiring, and one specific bug class
entirely undetectable.

**Generalisable rule: for any field assembled from scattered bits, the test set
must include values where those bits DISAGREE.** Equal-bit cases cannot
distinguish which source a bit came from. This applies to B bit 11, J bit 11,
and to any future field with a non-contiguous encoding.

### `fmt` output
Not checked directly. It is exercised indirectly: a wrong `fmt` produces a wrong
immediate, which the 221 immediate checks would catch.
- **RV32M decode** is deliberately absent (ADR-0003). The verified muldiv stays
  disconnected until M4 — a visible cost of scope discipline.

## Reproducing

    cd verif/verilator/decoder
    make ref     # regenerate encodings from the assembler
    make run
