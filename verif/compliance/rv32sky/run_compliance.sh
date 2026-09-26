#!/usr/bin/env bash
#
# ACT4 compliance run for RV32-SKY.
#
# WHY THIS SCRIPT EXISTS
# ======================
# The InterruptsSm exclusion below cannot live in rv32sky.yaml or
# test_config.yaml. `--exclude` is a typer.Option on the `act` CLI
# (framework/src/act/act.py:51), threaded into generate_test_dict(); there is no
# config-file route, confirmed by grepping config.py and select_tests.py for
# `exclude` and finding nothing.
#
# An exclusion that lives only in a command line is the same artifact class this
# milestone spent a week repairing: four config files that described the core
# from somewhere other than where the core is defined, each stale and each
# masked by the one before. A fifth living in shell history would be that
# failure with a shorter half-life. So the invocation is version-controlled
# beside the config it applies to.
#
# EXIT CODE IS PROPAGATED, NOT SWALLOWED
# ======================================
# docs/results/0018: run_lockstep.sh read compare.py's verdict and discarded the
# harness exit status, and two programs reported FAIL from the harness on every
# run for three weeks while the script said "all agree". Both components were
# correct; the composition read one and dropped the other. This script exits
# with run_tests.py's status unchanged, and prints expected vs actual counts so
# a test quietly leaving the set is visible rather than assumed.

set -u -o pipefail

ACT4="${ACT4:-$HOME/src/riscv-arch-test}"
CFG="${CFG:-config/cores/rv32sky/test_config.yaml}"

# ---------------------------------------------------------------------------
# Exclusions.
#
# Sm,SdtrigSm,SdtrigS,SdtrigU are the UPSTREAM default (see the Makefile:
# "Sm: Insufficient WARL configuration options"). They must be repeated here:
# overriding a make variable REPLACES its default, so passing only InterruptsSm
# would silently re-enable three upstream exclusions.
#
# InterruptsSm is ours. See docs/results/0023.
#
#   The test arms mie, triggers an interrupt via RVTEST_SET_MSW_INT /
#   RVTEST_SET_MEXT_INT, then executes wfi to wait for it. On this core those
#   macros are deliberately empty (rvmodel_macros.h): there is no CLINT, no
#   PLIC, and mip is driven entirely from irq_timer/irq_software/irq_external,
#   all tied low. No interrupt can ever arrive, so wfi is reached and trapped,
#   and trap signature word 0 records xIE=0/xIP=0 (bits 11/12) where the
#   reference - whose sail.json has a working CLINT - records both set.
#
#   This is NOT a false declaration. Declaring Sm is truthful: the core has
#   M-mode CSRs, trap entry, mret, and six measured trap causes. ExceptionsSm
#   tests that half and PASSES. ACT4 simply does not subdivide Sm into traps
#   and interrupts. Contrast Zifencei, which IS a false declaration - see
#   docs/results/0021 finding 2.
#
#   RE-ENABLE AT M5, when the CLINT lands (PROJECT_CONTEXT section 3.4).
#   Matching is on directory names under tests/ and is EXACT, not prefix
#   (parse_test_constraints.py:198) - which is why the upstream `Sm` token does
#   not already cover `InterruptsSm`.
# ---------------------------------------------------------------------------
EXCLUDE="Sm,SdtrigSm,SdtrigS,SdtrigU,InterruptsSm"

# Expected outcome. Update these WITH the result file that justifies the change.
EXPECT_TOTAL=47
EXPECT_PASS=47
# History of these two numbers:
#   46 of 47 until 2026-09-21. Zifencei-fence.i-00 failed: fence.i did not flush
#   the pipeline, so a self-modifying store was followed by a stale fetch
#   (docs/results/0021 finding 2). CLOSED - the flush landed in 47c829b and
#   docs/results/0024 records it. Zifencei was NOT withdrawn; the declaration is
#   now truthful.
#   47 of 47 since. A drop below that is a regression, not a known-open item.

# ---------------------------------------------------------------------------
# BUILD THE HARNESS BEFORE RUNNING IT.
#
# Added 2026-09-26. Until this existed, the script regenerated tests and then ran
# whatever binary happened to be in verif/verilator/act4/obj_dir. With the binary
# ABSENT it crashed loudly. With the binary merely STALE it would print
# "All 47 tests passed" against older RTL and say nothing at all. Failure mode #4.
#
# Found by accident: a deliberate `rm -rf obj_dir` ahead of a run turned the
# silent case into the loud one. docs/results/0026.
# ---------------------------------------------------------------------------
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

echo "=== building ACT4 harness"
make -C "$REPO/verif/verilator/act4" || {
    echo "ERROR: ACT4 harness build failed"; exit 2; }

# Freshness cross-check on the binary that will ACTUALLY run.
#
# The path built above and the path run_tests.py invokes come from two different
# places: this script builds verif/verilator/act4, while run_cmd.txt names the
# binary. Two files describing the same thing from different places is the exact
# artifact class M3.4b spent a week repairing. If they ever disagree, `make`
# succeeds and a stale binary runs - so the binary named in run_cmd.txt is
# checked against the RTL sources directly, not assumed to be the one built.
DUT_BIN="$(awk '{print $1; exit}' "$ACT4/config/cores/rv32sky/run_cmd.txt")"
[ -x "$DUT_BIN" ] || {
    echo "ERROR: run_cmd.txt names $DUT_BIN, which is missing or not executable"
    echo "       The build above produced:"
    echo "       $REPO/verif/verilator/act4/obj_dir/Vcore_tb_top"
    exit 2; }

# RTL_SRCS is deliberately unquoted in the find below: word splitting is how the
# file list becomes multiple arguments. No path in rtl/files.f contains a space.
RTL_SRCS="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$REPO/rtl/files.f" \
            | sed "s|^|$REPO/|")"
STALE="$(find $RTL_SRCS \
              "$REPO/verif/verilator/core/core_tb_top.sv" \
              "$REPO/verif/verilator/act4/tb_act4.cpp" \
              -newer "$DUT_BIN" -print)"
[ -z "$STALE" ] || {
    echo "ERROR: these sources are NEWER than the binary run_cmd.txt names:"
    echo "$STALE"
    echo "       run_cmd.txt points at a binary this script did not build."
    exit 2; }
echo "=== harness fresh: $DUT_BIN"

cd "$ACT4" || { echo "ERROR: cannot cd to $ACT4"; exit 2; }
[ -f "$CFG" ] || { echo "ERROR: $CFG not found under $ACT4"; exit 2; }

# Force regeneration. --exclude filters at TEST GENERATION, not at ELF build and
# not at run time, so three things must go or the exclusion silently does
# nothing:
#
#   work/stamps    - testgen/covergroupgen stamps depend on their sources and on
#                    the Makefile, NOT on the value of EXCLUDE_EXTENSIONS, so a
#                    changed exclusion list leaves them valid and `make tests`
#                    reports "Nothing to be done".
#   tests/<arch>   - already-generated .S sources for excluded suites remain on
#                    disk and are still picked up.
#   work/rv32sky   - already-built ELFs are up-to-date targets; their sources
#                    did not change, so make skips them and the old set runs.
#
# Measured 2026-09-14: removing only work/stamps left InterruptsSm in the set
# and the run reported 48 tests where 47 were expected. The count check below
# is what caught it. Failure mode #4, third instance this milestone.
rm -rf work/stamps work/rv32sky
rm -rf tests/priv tests/rv32i tests/rv32e tests/rv64i tests/rv64e

echo "=== generating (exclude: $EXCLUDE)"
make elfs CONFIG_FILES="$CFG" EXCLUDE_EXTENSIONS="$EXCLUDE" || {
    echo "ERROR: ELF generation failed"; exit 2; }

echo
echo "=== running"
./run_tests.py "$(cat config/cores/rv32sky/run_cmd.txt)" work/rv32sky/elfs
rc=$?

echo
actual_total=$(grep -c . work/rv32sky/summary.log 2>/dev/null || echo 0)
actual_pass=$(grep -c 'TEST PASSED' work/rv32sky/summary.log 2>/dev/null || echo 0)
echo "=== expected ${EXPECT_PASS} passed of ${EXPECT_TOTAL}"
echo "=== actual   ${actual_pass} passed of ${actual_total}"

if [ "$actual_total" != "$EXPECT_TOTAL" ]; then
    echo "WARNING: test COUNT changed. A test entered or left the set without"
    echo "         this script being updated. Check before trusting the result."
fi

# run_tests.py's status, unchanged. Zero is now the expected outcome (fence.i
# closed 2026-09-21), so NONZERO is the case that needs investigating. Note that
# the count check above is independent of this exit code: a test silently leaving
# the set can still produce a clean exit, which is why both exist.
exit $rc
