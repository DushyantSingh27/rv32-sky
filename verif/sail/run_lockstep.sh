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

FAIL=0
for T in "$@"; do
  printf "%-16s " "$T"
  $SAIL --rv32 --config-override verif/sail/rv32sky.json \
    --trace-instr --trace-gpr --trace-csr --trace-output "$WORK/sail_$T.log" \
    "sw/tests/$T.elf" >/dev/null 2>&1
  rm -f verif/verilator/core/obj_dir/Vcore_tb_top
  (cd verif/verilator/core && make trace HEX="../../../sw/tests/$T.hex" 2>&1) \
    > "$WORK/core_$T.log"
  OUT=$(python3 verif/sail/compare.py "$WORK/sail_$T.log" "$WORK/core_$T.log")
  if echo "$OUT" | grep -q "RESULT: PASS"; then
    echo "$OUT" | grep "instructions compared"
  else
    echo "DIVERGED"; echo "$OUT" | tail -12; FAIL=1
  fi
done
exit $FAIL
