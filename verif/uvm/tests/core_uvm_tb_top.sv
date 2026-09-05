// Full-core UVM testbench top (env 7).
//
// Named core_uvm_tb_top, NOT core_tb_top: verif/verilator/core/core_tb_top.sv
// already exists as the Verilator harness. Two modules with one name in the
// same repo is a build failure waiting for whichever tool reads both.
//
// The TCM loads the program via $readmemh on a +HEX= plusarg, exactly as the
// Verilator harness does. The same image is mirrored into the agent config so
// the monitor can recover an instruction word from a retired PC - the core
// does not carry the word through the pipeline, and reconstructing it here
// costs nothing.
module core_uvm_tb_top;

  import uvm_pkg::*;
  import rv32_pkg::*;
  // Load-bearing imports: a class-only package is dropped at elaboration
  // unless referenced, and a dropped package never registers with the factory.
  import core_agent_pkg::*;
  import core_env_pkg::*;
  import core_test_pkg::*;
  `include "uvm_macros.svh"

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  always #5ns clk = ~clk;

  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  core_if vif (.clk(clk), .rst_n(rst_n));

  // ---- DUT and memory ----
  logic [XLEN-1:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata;
  logic [31:0]     imem_rdata;
  logic            dmem_we;
  logic [3:0]      dmem_be;
  logic            periph_we;
  logic [XLEN-1:0] periph_addr, periph_wdata;
  logic            a_oor, b_oor;

  rv32_core u_core (
    .clk              (clk),
    .rst_n            (rst_n),
    .imem_addr        (imem_addr),
    .imem_rdata       (imem_rdata),
    .dmem_addr        (dmem_addr),
    .dmem_we          (dmem_we),
    .dmem_be          (dmem_be),
    .dmem_wdata       (dmem_wdata),
    .dmem_rdata       (dmem_rdata),
    .periph_we        (periph_we),
    .periph_addr      (periph_addr),
    .periph_wdata     (periph_wdata),
    .mem_misaligned_o (vif.misaligned),
    .csr_illegal_o    (vif.csr_illegal),
    .mtvec_o          (vif.mtvec),
    .mepc_o           (vif.mepc),
    .irq_pending_o    (vif.irq_pending),
    .trace_valid      (vif.trace_valid),
    .trace_pc         (vif.trace_pc),
    .trace_rd_we      (vif.trace_rd_we),
    .trace_rd_addr    (vif.trace_rd_addr),
    .trace_rd_data    (vif.trace_rd_data),
    .trace_mem_we     (vif.trace_mem_we),
    .trace_mem_addr   (vif.trace_mem_addr),
    .trace_mem_wdata  (vif.trace_mem_wdata)
  );

  tcm u_tcm (
    .clk            (clk),
    .a_addr         (imem_addr),
    .a_rdata        (imem_rdata),
    .b_addr         (dmem_addr),
    .b_we           (dmem_we),
    .b_be           (dmem_be),
    .b_wdata        (dmem_wdata),
    .b_rdata        (dmem_rdata),
    .a_out_of_range (a_oor),
    .b_out_of_range (b_oor)
  );

  always_comb begin
    vif.testctl_we   = periph_we && (periph_addr == ADDR_TESTCTL);
    vif.testctl_data = periph_wdata;
  end

  // The program image is NOT mirrored here. The test reads the hex file
  // directly into the agent config (core_test_pkg.sv): a static array in
  // module scope cannot be handed to a UVM object by reference, and routing
  // it through the config db needs a wrapper for no gain.
  //
  // A first version of this file mirrored the image and then failed to
  // deliver it - dead code that compiled cleanly and would have left every
  // instruction classified as NOP, with coverage looking plausible while
  // measuring nothing. Caught before compiling; recorded because it is
  // failure mode #1 in a new place.

  initial begin
    uvm_config_db#(virtual core_if)::set(null, "uvm_test_top", "vif", vif);
    run_test();
  end

  initial begin
    #200ms;
    `uvm_fatal("TB_TOP", "global timeout - simulation did not finish")
  end

endmodule
