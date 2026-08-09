// muldiv testbench top level.
module muldiv_tb_top;

  import uvm_pkg::*;
  import rv32_pkg::*;
  // Load-bearing: a package containing only classes is dropped at elaboration
  // unless referenced, and a dropped package never registers with the factory.
  import muldiv_agent_pkg::*;
  import muldiv_env_pkg::*;
  import muldiv_test_pkg::*;
  `include "uvm_macros.svh"

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  always #5ns clk = ~clk;

  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  muldiv_if vif (.clk(clk), .rst_n(rst_n));

  muldiv u_muldiv (
    .clk     (clk),
    .rst_n   (rst_n),
    .op      (vif.op),
    .a       (vif.a),
    .b       (vif.b),
    .valid_i (vif.valid_i),
    .ready_o (vif.ready_o),
    .result  (vif.result),
    .valid_o (vif.valid_o),
    .ready_i (vif.ready_i)
  );

  initial begin
    uvm_config_db#(virtual muldiv_if)::set(null, "uvm_test_top", "vif", vif);
    run_test();
  end

  initial begin
    #200ms;
    `uvm_fatal("TB_TOP", "global timeout - simulation did not finish")
  end

endmodule
