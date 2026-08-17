VERILATOR ?= verilator
RTL := ../../../rtl/pkg/rv32_pkg.sv \
       ../../../rtl/core/alu.sv ../../../rtl/core/regfile.sv \
       ../../../rtl/core/decoder.sv ../../../rtl/core/imm_gen.sv \
       ../../../rtl/core/if_stage.sv ../../../rtl/core/lsu.sv \
       ../../../rtl/mem/tcm.sv ../../../rtl/core/rv32_core.sv \
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
