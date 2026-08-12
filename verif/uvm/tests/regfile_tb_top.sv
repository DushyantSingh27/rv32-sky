// Register file testbench top level.
module regfile_tb_top;

  import uvm_pkg::*;
  import rv32_pkg::*;
  // Load-bearing: class-only packages are dropped at elaboration unless
  // referenced, and a dropped package never registers with the factory.
  import regfile_agent_pkg::*;
  import regfile_env_pkg::*;
  import regfile_test_pkg::*;
  `include "uvm_macros.svh"

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  always #5ns clk = ~clk;

  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  regfile_if vif (.clk(clk), .rst_n(rst_n));

  regfile u_regfile (
    .clk      (clk),
    .rst_n    (rst_n),
    .rs1_addr (vif.rs1_addr),
    .rs1_data (vif.rs1_data),
    .rs2_addr (vif.rs2_addr),
    .rs2_data (vif.rs2_data),
    .rd_addr  (vif.rd_addr),
    .rd_data  (vif.rd_data),
    .rd_we    (vif.rd_we)
  );

  initial begin
    uvm_config_db#(virtual regfile_if)::set(null, "uvm_test_top", "vif", vif);
    run_test();
  end

  initial begin
    #100ms;
    `uvm_fatal("TB_TOP", "global timeout - simulation did not finish")
  end

endmodule
