VERILATOR ?= verilator
# RTL comes from the shared list. Paths there are repo-relative, so they are
# rewritten to be relative to this directory.
RTL := $(shell sed -e 's/\#.*//' -e '/^\s*$$/d' ../../../rtl/files.f | sed 's|^|../../../|') \
       core_tb_top.sv
TOP  := core_tb_top
HEX    ?= ../../../sw/tests/t01_alu.hex
EXPECT ?=

.PHONY: all run trace clean
all: obj_dir/V$(TOP)

obj_dir/V$(TOP): tb_core.cpp $(RTL)
	$(VERILATOR) --cc --exe --build -j 0 -Wall -Wno-fatal \
	  --top-module $(TOP) $(RTL) tb_core.cpp -o V$(TOP)

run: obj_dir/V$(TOP)
	./obj_dir/V$(TOP) --hex $(HEX) +HEX=$(HEX) $(if $(EXPECT),--expect $(EXPECT))

trace: obj_dir/V$(TOP)
	./obj_dir/V$(TOP) --hex $(HEX) +HEX=$(HEX) $(if $(EXPECT),--expect $(EXPECT)) --trace

clean:
	rm -rf obj_dir
