# vplan: Zicsr, traps and interrupts

**Spec:** RISC-V Unprivileged ISA Ch. 9 (Zicsr); Privileged Architecture,
machine-level ISA.
**RTL:** `rtl/core/csr.sv`
**Env:** 4 — `docs/results/0010-csr-uvm-env4.md`

## CSR access semantics

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| `CSRRW` writes, returns old value | Zicsr §9.1 | RAL + UVM | 4 | `cp_op` (3 bins) | Covered | Y |
| `CSRRS` sets bits | Zicsr §9.1 | UVM | 4 | `cp_op` | Covered | Y |
| `CSRRC` clears bits | Zicsr §9.1 | UVM | 4 | `cp_op` | Covered | Y |
| Read suppressed when `rd == x0` | Zicsr §9.1 | UVM directed | 4 | `cp_read` (2 bins) | Covered | Y |
| Write suppressed when `rs1 == x0` | Zicsr §9.1 | UVM directed | 4 | `cp_write` (2 bins) | Covered | Y |
| Suppression combinations | Zicsr §9.1 | UVM | 4 | `x_read_write` (4 cells) | Covered | Y |
| Every address × every operation | Zicsr | UVM | 4 | `x_addr_op` (54 cells) | Covered | Y |
| Write to read-only CSR raises illegal | Zicsr §9.1 | UVM directed | 4 | `cp_ro_write` (2), `cp_illegal` (2) | Covered | Y |
| Access to unimplemented CSR raises illegal | Zicsr §9.1 | UVM directed | 4 | `cp_illegal` | Covered | Y |
| **`CSRRWI`/`CSRRSI`/`CSRRCI` immediate forms** | Zicsr §9.1 | — | — | none | **Deferred** | M4 |
| **Write suppressed when `uimm == 0`** | Zicsr §9.1 | — | — | none | **Deferred** | M4 |

The immediate forms are architecturally distinct instructions with their own
suppression rule (`uimm == 0` rather than `rs1 == x0`). The CSR block sees only
`csr_wdata` and cannot distinguish them — the pipeline decodes which form was
issued. Deferred to M4 with the decoder.

## Register map

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| All 18 CSRs reset correctly | Priv. spec | **RAL `uvm_reg_hw_reset_seq`** | 4 | automatic, all registers | Covered | Y |
| Writable bits behave as declared | Priv. spec | **RAL `uvm_reg_bit_bash_seq`** | 4 | 9 registers bashed | Covered | Y |
| `misa` reports RV32IMC correctly | Priv. spec | RAL | 4 | `hw_reset` | **Covered — found a DUT bug** | Y |
| `mvendorid`/`marchid`/`mimpid`/`mhartid` read zero | Priv. spec | RAL | 4 | `hw_reset` | Covered | Y |
| `mstatush` exists and reads zero (RV32) | Priv. spec | RAL | 4 | `hw_reset` | Covered | Y |
| `mscratch` fully read-write | Priv. spec | RAL | 4 | `bit_bash` | Covered | Y |
| **Backdoor vs frontdoor consistency** | §5.2 skill | RAL `uvm_reg_access_seq` | 4 | 6 registers via `hdl_path` slices | Covered | — |

`uvm_reg_access_seq` verifies frontdoor writes against backdoor reads and the
reverse, on the six registers with a single flat storage element (`mie`,
`mtvec`, `mscratch`, `mepc`, `mcause`, `mtval`). The rest are excluded via
`NO_REG_ACCESS_TEST` because they have nothing for a backdoor path to point at:
`mip` is combinational from pins, `mstatus` is assembled from separate bits,
the counters are 64-bit split across two CSR addresses, and the info CSRs are
constants.

**Verified, not assumed.** Pointing one path at a non-existent signal produced
`uvm_hdl_dsim.c(130) ... unable to locate hdl path` — DSim's own DPI layer
reporting the failure — confirming the clean run had genuinely exercised the
backdoor rather than silently skipping every register.

This also confirms `mepc` and `mtvec` implement WARL **at the write**: the
stored value equals the read-back value, so backdoor and frontdoor agree. Had
the RTL masked on read instead, this sequence would have caught it.

## WARL fields

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| `mtvec.MODE` accepts writes, reads 0 | Priv. spec | RAL + RTL assert | 4 | `bit_bash`, field `RO` | Covered | — |
| `mepc[0]` accepts writes, reads 0 | Priv. spec, IALIGN=16 | RAL + RTL assert | 4 | `bit_bash`, field `RO` | Covered | — |
| `mstatus.MPP` reads 2'b11 (M-mode only) | Priv. spec | RAL + RTL assert | 4 | `bit_bash`, field `RO` | Covered | — |
| `mstatus` reserved fields read zero | Priv. spec | RAL | 4 | `bit_bash`, explicit RO fields | Covered | — |
| **`mtvec` vectored mode** | Priv. spec | — | — | none | **Waived** | direct mode only, D-decision 2026-08-12 |

## Traps

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| Trap captures `mepc` | Priv. spec | UVM directed | 4 | `csr_trap_seq` | Covered | — |
| Trap captures `mcause` | Priv. spec | UVM directed | 4 | `csr_trap_seq` | Covered | — |
| Trap captures `mtval` | Priv. spec | UVM directed | 4 | `csr_trap_seq` | Covered | — |
| `MPIE <= MIE`, `MIE <= 0` on trap | Priv. spec | UVM directed | 4 | `csr_trap_seq` | Covered | — |
| `mepc` bit 0 forced zero on trap entry | Priv. spec | UVM directed | 4 | `csr_trap_seq` | Covered | — |
| **Trap priority over concurrent CSR write** | design | UVM directed | 4 | `csr_trap_seq` | Covered | — |
| `MIE <= MPIE`, `MPIE <= 1` on `mret` | Priv. spec | UVM directed | 4 | `csr_trap_seq` | Covered | — |
| **Trap DETECTION (illegal instr, misaligned, ecall)** | Priv. spec | — | — | none | **Deferred** | M4 |
| **PC redirect to `mtvec` on trap** | Priv. spec | — | — | none | **Deferred** | M4 |
| **PC restore from `mepc` on `mret`** | Priv. spec | — | — | none | **Deferred** | M4 |
| **Exception cause encoding correctness** | Priv. spec | — | — | none | **Deferred** | M4 |

The CSR block holds trap state and updates it on command. It does not decide
*when* to trap — that is the pipeline's job at M4. Every Deferred row above is
detection or control flow, not state.

## Interrupts

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| `mip` reflects the interrupt pins | Priv. spec | UVM directed | 4 | `csr_irq_seq` | Covered | — |
| `mip` is read-only from software | Priv. spec | RAL + directed | 4 | field `RO`, excluded from bash | Covered | — |
| `mie` masks per source | Priv. spec | UVM directed | 4 | `csr_irq_seq` | Covered | — |
| `irq_pending` requires MIE ∧ mie ∧ mip | Priv. spec | UVM directed | 4 | `csr_irq_seq` | Covered | — |
| **Interrupt actually taken (pipeline)** | Priv. spec | — | — | none | **Deferred** | M4 |
| **Interrupt priority ordering** | Priv. spec | — | — | none | **Deferred** | M4 |
| **`mtime`/`mtimecmp` generation** | Priv. spec | — | — | none | **Deferred** | M5 (CLINT) |

## Counters

| Feature | Source | Method | Env | Coverage | Status | Mut |
|---|---|---|---|---|---|---|
| `mcycle` free-runs | Priv. spec | UVM directed | 4 | `csr_counter_seq` | Covered | — |
| `minstret` increments only on retire | Priv. spec | UVM directed | 4 | `csr_counter_seq` | Covered | — |
| 64-bit rollover across `mcycleh` | Priv. spec | UVM directed | 4 | `csr_counter_seq` | Covered | — |
| 64-bit rollover across `minstreth` | Priv. spec | UVM directed | 4 | `csr_counter_seq` | Covered | — |
| Counters writable by software | Priv. spec | UVM directed | 4 | `csr_counter_seq` | Covered | — |
| **`instr_retired` driven correctly by the pipeline** | design | — | — | none | **Deferred** | M3 |
| **Unprivileged shadows `cycle`/`instret`** | Priv. spec | — | — | none | **Waived** | U-mode not implemented (D1) |

## Summary for this file

| Status | Count |
|---|---|
| Covered | 34 |
| Deferred | 12 |
| Waived | 2 |

The CSR block is the most completely verified in the project — RAL's automated
sequences check every reset value and every writable bit without a test being
written for them, and they found the one real DUT bug in M1/M2 (`misa`).

Everything Deferred is *control flow* rather than *state*: when to trap, where
to jump, which interrupt wins. That is M4's specification.
