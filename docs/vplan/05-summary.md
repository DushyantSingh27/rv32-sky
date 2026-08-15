# vplan summary

**Date:** 2026-08-13
**Scope:** full RV32IMC_Zicsr plus the microarchitecture of `PROJECT_CONTEXT.md` §3.

## Roll-up

| File | Covered | Partial | Planned | Deferred | Waived | Failing |
|---|---|---|---|---|---|---|
| `01-rv32i-base.md` | 19 | 8 | 0 | 21 | 0 | 0 |
| `02-rv32m.md` | 22 | 1 | 1 | 2 | 0 | 0 |
| `03-zicsr.md` | 34 | 0 | 0 | 12 | 2 | 0 |
| `04-microarch.md` | 15 | 1 | 0 | 36 | 0 | 1 |
| **Total** | **90** | **10** | **1** | **71** | **2** | **1** |

**52% of enumerated features are Covered. 41% are Deferred** — meaning the RTL
does not exist yet.

That ratio is the honest state of a project whose four leaf blocks are complete
and whose integration has not started. It is not a coverage shortfall: every
environment that exists sits at 100% functional coverage of its own bins.

## PROJECT_INSTRUCTIONS §5.3 targets

| Metric | Target | Actual |
|---|---|---|
| Functional coverage, per environment | ≥90% of defined bins | **100%** in all four |
| Line/toggle coverage on RTL | ≥95% | **not measured** — needs Verilator `--coverage`, M3 |
| riscv-formal | all checks passing, depth ≥20 | **not started** — M3 |
| RISCOF compliance | 100% on RV32IMC_Zicsr | **not started** — M4 |
| Scan fault coverage | ≥90% | **not started** — M8 |

Functional coverage is met. The other four are milestone-gated and correctly
untouched.

## What M3 must build, in priority order

Derived from the Deferred rows, ordered by how much else depends on them.

1. **Decoder** — 21 of the RV32I Deferred rows are blocked on it. Nothing
   instruction-level can be verified until an encoding maps to control signals.
2. **WB→ID forwarding** — **mandatory**, not optional. Env 3 verified read-first
   behaviour, which means a value written in WB is invisible to an instruction
   reading in ID unless forwarded. Without it, programs silently compute wrong
   answers.
3. **PC datapath** — branch targets, `JAL`/`JALR`, `AUIPC`. Eight Partial rows
   become Covered once the PC is an ALU operand and the redirect exists.
4. **Memory interface** — loads and stores, sign/zero extension, byte enables.
5. **Flush of an in-flight muldiv** — a 35-cycle divide must be cancellable on a
   branch mispredict. The RTL has no input for this today: a design gap, not
   just a verification one.
6. **Full-core UVM environment (env 7)** — the portfolio centrepiece per §5.2:
   constrained-random instruction streams checked against a Spike reference.

## Known gaps that are not milestone-deferred

| Gap | Where | Why it matters |
|---|---|---|
| Instruction-level decode of RV32M | `02-rv32m.md` | Env 2 drives `muldiv_op_e` directly and has never seen a 32-bit encoding |
| Back-to-back muldiv without idle cycles | `02-rv32m.md` | The driver inserts a gap; a pipeline will not |
| `MULHSU` operand-sign cross | `02-rv32m.md` | Covered generically, no dedicated cross for the signed×unsigned asymmetry |
| `CSRRWI`/`CSRRSI`/`CSRRCI` | `03-zicsr.md` | Different suppression rule (`uimm == 0`); the CSR block cannot distinguish them |
| muldiv misses 50 MHz | `04-microarch.md` | 43.5 MHz standalone; re-timed at M7 |

## Mutation-testing status

Non-standard column, included because it changed a conclusion.

| Env | Injected fault | Detected |
|---|---|---|
| 1 — ALU | `SRA` becomes `SRL` | Yes, 21 errors |
| 2 — muldiv | divider compare `>=` becomes `>` | Yes, 60 errors |
| 3 — regfile | `write_en` loses its x0 guard | **No — fixed, then yes** |
| 4 — CSR | `mscratch` write inverts bit 0 | Yes, 64 errors |

Env 3 reported zero mismatches and 100% coverage while being unable to detect a
fault in the behaviour it claimed to verify. Coverage measures what was
exercised; it says nothing about whether the checking works. See
`docs/results/0011-mutation-testing.md`.

## Maintenance

    python3 tools/extract_coverage.py     # structure, self-checking
    make -f verif/dsim.mk <env>-cov       # closure, per environment

Coverage **structure** is extracted from the source and self-checked against
recorded counts. Coverage **bin counts and percentages** are cited from DSim
`dcreport` output in `docs/results/`, not generated — see the note in
`tools/extract_coverage.py` explaining why bin counting was removed.
