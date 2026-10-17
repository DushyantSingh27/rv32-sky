#!/usr/bin/env bash
# run_coverage.sh -- structural coverage of the RTL over the defined regression
# set, merged and reported per file. M3.7 stage 1 step 7; docs/results/0028.
#
# THE REGRESSION SET (decided 2026-10-17; probe_traps.S deliberately excluded)
#   - the six lockstep programs, with their expected checksums
#   - the 47 ACT4 compliance tests
#   - the decoder harness
#
# EVERY INPUT IS READ FROM WHERE IT ALREADY LIVES, never copied here:
#   program list + checksums : verif/sail/run_lockstep.sh (DEFAULT_PROGS, expect_for)
#   ACT4 arguments           : $ACT4/config/cores/rv32sky/run_cmd.txt
#   ACT4 test count          : verif/compliance/rv32sky/run_compliance.sh (EXPECT_TOTAL)
# Each extraction asserts what it found. A second copy of any of these would
# be the duplicated-source-list problem this project has hit four times.
#
# ONLY PASSING RUNS ARE MERGED (decision D): a run that fails may have reached
# lines through wrong behaviour. Pass means:
#   core     exit 0 and "RESULT: PASS"
#   decoder  exit 0 and "RESULT: PASS"
#   ACT4     exit 0 and an RVCP-SUMMARY line -- run_tests.py's rule
# The number of files merged is asserted.
#
# Every run writes its own data file: a second write OVERWRITES the first
# (verif/verilator/cov_semantics, T1).
#
# Exit: 0 every run passed and merged; 1 any run failed (the report is still
# printed, marked INCOMPLETE); 2 setup error.
#
# Usage:  verif/verilator/coverage/run_coverage.sh
#   env:  COV_OUT  output dir (default: this dir's obj_dir_cov, git-ignored)
#         ACT4     riscv-arch-test checkout (default ~/src/riscv-arch-test)
#         JOBS     parallel ACT4 runs (default nproc)

set -u -o pipefail

# ---- internal mode: one ACT4 test, invoked in parallel by xargs below ------
if [ "${1:-}" = "--act4-one" ]; then
  elf="$2"; rel="${elf#"$ELFDIR"/}"; name="${rel//\//__}"; name="${name%.elf}"
  t0=$(date +%s.%N)
  # shellcheck disable=SC2086  # ACT_ARGS is deliberately word-split
  "$ACT_BIN" $ACT_ARGS --cov-file "$OUT/act4/$name.dat" "$elf" > "$OUT/act4/$name.log" 2>&1
  rc=$?
  t1=$(date +%s.%N)
  st=FAIL
  [ "$rc" = 0 ] && grep -q 'RVCP-SUMMARY' "$OUT/act4/$name.log" && st=PASS
  awk -v s="$st" -v n="$name" -v r="$rc" -v a="$t0" -v b="$t1" \
      'BEGIN { printf "%s\t%s\t%s\t%.2f\n", s, n, r, b - a }'
  exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="${COV_OUT:-$HERE/obj_dir_cov}"
ACT4="${ACT4:-$HOME/src/riscv-arch-test}"
JOBS="${JOBS:-$(nproc)}"
die() { echo "run_coverage: FATAL: $*" >&2; exit 2; }
banner() { printf '\n==================== %s\n' "$*"; }
T_START=$(date +%s)
cd "$REPO" || die "cannot cd to $REPO"

banner "INPUTS (read from their sources, each asserted)"
LS=verif/sail/run_lockstep.sh
PROGS="$(sed -nE 's/^DEFAULT_PROGS="([^"]+)"$/\1/p' "$LS")"
[ "$(wc -w <<< "$PROGS")" = 6 ] || die "expected 6 programs in $LS DEFAULT_PROGS, got: '$PROGS'"
declare -A EXPECT
while read -r p v; do EXPECT[$p]="$v"; done < <(
  sed -nE 's/^[[:space:]]*(t0[0-9]_[a-z0-9_]+)\)[[:space:]]*echo "(0x[0-9a-fA-F]+)".*/\1 \2/p' "$LS")
[ "${#EXPECT[@]}" = 4 ] || die "expected 4 checksums in $LS expect_for, found ${#EXPECT[@]}"
echo "programs: $PROGS"
for p in "${!EXPECT[@]}"; do echo "  expect $p = ${EXPECT[$p]}"; done | sort

RC_FILE="$ACT4/config/cores/rv32sky/run_cmd.txt"
[ -f "$RC_FILE" ] || die "$RC_FILE not found"
read -r -a RCMD < "$RC_FILE"
[ "${#RCMD[@]}" -ge 2 ] || die "$RC_FILE has no arguments after the binary"
ACT_ARGS="${RCMD[*]:1}"
echo "ACT4 args from run_cmd.txt: $ACT_ARGS"
N_ACT4="$(sed -nE 's/^EXPECT_TOTAL=([0-9]+)$/\1/p' verif/compliance/rv32sky/run_compliance.sh)"
[ -n "$N_ACT4" ] || die "EXPECT_TOTAL not found in run_compliance.sh"
ELFDIR="$ACT4/work/rv32sky/elfs"
mapfile -t ELFS < <(find "$ELFDIR" -name '*.elf' 2>/dev/null | sort)
[ "${#ELFS[@]}" = "$N_ACT4" ] || die "found ${#ELFS[@]} ELFs in $ELFDIR, run_compliance.sh expects $N_ACT4. Run run_compliance.sh first."
echo "ACT4 ELFs: ${#ELFS[@]} (expected $N_ACT4)"

banner "BUILD (clean; guard; generated exclusion file)"
make -f tools/guards.mk check-verilator || die "Verilator guard"
for d in core decoder act4; do
  rm -rf "verif/verilator/$d/obj_dir_cov"
  make -C "verif/verilator/$d" cov || die "coverage build failed: $d"
done
CORE_BIN=verif/verilator/core/obj_dir_cov/Vcore_tb_top
DEC_BIN=verif/verilator/decoder/obj_dir_cov/Vdecode_top
ACT_BIN="$REPO/verif/verilator/act4/obj_dir_cov/Vcore_tb_top"
for b in "$CORE_BIN" "$DEC_BIN" "$ACT_BIN"; do [ -x "$b" ] || die "$b missing after build"; done

rm -rf "$OUT"; mkdir -p "$OUT/core" "$OUT/act4"
PASSED=(); FAILED=()

banner "CORE HARNESS: $PROGS"
for p in $PROGS; do
  hex="$REPO/sw/tests/$p.hex"; exp="${EXPECT[$p]:-}"
  "$CORE_BIN" --hex "$hex" +HEX="$hex" ${exp:+--expect "$exp"} \
      --cov-file "$OUT/core/$p.dat" > "$OUT/core/$p.log" 2>&1
  rc=$?
  if [ "$rc" = 0 ] && grep -q '^RESULT: PASS$' "$OUT/core/$p.log"; then
    PASSED+=("$OUT/core/$p.dat"); echo "  PASS  $p"
  else
    FAILED+=("core $p (exit $rc)"); echo "  FAIL  $p (exit $rc) -- log:"; cat "$OUT/core/$p.log"
  fi
done

banner "DECODER HARNESS"
"$DEC_BIN" --cov-file "$OUT/decoder.dat" > "$OUT/decoder.log" 2>&1; rc=$?
cat "$OUT/decoder.log"
if [ "$rc" = 0 ] && grep -q '^RESULT: PASS$' "$OUT/decoder.log"; then
  PASSED+=("$OUT/decoder.dat"); echo "  PASS  decoder"
else
  FAILED+=("decoder (exit $rc)"); echo "  FAIL  decoder (exit $rc)"
fi

banner "ACT4: ${#ELFS[@]} tests, $JOBS in parallel"
export OUT ELFDIR ACT_BIN ACT_ARGS
printf '%s\n' "${ELFS[@]}" | xargs -P "$JOBS" -n 1 bash "$HERE/run_coverage.sh" --act4-one \
  | sort -k2 > "$OUT/act4/status.tsv"
n_pass=0
while IFS=$'\t' read -r st name rc secs; do
  if [ "$st" = PASS ]; then
    PASSED+=("$OUT/act4/$name.dat"); n_pass=$((n_pass + 1))
  else
    FAILED+=("act4 $name (exit $rc)"); echo "  FAIL  $name (exit $rc) -- log:"; cat "$OUT/act4/$name.log"
  fi
done < "$OUT/act4/status.tsv"
echo "  $n_pass of ${#ELFS[@]} passed"
echo "  slowest three (seconds):"
sort -t$'\t' -k4 -g "$OUT/act4/status.tsv" | tail -n 3 | awk -F'\t' '{printf "    %8s  %s\n", $4, $2}'
awk -F'\t' '{s += $4} END {printf "  summed ACT4 run time: %.1f s\n", s}' "$OUT/act4/status.tsv"

banner "MERGE (passing runs only)"
WANT=$(( $(wc -w <<< "$PROGS") + 1 + N_ACT4 ))
echo "  merging ${#PASSED[@]} data files (a complete run is $WANT)"
verilator_coverage --write "$OUT/merged.dat" "${PASSED[@]}" || die "verilator_coverage --write failed"

banner "REPORT -- rtl/core is gated (5.3), rtl/mem is reported only (decision B)"
python3 tools/covdat.py files "$OUT/merged.dat" --under rtl/
python3 - "$REPO/tools/covdat.py" "$OUT/merged.dat" "$REPO/rtl/files.f" <<'PY'
import importlib.util, sys, collections
spec = importlib.util.spec_from_file_location("covdat", sys.argv[1])
cd = importlib.util.module_from_spec(spec); spec.loader.exec_module(cd)
union, _ = cd.build_union(cd.parse(sys.argv[2]))
want = [l.split("#")[0].strip() for l in open(sys.argv[3])]
want = [w for w in want if w and not w.startswith("rtl/pkg/")]
seen = {k[0] for k in union}
missing = [w for w in want if not any(f.endswith(w) for f in seen)]
print("every rtl file outside rtl/pkg present:", "yes" if not missing else f"NO - missing {missing}")
TARGET = {"line": 95.0, "branch": 95.0, "toggle": 90.0}       # PROJECT_CONTEXT 5.3
for area in ("rtl/core/", "rtl/mem/"):
    pts, hit = collections.Counter(), collections.Counter()
    for k, c in union.items():
        if area in k[0]:
            pts[k[4]] += 1; hit[k[4]] += c > 0
    print(f"{area}")
    for t in ("line", "branch", "toggle"):
        if not pts[t]:
            continue
        pct = 100.0 * hit[t] / pts[t]
        mark = (f"target {TARGET[t]:.0f}%: {'MET' if pct >= TARGET[t] else 'BELOW'}"
                if area == "rtl/core/" else "reported only")
        print(f"  {t:<7} {hit[t]:>6} / {pts[t]:<6} = {pct:6.2f}%   {mark}")
PY

banner "SUMMARY"
echo "data: $OUT   wall time: $(( $(date +%s) - T_START )) s"
if [ "${#FAILED[@]}" -gt 0 ] || [ "${#PASSED[@]}" != "$WANT" ]; then
  echo "INCOMPLETE: ${#FAILED[@]} run(s) failed, ${#PASSED[@]} of $WANT merged:"
  printf '  %s\n' "${FAILED[@]}"
  exit 1
fi
echo "COMPLETE: all $WANT runs passed and were merged"
exit 0
