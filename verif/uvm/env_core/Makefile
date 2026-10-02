# UVM env 7 — full-core environment. docs/results/0020.
#
# WHY THIS FILE EXISTS
# ====================
# 0020's reproduce block could not be run:
#
#     cd ~/work/env7
#     verilator ... +incdir+$UVM_SRC +incdir+$V/uvm/env_core ...
#       <rtl files> <verif files> ...
#
# ~/work/env7 is outside the repo, $UVM_SRC and $V are unset, and the two file
# lists are placeholders. PROJECT_CONTEXT section 10's headline UVM result -
# 740 retirements across t02-t06, 0 invariant violations - rested on that.
# The sources were all committed; only the recipe was missing. docs/results/0027.
#
# Per PROJECT_INSTRUCTIONS 4.4 this file carries TOP, SRCS and the test name.
# Every flag and the UVM library path live in ../uvm.mk.

include ../uvm.mk

# ---------------------------------------------------------------------------
# RTL from the SINGLE source list. Paths in files.f are repo-relative, so they
# are rewritten relative to this directory - the same expansion the ACT4
# harness Makefile uses. Hand-maintaining a second copy of this list is the
# duplicated-source-list problem this project has hit four times.
RTL := $(shell sed -e 's/\#.*//' -e '/^\s*$$/d' ../../../rtl/files.f \
         | sed 's|^|../../../|')

# ---------------------------------------------------------------------------
# Verification sources, IN DEPENDENCY ORDER. SystemVerilog packages must be
# read before anything that imports them, and this order is read off the
# import lists rather than guessed:
#
#   core_if.sv          imports rv32_pkg; declared before core_agent_pkg,
#                       which declares `virtual core_if`
#   core_agent_pkg      imports uvm_pkg, rv32_pkg
#   core_env_pkg        imports core_agent_pkg
#   core_test_pkg       imports core_agent_pkg, core_env_pkg
#   core_uvm_tb_top     imports all three, instantiates the DUT and the TCM
#
# core_uvm_tb_top is deliberately NOT named core_tb_top: that name is taken by
# the Verilator C++ harness at verif/verilator/core/.
VERIF := ../agents/core_agent/core_if.sv \
         ../agents/core_agent/core_agent_pkg.sv \
         ../env_core/core_env_pkg.sv \
         ../tests/core_test_pkg.sv \
         ../tests/core_uvm_tb_top.sv

TOP  := core_uvm_tb_top
TEST := core_run_test

# SYNTHESIS is deliberately left UNDEFINED: this environment observes the
# core's retirement trace ports, which live under `ifndef SYNTHESIS. Defining
# it would compile a core with no trace ports and the monitor would see
# nothing - a silent zero-retirement run rather than a build error.
#
# RISCV_FORMAL likewise stays undefined. The RVFI ports are for SymbiYosys.

.PHONY: all run clean

all: obj_dir/V$(TOP)

obj_dir/V$(TOP): $(RTL) $(VERIF)
	$(VERILATOR) $(UVM_FLAGS) $(UVM_FILES) $(RTL) $(VERIF) \
	  --top-module $(TOP) -o V$(TOP) -j 0

# A program is required. The test fatals on a missing +HEX= anyway, but 90
# seconds into a build is a worse place to find out than before it starts.
run: check obj_dir/V$(TOP)
	@test -n "$(HEX)" || { \
	   echo "usage: make run HEX=<path to a .hex program>"; \
	   echo "       e.g. make run HEX=../../../sw/tests/build/t02_memory.hex"; \
	   exit 2; }
	@test -f "$(HEX)" || { echo "ERROR: $(HEX) not found"; exit 2; }
	./obj_dir/V$(TOP) +UVM_TESTNAME=$(TEST) +HEX=$(HEX)

clean:
	rm -rf obj_dir coverage.dat
