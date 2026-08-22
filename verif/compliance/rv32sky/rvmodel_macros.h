// rvmodel_macros.h - RV32-SKY
// HTIF termination, matching verif/sail/ and the M3.5 lockstep harness.
// SPDX-License-Identifier: Apache-2.0

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 8; .global tohost; tohost: .dword 0;         \
        .balign 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

// STANDARD_SM_SUPPORTED deliberately NOT defined: no M-mode CSRs.

///// STARTUP /////

#define RVMODEL_BOOT

// Defined BLANK to bypass the boot process. Per the upstream comment: "If no
// M-mode or CSRs are implemented, define this macro as blank." rtl/core/csr.sv
// is not in rtl/files.f and decoder.sv flags OP_SYSTEM illegal, so any CSR
// instruction in the boot path would retire as an unreported no-op.
#define RVMODEL_BOOT_TO_MMODE

// RVMODEL_ACCESS_FAULT_ADDRESS deliberately NOT defined: tcm.sv detects
// out-of-range access but rv32_core.sv does not consume the flag (M4).

///// TERMINATION /////

// Both 32-bit halves of the 64-bit tohost are written INSIDE the loop.
// A single store is ignored by Sail HTIF and produced a 10.5 GB trace
// (PROJECT_CONTEXT.md §9, verified 2026-08-20).

#define RVMODEL_HALT_PASS   \
  li x1, 1                 ;\
  la t0, tohost            ;\
  write_tohost_pass:       ;\
    sw x1, 0(t0)           ;\
    sw x0, 4(t0)           ;\
    j write_tohost_pass    ;\

#define RVMODEL_HALT_FAIL   \
  li x1, 3                 ;\
  la t0, tohost            ;\
  write_tohost_fail:       ;\
    sw x1, 0(t0)           ;\
    sw x0, 4(t0)           ;\
    j write_tohost_fail    ;\

///// IO /////

#define RVMODEL_IO_INIT(_R1, _R2, _R3)

// HTIF console putc: character to tohost[31:0], then device=1 cmd=1 to
// tohost[63:32]. The harness must distinguish this from termination.
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)  \
1:                            ;                        \
  lbu _R1, 0(_STR_PTR)        ;                        \
  beqz _R1, 3f                ;                        \
2:                            ;                        \
  la _R2, tohost              ;                        \
  sw _R1, 0(_R2)              ;                        \
  li _R1, 0x01010000          ;                        \
  sw _R1, 4(_R2)              ;                        \
  addi _STR_PTR, _STR_PTR, 1  ;                        \
  j 1b                        ;                        \
3:

///// INTERRUPTS - none implemented /////
// Defined empty rather than omitted so a stray reference assembles to nothing
// instead of failing the build. No CLINT, no interrupt pins consumed.

#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif // _RVMODEL_MACROS_H
