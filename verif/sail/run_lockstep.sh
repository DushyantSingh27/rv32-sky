#!/bin/bash
# Run every test program under both Sail and the core, and compare.
#
# Sail is the RISC-V Foundation's executable formal specification of the ISA.
# Agreement instruction-by-instruction is a conformance claim, not an internal
# consistency check - every other result in this project compares the core
# against a value the core itself produced.
set -uo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.local/bin:$PATH"
SAIL="${SAIL:-$HOME/src/sail-riscv-bin/bin/sail_riscv_sim}"
WORK="${WORK:-$HOME/work}"
mkdir -p "$WORK"

# EXPECTED CHECKSUMS.
#
# t01/t02 store 0 on the pass path, so the harness's default convention
# (zero = PASS) applies and no expected value is needed. t03-t06 store a
# CHECKSUM, which the harness treats as a failure code unless --expect is
# given. Without it they report RESULT: FAIL every run.
#
# t05 and t06 had no expected value for their entire history. Because this
# script only ever read compare.py's verdict and discarded the harness's,
# both reported "all agree" while the harness reported FAIL - see the
# provenance note in docs/results/0017 and docs/results/0018.
expect_for() {
  case "$1" in
    t03_checksum) echo "0x00fe3a2e" ;;
    t04_hazards)  echo "0x00fe3a2e" ;;
    t05_csr)      echo "0x82a4c825" ;;
    t06_traps)    echo "0xc2ffe562" ;;
    *)            echo "" ;;
  esac
}

# NO ARGUMENTS MEANS ALL SEVEN (six until t07_counters joined on 2026-10-19,
# docs/results/0029). Until 2026-10-16 a call with no arguments ran
# this loop zero times and exited 0, having compared nothing
# (docs/results/0028). The count check after the loop makes any recurrence loud.
DEFAULT_PROGS="t01_alu t02_memory t03_checksum t04_hazards t05_csr t06_traps t07_counters"
if [ "$#" -eq 0 ]; then set -- $DEFAULT_PROGS; fi
EXPECT_N=$#
COMPARED=0
TOTAL_INSNS=0

FAIL=0
for T in "$@"; do
  printf "%-16s " "$T"
  $SAIL --rv32 --config-override verif/sail/rv32sky.json \
    --trace-instr --trace-gpr --trace-csr --trace-output "$WORK/sail_$T.log" \
    "sw/tests/$T.elf" >/dev/null 2>&1
  rm -f verif/verilator/core/obj_dir/Vcore_tb_top

  # BOTH VERDICTS ARE CHECKED.
  #
  # compare.py answers "does the core agree with Sail?"; the harness answers
  # "did the program run to completion and produce the right value?". They
  # are independent, and this script previously discarded the second - so a
  # core that timed out, hung, or stored a wrong checksum still reported
  # agreement over whatever prefix it managed. Both layers worked; the
  # composition lost one of them.
  # NOEXPECT=1 blanks the expected values, for verifying THIS SCRIPT's
  # harness-verdict check against known-bad data (docs/results/0018).
  # Copying the script elsewhere does not work: it cd's relative to $0.
  if [ "${NOEXPECT:-0}" = "1" ]; then EXP=""; else EXP=$(expect_for "$T"); fi
  (cd verif/verilator/core && make trace HEX="../../../sw/tests/$T.hex" \
     ${EXP:+EXPECT=$EXP} 2>&1) > "$WORK/core_$T.log"
  CORE_RC=$?

  OUT=$(python3 verif/sail/compare.py "$WORK/sail_$T.log" "$WORK/core_$T.log")
  if ! echo "$OUT" | grep -q "RESULT: PASS"; then
    echo "DIVERGED"; echo "$OUT" | tail -12; FAIL=1
  elif [ "$CORE_RC" -ne 0 ]; then
    echo "HARNESS FAIL (lockstep agreed)"
    grep -E "^(cycles=|stored value:|RESULT:)" "$WORK/core_$T.log"
    FAIL=1
  else
    echo "$OUT" | grep "instructions compared"
    # An agreement over ZERO instructions is agreement with nothing.
    N=$(echo "$OUT" | grep -oE '[0-9]+ instructions compared' | grep -oE '^[0-9]+')
    if [ -z "$N" ] || [ "$N" -eq 0 ]; then
      echo "  ^ refused: no instructions were compared"; FAIL=1
    else
      COMPARED=$((COMPARED + 1)); TOTAL_INSNS=$((TOTAL_INSNS + N))
    fi
  fi
done

echo "LOCKSTEP: $COMPARED of $EXPECT_N programs agree, $TOTAL_INSNS instructions compared"
if [ "$COMPARED" -ne "$EXPECT_N" ]; then
  echo "LOCKSTEP: FAIL - only $COMPARED of $EXPECT_N programs produced an agreeing comparison"
  FAIL=1
fi
exit $FAIL
