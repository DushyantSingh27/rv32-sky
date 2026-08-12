# M1: CSR block standalone hardening

**Date:** 2026-08-12
**Design:** `rtl/core/csr.sv` - M-mode Zicsr, 20 CSRs
**Run:** `flow/csr/runs/RUN_2026-08-12_20-28-20`

## Tool and PDK versions
| Item | Value |
|---|---|
| LibreLane | v3.0.5 (AppImage) |
| PDK | sky130A, hash `8afc8346a57fe1ab7934ba5a6056ea8b43078e71` (2025.07.14) |
| Standard cells | `sky130_fd_sc_hd` |
| Constraints | `flow/constraints/block.sdc` (authored, estimates) |

## Exact command

    ~/librelane-devshell-x86_64.AppImage
    cd ~/dev/rv32-sky/flow/csr && librelane config.yaml

`USE_SLANG: true`, `CLOCK_PORT: clk`, `CLOCK_PERIOD: 20`, `FP_CORE_UTIL: 40`,
`PL_TARGET_DENSITY_PCT: 50`, `MAX_FANOUT_CONSTRAINT: 6`.

## Result

**Closes 50 MHz with zero setup and zero hold violations at every corner.**
Zero inferred latches.

| Metric | Value |
|---|---|
| Instance area | 48,748 um^2 |
| Standard cells | 2,765 |
| Sequential cells | 319 |
| Max slew violations | 173 (slow corners) |
| Max cap violations | 6 |

### Flop count check

Expected storage: `mcycle` 64 + `minstret` 64 + `mie` 32 + `mtvec` 32 +
`mscratch` 32 + `mepc` 32 + `mcause` 32 + `mtval` 32 + `mstatus` 2 = **322**.

Measured **319**. The three-flop difference is consistent with synthesis
removing the hardwired-zero low bits of `mtvec` (bits [1:0], MODE) and `mepc`
(bit [0], IALIGN=16) - both WARL fields that can only ever read zero.

`mip` correctly costs no storage: it is driven combinationally from the
interrupt pins, not latched.

## AREA PER FLOP ACROSS ALL FOUR M1 BLOCKS

| Block | Instance area | Std cells | Flops | um^2 per flop |
|---|---|---|---|---|
| ALU (registered harness) | 27,705 | 1,811 | 104 | 266 |
| **CSR** | **48,748** | **2,765** | **319** | **153** |
| muldiv | 99,711 | 5,340 | 578 | 172 |
| regfile | 147,663 | 7,938 | 992 | 149 |

The CSR block and the register file cost almost identically per flop - 153 vs
149 um^2 - despite entirely different structures. The register file is dominated
by two 32-to-1 read muxes; the CSR block by a 20-way address decode and write
mux.

**Inference (T4):** flop-based storage on sky130 costs roughly 150 um^2 per bit
including surrounding logic, largely independent of what that logic does. The
ALU is the outlier at 266 because its 104 flops are a measurement harness around
a large combinational block, not storage.

This strengthens the D4 case: the register file is not expensive because of a
design flaw, it is expensive because 992 flops is 992 flops. See
`docs/results/0007-regfile-standalone.md`.

## Design decisions recorded

- **Scope**: this block holds state and updates it on command. Trap DETECTION
  lives in the pipeline (M4) and arrives as `trap_valid` plus cause/epc/tval.
  Interrupt pins come from the CLINT (M5); this block latches and reports.
- **Read and write suppression arrive as separate strobes.** `CSRRW` with
  `rd == x0` must not read; `CSRRS`/`CSRRC` with `rs1 == x0` must not write -
  not "write the unchanged value", but perform no write. Decoding that in the
  pipeline keeps this block free of instruction-format knowledge.
- **Writes to read-only CSRs raise illegal instruction**, not a silent drop.
  Address bits [11:10] == 2'b11 marks a CSR read-only.
- **WARL implemented at the write, not the read.** `mepc_q <= {wval[31:1],1'b0}`
  stores the legal value rather than storing everything and masking on read.
  Both are architecturally equivalent, but storing the legal value means the
  backdoor path in env 4's RAL model sees what the frontdoor read returns -
  which matters when `uvm_reg_access_seq` compares the two.
- **Priority: trap, then mret, then software write.** A trap arriving in the
  same cycle as a `CSRRW` to `mepc` must win - the return address matters and
  the instruction is about to be abandoned. Getting this order wrong corrupts
  `mepc` under interrupt load, which is close to impossible to debug from
  software.
- **misa read-only**, mtvec **direct mode only** (MODE hardwired 0),
  unprivileged counter shadows (`cycle`, `instret`) omitted - they are only
  meaningful with U-mode and D1 fixes M-mode only. Revisit at M7.

## Register map

Machine info (read-only): `mvendorid` 0xF11, `marchid` 0xF12, `mimpid` 0xF13,
`mhartid` 0xF14 - all zero.

Trap setup: `mstatus` 0x300 (MIE, MPIE, MPP hardwired 2'b11), `misa` 0x301
(read-only, RV32IMC), `mie` 0x304, `mtvec` 0x305, `mstatush` 0x310 (zero,
required to exist in RV32).

Trap handling: `mscratch` 0x340, `mepc` 0x341, `mcause` 0x342, `mtval` 0x343,
`mip` 0x344 (read-only from software, driven by pins).

Counters: `mcycle`/`mcycleh` 0xB00/0xB80, `minstret`/`minstreth` 0xB02/0xB82.

## Caveats

1. Constraints are estimates for standalone characterisation, not signoff.
2. 173 max-slew and 6 max-cap violations at slow corners - the same pattern seen
   in every block. Not functional failures.
3. `Odb.CheckDesignAntennaProperties`: one input pin without antenna gate
   information, plus one similar. Not investigated; likely the clock or reset
   port at a block boundary with nothing driving it.
4. **Not yet functionally verified.** UVM env 4 (RAL) is next. These numbers
   describe a design whose WARL behaviour, read/write suppression and trap
   priority have not been checked.

## M1 STATUS: all four leaf blocks hardened

| Block | Timing | Area | Verified |
|---|---|---|---|
| ALU | 50 MHz | 27,705 um^2 | env 1, 100% |
| muldiv | 43.5 MHz | 99,711 um^2 | env 2, 100% |
| regfile | 50 MHz | 147,663 um^2 | env 3, 100% |
| CSR | 50 MHz | 48,748 um^2 | env 4 pending |

Total leaf-block area, excluding the ALU's measurement harness:
approximately **324,000 um^2**. The muldiv is the only block that does not close
50 MHz standalone.
