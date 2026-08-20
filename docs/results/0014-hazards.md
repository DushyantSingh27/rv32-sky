# M3.3: forwarding and interlocks

**Date:** 2026-08-17
**DUT:** `rtl/core/hazard_unit.sv`, wired into `rv32_core.sv`
**Gate:** a NOP-free program produces the same checksum as its padded equivalent


## PROVENANCE NOTE (added 2026-08-20)

The runs recorded in this file were obtained on a core with a **redirect flush
bug**: one instruction per taken branch was retiring that should have been
squashed, and because `wb_reg_we` gates on `mem_wb_q.valid`, its register write
actually landed.

Found by Sail lockstep (`docs/results/0015`), which no self-checking test in
this project could detect - all of them compare the core against a value the
core itself produced.

**The conclusions here stand.** Every checksum is unchanged after the fix, and
the mutation results were re-run on the corrected core and still fail. But the
cycle counts and retirement counts recorded below include the phantom
instructions.

## Result

| Program | Cycles | Retired | Checksum |
|---|---|---|---|
| `t03_checksum` — three NOPs between dependencies | ~270 | — | `0x00fe3a2e` |
| `t04_hazards` — identical code, all NOPs removed | 98 | 77 | `0x00fe3a2e` |

Same computation, same result, roughly a third of the cycles. `t01` and `t02`
still pass unchanged.

**Seven mutations injected, seven caught.**

## WB->ID forwarding is mandatory, not optional

The register file is read-first: a read colliding with a write to the same
address returns the PRE-WRITE value, verified across 6,009 collisions in env 3
(`docs/results/0008`). The file is read in ID and written in WB, three stages
apart — so without WB->ID forwarding, a value written in WB is invisible to an
instruction reading it in ID in the same cycle.

That is why `t01`–`t03` use **three** NOPs rather than two. The padding was
covering a gap, not merely being cautious.

Mutation H3 disabling this path caused a **timeout**, not a wrong answer: with
three-instruction dependencies broken throughout, control flow diverges far
enough that the program never reaches its terminating store.

## Design decisions

**Forwarding at the ALU operand muxes**, not into the ID/EX register. `id_ex_q`
keeps holding the architectural register values it read, so forwarding stays a
microarchitectural detail and the trace port remains meaningful for M3.5's Sail
lockstep.

**Priority: EX->EX beats MEM->EX.** Both may match when two writes to one
register land in consecutive cycles; the nearer producer carries the newer
value. Written as an explicit `if/else if` chain rather than relying on
assignment order, so the priority is a property of the code rather than of its
layout.

**x0 never forwards.** The decoder deliberately does NOT suppress `reg_write`
for `rd == x0` — the register file owns that, one guard in one place
(`docs/results/0012`). But the forwarding logic does not consult the register
file; it looks at `rd_addr` and `reg_write`. So the hazard unit needs its own
`rd_addr != 0` test, and its absence is a real bug rather than harmless
redundancy.

**Load-use stalls rather than re-issues.** A load produces data in MEM but the
next instruction needs it in EX — one stage too early, and no forwarding path
moves data backwards in time. One-cycle stall: hold IF and ID, bubble EX, let
the load reach MEM/WB where MEM->EX supplies it.

**Two paths beyond the ALU operands also need forwarding**, and both were nearly
missed:

- **Store data.** `sw x1, 0(x2)` right after writing `x1` must store the new
  value. `rs2` there is the DATA, bypassing the ALU entirely, so it takes the
  forwarded value directly into `ex_mem_q.rs2_data`.
- **JALR target.** `rs1` feeds the target calculation outside the ALU, so
  `jalr` after writing its base register would otherwise jump to a stale
  address.

## MUTATION TESTING

| # | Mutation | Result |
|---|---|---|
| H1 | EX->EX forwarding disabled | TIMEOUT |
| H2 | MEM->EX forwarding disabled | wrong checksum |
| H3 | WB->ID forwarding disabled | TIMEOUT |
| H4 | load-use interlock disabled | wrong checksum |
| H5 | forwarding priority inverted | **survived, then caught** |
| H6 | x0 forwarding guard removed | **survived, then caught** |
| H7 | store data not forwarded | wrong checksum |

### Two more test-value gaps, same shape as M3.2's four

**H5** needs two writes to the SAME register in consecutive cycles, so that MEM
and WB both match and the choice between them is observable. t04 never did that.

**H6** needs an instruction writing x0 followed closely by one reading it. t04
never wrote x0 deliberately.

Added to t03 (and therefore t04):

    addi  x27, x0, 100
    addi  x27, x0, 200      # second write, one cycle later
    add   x28, x27, x0      # must see 200, not 100

    addi  x0,  x0, 999      # architecturally a no-op
    add   x29, x0,  x0      # must be 0, not 999

Both mutations then failed.

**This is the fifth and sixth instance today of one pattern: the DUT computes a
function of its inputs, and the chosen inputs land where two different functions
agree.** The earlier four were the B-immediate bit 11, halfword offset, SRAI on
zero, and LBU with bit 7 clear (`docs/results/0012`, `0013`).

The x0 case is the most instructive: it is the interaction of two decisions each
correct in isolation. The decoder does not suppress `reg_write` for x0 because
the register file owns x0. The forwarding logic never asks the register file. Only
integration testing finds that.

## BUG: the test was position-dependent after claiming not to be

t04 initially failed with a checksum differing by exactly 12. The cause was in
t03, not the RTL.

t03 folded in the DIFFERENCE between two `auipc` results, with a comment
claiming this was position-independent. It is not: the difference equals the
byte distance between the two instructions, and stripping the NOPs changed that
distance from 16 to 4. 16 − 4 = 12.

Fixed by comparing one `auipc` against a LABEL resolved by the linker:

    here:
        auipc x24, 0
        lui   x25, %hi(here)
        addi  x25, x25, %lo(here)
        sub   x26, x24, x25      # 0 wherever `here` lands

Position-independent in the way the original only claimed to be. With
`alu_src_a_pc` broken, `auipc` computes `x0 + 0` while the `lui`/`addi` path
yields the real address, so the difference becomes large and nonzero.

## Build-system finding: two file lists, one build failure

Adding `hazard_unit.sv` to the lint command but not to the core harness's
Makefile produced `Cannot find file containing module: 'hazard_unit'` — lint
passed while the build failed.

Fixed with `rtl/files.f`, a single source list consumed by `tools/lint.sh` and
by the Verilator Makefiles. Adding a module now means editing one file.

Same principle as ADR-0001 portability rule 3, which imposed a shared source
list on the UVM environments. It was applied there and not here.

## Deferred

**The muldiv flush port.** `docs/vplan/02-rv32m.md` recorded that a 35-cycle
divide must be cancellable on a branch mispredict, and the block has no such
input. M3 is RV32I only, so the muldiv is not instantiated; adding the port now
would mean a full env 2 re-verification pass on a block nothing uses. **M4 adds
the port and re-verifies alongside RV32M decode.**

## Not verified

- **Interaction of flush and stall.** A branch immediately after a load-use
  stall is not specifically tested.
- **Independent reference.** The golden checksum is what a core passing seven
  mutations produces, not an externally derived value. M3.5's Sail lockstep
  supersedes this.
- **Structural coverage.** No line or toggle coverage has been measured on the
  core. PROJECT_INSTRUCTIONS 5.3 wants >=95%; Verilator `--coverage` at M3.7.

## Reproducing

    cd sw/tests
    ./build.sh t03_checksum.S
    python3 ../../tools/strip_nops.py t03_checksum.S t04_hazards.S
    ./build.sh t04_hazards.S
    cd ../verif/verilator/core
    make run HEX=../../../sw/tests/t04_hazards.hex EXPECT=0x00fe3a2e
