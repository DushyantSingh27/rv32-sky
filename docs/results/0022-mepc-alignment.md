# 0022 — `mepc[1:0]` masked. Six ACT4 Zicsr tests fixed.

**Date:** 2026-09-13
**Milestone:** M3.4b
**DUT:** `rtl/core/csr.sv`, `rtl/pkg/rv32_pkg.sv`
**Tools:** Verilator 5.050 (`v5.050-60-g3d2421f3b`), GCC 16.1.0 (`g6afcc4f6d`),
Sail RISC-V 0.13.1, ACT4 `riscv-arch-test`
**Status:** Fixed and mutation-tested. Finding 1 of `docs/results/0021` closed.

## Result

| | Before | After |
|---|---|---|
| ACT4 | 40 / 48 | **46 / 48** |
| Sail lockstep | 800 instructions, exit 0 | **800 instructions, exit 0 — unchanged** |

The six `rv32i/Zicsr` failures are closed. `Zifencei-fence.i-00` and
`priv/InterruptsSm-00` remain, unchanged, and are tracked in `0021`.

## The fix

`csr.sv` masked `mepc[0]` only, at both the trap-entry site and the software
write site:

    mepc_q <= {wval[XLEN-1:1], 1'b0};   // "IALIGN=16 with C"

IALIGN is 32 on this core, not 16. Measured, not assumed:

    sail_riscv_sim --config verif/compliance/rv32sky/sail.json --print-isa-string
    rv32i_zicsr_zifencei_zvl32b_zvl64b_zvl128b_zvl256b_ssstateen_smstateen

No `c`. With IALIGN=32 the spec requires `mepc[1:0]` to read as zero.

A package constant now drives both sites:

    localparam int unsigned MEPC_LSB_ZEROS = 2;   // rv32_pkg.sv

chosen over a hardcoded `2'b00` because adding `C` at M4 changes the correct
mask, and a literal with an explanatory comment is precisely the artifact that
drifted in the three files repaired earlier this week. M4 below is the mutation
that proves the constant actually drives both sites rather than sitting
decoratively beside them.

Six edits: the constant, two mask sites, the immediate assertion at
`csr.sv:214`, and the `trap_epc_lsb_unused` declaration and its liveness
assertion — the latter two widened from one bit to `MEPC_LSB_ZEROS` bits so
`trap_epc[1]` is not a silently dropped bit. The existing comment says that
signal is named explicitly "so the discard is visible as a spec rule"; leaving
it one bit wide would have defeated the thing it exists for.

### Side effect worth recording

`mepc_o` feeds `ex_redirect_pc` on `mret` (`rv32_core.sv:399`). Before the fix,
an `mret` to a software-written `mepc` with bit 1 set would have fetched from a
2-mod-4 address, which `tcm.sv` flags via `a_out_of_range`. Masking `[1:0]`
closes that path. This was not the reason for the fix and no test exercised it.

## Mutation testing

Each mutation injected into a file verified clean by `grep -c MUTATION`, built
with `make clean` in the harness directory, restored from a golden copy in
`$HOME`, and re-verified at 0. Golden copies are in `$HOME` rather than `/tmp`
because `0018` records a `/tmp` golden that did not survive between sessions:
the mutation stayed in the file and the re-run reproduced the previous result.

Run one at a time, not batched. `0017` records that an RTL immediate assertion
`$stop`s on first violation and masks everything after it, so a batched run can
report kills that never happened.

| # | Mutation | Verdict | Caught by |
|---|---|---|---|
| M1 | `MEPC_LSB_ZEROS = 1` (both sites revert) | KILLED | Six Zicsr tests return; 8 failed / 40 passed |
| M2 | `MEPC_LSB_ZEROS = 3` (over-mask) | KILLED | Whole suite times out; 0 passed / 48 failed |
| M3 | trap-entry site hardcoded to bit 0 | **SURVIVED** | Unreachable — see below |
| M4 | software site hardcoded to bit 0, constant left at 2 | KILLED | `csr.sv:215` assertion, naming the value |

Project total: **35 mutations, 33 killed, 2 documented unreachable** (M3 here,
mutation A in `0018`).

### M1 is the load-bearing kill

Reverting the constant reproduces the original failure set exactly — the same
six tests, `InterruptsSm` and `fence.i` unchanged. That establishes the fix is
real and that nothing else changed during the session was masking it.

### M2 is a weak kill, and the value does not rest on it

M2 was designed to show the suite discriminates *over*-masking, not only
under-masking. It does reject `3` — but by collapsing the entire suite, not by
detecting a `mepc` mismatch. All 48 tests failed with **no RVCP-SUMMARY line in
any of them**, including `I-andi-00` and `I-sb-00`, which never touch `mepc`.
`I-andi-00` ran the full 10,000,000-cycle budget and retired 6,973,687
instructions: executing continuously, no fault, never terminating.

**The mechanism was not established.** A mutation that breaks everything does
not demonstrate that the tests are sensitive to the specific thing mutated —
every over-masking mutation would look identical. So the value `2` rests on the
IALIGN=32 measurement and on M1's clean kill. It is **not** pinned to exactly 2
by the test suite, and should not be reported as though it were.

### M3 is unreachable, with a measured reason

`trap_epc` is a program counter. With IALIGN=32 — measured from the Sail ISA
string above — every trapping PC on this core is 4-byte aligned, so
`trap_epc[1]` is already zero when it reaches the mask. Narrowing the mask at
that site cannot change the stored value.

`t06_traps` takes six trap causes and compares every `mepc` against Sail, and it
passed under M3 with all 100 instructions agreeing. It is not that the test is
weak: **no input exists on this core that would distinguish the two mask widths
at the trap-entry site.**

Same category as `0018`'s mutation A — a guard that is correct, cheap, and worth
keeping while being untestable. A was unreachable because the squash mechanism
zeroes the entire `id_ex_q` struct; this is unreachable because IALIGN makes the
input always aligned. Both are design decisions, not verification claims.

Keeping the wide mask there costs nothing and stays correct by construction: if
`C` lands at M4, `trap_epc` may carry 2-byte-aligned PCs and `MEPC_LSB_ZEROS`
becomes 1 for the same reason.

### M4 is the kill that justifies the parameterisation

M4 hardcodes the software write site while leaving the constant at 2, so the
constant and the write disagree. The immediate assertion caught it before the
test's own self-check:

    csr.sv:215: Assertion failed in TOP.core_tb_top.u_core.u_csr:
      csr: mepc low 2 bit(s) not zero: 0x8b4b5cfe

`0x8b4b5cfe` is the same value `0021` records as `csrrsi`'s bad readback — now
caught one layer earlier, by the RTL rather than by the test.

That is the case for a single source of truth over a literal: a site that stops
honouring the constant is *detected*, not silently divergent. A constant nothing
depends on would be worse than a hardcoded value, because it would look like
protection while providing none.

## Three wrong hypotheses, recorded

A results file recording only successes is incomplete (PROJECT_INSTRUCTIONS
§5.2). Three explanations were proposed during this session and none survived
contact with the output.

**1. "The `mepc` comment is wrong but the behaviour is fine."** Proposed two
sessions earlier, on the grounds that Sail agreed across 800 instructions.
Wrong: the comment documented a real behavioural divergence, and Sail agreed
because no test before ACT4 wrote a bit-1-set value into `mepc`. Recorded in
`0021` finding 1.

**2. "M2 collapses the suite because the `csr.sv` assertion fires."** The log
showed a clean TIMEOUT with no `$error` at all. One line of output killed it.

**3. "M2 collapses the suite because `mret` lands 8-byte-aligned inside
`rvmodel_boot`."** Plausible, and consistent with 6.97M retirements and no
fault. Wrong: `objdump` shows `rvmodel_boot` contains no `mret` — it is five
`csrw` instructions followed by `mscratch` setup. Notably it does contain
`csrw mepc,zero` at `0x400c4`, which is unaffected by any mask width.

The pattern across all three, and across `0021`'s two findings, is the same: a
plausible mechanism reasoned from the source rather than measured from the
output. `0017` records five consecutive wrong Sail flags recalled rather than
read; `0018` records two file-edit anchors taken from chat-pasted copies rather
than the files. **A comment explaining why something is correct is a claim, and
claims predating the current session deserve the same T5 treatment as a recalled
tool flag.** PROJECT_INSTRUCTIONS §2.1 already applies that to tool versions,
command syntax and config keys; design rationale in source comments belongs in
the same category. Two instances in one afternoon.

Chasing hypothesis 3 further was stopped deliberately. M2 is dead either way,
and the only thing riding on the mechanism was one sentence of wording in this
file. The honest wording cost nothing; instrumenting the harness to chase a
mutation already known to be dead would have.

## Reproduce

    cd ~/dev/rv32-sky && ./verif/sail/run_lockstep.sh \
      t01_alu t02_memory t03_checksum t04_hazards t05_csr t06_traps
    # expect 800 instructions, exit 0

    cd ~/src/riscv-arch-test
    ./run_tests.py "$(cat config/cores/rv32sky/run_cmd.txt)" work/rv32sky/elfs
    # expect 2 failed, 46 passed out of 48

## Provenance

Every expected value comes from ACT4, derived from Sail configured to match this
core. No value in this file was produced by the DUT.

`verilator --lint-only` clean across 12 modules after the edit.

**Not verified here:** `MEPC_LSB_ZEROS = 2` is not pinned to exactly 2 by the
test suite (see M2). The trap-entry mask width is not verified at all (see M3).
`Zifencei-fence.i-00` and `priv/InterruptsSm-00` remain open in `0021`, and the
`Zifencei` declaration in `verif/compliance/rv32sky/rv32sky.yaml` remains a
false claim about this core until `fence.i` is either implemented or withdrawn.
