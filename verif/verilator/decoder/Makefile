# Directed decoder test. Reference encodings come from the RISC-V assembler.
VERILATOR ?= verilator
RTL       := ../../../rtl/pkg/rv32_pkg.sv ../../../rtl/core/decoder.sv \
             ../../../rtl/core/imm_gen.sv decode_top.sv
TOP       := decode_top

.PHONY: all ref run clean
all: run

ref:
	python3 gen_ref.py

obj_dir/V$(TOP): tb_decoder.cpp ref_cases.h $(RTL)
	$(VERILATOR) --cc --exe --build -j 0 \
	  -Wall -Wno-fatal \
	  --top-module $(TOP) \
	  $(RTL) tb_decoder.cpp \
	  -o V$(TOP)

run: obj_dir/V$(TOP)
	./obj_dir/V$(TOP)

clean:
	rm -rf obj_dir
