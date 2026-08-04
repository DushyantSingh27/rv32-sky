// ALU testbench interface.
//
// The DUT is purely combinational and has no clock. This interface carries one
// anyway, existing ONLY in the testbench: the driver applies stimulus on posedge,
// the monitor samples on negedge once combinational logic has settled. That gives
// deterministic sampling and keeps the agent structurally identical to every other
// UVM agent - which matters when this env is reused at M3 with the ALU sitting
// between real pipeline registers.
interface alu_if (input logic clk);
  import rv32_pkg::*;

  alu_op_e         op;
  branch_op_e      branch_op;
  logic [XLEN-1:0] a;
  logic [XLEN-1:0] b;
  logic [XLEN-1:0] result;
  logic            branch_taken;

  clocking drv_cb @(posedge clk);
    output op, branch_op, a, b;
  endclocking

  clocking mon_cb @(negedge clk);
    input op, branch_op, a, b, result, branch_taken;
  endclocking

  modport drv (clocking drv_cb);
  modport mon (clocking mon_cb);
endinterface
