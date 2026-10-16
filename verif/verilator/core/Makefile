VERILATOR ?= verilator
# RTL comes from the shared list. Paths there are repo-relative, so they are
# rewritten to be relative to this directory.
RTL := $(shell sed -e 's/\#.*//' -e '/^\s*$$/d' ../../../rtl/files.f | sed 's|^|../../../|') \
       core_tb_top.sv
TOP  := core_tb_top
HEX    ?= ../../../sw/tests/t01_alu.hex
EXPECT ?=

include ../../../tools/guards.mk

# ---------------------------------------------------------------------------
# Coverage build (M3.7, docs/results/0028). Its own Mdir, so the normal
# binary keeps its flags exactly.
#
# COV_MDIR is a SIBLING of obj_dir, never inside it. Nested as obj_dir/cov,
# Verilator 5.050's generated makefile linked the NORMAL build's harness
# object (compiled -DVM_COVERAGE=0) into the coverage binary and compiled
# none of its own. The recipe below now checks for that and refuses.
#
# Line and toggle only: plain --coverage would add expression and FSM points
# to the 5.3 denominator in this Verilator (--help, 2026-10-09).
#
# COV_MAX_WIDTH: at the default, toggle coverage silently drops every signal
# over 256 total bits, packed structs and unpacked arrays included
# (verif/verilator/cov_semantics, T4). Raised so nothing in rtl/core is
# dropped. The TCM's memory array is wider still and IS dropped -- on
# purpose, decision B: rtl/mem is reported, not gated.
#
# Make does not track variables. Changing COV_MAX_WIDTH or COV_VLT does NOT
# rebuild: delete $(COV_MDIR) first. The coverage scripts always do.
COV_MAX_WIDTH ?= 8192
COV_VLT       ?= $(COV_MDIR)/rtl_cov.vlt
COV_MDIR      ?= obj_dir_cov
COV_FLAGS     := --coverage-line --coverage-toggle --coverage-max-width $(COV_MAX_WIDTH)

.PHONY: all run trace clean cov
all: obj_dir/V$(TOP)

obj_dir/V$(TOP): tb_core.cpp ../common/harness_cov.h $(RTL) | check-verilator
	$(VERILATOR) --cc --exe --build -j 0 -Wall -Wno-fatal \
	  --top-module $(TOP) $(RTL) tb_core.cpp -o V$(TOP)

run: obj_dir/V$(TOP)
	./obj_dir/V$(TOP) --hex $(HEX) +HEX=$(HEX) $(if $(EXPECT),--expect $(EXPECT))

trace: obj_dir/V$(TOP)
	./obj_dir/V$(TOP) --hex $(HEX) +HEX=$(HEX) $(if $(EXPECT),--expect $(EXPECT)) --trace

# The exclusion file is GENERATED from the RTL on every coverage build, so its
# line ranges cannot drift when a file is edited (decision A, docs/results/0028).
# Written to a temporary name and moved into place only on success: a failed
# generation must not leave behind a file make would treat as up to date.
$(COV_MDIR)/rtl_cov.vlt: ../../../rtl/files.f $(RTL) ../../../tools/gen_cov_vlt.py
	@mkdir -p $(COV_MDIR)
	python3 ../../../tools/gen_cov_vlt.py emit --root ../../.. > $@.tmp && mv $@.tmp $@

cov: $(COV_MDIR)/V$(TOP)

$(COV_MDIR)/V$(TOP): tb_core.cpp ../common/harness_cov.h $(RTL) $(COV_VLT) | check-verilator
	$(VERILATOR) --cc --exe --build -j 0 -Wall -Wno-fatal $(COV_FLAGS) \
	  --top-module $(TOP) $(COV_VLT) $(RTL) tb_core.cpp -Mdir $(COV_MDIR) -o V$(TOP)
	@test -f $(COV_MDIR)/tb_core.o || { rm -f $@; \
	  echo "BUILD GUARD: $(COV_MDIR)/tb_core.o was not compiled; the binary linked"; \
	  echo "  another build's harness object. Binary removed. docs/results/0028"; \
	  exit 2; }

clean:
	rm -rf obj_dir obj_dir_cov
