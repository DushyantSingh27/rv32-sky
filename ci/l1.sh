#!/usr/bin/env bash
# ci/l1.sh -- L1: fast regression, run in CI on every push. PROJECT_CONTEXT 5.3;
# M3.7, docs/results/0030.
#
#   elfs      ci/check_elfs.py -- the committed ACT4 inputs are intact
#   swbuild   ci/build_sw_tests.sh -- every test program rebuilt, .hex unchanged
#   lockstep  verif/sail/run_lockstep.sh -- the core agrees with Sail
#   coverage  verif/verilator/coverage/run_coverage.sh -- 56 runs merged,
#             rtl/core against every 5.3 target
#   classify  classify_toggles.py -- every uncovered rtl/core toggle point is
#             explained by exactly one rule, and no rule is stale
#
# Every build directory is deleted first: a stale binary passing is failure
# mode #4, and it has happened three times. Every check runs even after one
# fails; output is printed in full.
#
# Exit: 0 every check passed; 1 any check failed; 2 the clean step failed.

set -u -o pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || { echo "l1: cannot cd to repo root"; exit 2; }
export PATH="$HOME/.local/bin:$PATH"
TSV=verif/verilator/coverage/obj_dir_cov/uncovered-toggles.tsv

printf '==================== L1 clean\n'
for d in core decoder act4; do rm -rf "verif/verilator/$d/obj_dir" "verif/verilator/$d/obj_dir_cov"; done
rm -rf verif/verilator/coverage/obj_dir_cov
for d in core decoder act4; do
  [ ! -e "verif/verilator/$d/obj_dir" ] && [ ! -e "verif/verilator/$d/obj_dir_cov" ] \
    || { echo "l1: could not delete the $d build directories"; exit 2; }
done
echo "build directories deleted"

CHECKS=(
  "elfs|python3 ci/check_elfs.py"
  "swbuild|bash ci/build_sw_tests.sh"
  "lockstep|bash verif/sail/run_lockstep.sh"
  "coverage|bash verif/verilator/coverage/run_coverage.sh"
  "classify|python3 verif/verilator/coverage/classify_toggles.py verif/verilator/coverage/obj_dir_cov/merged.dat > $TSV"
)

T0=$(date +%s.%N)
RESULTS=(); NFAIL=0
for c in "${CHECKS[@]}"; do
  name="${c%%|*}"; cmd="${c#*|}"
  printf '\n==================== L1 %s: %s\n' "$name" "$cmd"
  t0=$(date +%s.%N)
  bash -c "$cmd"
  rc=$?
  t1=$(date +%s.%N)
  secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
  if [ "$rc" = 0 ]; then RESULTS+=("[PASS] $name (${secs} s)"); else RESULTS+=("[FAIL] $name (exit $rc, ${secs} s)"); NFAIL=$((NFAIL + 1)); fi
done
T1=$(date +%s.%N)

printf '\n==================== L1 SUMMARY\n'
printf '  %s\n' "${RESULTS[@]}"
awk -v a="$T0" -v b="$T1" 'BEGIN { printf "  wall %.1f s\n", b - a }'
if [ "$NFAIL" -gt 0 ]; then
  echo "L1: FAIL ($NFAIL of ${#CHECKS[@]} checks)"
  exit 1
fi
echo "L1: PASS (${#CHECKS[@]} of ${#CHECKS[@]} checks)"
exit 0
