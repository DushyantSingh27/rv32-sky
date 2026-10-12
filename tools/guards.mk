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

.DEFAULT_GOAL := $(GUARDS_SAVED_GOAL)
