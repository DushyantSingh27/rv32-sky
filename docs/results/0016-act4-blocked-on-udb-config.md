# M3.4: ACT4 compliance - flow stood up, blocked at UDB config generation

**Date:** 2026-08-21
**Status:** BLOCKED. Not a failure of the DUT; a structural limit of the ACT4
configuration layer for a core with no machine-mode state.

## Tool versions

| Item | Value |
|---|---|
| ACT4 | `riscv-arch-test` branch `act4`, commit `8693fd9` |
| udb gem | 0.1.15 (via bundler 4.0.18, Ruby 3.4.10) |
| udb-gen | 0.1.14 |
| act framework | installed via `uv` from `framework/`, CPython 3.14.6 |
| Compiler | GCC 16.1.0 (`g6afcc4f6d`), binutils 2.46, riscv-collab nightly `2026.07.15` |
| Reference model | Sail RISC-V 0.13.1 |

## What was completed

- `verif/compliance/rv32sky/link.ld` - `RAM_ORIGIN = TEST_BASE = 0x0` matching
  `RESET_VECTOR` in `rtl/pkg/rv32_pkg.sv`; `RAM_LENGTH = 0x40000`.
- `verif/compliance/rv32sky/rvmodel_macros.h` - HTIF termination, both 32-bit
  halves of `tohost` written inside the loop (see `docs/results/0015`).
  `RVMODEL_BOOT_TO_MMODE` defined blank per the documented CSR-less bypass.
- `verif/compliance/rv32sky/test_config.yaml` - absolute paths to the GCC 16
  toolchain, leaving the 10.2.0 toolchain untouched so M3.1's 4,592 decoder
  checks remain reproducible.
- `rtl/mem/tcm.sv` - `SIZE_BYTES` parameter added, defaulting to
  `TCM_SIZE_BYTES` so the synthesised path and all existing harnesses are
  byte-identical. Lint passes.
- Toolchain SHA-256 verified against the GitHub release digest.
- Bundler 2.6.9 / `.mise.toml` 4.0.18 mismatch resolved itself: ACT4 detected
  it, installed 4.0.18 and restarted. 75 gems installed. Open item closed.

## The blocker, measured

The UDB config must declare the implemented extension set. This core is RV32I
plus `Zifencei`, with NO Zicsr and NO trap path (`rtl/core/csr.sv` exists and
is verified standalone but is not in `rtl/files.f` and not instantiated).
All four available config types were tested:

| `type:` | `MXLEN` | Result |
|---|---|---|
| `fully configured` | present | REJECTED - "Parameter is not defined by this config: 'MXLEN'. Failing condition(s): `Sm>=0`{false}". Same for PHYS_ADDR_WIDTH, M_MODE_ENDIANNESS, MISALIGNED_LDST. |
| `fully configured` | absent | REJECTED - "Must set MXLEN for a full config" |
| `partially configured` | present | UDB CRASH - `Cannot represent true/false in DIMACS (RuntimeError)`, `udb/logic.rb:3378` in `to_dimacs`, reached from `cfg_arch.rb:444 partial_config_valid?` |
| `unconfigured` | present | Validates. But `udb-gen` refuses: "Config 'rv32sky' is not fully configured. Only fully configured configs are supported." `extensions.txt` never written. |

`MXLEN` is defined only under the `Sm` (machine-mode) extension, yet is
referenced by `register_file/X.yaml` - the base integer register file that the
I extension requires. `udb-gen` accepts only `fully configured`. Therefore no
valid ACT4 configuration exists for a core without machine-mode state.

Control: `udb validate cfg config/cores/cve2/cv32e20/cv32e20.yaml` reports
"Config cv32e20 is valid". The gem installation is sound; the limitation is in
the configuration model, not in this setup.

## Hypotheses tested and rejected

1. **"ACT4 tests require CSRs in their preamble" (T5).** REJECTED by
   measurement. The reference `rvmodel_macros.h` documents the opposite: "If no
   M-mode or CSRs are implemented, define this macro as blank to bypass the
   boot process." `test_config.yaml` carries a second lever,
   `include_priv_tests: False`. The test layer supports a CSR-less DUT.
2. **"The minimal config under-specifies parameters."** REJECTED. It
   over-specified: all four declared parameters were Sm-scoped and invalid
   without Sm.
3. **"A less-committed config type avoids the Sm requirement."** PARTIALLY
   correct - `unconfigured` validates - but rejected at the generation stage.

Note on process: conclusion (3) was stated as "no valid config exists" after
testing two of three types. The third was legal. Recorded because the error was
premature generalisation from a tested subset, which is the same shape as
failure mode #1 in PROJECT_INSTRUCTIONS §7.

## Options considered

1. **Declare `Sm` anyway.** Rejected. The config would assert `mtvec`, trap
   entry and `PRECISE_SYNCHRONOUS_EXCEPTIONS` against hardware that has none.
   Sail would model a machine-mode hart while the DUT flags every CSR
   instruction illegal without consuming the flag. Any resulting number would
   describe different hardware than the DUT. PROJECT_INSTRUCTIONS §5.2.
2. **Report upstream and wait.** Correct but open-ended; does not fit the
   milestone. Filed as a background task.
3. **Integrate CSR and trap support, then declare `Sm` truthfully.** CHOSEN.
   `csr.sv` is already verified (env 4, 100% functional coverage, RAL) and was
   written with `trap_valid`/`trap_epc`/`trap_cause`/`trap_tval` inputs for
   this purpose. This is M4 work pulled forward, not new design.

## Consequences

- M3.4 resumes after CSR and synchronous-trap integration. All artifacts above
  are retained unchanged; only `rv32sky.yaml` gains the `Sm` declaration and
  its parameters, each answerable from RTL.
- Milestone order changes: CSR/trap integration moves ahead of ACT4 completion.
  PROJECT_CONTEXT §7 to be updated.
- UDB `partially configured` crash to be reported upstream.
