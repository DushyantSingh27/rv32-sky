# DSim invocation flags only. Source lists live in the shared .f files.
# ADR-0001 portability rule 3: per-simulator makefiles contain flags, not sources.

DSIM_HOME   ?= $(HOME)/AltairDSim/2026
UVM_VERSION ?= 2020.3.1
UVM_SRC     := $(DSIM_HOME)/uvm/$(UVM_VERSION)/src

TEST    ?= alu_smoke_test
SEED    ?= 1
N_ITEMS ?= 500
COVDB   ?= alu_$(TEST)_seed$(SEED).db
FLIST   ?= verif/files_alu.f
TOP     ?= alu_tb_top

DSIM_FLAGS := -uvm $(UVM_VERSION) +incdir+$(UVM_SRC) \
              +incdir+verif/uvm/env_alu \
              -top $(TOP) \
              -sv_seed $(SEED) \
              -cov-db $(COVDB) \
              +UVM_TESTNAME=$(TEST) \
              +N_ITEMS=$(N_ITEMS)

.PHONY: alu alu-full alu-cov clean-cov

alu:
	dsim -F $(FLIST) $(DSIM_FLAGS)

alu-full:
	$(MAKE) -f verif/dsim.mk alu TEST=alu_full_test N_ITEMS=20000

alu-cov:
	dcreport -out_dir cov_report_$(TEST) $(COVDB)

clean-cov:
	rm -f *.db
	rm -rf cov_report_*

# Waveform run. +acc is required at compile time or signals are optimized away.
WAVE_ITEMS ?= 10
.PHONY: alu-wave wave
alu-wave:
	dsim -F $(FLIST) -uvm $(UVM_VERSION) +incdir+$(UVM_SRC) \
	  +incdir+verif/uvm/env_alu -top $(TOP) \
	  +acc+rwcbfsWF -waves alu.vcd -dump-agg \
	  -sv_seed $(SEED) +UVM_TESTNAME=alu_smoke_test +N_ITEMS=$(WAVE_ITEMS)

wave:
	gtkwave alu.vcd verif/waves/alu.gtkw &
