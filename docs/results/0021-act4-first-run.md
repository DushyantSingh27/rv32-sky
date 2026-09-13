# 0021 — ACT4 first run: 40 of 48 passing, two real DUT bugs found

**Date:** 2026-09-13
**Milestone:** M3.4b
**DUT:** `rtl/core/rv32_core.sv` + `rtl/core/csr.sv` + `rtl/mem/tcm.sv`, via
`verif/verilator/act4/`
**Tools:** Verilator 5.050 (`v5.050-60-g3d2421f3b`), GCC 16.1.0 (`g6afcc4f6d`),
Sail RISC-V 0.13.1, ACT4 `riscv-arch-test`, udb 0.1.15 / udb-gen 0.1.14
**Status:** Harness complete and verified. Two bugs found, neither fixed yet.

## Result

    40 passed, 8 failed, out of 48 tests

| Suite | Tests | Result |
|---|---|---|
| `rv32i/I` | 39 | **all pass** |
| `rv32i/Zicsr` | 6 | all fail — one cause |
| `rv32i/Zifencei` | 1 | fails — separate cause |
| `priv/InterruptsSm` | 1 | fails — **not yet triaged** |
| Others (`Zaamo`, `Zalrsc`, etc.) | 2 | pass |

Every one of the 39 base-I tests passes. That is a meaningful cross-check: two
independent test sources — Sail lockstep (M3.5, 800 instructions) and the
official architectural suite — agree on the part of the ISA they overlap. Every
failure is in territory added at M3.4a.

All eight failures ran to completion and self-checked. Every log carries an
`RVCP-SUMMARY: TEST FAILED` line and `tohost=3`. **These are DUT findings, not
harness problems.**

## Reproduce

    cd ~/src/riscv-arch-test
    make elfs CONFIG_FILES=config/cores/rv32sky/test_config.yaml
    ./run_tests.py "$(cat config/cores/rv32sky/run_cmd.txt)" work/rv32sky/elfs

Expect `8 failed, 40 passed out of 48 tests`, exit 1.

---

## FINDING 1 — `mepc[1]` is not masked. Six tests, one cause.

Every Zicsr failure is CSR address `0x341` (`mepc`) and every discrepancy is
exactly bit 1 set where it should be clear.

| Test | Instruction | Bad | Expected |
|---|---|---|---|
| `csrrw` | `0x34109773` | `0xff37c166` | `0xff37c164` |
| `csrrs` | `0x34102473` | `0xd5991566` | `0xd5991564` |
| `csrrc` | `0x34103d73` | `0x0faf331e` | `0x0faf331c` |
| `csrrwi` | `0x3418d1f3` | `0x154b01ce` | `0x154b01cc` |
| `csrrci` | `0x34187073` | `0x262b870e` | `0x262b870c` |
| `csrrsi` | `0x341f6073` | `0x8b4b5cfe` | `0x8b4b5cfc` |

`csr.sv:189` masks bit 0 only:

    CSR_MEPC: mepc_q <= {wval[XLEN-1:1], 1'b0};

with the comment *"mepc bit 0 is WARL: reads back 0 (IALIGN=16 with C)."*
`csr.sv:169` carries the identical mask on the trap-entry path.

**IALIGN is 32 on this core, not 16.** Measured, not assumed:

    sail_riscv_sim --config verif/compliance/rv32sky/sail.json --print-isa-string
    rv32i_zicsr_zifencei_zvl32b_zvl64b_zvl128b_zvl256b_ssstateen_smstateen

No `c`. With IALIGN=32 the spec requires `mepc[1:0]` to read as zero. The
expected values ACT4 checks against come from Sail configured to match this
core, so the expectation is authoritative.

### Why seven earlier checks missed it

Before ACT4, `mepc` was only ever written **by hardware on trap entry**, and
`trap_epc` is a program counter — always 4-byte aligned, so bit 1 was already
zero arriving at the mask. Both mask sites were exercised hundreds of times with
inputs where the correct and incorrect implementations produce identical
results. Only a *software* write of an arbitrary value to `mepc` distinguishes
them, and no test before ACT4 performed one.

The immediate assertion at `csr.sv:212` checks `mepc_q[0] == 1'b0` and would not
have caught it either — it asserts exactly the bit that was already handled.

**This is the eighth instance of failure mode #1** (PROJECT_INSTRUCTIONS §7):
test values landing where two different implementations agree. It is also the
second instance, after `0018`'s store-suppression sentinel, where the mechanism
written to catch a class of bug sat adjacent to the bug and missed it.

### A wrong call, recorded

Earlier in the same session that produced this file, the `IALIGN=16 with C`
comment was noticed and dismissed: *"behaviour is fine and Sail agrees across
800 instructions, so only the comment is wrong."*

That was wrong. The comment documented a real behavioural divergence, and the
reason Sail agreed across 800 instructions is the reason given above — no test
wrote a bit-1-set value into `mepc`. Reasoning about the RTL from a comment
produced a confident and incorrect conclusion; an external test suite produced
the correct one within the hour.

### Scope of the fix (not yet applied)

Two mask sites (`csr.sv:169`, `csr.sv:189`), one immediate assertion
(`csr.sv:212`), and three comments asserting IALIGN=16. An open design question:
masking `[1:0]` is correct for this core today, but must revert to bit 0 only if
`C` is added at M4. Whether to hardcode or derive from a package parameter is
undecided.

---

## FINDING 2 — `fence.i` does not flush the pipeline. One test, real bug.

`Zifencei-fence.i-00`, `x24`: bad `0x4`, expected `0x8`.

The test is self-modifying code:

    40:  li    s8,3            # x24 = 3
    64:  addi  ra,ra,48        # ra = 0x90
    80:  lw    a6,0(gp)        # load a replacement instruction word
    88:  sw    a6,0(ra)        # store it OVER the instruction at 0x90
    8c:  fence.i
    90:  addi  s8,s8,1         # <-- the word just overwritten
    98:  beq   tp,s8,...       # check

`x24 = 4` is `3 + 1`: **the core executed the original `addi s8,s8,1`, not the
replacement.**

By the time the `sw` at `0x88` commits in MEM, the word at `0x90` is already in
ID and `0x94` is in IF — both fetched two cycles earlier. `tcm.sv` is dual-port
with combinational reads, so the store is immediately *visible* to the fetch
port, but visibility does nothing for instructions already inside the pipeline.

**Flushing the pipeline is precisely what `fence.i` is for on a core with no
I-cache.** `decoder.sv` accepts it as a legal no-op.

### The justification was wrong, and it is written in three files

> `Zifencei` is declared because `decoder.sv` accepts `fence.i` as a legal
> no-op, which is architecturally correct for a single-hart, in-order core with
> no I-cache and no store buffer.

There is no I-cache and no store buffer, but there *is* a pipeline holding
already-fetched instructions. "Nothing to flush" was the wrong conclusion.

That text appears in `verif/compliance/rv32sky/rv32sky.yaml`,
`verif/sail/rv32sky.json`, and `PROJECT_CONTEXT.md` §3.1. It was carried forward
into the 2026-09-09 document reconciliation and the 2026-09-11 yaml rewrite
without being tested, because it sounded correct and predated the session.

**Consequence: the `Zifencei` declaration is currently a false claim about this
core.** Either the flush is implemented, or the declaration is withdrawn.
Leaving it declared and unimplemented is exactly the failure this milestone
exists to repair.

Note `0xec` in the same test: `.insn 4, 0x0001100f` — `fence.i` with non-zero
reserved fields. Any fix must handle that encoding too.

### Why no earlier test could have caught this

No test program before ACT4 modified its own instruction memory. Sail models
`fence.i` correctly, so lockstep would have caught it — on a self-modifying
program, of which there were none.

---

## FINDING 3 — `InterruptsSm`. NOT TRIAGED.

`priv/InterruptsSm-00`, 12,760 retirements before failing. The RVCP debug tail
mentions `(MPP/SPP/MPV), or wrong vectored interrupt entry`.

**No cause is proposed here.** The core has no CLINT, no interrupt pins
consumed, and declares `MTVEC_MODES: [0]` (direct only), so several
explanations are available and none has been measured. `0017` records five
consecutive wrong hypotheses on one bug before a `$display` settled it;
PROJECT_INSTRUCTIONS §2.4 requires one hypothesis and one measurement rather
than a list.

Open. To be triaged separately.

---

## Harness verification

The harness is new (`verif/verilator/act4/tb_act4.cpp`), so its own correctness
is a precondition for trusting any result above.

**ELF loader cross-checked against `objdump`.** The C++ parser could produce a
plausible-looking wrong image, which is failure mode #1 applied to the harness
itself. `--dump-hex` writes the loaded image; compared against `objdump -d`:

| Check | Harness | objdump / nm |
|---|---|---|
| word 0 | `00041097` | `auipc ra,0x41` = `00041097` |
| word 1 | `0bc08093` | `addi ra,ra,188` = `0bc08093` |
| `tohost` | `0x00020090` | `nm`: `00020090 D tohost` |

`$readmemh` indexes `tcm.sv`'s `mem[]` by **word**, so `@` directives are word
indices. Byte addresses would have placed every segment at four times its
address. Three directives appear (`@0`, `@2000`, `@10400`), matching the three
`PT_LOAD` segments at `0x0`, `0x8000` and `0x41000`.

**The checker was shown to fail.** Per `0018` — a checker that cannot fail is
not evidence. `--force-fail` inverts a PASS verdict; on the same ELF:

    ./obj_dir/Vcore_tb_top I-add-00.elf                 → exit 0
    ./obj_dir/Vcore_tb_top --force-fail I-add-00.elf     → exit 1

**Both HTIF branches exercised on the first run.** `run_tests.py` requires two
independent signals — exit code 0 **and** an `RVCP-SUMMARY` line, which the test
prints through the HTIF console path. `I-add-00` produced both.

**Parallelism verified.** `-j 20` and `-j 1` both give 40/48, confirming the
PID-unique temp hex path does not collide across parallel runs.

**Lockstep re-run after `core_tb_top.sv` gained `TCM_BYTES`:** 800 instructions,
six programs, exit 0. The parameterisation is transparent.

## Provenance

Every expected value in every failure above comes from ACT4, derived from Sail
configured to match this core. No value was produced by the DUT.

`verif/compliance/rv32sky/sail.json` is generated from Sail's own default plus
the extension set read out of `verif/sail/rv32sky.json`, so the compliance and
lockstep models cannot disagree about what the core implements.

**Not verified here:** no fix has been applied to either finding, so no claim is
made that the core passes. `InterruptsSm` has no diagnosis. The 48 tests are the
suite generated with `EXTENSIONS` unset and the upstream
`EXCLUDE_EXTENSIONS ?= Sm,SdtrigSm,SdtrigS,SdtrigU` default still in force —
whether `Sm` tests are meaningful against this core's WARL surface is untested,
and upstream excludes them citing *"insufficient WARL configuration options."*
