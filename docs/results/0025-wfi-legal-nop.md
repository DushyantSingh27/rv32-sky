# 0025 — `wfi` is a legal M-mode no-op. The last `Sm` gap closed.

**Date:** 2026-09-23
**Milestone:** M3.4b
**DUT:** `rtl/core/decoder.sv`
**Harness:** `verif/verilator/decoder/tb_decoder.cpp`
**Tools:** Verilator 5.050 (`v5.050-60-g3d2421f3b`), GCC 16.1.0 (`g6afcc4f6d`),
Sail RISC-V 0.13.1, ACT4 `riscv-arch-test`
**Commit:** `ea31073`
**Status:** Fixed and mutation-tested. The `wfi` discrepancy opened in `0023` is
closed. One item left open — Sail's `wfi_is_nop`, below.

## Result

| | Before | After |
|---|---|---|
| Decoder harness | 6,876 checks, 0 fail | **6,882 checks, 0 fail** |
| Sail lockstep | 800, exit 0 | **800, exit 0 — unchanged** |
| ACT4 | 47 / 47, exit 0 | **47 / 47 — unchanged** |

Neither regression moved, and that is expected: **no lockstep program and no
running ACT4 test contains a `wfi`.** The only test that executes one is
`InterruptsSm`, excluded in `0023` for an unrelated reason.

## The bug

`rv32sky.yaml` declares `Sm`. Under `Sm`, `wfi` is a legal M-mode instruction.
`decoder.sv` trapped it as illegal:

    default: ctrl.illegal = 1'b1;   // WFI, SRET: M4/M5

`wfi` is `funct12 = 0x105`, falling through to that arm. Found by `0023` while
diagnosing `InterruptsSm`: `XCAUSE = 2`, `XTVAL = 0x10500073`. Same shape as
`fence.i` in `0021` — a declaration claiming behaviour the core did not have.

## The fix

One case arm. **No `ctrl_t` field**: an empty arm gives every `ctrl` default plus
`illegal = 0`, which is exactly a no-op. So unlike `fence.i` (`0024`), nothing in
the struct moved, no extraction macro changed, and the width guard was untouched.

    12'h105: ;                        // WFI - legal no-op
    default: ctrl.illegal   = 1'b1;   // SRET and the rest: no S mode

**A no-op is not merely permitted here, it is the only implementable choice.**
The spec allows implementing `wfi` as a no-op. On this core it is forced: `mip`
is driven entirely from `irq_timer` / `irq_software` / `irq_external`, all tied
low, so a real wait-for-interrupt would never wake.

`sret` (`funct12 = 0x102`) stays illegal — no S mode. The `rs1`/`rd` zero check
above the `funct12` case is untouched, so malformed `wfi` encodings still trap.

`mstatus.TW` can make `wfi` trap from a lower privilege mode. Unreachable here —
no U or S mode, and `csr.sv` does not implement TW at all. Recorded in the
comment for M4/M5 rather than parameterised: a knob for a privilege mode that
does not exist is speculative. `MEPC_LSB_ZEROS` in `0022` was different because
`C` is on the M4 roadmap and would silently reintroduce a real bug.

## The harness failed first, which is the point

`0x10500073` sat in `bad_opcodes` as:

    0x10500073u,   // wfi    - illegal until M5

After the RTL change the harness reported **1 failure** of 6,876. That is the 613
illegal cases doing their job — the change was caught by the mechanism that
exists to catch it, before anything downstream ran.

**"illegal until M5" was a recorded scope decision, not an oversight.** It was
surfaced and overridden deliberately: the `Sm` declaration is live *now*, so the
config was false until this landed. The milestone comment is rewritten, not
quietly dropped.

### The swap, and why six checks rather than one

- **removed** `0x10500073` from `bad_opcodes`
- **added** `0x10508073` — `wfi` with `rs1 = x1`, which the `rs1`/`rd` zero check
  must still reject. Same pattern as `0017`'s hand-written `ecall` with `rd=x1`,
  the literal that alone killed its mutation 3, and one the assembler will not
  emit
- **added** a legal-`wfi` literal block checking `illegal`, `reg_write`,
  `csr_op`, `is_ecall`, `is_ebreak`, `is_mret`

Proving `wfi` stopped being illegal takes one check. Proving it did not
accidentally become *something else* takes the other five — a bare `illegal == 0`
would pass a decode that also set `reg_write` or a `csr_op`.

**Predicted 6,876 + 6 = 6,882** (the `bad_opcodes` swap is net zero).
**Measured 6,882, 0 failures, 613 illegal cases unchanged.** The count matching
exactly, not the zero, is what shows every new check is wired where intended.

## Mutation testing

Injected into a file verified clean, built with `make clean`, restored with
`git checkout` against `ea31073` and verified by `git status --short` returning
empty. The fix was **committed before mutating** precisely so that restore is a
whole-file comparison — `0024` records the near-miss where the golden copies were
taken before the fix and a restore would have silently reverted it.

| # | Mutation | Verdict | Decoder harness | ACT4 | Lockstep |
|---|---|---|---|---|---|
| W1 | `12'h105` arm removed — `wfi` illegal again | KILLED | **FAIL, 1 failure** | 47/47 | 800, exit 0 |
| W2 | `default: ;` — every `funct12` legal | KILLED | **FAIL, 1 failure** | 47/47 | not run |

Project total: **41 mutations, 38 killed, 3 documented unreachable**
(`0018` A, `0022` M3, `0024` F4).

**W1 produced exactly 1 failure, not 6.** Reverting sets `illegal` and touches
nothing else, so the five checks proving `wfi` did not become something else
still pass. The prediction landed on the number, not just the verdict.

**W2 produced exactly 1 failure too** — `sret`. No count was predicted, because
only two entries of the `bad_opcodes` array had been read and the rest were
unknown. One is the answer: `sret` is the only other `funct3=000` `funct12`
encoding in the set. `0x10508073` stayed illegal under W2, correctly — it is
caught by the `rs1`/`rd` check, which W2 does not touch.

W2 is the mutation `0022`'s M2 argued for. W1 tests under-permissiveness, W2
over. This change moved the boundary in one direction, so an overshoot would hide
in the other.

Lockstep was omitted from W2: it contains no `sret` and no `wfi`, W1 had already
shown it blind to this class, and a third identical 800 adds nothing.

## THE PATTERN: the decoder harness is the only check on decode

Both `wfi` mutations were killed **by the decoder harness alone**, with ACT4
surviving both. That claim rests on the survivals, not on the failures — a kill
shows the harness works; the other two passing is what shows nothing else can
see it.

This is the **second instance in two days**. `0024`'s F3 (`is_fencei` set for all
MISCMEM) was killed by the decoder harness alone, with ACT4 47/47 and no lockstep
program containing a plain `fence`.

| Decode error | Killed by | Blind |
|---|---|---|
| `is_fencei` ignores funct3 (`0024` F3) | decoder harness | ACT4, lockstep |
| `wfi` illegal (W1) | decoder harness | ACT4, lockstep |
| every `funct12` legal (W2) | decoder harness | ACT4 |

**Two of the three were, until days ago, the harness's own blind spot.** It could
not see `is_fencei` at all (6,624 checks, 0 failures with a new field), and it
listed `wfi` as permanently illegal.

The generalisation worth carrying: **an instruction the test programs never
execute is verified only by the decoder harness, and only if someone writes the
vector by hand.** Compliance suites and lockstep both verify what their programs
happen to run. `0017` said the same thing about `ecall`/`ebreak` literals — this
is the third and fourth instance, and it is now a rule rather than an anecdote.

## OPEN — Sail's `wfi_is_nop` is `false` and has not been measured

`verif/compliance/rv32sky/sail.json` inherits Sail's default
`platform.wfi_is_nop: false`. The generator overrides only `clint` and
`simple_interrupt_generator`, so nobody had looked at this key.

**What `false` does is T5 — unverified.** The reasoning for proceeding anyway:
`wfi_available_to_user_mode` exists as a *separate* legality knob, which implies
`wfi_is_nop` controls nop-versus-wait rather than legality, and M-mode `wfi` is
mandatory in the privileged spec. **That is T4 inference, not a measurement.**

It is also **unobservable today** — no lockstep program and no running ACT4 test
executes a `wfi`, so the setting cannot be exhibited either way. Same category as
`MISALIGNED_LDST_EXCEPTION_PRIORITY` in `0022`.

It stops being unobservable the moment `InterruptsSm` is re-enabled at M5, or if
any lockstep program uses `wfi`. **To do:** a `probe_wfi.S` in the style of
`probe_traps.S`, run under both settings, then set `wfi_is_nop: true` in both
Sail configs if it matches the core — by hand in `verif/sail/rv32sky.json`, and
through `gen_act4_sail_config.py` for the compliance one, since `platform` is
where it lives.

Not done in this session. Recorded as open rather than left implicit.

## Reproduce

    cd ~/dev/rv32-sky/verif/verilator/decoder && make clean && make ref && make run
    # 241 reference cases, 613 illegal cases, 6,882 checks, 0 failures

    cd ~/dev/rv32-sky
    ./verif/sail/run_lockstep.sh t01_alu t02_memory t03_checksum \
      t04_hazards t05_csr t06_traps          # 800, exit 0
    ./verif/compliance/rv32sky/run_compliance.sh   # 47 of 47, exit 0

## Provenance

Decoder expectations are derived from the RISC-V privileged spec by hand, not
from the encoding and not from the RTL, per `0017`. The `XCAUSE`/`XTVAL` values
that found the bug come from ACT4 via Sail (`0023`). No value in this file was
produced by the DUT.

`verilator --lint-only` clean across 12 modules after the edit.

**Not verified here:** Sail's `wfi_is_nop` semantics (above). `mstatus.TW`, which
is unreachable with no U or S mode. `wfi` behaviour under an I-cache, which does
not exist until M5. Coverage of `wfi` decode rests entirely on the six
hand-written literal checks in `tb_decoder.cpp` — nothing else in the project
executes the instruction.
