#!/usr/bin/env bash
# ci/build_sw_tests.sh -- rebuild every sw/tests program that has a tracked
# .hex, require the rebuilt .hex to equal the tracked one, and install the
# rebuilt .elf (git-ignored) where run_lockstep.sh and run_coverage.sh read it.
#
# WHY: the core harness runs the tracked .hex, but Sail runs the .elf, which is
# not tracked. Without this, a fresh clone has no .elf at all, and a .hex that
# had drifted from its .S would make lockstep compare two different programs.
# M3.7, docs/results/0030; the .gitignore comment that said otherwise was
# corrected in the same commit.
#
# Builds happen in a temporary directory, so no tracked file is ever written.
# The .elf files are copied into sw/tests/ only for programs whose .hex matched.
#
# Exit: 0 every program rebuilt identical; 1 any build failed or drifted.

set -u -o pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 2

echo "toolchain: $(riscv64-unknown-elf-as --version 2>&1 | sed -n 1p)  [$(command -v riscv64-unknown-elf-as)]"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp sw/tests/*.S "$T"/ || { echo "swbuild: no .S sources"; exit 1; }

mapfile -t HEXES < <(find sw/tests -maxdepth 1 -name '*.hex' | sort)
[ "${#HEXES[@]}" -gt 0 ] || { echo "swbuild: no tracked .hex files found"; exit 1; }

n_same=0; fail=0
for hex in "${HEXES[@]}"; do
  base="$(basename "$hex" .hex)"
  if [ ! -f "$T/$base.S" ]; then
    echo "  NO SOURCE  $hex has no $base.S"; fail=1; continue
  fi
  if ! (cd "$T" && bash "$REPO/sw/tests/build.sh" "$base.S"); then
    echo "  BUILD FAILED  $base.S"; fail=1; continue
  fi
  if cmp -s "$T/$base.hex" "$hex"; then
    cp "$T/$base.elf" "sw/tests/$base.elf"
    echo "  same   $hex"
    n_same=$((n_same + 1))
  else
    echo "  DRIFT  $hex differs from a rebuild of $base.S (tracked < > rebuilt):"
    diff "$hex" "$T/$base.hex"
    fail=1
  fi
done
echo "swbuild: $n_same of ${#HEXES[@]} programs rebuilt identical to the tracked .hex"
exit $fail
