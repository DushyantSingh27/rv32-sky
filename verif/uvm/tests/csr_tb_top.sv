// CSR testbench top level.
module csr_tb_top;

  import uvm_pkg::*;
  import rv32_pkg::*;
  // Load-bearing: class-only packages are dropped at elaboration unless
  // referenced, and a dropped package never registers with the factory.
  import csr_agent_pkg::*;
  import csr_ral_pkg::*;
  import csr_env_pkg::*;
  import csr_test_pkg::*;
  `include "uvm_macros.svh"

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  always #5ns clk = ~clk;

  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  csr_if vif (.clk(clk), .rst_n(rst_n));

  csr u_csr (
    .clk           (clk),
    .rst_n         (rst_n),
    .csr_addr      (vif.csr_addr),
    .csr_op        (vif.csr_op),
    .csr_wdata     (vif.csr_wdata),
    .csr_read      (vif.csr_read),
    .csr_write     (vif.csr_write),
    .csr_rdata     (vif.csr_rdata),
    .csr_illegal   (vif.csr_illegal),
    .trap_valid    (vif.trap_valid),
    .trap_epc      (vif.trap_epc),
    .trap_cause    (vif.trap_cause),
    .trap_tval     (vif.trap_tval),
    .mret          (vif.mret),
    .irq_timer     (vif.irq_timer),
    .irq_software  (vif.irq_software),
    .irq_external  (vif.irq_external),
    .mtvec_o       (vif.mtvec_o),
    .mepc_o        (vif.mepc_o),
    .irq_pending   (vif.irq_pending),
    .instr_retired (vif.instr_retired)
  );

  initial begin
    uvm_config_db#(virtual csr_if)::set(null, "uvm_test_top", "vif", vif);
    run_test();
  end

  initial begin
    #200ms;
    `uvm_fatal("TB_TOP", "global timeout - simulation did not finish")
  end

endmodule
