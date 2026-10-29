#!/usr/bin/env bash
# ci/l0.sh -- L0: the checks that run before every push (tools/hooks/pre-push)
# and as the first CI job. PROJECT_CONTEXT 5.3; M3.7, docs/results/0030.
#
# Every check runs even after one fails, so a single run shows every problem.
# Each check's output is printed in full; nothing is filtered.
#
# PATH: $HOME/.local/bin first, the same convention as tools/lint.sh and
# verif/sail/run_lockstep.sh, so the guard checks the Verilator that lint
# actually uses. In an OSS CAD Suite shell this selects the pinned 5.050 rather
# than failing; the guard still fails if no pinned build is installed.
#
# Exit: 0 every check passed; 1 any check failed.

set -u -o pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || { echo "l0: cannot cd to repo root"; exit 2; }
export PATH="$HOME/.local/bin:$PATH"

CHECKS=(
  "guard|make -f tools/guards.mk check-verilator"
  "lint|tools/lint.sh"
  "covvlt-selftest|python3 tools/gen_cov_vlt.py selftest"
  "covvlt-emit|python3 tools/gen_cov_vlt.py emit --root . > /dev/null"
  "pragmas|python3 ci/check_pragmas.py"
  "filelists|python3 ci/check_filelists.py"
)

T0=$(date +%s.%N)
RESULTS=()
NFAIL=0
for c in "${CHECKS[@]}"; do
  name="${c%%|*}"; cmd="${c#*|}"
  printf '\n==================== L0 %s: %s\n' "$name" "$cmd"
  bash -c "$cmd"
  rc=$?
  if [ "$rc" = 0 ]; then RESULTS+=("[PASS] $name"); else RESULTS+=("[FAIL] $name (exit $rc)"); NFAIL=$((NFAIL + 1)); fi
done
T1=$(date +%s.%N)

printf '\n==================== L0 SUMMARY\n'
printf '  %s\n' "${RESULTS[@]}"
awk -v a="$T0" -v b="$T1" 'BEGIN { printf "  wall %.2f s\n", b - a }'
if [ "$NFAIL" -gt 0 ]; then
  echo "L0: FAIL ($NFAIL of ${#CHECKS[@]} checks)"
  exit 1
fi
echo "L0: PASS (${#CHECKS[@]} of ${#CHECKS[@]} checks)"
exit 0
