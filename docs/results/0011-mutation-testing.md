# Mutation testing across UVM environments 1-4

**Date:** 2026-08-13
**Method:** inject one deliberate fault into the RTL, run the environment,
confirm it fails, revert, confirm it passes.

## Why

All four environments reported zero mismatches and 100% functional coverage.
None had been shown to FAIL. **A checker that cannot fail is not a checker** -
and coverage measures what was exercised, not whether the checking works.

This is a manual, one-off form of mutation testing. The systematic equivalents
arrive later: formal property checking at M4 (riscv-formal) and ATPG fault
coverage at M8.

## Results

| Env | Injected fault | Errors | Verdict |
|---|---|---|---|
| 1 - ALU | `SRA` becomes `SRL` (drop the signed cast) | 21 | **CAUGHT** |
| 2 - muldiv | Divider compare `>=` becomes `>` | 60 | **CAUGHT** |
| 3 - regfile | `write_en` loses its x0 guard | **0** | **SURVIVED** |
| 4 - CSR | `mscratch` write inverts bit 0 | 64 | **CAUGHT** |

All four reverted cleanly to zero errors afterwards.

## FINDING 1: env 3 could not detect a surviving mutant

Changing `write_en = rd_we && (rd_addr != 5'd0)` to `write_en = rd_we` makes x0
writable. Env 3 reported **zero errors**.

Cause: the DUT has two independent x0 guards. The write-enable suppression was
removed, but the read mux still forces zero
(`rs1_data = (rs1_addr == 5'd0) ? '0 : regs[rs1_addr]`). x0 stores the value and
the read path masks it - **architecturally invisible through the ports**.

`docs/results/0008` claimed the write-then-read directed test "targets the
specific bug of a register file that STORES to entry 0 and masks it on read."
**That claim was false as written** and has been corrected. A port-level test
cannot distinguish those cases.

To be precise about severity: with both guards present the DUT is correct, and
with only the read mux it remains architecturally correct through the port
interface. This is a redundancy the test cannot see, not a bug that would escape
to silicon. But it matters if the register file is later swapped for ORRAM
(Decision D4), where the read mux is internal to the macro.

**Fix:** a mechanism-level assertion inside the RTL, checking `write_en` is
never asserted for x0 - not just that the read returns zero.

## FINDING 2: RTL assertions were invisible to the regression gate

After adding the assertion, the mutant fired it **twice** - and the run still
reported `UVM_ERROR : 0`.

`$error` from an immediate assertion is a simulator-level message
(`=E:[$error call]`). UVM's report server never sees it. Every check run in this
project so far greps `UVM_ERROR`, so **a regression could report a clean pass
while the DUT was broken**.

This affects all four blocks - every one has `` `ifndef SYNTHESIS `` assertions
that could not fail a regression.

**Fix:** a `check-errors` make target that counts UVM errors, UVM fatals AND
simulator-level assertion failures, and exits non-zero on any of them.

    make -f verif/dsim.mk regfile > run.log 2>&1
    make -f verif/dsim.mk check-errors LOG=run.log

Verified: FAIL on the mutant (2 RTL assertions), PASS on all four clean blocks.

This becomes load-bearing at M3, when CI runs on every commit. Without it the
two-tier assertion rule in PROJECT_CONTEXT 2.5 gives diagnostic aids rather than
gates.

## FINDING 3: detection is more sensitive than bit-level reasoning suggests

The CSR mutant inverted bit 0 on `mscratch` writes. Predicted ~2 errors (the
write-1 and write-0 passes on bit 0); observed **64**. Every bash pattern across
all 32 bits comes back wrong in bit 0, so 32 x 2 = 64.

Worth recording because it cuts against intuition: a single-bit fault in a
shared write path is detected by every access, not only by accesses that touch
that bit.

## Conclusion

Three of four environments demonstrably detect the faults they were written to
catch. The fourth did not, and fixing it exposed a flow-level gap that affected
all four.

**One deliberate fault in one line of RTL surfaced three distinct problems.**
That is the argument for making mutation testing routine rather than a one-off -
it should run before any environment is declared complete.

**Open item:** the four faults here were chosen by hand. A systematic sweep -
mutating every operator in every RTL file - would give a real mutation score.
Not attempted; the manual version was enough to find what it found.
