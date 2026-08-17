#!/bin/bash
# Lint the whole RTL from the shared file list.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

FILES=$(grep -v '^\s*#' rtl/files.f | grep -v '^\s*$')
TOP="${1:-rv32_core}"

verilator --lint-only -Wall --timing $FILES --top-module "$TOP"
echo "lint OK: $TOP"
