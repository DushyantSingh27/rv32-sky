# Covergroup scope probe, under UVM. See cg5.sv for what it measures and why.
#
# First consumer of verif/uvm/uvm.mk. Per PROJECT_INSTRUCTIONS 4.4 this file
# carries only TOP, SRCS and the test name; every flag lives in the include.

include ../uvm.mk

TOP  := cg5_tb_top
SRCS := cg5.sv
TEST := cg5_test

.PHONY: all run clean

all: obj_dir/V$(TOP)

obj_dir/V$(TOP): $(SRCS)
	$(VERILATOR) $(UVM_FLAGS) $(UVM_FILES) $(SRCS) \
	  --top-module $(TOP) -o V$(TOP) -j 0

# check runs BEFORE the build, not after: a build against the wrong Verilator
# or a missing UVM tree wastes ~90 s and then reports a number that means
# nothing.
run: check obj_dir/V$(TOP)
	./obj_dir/V$(TOP) +UVM_TESTNAME=$(TEST)

clean:
	rm -rf obj_dir coverage.dat
