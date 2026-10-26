#!/usr/bin/env bash
# Equivalence evidence for the twelve default-arm folds (folds.py).
#
#   gold    = rtl/ at BASE (the commit before the folds), via git archive
#   stage1  = gold + the class A/B/C folds only
#   folded  = the working tree; must equal gold + every fold in folds.py
#
# Unconstrained equivalence, Yosys equiv flow (equiv_make, equiv_simple,
# equiv_induct, equiv_status -assert; read from `help` 2026-10-25), gold
# and gate each elaborated and flattened in its own session, then compared:
#   dec     decoder  gold vs folded            PASS     D90 D119 D295
#   lsu_c   lsu      gold vs stage1            PASS     L59 L71 L83
#   alu_c   alu      gold vs stage1            PASS     A58
#   rf      regfile  gold vs folded            PASS     R103 R115
#   core    rv32_core gold vs folded, gold submodules on both sides   PASS  W890
#   id_rf   regfile  gold vs gold              PASS     control: flow closes on state
# Class D, SBY prove on a miter (status semantics: verif/formal/controls):
#   alu_d_free / lsu_d_free   no constraint     FAIL    control: the fold is real
#   alu_d / lsu_d             decoded range     PASS    A45 / L50
# Wrong folds, scratch copies only - each must FAIL its check:
#   X_DEC X_LSU X_ALU X_RF X_CORE (equiv), X_ALUD X_LSUD (class D)
# Every check that passes has a mutant that fails it, so none is vacuous.
#
# OSS CAD Suite shell. Usage: run_fold_equiv.sh <base-commit> [workdir]
# Exit 0 only if every result is as predicted. Last line: FOLD EQUIV: ...
set -u -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BASE="${1:?usage: run_fold_equiv.sh <base-commit> [workdir]}"
WORK="${2:-$HOME/scratch/fold_equiv}"
CAP=1800
RES=(); BAD=0
rec() { RES+=("$*"); echo ">>> $*"; }
want() { if [ "$2" = "$3" ]; then rec "PASS  $1: $2"; else rec "FAIL  $1: got $2, want $3"; BAD=$((BAD+1)); fi; }

rm -rf "$WORK"; mkdir -p "$WORK/gold"
echo "=== tools"; command -v yosys sby timeout python3; yosys -V
git -C "$REPO" log --oneline -1
echo "=== base $BASE: $(git -C "$REPO" log --oneline -1 "$BASE")"
git -C "$REPO" archive "$BASE" rtl | tar -x -C "$WORK/gold" || { echo "STOP: git archive $BASE"; exit 1; }

mapfile -t RTL < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$REPO/rtl/files.f")

# The working tree must be EXACTLY gold + folds.py, so the table is the change.
python3 "$HERE/folds.py" build "$WORK/gold" "$WORK/expect" ABCD || { echo "STOP: folds do not apply to $BASE"; exit 1; }
python3 "$HERE/folds.py" build "$WORK/gold" "$WORK/stage1" ABC  || { echo "STOP: stage1 build"; exit 1; }
for f in alu decoder lsu regfile rv32_core; do
  if ! diff "$WORK/expect/rtl/core/$f.sv" "$REPO/rtl/core/$f.sv"; then
    echo "STOP: rtl/core/$f.sv is not gold + folds.py"; exit 1
  fi
done
echo "working tree == $BASE + folds.py, for all five files"

rename() {  # <file> <module> <newname>
  python3 - "$1" "$2" "$3" <<'PY' || exit 1
import sys
f, m, n = sys.argv[1:4]
s = open(f).read()
old = f"module {m}\n"
assert s.count(old) == 1, f"'module {m}' occurs {s.count(old)} times in {f}"
open(f, "w").write(s.replace(old, f"module {n}\n"))
PY
}

# eq <job> <module> <gold.sv> <gate.sv> [mutant] [dep ...]   -> ST
eq() {
  local job="$1" m="$2" g="$3" n="$4" mut="$5"; shift 5
  local d="$WORK/$job"; rm -rf "$d"; mkdir -p "$d"
  local deps=()
  for x in "$@"; do cp "$x" "$d/"; deps+=("$(basename "$x")"); done
  cp "$g" "$d/${m}_gold.sv"; cp "$n" "$d/${m}_gate.sv"
  [ -n "$mut" ] && { python3 "$HERE/folds.py" mutate "$d/${m}_gate.sv" "$mut" || exit 1; }
  rename "$d/${m}_gold.sv" "$m" "${m}_gold"; rename "$d/${m}_gate.sv" "$m" "${m}_gate"
  # Gold and gate are elaborated in SEPARATE Yosys sessions and meet only as
  # RTLIL. MEASURED 2026-10-25 (s11 run 1): reading both in one session gives
  # each a `top` attribute, `hierarchy` then picks one and deletes the other
  # ("Removing unused module `\\regfile_gold'"), and equiv_make fails with
  # "Can't find gold module". `hierarchy -top <side>` after flatten is used
  # on purpose here: it removes the now-unused submodules, so each .il holds
  # exactly one module.
  local side
  for side in gold gate; do
    cat > "$d/$side.ys" <<YS
plugin -i slang
read_slang --std 1800-2017 --top ${m}_${side} ${deps[*]} ${m}_${side}.sv
hierarchy -check -top ${m}_${side}
proc
flatten
hierarchy -top ${m}_${side}
memory
opt_clean
async2sync
ls
write_rtlil ${side}.il
YS
  done
  cat > "$d/eq.ys" <<YS
read_rtlil gold.il
read_rtlil gate.il
ls
equiv_make ${m}_gold ${m}_gate equiv
hierarchy -top equiv
equiv_simple -seq 5
equiv_induct -seq 5
equiv_status
equiv_status -assert
YS
  echo; echo "---------- $job ($m${mut:+, mutant $mut})"
  diff "$g" "$n"
  cat "$d/gold.ys" "$d/eq.ys"
  local t0=$SECONDS
  ( cd "$d" && timeout "$CAP" yosys -s gold.ys && timeout "$CAP" yosys -s gate.ys \
      && timeout "$CAP" yosys -s eq.ys ) > "$WORK/$job.log" 2>&1; local rc=$?
  cat "$WORK/$job.log"
  if   [ "$rc" = 124 ]; then ST=TIMEOUT
  elif [ "$rc" = 0 ] && grep -q "Executing EQUIV_STATUS" "$WORK/$job.log"; then ST=PASS
  elif [ "$rc" != 0 ] && grep -qi "unproven" "$WORK/$job.log"; then ST=FAIL
  else ST="OTHER(rc=$rc)"; fi
  echo "--- $job: yosys exit $rc -> $ST, $((SECONDS - t0)) s"
}

# dd <job> <module> <c.sv> <f.sv> <miter> <defs> [mutant]   -> ST
dd() {
  local job="$1" m="$2" c="$3" f="$4" miter="$5" defs="$6" mut="${7:-}"
  local d="$WORK/$job"; rm -rf "$d"; mkdir -p "$d"
  cp "$WORK/gold/rtl/pkg/rv32_pkg.sv" "$d/"
  cp "$c" "$d/${m}_c.sv"; cp "$f" "$d/${m}_f.sv"; cp "$HERE/$miter" "$d/"
  [ -n "$mut" ] && { python3 "$HERE/folds.py" mutate "$d/${m}_f.sv" "$mut" || exit 1; }
  rename "$d/${m}_c.sv" "$m" "${m}_c"; rename "$d/${m}_f.sv" "$m" "${m}_f"
  local top="${miter%.sv}"
  {
    echo "[options]"; echo "mode prove"; echo "depth 2"; echo
    echo "[engines]"; echo "smtbmc boolector"; echo
    echo "[script]"; echo "plugin -i slang"
    echo "read_slang --std 1800-2017 $defs --top $top rv32_pkg.sv ${m}_c.sv ${m}_f.sv $miter"
    echo "prep -top $top"; echo
    echo "[files]"; echo rv32_pkg.sv; echo "${m}_c.sv"; echo "${m}_f.sv"; echo "$miter"
  } > "$d/job.sby"
  echo; echo "---------- $job ($m $defs${mut:+, mutant $mut})"
  diff "$c" "$f"
  cat "$d/job.sby"
  ( cd "$d" && timeout "$CAP" sby job.sby ) > "$WORK/$job.log" 2>&1; local rc=$?
  cat "$WORK/$job.log"
  ST="$(cat "$d/job/status" 2>/dev/null || echo NONE)"; [ "$rc" = 124 ] && ST=TIMEOUT
  echo "--- $job: sby exit $rc, status '$ST'"
  ST="${ST%% *}"
}

G="$WORK/gold/rtl"; S1="$WORK/stage1/rtl"; F="$REPO/rtl"
PKG="$G/pkg/rv32_pkg.sv"
CORE_DEPS=()
for f in "${RTL[@]}"; do [ "$(basename "$f")" = rv32_core.sv ] || CORE_DEPS+=("$WORK/gold/$f"); done

echo; echo "==================== UNCONSTRAINED EQUIVALENCE"
eq id_rf regfile   "$G/core/regfile.sv"   "$G/core/regfile.sv"   ""     "$PKG"; want "id_rf (gold vs gold)" "$ST" PASS
eq dec   decoder   "$G/core/decoder.sv"   "$F/core/decoder.sv"   ""     "$PKG"; want "dec   D90 D119 D295" "$ST" PASS
eq lsu_c lsu       "$G/core/lsu.sv"       "$S1/core/lsu.sv"      ""     "$PKG"; want "lsu_c L59 L71 L83"   "$ST" PASS
eq alu_c alu       "$G/core/alu.sv"       "$S1/core/alu.sv"      ""     "$PKG"; want "alu_c A58"           "$ST" PASS
eq rf    regfile   "$G/core/regfile.sv"   "$F/core/regfile.sv"   ""     "$PKG"; want "rf    R103 R115"     "$ST" PASS
eq core  rv32_core "$G/core/rv32_core.sv" "$F/core/rv32_core.sv" ""     "${CORE_DEPS[@]}"; want "core  W890" "$ST" PASS

echo; echo "==================== CLASS D"
dd alu_d_free alu "$S1/core/alu.sv" "$F/core/alu.sv" alu_d_miter.sv "-D FREE"; want "alu_d_free (control)" "$ST" FAIL
dd alu_d      alu "$S1/core/alu.sv" "$F/core/alu.sv" alu_d_miter.sv "";        want "alu_d A45"            "$ST" PASS
dd lsu_d_free lsu "$S1/core/lsu.sv" "$F/core/lsu.sv" lsu_d_miter.sv "-D FREE"; want "lsu_d_free (control)" "$ST" FAIL
dd lsu_d      lsu "$S1/core/lsu.sv" "$F/core/lsu.sv" lsu_d_miter.sv "";        want "lsu_d L50"            "$ST" PASS

echo; echo "==================== WRONG FOLDS"
eq X_DEC  decoder   "$G/core/decoder.sv"   "$F/core/decoder.sv"   X_DEC  "$PKG"; want "X_DEC  vs dec"   "$ST" FAIL
eq X_LSU  lsu       "$G/core/lsu.sv"       "$S1/core/lsu.sv"      X_LSU  "$PKG"; want "X_LSU  vs lsu_c" "$ST" FAIL
eq X_ALU  alu       "$G/core/alu.sv"       "$S1/core/alu.sv"      X_ALU  "$PKG"; want "X_ALU  vs alu_c" "$ST" FAIL
eq X_RF   regfile   "$G/core/regfile.sv"   "$F/core/regfile.sv"   X_RF   "$PKG"; want "X_RF   vs rf"    "$ST" FAIL
eq X_CORE rv32_core "$G/core/rv32_core.sv" "$F/core/rv32_core.sv" X_CORE "${CORE_DEPS[@]}"; want "X_CORE vs core" "$ST" FAIL
dd X_ALUD alu "$S1/core/alu.sv" "$F/core/alu.sv" alu_d_miter.sv "" X_ALUD; want "X_ALUD vs alu_d" "$ST" FAIL
dd X_LSUD lsu "$S1/core/lsu.sv" "$F/core/lsu.sv" lsu_d_miter.sv "" X_LSUD; want "X_LSUD vs lsu_d" "$ST" FAIL

echo; echo "==================== SUMMARY"
printf '%s\n' "${RES[@]}"
if [ "$BAD" = 0 ]; then echo "FOLD EQUIV: all ${#RES[@]} results as predicted"; exit 0; fi
echo "FOLD EQUIV: $BAD of ${#RES[@]} not as predicted"; exit 1
