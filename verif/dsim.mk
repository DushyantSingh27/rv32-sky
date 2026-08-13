# Regression pass/fail must account for BOTH UVM errors and simulator-level
# assertion failures. RTL immediate assertions ($error inside `ifndef SYNTHESIS)
# are reported by the simulator as =E:[$error call], NOT through the UVM report
# server - so grepping UVM_ERROR alone reports a clean pass while the DUT is
# broken. Demonstrated 2026-08-13: a regfile mutant that made x0 writable fired
# the RTL assertion twice and still showed UVM_ERROR : 0.
#
# Usage:  make -f verif/dsim.mk <target> 2>&1 | tee run.log
#         make -f verif/dsim.mk check-errors LOG=run.log
.PHONY: check-errors
check-errors:
	@uvm=$$(grep -oP '(?<=^UVM_ERROR :)\s*\d+' $(LOG) | tr -d ' ' | head -1); \
	 fat=$$(grep -oP '(?<=^UVM_FATAL :)\s*\d+' $(LOG) | tr -d ' ' | head -1); \
	 ast=$$(grep -c '=E:\[\$$error call\]' $(LOG)); \
	 err=$$(grep -c '^=E:' $(LOG)); \
	 echo "  UVM_ERROR      : $${uvm:-0}"; \
	 echo "  UVM_FATAL      : $${fat:-0}"; \
	 echo "  RTL assertions : $$ast"; \
	 echo "  tool errors    : $$err"; \
	 if [ "$${uvm:-0}" != "0" ] || [ "$${fat:-0}" != "0" ] || [ "$$ast" != "0" ]; then \
	   echo "  RESULT: FAIL"; exit 1; \
	 else echo "  RESULT: PASS"; fi

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


# ---------------- csr (UVM env 4, RAL) ----------------
CSR_TEST  ?= csr_full_test
CSR_FLIST ?= verif/files_csr.f
CSR_TOP   ?= csr_tb_top
CSR_COVDB ?= csr_$(CSR_TEST)_seed$(SEED).db

CSR_FLAGS := -uvm $(UVM_VERSION) +incdir+$(UVM_SRC) \
             +incdir+verif/uvm/env_csr \
             -top $(CSR_TOP) \
             -sv_seed $(SEED) \
             -cov-db $(CSR_COVDB) \
             +UVM_TESTNAME=$(CSR_TEST)

.PHONY: csr csr-reset csr-bash csr-directed csr-cov
csr:
	dsim -F $(CSR_FLIST) $(CSR_FLAGS)

csr-reset:
	$(MAKE) -f verif/dsim.mk csr CSR_TEST=csr_hw_reset_test

csr-bash:
	$(MAKE) -f verif/dsim.mk csr CSR_TEST=csr_bit_bash_test

csr-directed:
	$(MAKE) -f verif/dsim.mk csr CSR_TEST=csr_directed_test

csr-cov:
	dcreport -out_dir cov_report_$(CSR_TEST) $(CSR_COVDB)
