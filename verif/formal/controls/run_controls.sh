#!/usr/bin/env bash
# Formal flow controls: what SBY reports, measured, for answers known in advance.
#
#   K1 cover  cover(1'b1)                 reachable       predicted PASS
#   K2 cover  cover(1'b0)                 unreachable     predicted not PASS
#   K3 prove  assert(a == a)              always true     predicted PASS
#   K4 prove  assert(a == 0)              false at a=1    predicted FAIL
#   K5 prove  assume(0), assert(a == 0)   vacuous         predicted not PASS
#                                         (0026 saw PREUNSAT / ERROR for this)
#   K6 prove  slang: assert(a == a)       always true     predicted PASS
#   K7 prove  slang: assert(a == 0)       false at a=1    predicted FAIL
#
# K7 is the important one: if it PASSES, yosys-slang drops immediate
# assertions and any proof written that way is vacuous.
#
# Runs in a scratch copy so SBY's output directories never land in the repo.
# OSS CAD Suite shell. Usage: run_controls.sh [workdir]
set -u -o pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${1:-$HOME/scratch/formal_controls}"
rm -rf "$WORK"; mkdir -p "$WORK"; cp "$SRC"/*.sby "$SRC"/*.sv "$WORK"/
cd "$WORK" || exit 2
echo "=== tools"; command -v sby yosys yosys-smtbmc boolector; yosys -V
declare -A PRED=( [k1_cover_one]=PASS [k2_cover_zero]=notPASS [k3_assert_true]=PASS
                  [k4_assert_false]=FAIL [k5_vacuous]=notPASS [k6_slang_true]=PASS
                  [k7_slang_false]=FAIL )
bad=0
for j in k1_cover_one k2_cover_zero k3_assert_true k4_assert_false k5_vacuous k6_slang_true k7_slang_false; do
  echo; echo "==================== $j"
  cat "$j.sby"
  sby "$j.sby"; rc=$?
  st="$(cat "$j/status" 2>/dev/null || echo 'NO STATUS FILE')"
  first="${st%% *}"
  echo "--- $j: sby exit $rc, status file: '$st'"
  case "${PRED[$j]}" in
    notPASS) [ "$first" != PASS ] && v=as-predicted || v=CONTRADICTS ;;
    *)       [ "$first" = "${PRED[$j]}" ] && v=as-predicted || v=CONTRADICTS ;;
  esac
  [ "$v" = as-predicted ] || bad=$((bad + 1))
  printf 'CONTROL %-16s predicted %-8s status %-28s exit %s  %s\n' "$j" "${PRED[$j]}" "'$st'" "$rc" "$v" >> "$WORK/summary.txt"
done
echo; echo "==================== SUMMARY"; cat "$WORK/summary.txt"
echo "CONTROLS: $((7 - bad)) of 7 as predicted"
exit $(( bad > 0 ))
