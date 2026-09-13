# ACT4 compliance harness.
#
# Separate directory and separate obj_dir from verif/verilator/core. A second
# build product beside the first is how docs/results/0017's stale-artifact
# problem happens: Verilator reported "Built from 0.000 MB sources in 0 modules"
# after a source change because only the C++ had been recompiled.
#
# The ONLY difference from the core harness at RTL level is TCM_BYTES. The
# elaborated design is otherwise identical, which is the point: compliance runs
# against the same core as lockstep, not a variant of it.

VERILATOR ?= verilator

# RTL comes from the shared list. Paths there are repo-relative, so they are
# rewritten to be relative to this directory.
RTL := $(shell sed -e 's/\#.*//' -e '/^\s*$$/d' ../../../rtl/files.f | sed 's|^|../../../|') \
       ../core/core_tb_top.sv
TOP := core_tb_top

# THREE NUMBERS MUST AGREE. Changing one means changing all three:
#   TCM_BYTES here
#   RAM_LENGTH in verif/compliance/rv32sky/link.ld
#   DUT_RAM_SIZE in verif/compliance/rv32sky/gen_act4_sail_config.py
# link.ld's own ASSERTs name sail.json as the file that must move with it.
# tb_act4.cpp's --tcm-bytes default must match TCM_BYTES or an ELF that fits
# the TCM will be rejected by the loader, or worse, one that does not fit will
# be accepted.
TCM_BYTES ?= 1048576

ELF    ?=
CYCLES ?= 10000000

.PHONY: all run check clean
all: obj_dir/V$(TOP)

obj_dir/V$(TOP): tb_act4.cpp $(RTL)
	$(VERILATOR) --cc --exe --build -j 0 -Wall -Wno-fatal \
	  --top-module $(TOP) -GTCM_BYTES=$(TCM_BYTES) \
	  $(RTL) tb_act4.cpp -o V$(TOP)

run: obj_dir/V$(TOP)
	@test -n "$(ELF)" || { echo "usage: make run ELF=/path/to/test.elf"; exit 2; }
	./obj_dir/V$(TOP) --cycles $(CYCLES) --tcm-bytes $(TCM_BYTES) --verbose $(ELF)

# Dump the loaded image for the objdump cross-check. See the header of
# tb_act4.cpp: a parser bug produces a plausible-looking wrong image, so the
# loader is verified against objdump before any suite run.
check: obj_dir/V$(TOP)
	@test -n "$(ELF)" || { echo "usage: make check ELF=/path/to/test.elf"; exit 2; }
	./obj_dir/V$(TOP) --cycles $(CYCLES) --tcm-bytes $(TCM_BYTES) --verbose \
	  --dump-hex /tmp/rv32sky_check.hex $(ELF)
	@echo "image written to /tmp/rv32sky_check.hex"

clean:
	rm -rf obj_dir
