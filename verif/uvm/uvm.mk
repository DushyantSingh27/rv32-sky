# verif/uvm/uvm.mk — shared UVM build rules for every environment.
#
# WHY THIS FILE EXISTS
# ====================
# Until 2026-09-29 there was NO committed UVM build recipe. verif/dsim.mk is the
# dead Altair one; nothing replaced it after ADR-0006. The consequences, both
# found the same day:
#
#   - docs/results/0020's reproduce block reads `cd ~/work/env7` with
#     `<rtl files>`, `<verif files>`, `$UVM_SRC` and `$V` all unresolved. The
#     740-retirement env 7 result in PROJECT_CONTEXT section 10 could not be
#     re-run by anyone, including its author.
#   - cg3.sv, the probe that justified dropping functional coverage from
#     section 5.3, is not in the repo at all.
#
# Section 5.3: a result that cannot be reproduced is not reported. Every other
# flow in this project - Verilator, Sail, ACT4, formal - has a committed
# recipe. The UVM flow was brought up in a hurry after the DSim shutdown and
# never got one.
#
# PROJECT_INSTRUCTIONS 4.4: one shared source list consumed by every
# simulator makefile; per-simulator makefiles carry invocation flags only.
# This is that shared file. A per-environment Makefile sets TOP, SRCS and
# TESTNAME, includes this, and adds nothing else.

# ---------------------------------------------------------------------------
# UVM library.
#
# Accellera UVM 2020.3.1. RELOCATED 2026-09-29 to ~/src/uvm-2020.3.1, out of
# ~/AltairDSim/2026/uvm/2020.3.1 where it previously lived. The library itself
# is Accellera's and works fine, but depending on a path inside a dead vendor
# install means a tidy-up silently breaks every UVM build in the project.
#
# UVM_SRC is the *src* directory: uvm_pkg.sv sits directly in it and the DPI
# sources are in src/dpi/. Recorded in tools/versions.md with an md5 of
# uvm_pkg.sv, because "UVM 2020.3.1" alone does not distinguish Accellera's
# copy from a vendor's patched one.
UVM_SRC ?= $(HOME)/src/uvm-2020.3.1/src

VERILATOR ?= verilator
EXPECT_VL := 5.050

# ---------------------------------------------------------------------------
# Flags, from the recipe recorded in docs/results/0020 and ADR-0006.
#
# --vpi and uvm_dpi.cc are BOTH required. Without them the link fails on
# undefined DPI and VPI symbols - three separate link failures were worked
# through on 2026-09-06 before this set was settled. uvm_dpi.cc has no vendor
# conditionals, so no -D define is needed.
#
# --coverage-user enables covergroup coverage. Without it every covergroup
# reads 0.00%, which is indistinguishable from the class-scope limitation and
# would produce a false negative on any coverage probe.
UVM_FLAGS := --binary --timing --vpi --coverage-user -Wno-fatal \
             +incdir+$(UVM_SRC) -CFLAGS "-I$(UVM_SRC)/dpi"

UVM_FILES := $(UVM_SRC)/uvm_pkg.sv $(UVM_SRC)/dpi/uvm_dpi.cc

# ---------------------------------------------------------------------------
# Guards. Both failure modes below have actually occurred.

.PHONY: check-uvm check-verilator

# The relocation above is a copy, and a path constructed rather than read is
# how the dpi/ vs src/dpi/ mistake happened on 2026-09-29.
check-uvm:
	@test -f $(UVM_SRC)/uvm_pkg.sv || { \
	   echo "ERROR: $(UVM_SRC)/uvm_pkg.sv not found."; \
	   echo "       UVM_SRC must be the library's *src* directory."; \
	   exit 2; }
	@test -f $(UVM_SRC)/dpi/uvm_dpi.cc || { \
	   echo "ERROR: $(UVM_SRC)/dpi/uvm_dpi.cc not found."; \
	   echo "       The DPI sources live in src/dpi/, not dpi/."; \
	   exit 2; }
	@echo "UVM_SRC = $(UVM_SRC)"

# docs/results/0026: sourcing the OSS CAD Suite prepends its bin to PATH and
# substitutes Verilator 5.053 for the pinned 5.050, silently. Every result in
# docs/results was measured with 5.050.
check-verilator:
	@v=$$($(VERILATOR) --version | awk '{print $$2}'); \
	 if [ "$$v" != "$(EXPECT_VL)" ]; then \
	   echo "ERROR: verilator is $$v, expected $(EXPECT_VL)"; \
	   echo "       which verilator -> $$(which $(VERILATOR))"; \
	   echo "       Use a shell where the OSS CAD Suite has NOT been sourced."; \
	   exit 2; \
	 fi; \
	 echo "verilator $$v  ($$(which $(VERILATOR)))"

check: check-verilator check-uvm
