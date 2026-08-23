# Shared RTL source list, in dependency order.
#
# ONE list, consumed by every consumer: the Verilator harnesses, the lint
# script, and LibreLane. Adding a module means editing this file and nothing
# else. The alternative - a file list per consumer - already cost a build
# failure when hazard_unit.sv was added to the lint command but not to the
# core harness's Makefile.
#
# Same principle as ADR-0001 portability rule 3 for the UVM environments.
rtl/pkg/rv32_pkg.sv
rtl/core/alu.sv
rtl/core/regfile.sv
rtl/core/decoder.sv
rtl/core/imm_gen.sv
rtl/core/if_stage.sv
rtl/core/lsu.sv
rtl/core/hazard_unit.sv
rtl/core/csr.sv
rtl/mem/tcm.sv
rtl/core/rv32_core.sv
