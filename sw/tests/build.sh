#!/bin/bash
# Assemble a test program into a hex image for the Verilator harness.
#
# -m elf32lriscv is REQUIRED. The toolchain is riscv64-unknown-elf-*, and while
# the assembler honours -march=rv32i -mabi=ilp32, the LINKER has no such flags
# and defaults to elf64-littleriscv. Without -m it fails with:
#   ABI is incompatible with that of the selected emulation
#
# No error suppression anywhere. An earlier version used `ld ... || ld ...` to
# fall back on an unsupported option, which hid the real failure entirely.
set -euo pipefail

SRC="${1:-}"
[ -z "$SRC" ] && { echo "usage: build.sh prog.S"; exit 1; }
BASE="${SRC%.S}"

riscv64-unknown-elf-as  -march=rv32i -mabi=ilp32 "$SRC" -o "$BASE.o"
riscv64-unknown-elf-ld  -m elf32lriscv -Ttext=0x0 "$BASE.o" -o "$BASE.elf"
riscv64-unknown-elf-objcopy -O binary "$BASE.elf" "$BASE.bin"
od -An -tx4 -v -w4 "$BASE.bin" | tr -d ' ' | grep -v '^$' > "$BASE.hex"

WORDS=$(wc -l < "$BASE.hex")
echo "$BASE.hex: $WORDS words"
[ "$WORDS" -gt 0 ] || { echo "ERROR: empty hex image"; exit 1; }
