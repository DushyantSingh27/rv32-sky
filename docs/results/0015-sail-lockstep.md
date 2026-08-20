# M3.5: Sail lockstep

**Date:** 2026-08-20
**Reference:** Sail RISC-V model 0.13.1, release `2026-08-17-8f91355`
**Method:** offline trace comparison, PC and register write per retired instruction

## Result

| Program | Instructions compared | Verdict |
|---|---|---|
| `t01_alu` | 60 | agree |
| `t02_memory` | 176 | agree |
| `t03_checksum` | 305 | agree |
| `t04_hazards` | 80 | agree |

Every PC and every register write matches the RISC-V Foundation's executable
formal specification of the ISA.

**This is the first result in the project checked against a reference neither
written here nor derived from the core's own output.** Every golden checksum is
self-derived; the decoder's assembler check (`docs/results/0012`) is the only
other external reference.

t04 matters most: no NOP padding, so every forwarding path and the load-use
interlock are exercised, and Sail confirms every result.

## THE HEADLINE: lockstep found a bug 23 mutations missed

The core was retiring one instruction per taken branch that should have been
squashed. Because `wb_reg_we` gates on `mem_wb_q.valid`, **that instruction's
register write actually landed** - real architectural corruption, not a
reporting artifact.

It survived everything:

- 23 mutations across M1-M3.3
- four independent test programs
- seven hazard-specific faults at M3.3
- 100% functional coverage in four UVM environments

All of them compare the core against a value the core itself produced. Sail
found it in the first comparison.

**Measured directly.** Reverting the fix and running both methods on the same
fault:

| Method | Verdict |
|---|---|
| Checksum test (the M3.2/M3.3 method) | **PASS** |
| Sail lockstep | **DIVERGED at instruction 19** |

    sail [19] pc=0x00000040  x8 <= 0x0000000a
    core [19] pc=0x00000054  x10 <= 0x00000100

The core retires `0x54`, which Sail never executes. The checksum cannot see it
because `x10` is legitimately rewritten moments later - a property of these
programs, not of the design.

## The bug: a one-cycle gap between squash and redirect

The redirect is REGISTERED (added at M3.2 while chasing a misdiagnosed
evaluation-order hazard). So `ex_redirect_valid` asserts while the branch is in
EX, and `redirect_valid` reaches the PC one cycle later. IF keeps fetching
sequentially in between.

Measured on t04:

    c20  IF=00000050 | if_id v=1 pc=0000004c | id_ex v=1 pc=00000048 | exrv=1 rv=0
    c21  IF=00000054 | if_id v=0 pc=00000000 | id_ex v=0 pc=00000000 | exrv=0 rv=1
    c22  IF=00000040 | if_id v=1 pc=00000054 | id_ex v=0 pc=00000000 | exrv=0 rv=0

At c20 `exrv=1` squashes `0x4c`. At c21 the PC finally redirects, but `exrv` has
dropped - and IF has already fetched `0x54`. At c22 `if_id` latches it with
valid set, and it flows through to retirement.

**Fix:** squash `if_id` on `ex_redirect_valid || redirect_valid`, covering both
cycles of the redirect.

### Four wrong fixes first

| Attempt | Result |
|---|---|
| Flush `ex_mem_q` and `mem_wb_q` too | loop counter destroyed before forwarding could use it - infinite hang |
| Flush `ex_mem_q` only | squashed the BRANCH ITSELF as it advanced EX->MEM |
| Revert to the original two registers | phantom returns |
| Squash `if_id` on `ex_redirect_valid` instead of `redirect_valid` | phantom moves one instruction later |

Each attempt moved the symptom by exactly one instruction. **That pattern was
itself the diagnostic** - a timing skew, not a wrong boundary - and it should
have been read after the second attempt rather than the fourth. One `$display`
of pipeline state settled it immediately.

Same lesson as the `0xdeadbeef` bug at M3.2, where five hypotheses preceded one
measurement.

### The correct flush boundary

- `if_id` and `id_ex_q` are squashed, on **either** redirect cycle
- `ex_mem_q` is NOT: `ex_redirect_valid` asserts while the branch itself is in
  EX, and clearing it there squashes the branch as it advances
- `mem_wb_q` is NOT: an instruction that reached MEM/WB executed before the
  branch and has already committed. It also feeds WB->ID forwarding, which the
  read-first register file makes mandatory - flushing it hung the core.

## Second bug: test data collided with the HTIF window

t02, t03 and t04 used `lui xN, 0x1` = `0x1000` for their data area. The linker
script places `tohost` at `0x1000`.

Sail's HTIF watches that address, so `sw a1, 0(a0)` writing `0xabcde123` was
read as an HTIF command and **reset the machine** - Sail's PC jumped back to
`0x00000000` mid-program. Your core has no HTIF, so it simply stored the data.

Both machines behaved correctly; the program asked for two incompatible things
at one address.

Fixed by moving the data area to `0x1100`. Same failure class as the
`0xdeadbeef` episode at M3.2, where a store landed in the instruction stream: a
unified TCM has no protection between regions, and the program must respect the
map.

**This would have broken every ACT4 compliance test at M3.4 identically.**

## Sail configuration

`verif/sail/rv32sky.json`, an override on `--rv32`. Nine validation errors were
worked through, each naming exactly one inconsistency:

| Error | Cause |
|---|---|
| `Zama16b` granule | atomics config on a region with no atomics |
| CLINT unmapped | the override REPLACES `memory.regions` rather than merging |
| Interrupt generator unmapped | same |
| `Ziccamoa` needs `AMOArithmetic` | atomics extension without atomic support |
| `mstatus.FS` not read-only | no S, no F, but FS still writable |
| `physaddr_bits` 34 without Sv32 | address width implying an absent MMU |
| Zve*f/Zve*d need F/D | `V.support_level` was still `"Full"` |
| `mstatus.VS` not read-only | vector registers now disabled |
| index EEW exceeds ELEN | self-inflicted: forcing `elen_exp` to 3 |

Every one is the model refusing to describe incoherent hardware. That rigour is
what makes it worth checking against.

**The model matches the core exactly:** 76 of 78 extensions disabled, keeping
only `Zicsr` (the CSR block is built and verified, wired in at M4) and
`Zifencei` (the decoder accepts `fence.i` as a no-op). No CLINT, no interrupt
controller, `misa` read-only, 8 KB TCM at `0x0`, peripheral window at
`0x8000_0000`.

**A permissive model is a weak reference.** If Sail modelled the M extension
while the core rejects `mul`, a multiply would execute under Sail and trap on
the core - a divergence that is correct behaviour from both, describing
different machines.

## HTIF termination

`tohost` is 64-bit and Sail responds only when both halves are written in
succession (sail-riscv issue #218 reports three writes being needed). A single
4-byte store is ignored - the first attempt produced a **10.5 GB trace in
seconds** as the program spun in its halt loop.

ACT's own generated tests solve this by writing `tohost` INSIDE the halt loop.
The same approach here: the halt loop is the write loop, writing both halves.

`build.sh` now fails if `tohost` is absent, rather than producing a binary that
hangs Sail.

## Provenance note for earlier results

`docs/results/0013` (M3.2) and `0014` (M3.3) were obtained on a core with the
flush bug. Their conclusions stand - all four M3.3 mutations were re-run on the
corrected core and still fail, and every checksum is unchanged - but the runs
recorded there executed one extra instruction per taken branch.

## Reproducing

    ./verif/sail/run_lockstep.sh t01_alu t02_memory t03_checksum t04_hazards
