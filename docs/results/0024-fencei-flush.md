# 0024 — `fence.i` flushes the pipeline. ACT4 47/47.

**Date:** 2026-09-22
**Milestone:** M3.4b
**DUT:** `rtl/core/decoder.sv`, `rtl/core/rv32_core.sv`, `rtl/pkg/rv32_pkg.sv`
**Harness:** `verif/verilator/decoder/tb_decoder.cpp`
**Tools:** Verilator 5.050 (`v5.050-60-g3d2421f3b`), GCC 16.1.0 (`g6afcc4f6d`),
Sail RISC-V 0.13.1, ACT4 `riscv-arch-test`
**Commit:** `47c829b`
**Status:** Fixed and mutation-tested. Finding 2 of `docs/results/0021` closed.
**First clean compliance run of the project.**

## Result

| | Before | After |
|---|---|---|
| ACT4 (`run_compliance.sh`) | 46 / 47, exit 1 | **47 / 47, exit 0** |
| Sail lockstep | 800 instructions, exit 0 | **800, exit 0 — unchanged** |
| Decoder harness | 6,624 checks, 0 fail | **6,876 checks, 0 fail** |

## The bug

`decoder.sv` decoded `fence.i` as a legal no-op, with the comment:

> Decoded as a legal no-op. This core is single-hart, in-order and has no store
> buffer, so ordering is already sequentially consistent.

and the same justification in `verif/sail/rv32sky.json` and `PROJECT_CONTEXT`
§3.1: *no I-cache, so nothing to flush.* **Wrong.** With no I-cache a store is
visible to the fetch port at once — but the **pipeline** still holds the two
instructions fetched before the store commits. `Zifencei-fence.i-00` stores a
new instruction to `0x90` at `0x88`, executes `fence.i` at `0x8c`, and the core
then ran the **stale** `addi` at `0x90`: `x24 = 4` where Sail expects `8`.

## The fix

`fence.i` redirects EX to its own `PC+4`, discarding the instructions behind it
and forcing a re-fetch.

**Timing.** The preceding store is in MEM while `fence.i` is in EX, and
`tcm.sv` writes on that cycle's posedge. The redirect is registered before
reaching `if_stage`, so the re-fetch reads the updated word. A redirect from EX
is correctly timed, not a cycle early — settled by reading the pipeline, not by
trial.

**One redirect path, not two.** It joins the shared path alongside traps,
`mret` and branches, gated on `id_ex_q.valid` exactly as `mret` is. The comment
above that block explains why: a second, parallel redirect source is the shape of
the M3.5 bug that took four wrong fixes to find.

**Priority.** Trap, then `mret`, then `fence.i`, then branch. `fence.i` and a
taken branch cannot be the same instruction, so their relative order is
unobservable.

### `is_fencei` is the MSB of `ctrl_t`, out of its logical group

It belongs beside `is_mret`. But a packed struct places its first-declared field
in the MSBs, so declaring it **first** puts it at bit 46 and leaves every
existing field at its old position. Beside `is_mret` it would have shifted all 25
extraction macros in `tb_decoder.cpp` — the harness whose earlier field-map guard
passed while 1,771 checks failed (`0017`). A comment in the struct says so.

### The RTL caught the missing default; the harness would not have

`decoder.sv` defaults `ctrl` with a **named assignment pattern** listing every
member. Adding `is_fencei` to the struct without adding it to the pattern was a
**hard error** from Verilator — not a silent latch:

    %Error: rtl/core/decoder.sv:42:12: Assignment pattern missed initializing
            elements: 'logic' 'is_fencei'

That is the completeness guarantee the harness macros lack.

## The decoder harness was blind — measured

Before any harness change, with a 47-bit `ctrl_t` and a new decode:

    total checks: 6624    failures: 0    RESULT: PASS

No check looked at bit 46. `fence` and `fence.i` were both reference cases,
returning the same all-false expectation — so the harness passed whether the
decode was right or wrong.

### Its width guard never checked width

The guard in `main()` tested `(ctrl >> 45) == 1` for `add x11,x17,x28`, and its
comment claimed *"ctrl_t must be exactly 46 bits."* Line 30 called it a *"static
assert on total width."* Neither was true. **No static assert exists**, and the
runtime check requires only that nothing *above* bit 45 is set **for that one
instruction** — so a field added at the MSB that reads zero there passes. That is
exactly what `is_fencei` does. It was always a **shift detector**, and a good one;
the comments now say so.

### The update, and a prediction that could be checked exactly

- `C_IS_FENCEI` at bit 46
- `is_fencei` in `Expect`; `fence` and `fence.i` now **differ**
- checked for **every** reference case, so all 241 must leave it clear unless
  they are `fence.i`
- three hand-written literals, where correct and plausible-wrong decodes diverge:
  `0x0000000f` fence → 0, `0x0000100f` fence.i → 1, and `0x0001100f` — `fence.i`
  with reserved `rs1` set, which the assembler never emits and the ACT4 test
  reaches only via `.insn`. Same reason `0017`'s hand-written `ecall`/`ebreak`
  literals were the only vectors that killed its mutation 3.

**Predicted:** 6,624 + 241 + 11 = **6,876** checks. **Measured: 6,876, 0
failures.** The count matching to the check, not the zero, is what shows every
new check is wired where intended.

## Mutation testing

Injected one at a time into files verified clean, built with `make clean`.
Restored with `git checkout` against the committed fix, and verified by
`git status --short` returning **empty** — a whole-file comparison, strictly
stronger than grepping for a `MUTATION` marker.

The first set of golden copies (`*.pre-fencei` in `$HOME`) were taken
**before** the fix. Restoring from them would have silently reverted `fence.i`
entirely, and the next run would have looked like a mutation still in place. New
goldens of the fixed state were taken before F1. `0017`'s silent-restore failure,
caught before it happened this time.

| # | Mutation | Verdict | How |
|---|---|---|---|
| F1 | `fence.i` redirect term removed | KILLED | 46/47 — `fence.i-00` only |
| F2 | target `pc` instead of `pc+4` | KILLED | **47/47** fail, all by timeout |
| F3 | `is_fencei = 1` for all MISCMEM | KILLED | **decoder harness only**, 2 failures |
| F4 | `valid` gate dropped (both uses) | **SURVIVED** | unreachable — see below |
| F | `0018` mutation F re-run | KILLED | 5 of 6 lockstep programs, 47/47 ACT4 |

Project total: **39 mutations, 36 killed, 3 documented unreachable**
(`0018` A, `0022` M3, F4 here).

### F2: my scope prediction was wrong

Predicted: 46/47, only `fence.i-00` failing. **Measured: all 47 failed.**

The mechanism half held: `fence.i-00` timed out at 10,000,000 cycles with
2,501,183 retirements — one per four cycles, the signature of a tight
self-redirect loop. But `Zicsr-csrrw-00` died identically (2,502,073), and so did
every other test.

**ACT4's own infrastructure performs self-modifying code.** `objdump` of
`I-add-00`, a test unrelated to `Zifencei`:

    411f0:  bne  s0,t2,411cc <overwt_tt_Mloop>
    411f4:  fence.i                        <endcopy_Mtramp>
     44c4:  blt  t2,s0,44b4 <resto_Mloop>
     44c8:  fence.i

The trap trampoline table is copied into place and fenced in **every** test. So
before this fix, all 47 tests executed `fence.i` as a no-op, and 46 passed.

Why they passed is inference, tightly grounded (T4): the stale window is the two
instructions behind `fence.i`, in IF and ID. The trampoline is written far from
the copy loop and executed only when a trap fires much later, so the written
words were never in the pipeline. Only a store targeting an address within two
instructions of the `fence.i` exposes the no-op — which is precisely what
`fence.i-00` constructs.

**Forward consequence for M5.** With an I-cache, a no-op `fence.i` breaks the
trampoline copy in *every* test. Today the flush is load-bearing for one test; at
M5 it will be load-bearing for all of them. Building it now, against a test that
proves it broken, is cheaper than building it at M5 with no test.

### F3: the mutation the harness update exists for

Setting `is_fencei` for every MISCMEM makes a plain `fence` redirect to its own
PC+4 — two wasted cycles, no architectural change.

| Check | F3 |
|---|---|
| Decoder harness | **KILLED**, exactly 2 failures as predicted (reference `fence` `0x0ff0000f`, and literal `0x0000000f`) |
| ACT4 | 47/47 — survives |
| Lockstep | not affected: no lockstep program contains a plain `fence` |

**ACT4's survival is not vacuous, but it is carried by one test.** A plain
`fence` appears in exactly one of 47 ELFs — `I-fence-00`, four times. So the
mutated path genuinely ran, four `fence`s each redirected, and the test
self-checked clean. "Architecturally invisible" is therefore **measured**, by one
test.

This was checked deliberately. A single-ELF `objdump` of `I-add-00` first
returned zero plain `fence`s, which would have made the survival vacuous —
surviving because the path never ran, not because its effect is invisible. Those
are different claims; only the suite-wide count settled which.

**The decoder harness is the only check on `fence` decode anywhere in the
project.** Without the update, a decode error of this class could never be
caught — the core's own behaviour cannot reveal it.

### F4: unreachable, by an inherited reason

Both uses of `id_ex_q.valid` in the `fence.i` terms were removed. 47/47 ACT4 and
800/800 lockstep including `t04_hazards`, the program that stalls and redirects
hardest.

`0017` measured, with a `$display` probe, that `rv32_core.sv` clears the
**entire** `id_ex_q` struct on redirect and on stall, so a bubble carries
`is_fencei = 0` along with `valid = 0`. That measurement was taken on CSR
instructions; the clearing is struct-wide, so it covers `is_fencei` by
construction — **inference from a measured mechanism, not a fresh measurement.**

Same category as `0018`'s mutation A: a correct, cheap guard, kept as defence
against a future change to valid-bit-only bubbling, **not claimed as verified**.

### F: re-established, and broader than `0018` recorded

`0018`'s own rule: a mutation result belongs to a specific RTL text. `fence.i`
added a fourth source into the flush F guards, so F was re-run rather than
carried forward.

F reverts `.flush (ex_redirect_valid || redirect_valid)` to
`.flush (redirect_valid)`. Five of six lockstep programs diverge with the M3.5
signature:

    t02_memory  core retires 0x28 in the shadow of the branch at 0x20;
                sail goes to 0x38
    t06_traps   core retires 0x40 behind the trap at 0x38;
                sail enters the handler at 0xdc

and all 47 ACT4 tests fail.

**`t01_alu` agrees**, correctly: `0020` excluded it from env 7 because its pass
path contains no branch. An independent confirmation that F hits exactly the
redirect path and nothing else.

**Limit:** with every test failing on branches first, F cannot isolate whether
`fence.i` specifically inherits the protection. That `fence.i` shares the flush
is established by reading `rv32_core.sv:102`, not by this mutation.

## A coverage fact worth stating plainly

A 47/47 suite, with single tests carrying whole behavioural guarantees:

| Behaviour | Tests that exercise it |
|---|---|
| `fence.i` actually flushes (F1) | 1 of 47 |
| `fence.i` returns to the right place (F2) | 47 of 47, via ACT4's trampoline copy |
| plain `fence` decode (F3) | 1 of 47 at runtime — and it **cannot see** the error; only the decoder harness can |

A pass count says nothing about how thinly a behaviour is covered. Mutations are
what exposed these numbers.

## Wrong calls, recorded

**The `fence.i` justification was accepted, not tested.** It predated the
session, sounded architecturally sound, and was carried into both the
2026-09-09 `PROJECT_CONTEXT` reconciliation and the 2026-09-11 yaml rewrite
without question. Same shape as the `mepc` comment in `0021`/`0022`: a comment
explaining why something is correct is a claim, and deserves T5 treatment.

**F2's scope was over-predicted.** Caught by reading the whole result rather than
checking only the test the prediction named.

## Reproduce

    cd ~/dev/rv32-sky
    ./verif/compliance/rv32sky/run_compliance.sh            # 47 of 47, exit 0
    ./verif/sail/run_lockstep.sh t01_alu t02_memory t03_checksum \
      t04_hazards t05_csr t06_traps                          # 800, exit 0
    cd verif/verilator/decoder && make clean && make ref && make run
                                                             # 6,876 checks, 0 fail

## Provenance

Every expected value comes from ACT4 or Sail, configured to match this core; the
decoder expectations from the RISC-V spec by hand, per `0017`. No value in this
file was produced by the DUT.

`verilator --lint-only` clean across 12 modules after the edit.

**Not verified here:** whether `fence.i` specifically inherits F's protection
(read from source, not isolated by mutation). The `valid` gate (F4, unreachable).
Coverage of plain `fence` rests on one ACT4 test plus the decoder harness. `wfi`
still traps as illegal under a truthful `Sm` declaration — open, `0023`.
