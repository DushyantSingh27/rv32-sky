# Coverage-data semantics probe. M3.7 stage 0 step 3; run_semantics.sh drives it.
#
# Builds two binaries over the same cov_leaf.sv at different hierarchy depths.
# Line and toggle only: --coverage would also enable expression and FSM
# coverage in this Verilator (--help, 2026-10-09) and change the denominator.

include ../../../tools/guards.mk

VFLAGS := --binary --timing --coverage-line --coverage-toggle -j 0
SV_A   := top_a.sv cov_leaf.sv cov_wide.sv
SV_B   := top_b.sv cov_wrap.sv cov_leaf.sv

.PHONY: all clean
all: obj_dir/a/Vtop_a obj_dir/b/Vtop_b obj_dir/w/Vtop_a obj_dir/x1/Vtop_b obj_dir/x2/Vtop_b

# Verilator creates the -Mdir but not its parent: without the mkdir the
# first build fails with "Cannot write obj_dir/a/...".
obj_dir/a/Vtop_a: $(SV_A) | check-verilator
	@mkdir -p obj_dir
	$(VERILATOR) $(VFLAGS) $(SV_A) --top-module top_a -Mdir obj_dir/a -o Vtop_a

obj_dir/b/Vtop_b: $(SV_B) | check-verilator
	@mkdir -p obj_dir
	$(VERILATOR) $(VFLAGS) $(SV_B) --top-module top_b -Mdir obj_dir/b -o Vtop_b

# T4b: top_a again with the toggle width limit raised above arr2k's 65,536
# bits. Same sources, same stimulus, one flag different.
obj_dir/w/Vtop_a: $(SV_A) | check-verilator
	@mkdir -p obj_dir
	$(VERILATOR) $(VFLAGS) --coverage-max-width 131072 $(SV_A) --top-module top_a -Mdir obj_dir/w -o Vtop_a

# T6: exclusion by configuration file. The sources are never edited, which is
# the point: the same mechanism would keep rtl/ untouched.
obj_dir/x1/Vtop_b: excl_logic.vlt $(SV_B) | check-verilator
	@mkdir -p obj_dir
	$(VERILATOR) $(VFLAGS) excl_logic.vlt $(SV_B) --top-module top_b -Mdir obj_dir/x1 -o Vtop_b

obj_dir/x2/Vtop_b: excl_decls.vlt $(SV_B) | check-verilator
	@mkdir -p obj_dir
	$(VERILATOR) $(VFLAGS) excl_decls.vlt $(SV_B) --top-module top_b -Mdir obj_dir/x2 -o Vtop_b

clean:
	rm -rf obj_dir
