// ALU testbench top level.
module alu_tb_top;

  import uvm_pkg::*;
  import rv32_pkg::*;
  `include "uvm_macros.svh"

  // Testbench-only clock. The DUT is combinational and never sees it -
  // it exists to give the driver and monitor deterministic timing.
  logic clk = 1'b0;
  always #5ns clk = ~clk;

  alu_if vif (.clk(clk));

  alu u_alu (
    .op           (vif.op),
    .branch_op    (vif.branch_op),
    .a            (vif.a),
    .b            (vif.b),
    .result       (vif.result),
    .branch_taken (vif.branch_taken)
  );

  initial begin
    uvm_config_db#(virtual alu_if)::set(null, "uvm_test_top", "vif", vif);
    run_test();
  end

  initial begin
    #1ms;
    `uvm_fatal("TB_TOP", "global timeout - simulation did not finish")
  end

endmodule
