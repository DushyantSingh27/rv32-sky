// muldiv testbench interface.
//
// Unlike the ALU, this DUT is sequential and the clock is real - it drives the
// multiplier and divider state machines. A transaction spans 17 to 33 cycles,
// so the driver and monitor both track a protocol rather than sampling once
// per clock.
//
//   accept  when valid_i && ready_o
//   deliver when valid_o && ready_i
interface muldiv_if (input logic clk, input logic rst_n);
  import rv32_pkg::*;

  muldiv_op_e      op;
  logic [XLEN-1:0] a;
  logic [XLEN-1:0] b;
  logic            valid_i;
  logic            ready_o;
  logic [XLEN-1:0] result;
  logic            valid_o;
  logic            ready_i;

  clocking drv_cb @(posedge clk);
    output op, a, b, valid_i, ready_i;
    input  ready_o, valid_o, result;
  endclocking

  clocking mon_cb @(posedge clk);
    input op, a, b, valid_i, ready_o, result, valid_o, ready_i;
  endclocking

  modport drv (clocking drv_cb, input rst_n);
  modport mon (clocking mon_cb, input rst_n);
endinterface
