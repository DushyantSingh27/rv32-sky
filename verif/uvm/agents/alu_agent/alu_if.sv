// ALU testbench interface.
//
// The DUT is purely combinational and has no clock. This interface carries one
// anyway, existing ONLY in the testbench: the driver applies stimulus on posedge,
// the monitor samples on negedge once combinational logic has settled.
//
// drv_toggle is a testbench-only handshake. The driver flips it once per
// transaction; the monitor emits only when it changes. Without it the monitor
// re-samples stale pins on every negedge - including during drain time - and
// scores transactions nobody drove. A toggle rather than a level also handles
// two identical back-to-back transactions correctly.
interface alu_if (input logic clk);
  import rv32_pkg::*;

  alu_op_e         op;
  branch_op_e      branch_op;
  logic [XLEN-1:0] a;
  logic [XLEN-1:0] b;
  bit              drv_toggle;
  logic [XLEN-1:0] result;
  logic            branch_taken;

  clocking drv_cb @(posedge clk);
    output op, branch_op, a, b, drv_toggle;
  endclocking

  clocking mon_cb @(negedge clk);
    input op, branch_op, a, b, drv_toggle, result, branch_taken;
  endclocking

  modport drv (clocking drv_cb);
  modport mon (clocking mon_cb);
endinterface
