# vplan: RV32I base integer instruction set

**Spec:** RISC-V Unprivileged ISA, Chapter 2 (RV32I Base Integer Instruction Set)
**RTL:** `rtl/core/alu.sv`, `regfile.sv` — no decoder or datapath yet
**Env:** 1 — `docs/results/0004-alu-uvm-env1.md`

## Reading this file

Most rows below are **Partial** or **Deferred**, and the distinction is precise:

- **Partial** — the underlying *computation* is verified in a leaf block, but
  the *instruction* is not, because no decoder maps an encoding to it.
- **Deferred** — no implemented mechanism exists at all.

Neither means "not bothered with". They mean the RTL does not exist yet.
Env 1 verifies an ALU: it drives `alu_op_e` directly and has never seen a
32-bit instruction encoding. RV32I defines ~40 instructions; an ALU implements
11 operations. The gap between those numbers is M3.

## Integer register-register (OP)

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| `ADD` computation | §2.4 | UVM | 1 | `cp_op` (11 bins) | Covered | Y |
| `SUB` computation | §2.4 | UVM | 1 | `cp_op` | Covered | Y |
| `SLL` computation, shamt = `rs2[4:0]` | §2.4 | UVM | 1 | `cp_shamt` (7), `cp_b_ge_32` (2) | Covered | Y |
| `SRL` computation | §2.4 | UVM | 1 | `cp_op`, `cp_shamt` | Covered | Y |
| `SRA` sign-extends | §2.4 | UVM | 1 | `cp_op`, `cp_shamt` | Covered | Y |
| `SLT` signed comparison | §2.4 | UVM | 1 | `cp_op`, `x_op_operands` (343) | Covered | Y |
| `SLTU` unsigned comparison | §2.4 | UVM | 1 | `cp_op`, `x_op_operands` | Covered | Y |
| `XOR` / `OR` / `AND` | §2.4 | UVM | 1 | `cp_op` | Covered | Y |
| Decode of `funct7`/`funct3` to operation | §2.4 | — | — | none | **Deferred** | M3 |
| Operand sourcing from `rs1`/`rs2` | §2.4 | — | — | none | **Deferred** | M3 |
| Result writeback to `rd` | §2.4 | — | — | none | **Deferred** | M3 |

## Integer register-immediate (OP-IMM)

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| `ADDI`/`SLTI`/`SLTIU`/`XORI`/`ORI`/`ANDI` computation | §2.4 | UVM | 1 | shares `cp_op` with OP | **Partial** | Y |
| `SLLI`/`SRLI`/`SRAI` computation | §2.4 | UVM | 1 | `cp_shamt` | **Partial** | Y |
| I-type immediate sign-extension | §2.3 | — | — | none | **Deferred** | M3 |
| `shamt[5]` must be zero (illegal otherwise) | §2.4 | — | — | none | **Deferred** | M3 |

The computation is identical to the register-register form; only the operand
source differs. Marked Partial rather than Covered because immediate extraction
and sign-extension are unverified.

## Upper immediate

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| `LUI` result is the immediate | §2.4 | UVM | 1 | `cp_op` `ALU_PASS_B` | **Partial** | Y |
| `AUIPC` result is `PC + imm` | §2.4 | UVM | 1 | `cp_op` `ALU_ADD` | **Partial** | Y |
| U-type immediate formation (`imm[31:12]`) | §2.3 | — | — | none | **Deferred** | M3 |
| PC available as an ALU operand | §2.4 | — | — | none | **Deferred** | M3 |

## Control transfer

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| `BEQ` comparison | §2.5 | UVM | 1 | `cp_branch_op` (7 bins) | Covered | Y |
| `BNE` comparison | §2.5 | UVM | 1 | `cp_branch_op` | Covered | Y |
| `BLT` signed comparison | §2.5 | UVM | 1 | `cp_branch_op`, `x_op_branch` | Covered | Y |
| `BGE` signed comparison | §2.5 | UVM | 1 | `cp_branch_op` | Covered | Y |
| `BLTU` unsigned comparison | §2.5 | UVM | 1 | `cp_branch_op` | Covered | Y |
| `BGEU` unsigned comparison | §2.5 | UVM | 1 | `cp_branch_op` | Covered | Y |
| Branch comparison at the sign boundary | §2.5 | UVM directed | 1 | `alu_corner_seq` | Covered | Y |
| Branch target = `PC + imm` | §2.5 | — | — | none | **Deferred** | M3 |
| PC redirect on taken branch | §2.5 | — | — | none | **Deferred** | M3 |
| `JAL` link value = `PC + 4` | §2.5 | UVM | 1 | `cp_op` `ALU_ADD` | **Partial** | M3 |
| `JAL` target = `PC + imm` | §2.5 | — | — | none | **Deferred** | M3 |
| `JALR` target = `(rs1 + imm) & ~1` | §2.5 | — | — | none | **Deferred** | M3 |
| Misaligned instruction fetch exception | §2.5 | — | — | none | **Deferred** | M4 |

## Load and store

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| Address computation `rs1 + imm` | §2.6 | UVM | 1 | `cp_op` `ALU_ADD` | **Partial** | Y |
| `LB`/`LH`/`LW` sign-extension | §2.6 | — | — | none | **Deferred** | M3 |
| `LBU`/`LHU` zero-extension | §2.6 | — | — | none | **Deferred** | M3 |
| `SB`/`SH`/`SW` byte enables | §2.6 | — | — | none | **Deferred** | M3 |
| Misaligned load/store exception | §2.6 | — | — | none | **Deferred** | M4 |

## Memory ordering and environment

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| `FENCE` | §2.7 | — | — | none | **Deferred** | M4 |
| `ECALL` raises environment-call exception | §2.8 | — | — | none | **Deferred** | M4 |
| `EBREAK` raises breakpoint exception | §2.8 | — | — | none | **Deferred** | M4 |
| Illegal instruction on unknown opcode | §2.2 | — | — | none | **Deferred** | M4 |

## Register file behaviour

Covered fully by env 3 — see `04-microarch.md`.

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| `x0` reads zero | §2.1 | UVM | 3 | `cp_rs1`/`cp_rs2` x0 bins | Covered | Y |
| `x0` discards writes | §2.1 | UVM + RTL assert | 3 | `cp_write_x0` (2 bins) | Covered | Y (after fix) |
| 32 registers addressable | §2.1 | UVM | 3 | `cp_rs1`/`cp_rs2`/`cp_rd` (33 bins each) | Covered | Y |

## Summary for this file

| Status | Count |
|---|---|
| Covered | 19 |
| Partial | 8 |
| Deferred | 21 |

**The 21 Deferred rows are M3 and M4's specification.** Every one names a
mechanism that does not exist: the decoder, immediate formation, PC datapath,
memory interface, and exception generation.

**The 8 Partial rows are the cheaper half of M3**: the computation is already
verified in a leaf block, so what remains is wiring plus an instruction-level
environment to confirm the wiring.
