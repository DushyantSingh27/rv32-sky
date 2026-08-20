#!/bin/bash
# Assemble a test program into an ELF plus a hex image.
#
# -m elf32lriscv is REQUIRED: the toolchain is riscv64-unknown-elf-*, and while
# the assembler honours -march=rv32i -mabi=ilp32, the LINKER has no such flags
# and defaults to elf64-littleriscv.
#
# The linker script places `tohost` at 0x1000 so Sail and ACT4 terminate on a
# write there. Without it Sail runs a halt loop forever.
#
# No error suppression. An earlier version used `ld ... 2>/dev/null || ld ...`
# to tolerate one missing option and hid an unrelated failure completely.
set -euo pipefail

SRC="${1:-}"
[ -z "$SRC" ] && { echo "usage: build.sh prog.S"; exit 1; }
BASE="${SRC%.S}"
LD_SCRIPT="$(dirname "$0")/../linker/rv32sky.ld"

riscv64-unknown-elf-as  -march=rv32i -mabi=ilp32 "$SRC" -o "$BASE.o"
riscv64-unknown-elf-ld  -m elf32lriscv -T "$LD_SCRIPT" "$BASE.o" -o "$BASE.elf"
riscv64-unknown-elf-objcopy -O binary "$BASE.elf" "$BASE.bin"
od -An -tx4 -v -w4 "$BASE.bin" | tr -d ' ' | grep -v '^$' > "$BASE.hex"

WORDS=$(wc -l < "$BASE.hex")
TEXT=$(riscv64-unknown-elf-size -A "$BASE.elf" | awk '/\.text/ {print $2}')
echo "$BASE.hex: $WORDS words, .text = $TEXT bytes"
[ "$WORDS" -gt 0 ] || { echo "ERROR: empty hex image"; exit 1; }

# tohost must exist, or Sail runs forever.
if ! riscv64-unknown-elf-nm "$BASE.elf" | grep -q " tohost$"; then
  echo "ERROR: no tohost symbol - Sail will not terminate"; exit 1
fi
