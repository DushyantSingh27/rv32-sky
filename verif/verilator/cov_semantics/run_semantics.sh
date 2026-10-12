#!/usr/bin/env bash
# M3.7 stage 0 step 3 -- what Verilator's coverage data actually does.
#
# Every Stage 1 number depends on these answers, and none is in --help:
#   T1  Does a second run overwrite coverage.dat or accumulate into it?
#   T2  Does verilator_coverage --write merge same-binary runs as a union?
#   T3  Does it merge one source file reached through two different tops?
#   T4  Which signals does toggle coverage silently leave out?
#   T5  What do --filter-type, --report summary and --write-info produce?
#   T6  Can a .vlt configuration file exclude line ranges from coverage?
#
# Each test is built so the competing answers produce DIFFERENT output.
# Read the whole log; do not grep it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
COVDAT=(python3 "$REPO/tools/covdat.py")
RUN="$HERE/obj_dir/run"

banner() { printf '\n==================== %s\n' "$*"; }

banner "BUILD (clean first: stale binaries have faked passes three times)"
make -C "$HERE" clean
# Deliberately no goal: this also tests that including guards.mk did not
# steal the default goal. If it did, only the guard runs, nothing is built,
# and the first ./Vtop_a below fails with "No such file".
make -C "$HERE"

mkdir -p "$RUN"
cd "$RUN"

banner "T1  overwrite or accumulate?  same binary, default file, SEL=1 then SEL=0"
# Overwrite:   in run2 the 'if (sel)' arm reads 0 and the else arm is nonzero.
# Accumulate:  in run2 BOTH arms are nonzero.
rm -f coverage.dat
../a/Vtop_a +SEL=1
test -f coverage.dat || { echo "FATAL: no coverage.dat after run 1"; exit 3; }
cp coverage.dat run1_sel1.dat
../a/Vtop_a +SEL=0
cp coverage.dat run2_sel0.dat
"${COVDAT[@]}" summary run1_sel1.dat
"${COVDAT[@]}" dump    run1_sel1.dat --file cov_leaf.sv
"${COVDAT[@]}" dump    run2_sel0.dat --file cov_leaf.sv

banner "T2  merge, same binary"
# Union:      merged record count == run1's, both arms nonzero, counts summed.
# Duplicate:  merged record count == run1 + run2.
verilator_coverage --write merged_same.dat run1_sel1.dat run2_sel0.dat
"${COVDAT[@]}" summary merged_same.dat
"${COVDAT[@]}" dump    merged_same.dat --file cov_leaf.sv

banner "T3  merge across tops: cov_leaf at top_a.u_leaf vs top_b.u_wrap.inner"
# One record per point, both arms nonzero: points keyed by source, so the
#   decoder harness's coverage of decoder.sv merges with the core harness's.
# Two records per point differing only in hierarchy: keyed by instance, and
#   the per-line union has to be computed after the merge.
../b/Vtop_b +SEL=1 +verilator+coverage+file+runb_sel1.dat
test -f runb_sel1.dat || { echo "FATAL: +verilator+coverage+file+ was ignored"; exit 3; }
"${COVDAT[@]}" dump runb_sel1.dat --file cov_leaf.sv
verilator_coverage --write merged_tops.dat run2_sel0.dat runb_sel1.dat
"${COVDAT[@]}" dump  merged_tops.dat --file cov_leaf.sv
"${COVDAT[@]}" files merged_tops.dat --under cov_leaf.sv

banner "T4  toggle points per signal in cov_wide (any ABSENT signal was silently excluded)"
"${COVDAT[@]}" signals run1_sel1.dat --file cov_wide.sv \
  --expect w32,w256,w257,w1024,w4096,ws,arr8,arr64,arr2k

banner "T4b same probe, --coverage-max-width 131072: every ABSENT above should now be PRESENT"
../w/Vtop_a +SEL=1 +verilator+coverage+file+wide.dat
"${COVDAT[@]}" signals wide.dat --file cov_wide.sv \
  --expect w32,w256,w257,w1024,w4096,ws,arr8,arr64,arr2k

banner "T5a --filter-type: a name that matches yields records, a wrong one yields none"
for ty in line toggle; do
  rm -f "only_$ty.dat"
  verilator_coverage --filter-type "$ty" --write "only_$ty.dat" merged_same.dat || true
  if [ -s "only_$ty.dat" ]; then
    "${COVDAT[@]}" summary "only_$ty.dat" || echo "(--filter-type $ty: no usable records)"
  else
    echo "(--filter-type $ty: no output file, or empty)"
  fi
done

banner "T5b --report summary"
verilator_coverage --report summary merged_same.dat || echo "(--report summary FAILED)"

banner "T5c --write-info on top_b alone (small enough to read whole)"
verilator_coverage --write-info leaf_b.info runb_sel1.dat || echo "(--write-info FAILED)"
cat leaf_b.info || true

banner "T6  exclusion by .vlt file; baseline is runb_sel1.dat (same top, no .vlt)"
# excl_logic (lines 10-16): cov_leaf line+branch points gone, toggles kept.
# excl_decls (lines 6-8):   cov_leaf toggles gone, line+branch kept.
# Any other outcome means -lines does not do what decision A would rely on.
#
# The .vlt files name line numbers, and line numbers drift when a file is
# edited -- silently excluding the wrong lines. So the numbers are checked
# against the source before they are trusted. Stage 1 needs the same check.
L="$HERE/cov_leaf.sv"
sed -n '10p'  "$L" | grep -q 'always_ff' || { echo "FATAL: cov_leaf.sv:10 is not the always_ff; .vlt ranges are stale"; exit 3; }
sed -n '16p'  "$L" | grep -qx '  end'     || { echo "FATAL: cov_leaf.sv:16 is not the block's end; .vlt ranges are stale"; exit 3; }
sed -n '6,8p' "$L" | grep -cE '^ *(input|output) +logic' | grep -qx 3 || { echo "FATAL: cov_leaf.sv:6-8 are not the 3 port declarations"; exit 3; }
echo "line anchors checked: 10 always_ff, 16 end, 6-8 port declarations"
../x1/Vtop_b +SEL=1 +verilator+coverage+file+x_logic.dat
../x2/Vtop_b +SEL=1 +verilator+coverage+file+x_decls.dat
for f in runb_sel1.dat x_logic.dat x_decls.dat; do
  echo "--- $f"
  "${COVDAT[@]}" files "$f" --under cov_leaf.sv || echo "(no cov_leaf.sv points at all in $f)"
done

banner "DONE"
