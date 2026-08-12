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


# ---------------- muldiv (UVM env 2) ----------------
MD_TEST  ?= md_smoke_test
MD_FLIST ?= verif/files_muldiv.f
MD_TOP   ?= muldiv_tb_top
MD_COVDB ?= muldiv_$(MD_TEST)_seed$(SEED).db

MD_FLAGS := -uvm $(UVM_VERSION) +incdir+$(UVM_SRC) \
            +incdir+verif/uvm/env_muldiv \
            -top $(MD_TOP) \
            -sv_seed $(SEED) \
            -cov-db $(MD_COVDB) \
            +UVM_TESTNAME=$(MD_TEST) \
            +N_ITEMS=$(N_ITEMS)

.PHONY: muldiv muldiv-full muldiv-bp muldiv-cov muldiv-wave
muldiv:
	dsim -F $(MD_FLIST) $(MD_FLAGS)

muldiv-full:
	$(MAKE) -f verif/dsim.mk muldiv MD_TEST=md_full_test N_ITEMS=20000

muldiv-bp:
	$(MAKE) -f verif/dsim.mk muldiv MD_TEST=md_backpressure_test N_ITEMS=2000

muldiv-cov:
	dcreport -out_dir cov_report_$(MD_TEST) $(MD_COVDB)

muldiv-wave:
	dsim -F $(MD_FLIST) -uvm $(UVM_VERSION) +incdir+$(UVM_SRC) \
	  +incdir+verif/uvm/env_muldiv -top $(MD_TOP) \
	  +acc+rwcbfsWF -waves muldiv.vcd -dump-agg \
	  -sv_seed $(SEED) +UVM_TESTNAME=md_smoke_test +N_ITEMS=5


# ---------------- regfile (UVM env 3) ----------------
RF_TEST  ?= rf_smoke_test
RF_FLIST ?= verif/files_regfile.f
RF_TOP   ?= regfile_tb_top
RF_COVDB ?= regfile_$(RF_TEST)_seed$(SEED).db

RF_FLAGS := -uvm $(UVM_VERSION) +incdir+$(UVM_SRC) \
            +incdir+verif/uvm/env_regfile \
            -top $(RF_TOP) \
            -sv_seed $(SEED) \
            -cov-db $(RF_COVDB) \
            +UVM_TESTNAME=$(RF_TEST) \
            +N_ITEMS=$(N_ITEMS)

.PHONY: regfile regfile-full regfile-cov
regfile:
	dsim -F $(RF_FLIST) $(RF_FLAGS)

regfile-full:
	$(MAKE) -f verif/dsim.mk regfile RF_TEST=rf_full_test N_ITEMS=20000

regfile-cov:
	dcreport -out_dir cov_report_$(RF_TEST) $(RF_COVDB)
