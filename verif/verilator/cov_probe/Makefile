# Covergroup scope probe. See cg4.sv for what it measures and why.
#
# Deliberately UVM-free, so the build is seconds rather than the ~2 minutes an
# instance of the UVM library costs. That also keeps the result attributable:
# if the probe needed UVM to run, a failure could be UVM's rather than
# Verilator's.
#
# MUST be run with the PINNED Verilator, not the OSS CAD Suite's. The suite
# ships 5.053; every result in docs/results was measured with 5.050, and this
# probe's whole purpose is to characterise 5.050's behaviour. `make run`
# asserts this before it builds.

VERILATOR ?= verilator
EXPECT_VL := 5.050

TOP := cg4

.PHONY: all run check-verilator clean

all: obj_dir/V$(TOP)

# The version guard. docs/results/0026 records the near-miss: sourcing the OSS
# CAD Suite silently substitutes a different Verilator and nothing announces it.
check-verilator:
	@v=$$($(VERILATOR) --version | awk '{print $$2}'); \
	 if [ "$$v" != "$(EXPECT_VL)" ]; then \
	   echo "ERROR: verilator is $$v, expected $(EXPECT_VL)"; \
	   echo "       which verilator -> $$(which $(VERILATOR))"; \
	   echo "       The OSS CAD Suite shadows the pinned copy. Use a shell"; \
	   echo "       where the suite environment has NOT been sourced."; \
	   exit 2; \
	 fi; \
	 echo "verilator $$v  ($$(which $(VERILATOR)))"

# --coverage-user enables covergroup coverage. Without it every figure reads
# 0.00% and the probe would report a false negative - ADR-0006 rules that out
# by measurement, and this comment exists so nobody re-derives it.
obj_dir/V$(TOP): $(TOP).sv
	$(VERILATOR) --binary --coverage-user -Wno-fatal \
	  --top-module $(TOP) $(TOP).sv -o V$(TOP) -j 0

run: check-verilator obj_dir/V$(TOP)
	./obj_dir/V$(TOP)

clean:
	rm -rf obj_dir coverage.dat
