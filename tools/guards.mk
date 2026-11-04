# tools/guards.mk -- shared preconditions for every build in this repo.
#
# Included, never run on its own except to test a guard:
#
#     include <path-to-repo>/tools/guards.mk
#     mytarget: | check-verilator        # order-only: guard runs, never forces a rebuild
#
# Every guard here exists because its failure has already happened once, and
# every guard was shown to FAIL before it was committed. A guard that cannot
# fail is not evidence (PROJECT_INSTRUCTIONS 4.5).
#
# Including this file must not change the includer's default goal. GNU make
# makes the first rule it reads the default, so the goal in force before this
# file is saved and restored at the bottom.

GUARDS_SAVED_GOAL := $(.DEFAULT_GOAL)

GUARDS_MK := $(abspath $(lastword $(MAKEFILE_LIST)))
REPO_ROOT := $(abspath $(dir $(GUARDS_MK))..)

# ---------------------------------------------------------------------------
# check-verilator
#
# Sourcing ~/src/oss-cad-suite/environment prepends that suite's bin to PATH
# and substitutes Verilator 5.053 for the 5.050 every result in docs/results/
# was measured with. Nothing announces it (docs/results/0026).
#
# Pinned on the full rev, not "5.050": a different build of 5.050 is a
# different tool. tools/versions.md records this rev.
#
# verilator_coverage is checked too, and must sit in the same directory as
# verilator. A coverage file written by one build and read by another is the
# same hazard one step later.

VERILATOR          ?= verilator
VERILATOR_COVERAGE ?= verilator_coverage
EXPECT_VL_REV      := v5.050-60-g3d2421f3b

.PHONY: check-verilator
check-verilator:
	@for t in $(VERILATOR) $(VERILATOR_COVERAGE); do \
	   p="$$(command -v $$t)" || { echo "GUARD FAILED: $$t is not on PATH"; exit 2; }; \
	   v="$$($$t --version 2>&1)"; \
	   case "$$v" in \
	     *"rev $(EXPECT_VL_REV)"*) echo "guard: $$t -> $$p ($(EXPECT_VL_REV))" ;; \
	     *) echo "GUARD FAILED: $$t at $$p reports:"; \
	        echo "    $$v"; \
	        echo "  expected rev $(EXPECT_VL_REV)."; \
	        echo "  If the OSS CAD Suite environment is sourced in this shell, its"; \
	        echo "  Verilator is first on PATH. Open a fresh terminal. docs/results/0026"; \
	        exit 2 ;; \
	   esac; \
	 done
	@d1="$$(dirname "$$(command -v $(VERILATOR))")"; \
	 d2="$$(dirname "$$(command -v $(VERILATOR_COVERAGE))")"; \
	 test "$$d1" = "$$d2" || { \
	   echo "GUARD FAILED: verilator is in $$d1 but verilator_coverage is in $$d2"; \
	   exit 2; }

# ---------------------------------------------------------------------------
# check-sail
#
# Two different Sail binaries both report "0.13.1": the 0.13.1 tag build
# (b83c230e...) and the dated release 2026-08-17-8f91355 (55de5754...) that
# every lockstep result and the ACT4 ELF set were produced with (measured
# 2026-10-30, docs/results/0030). A version string cannot tell them apart,
# so this guard pins the binary's sha256.
#
# SAIL defaults to the path verif/sail/run_lockstep.sh uses, and an SAIL in
# the environment overrides it in both places.
#
# Run by ci/l0.sh, NOT by run_lockstep.sh: the L1 lockstep mutants (S2-S5,
# ci/mutate_l1.py) substitute wrapper scripts for Sail to test the verdict
# rule, and a hash check there would stop them before the rule they exist
# to test. Known limit: L1 run on its own with a different SAIL is unguarded.

SAIL               ?= $(HOME)/src/sail-riscv-bin/bin/sail_riscv_sim
EXPECT_SAIL_SHA256 := 55de57547cc2f1cf5be4e41ac3e7664d9c9534f9f43ef76f53fded3a4672a0f3

.PHONY: check-sail
check-sail:
	@p="$$(command -v $(SAIL))" || { echo "GUARD FAILED: Sail '$(SAIL)' not found or not executable"; exit 2; }; \
	 h="$$(sha256sum "$$p" | cut -d' ' -f1)"; \
	 if [ "$$h" = "$(EXPECT_SAIL_SHA256)" ]; then \
	   echo "guard: sail -> $$p (sha256 $(EXPECT_SAIL_SHA256))"; \
	 else \
	   echo "GUARD FAILED: Sail at $$p has sha256"; \
	   echo "    $$h"; \
	   echo "  expected $(EXPECT_SAIL_SHA256)"; \
	   echo "  (release 2026-08-17-8f91355). Its --version may still say 0.13.1. docs/results/0030"; \
	   exit 2; \
	 fi

.DEFAULT_GOAL := $(GUARDS_SAVED_GOAL)
