// SYNTHESIS MEASUREMENT HARNESS - not part of the CPU design.
//
// The ALU is purely combinational, so hardening it alone gives OpenROAD no clock and
// produces meaningless timing against an invented virtual clock (__VIRTUAL_CLK__).
// This wrapper puts flops on every input and output, creating a true
// register-to-register path through the ALU - exactly what the EX stage will look like
// in the real pipeline. The measured slack is therefore the number that matters.
//
// Lives in flow/ rather than rtl/ because it is a measurement fixture, not design.
module alu_synth_harness
  import rv32_pkg::*;
(
  input  logic            clk,
  input  logic            rst_n,
  input  logic [3:0]      op_i,
  input  logic [2:0]      branch_op_i,
  input  logic [XLEN-1:0] a_i,
  input  logic [XLEN-1:0] b_i,
  output logic [XLEN-1:0] result_o,
  output logic            branch_taken_o
);

  alu_op_e         op_q;
  branch_op_e      branch_op_q;
  logic [XLEN-1:0] a_q, b_q;
  logic [XLEN-1:0] result_c;
  logic            branch_taken_c;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      op_q        <= ALU_ADD;
      branch_op_q <= BR_NONE;
      a_q         <= '0;
      b_q         <= '0;
    end else begin
      op_q        <= alu_op_e'(op_i);
      branch_op_q <= branch_op_e'(branch_op_i);
      a_q         <= a_i;
      b_q         <= b_i;
    end
  end

  alu u_alu (
    .op           (op_q),
    .branch_op    (branch_op_q),
    .a            (a_q),
    .b            (b_q),
    .result       (result_c),
    .branch_taken (branch_taken_c)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      result_o       <= '0;
      branch_taken_o <= 1'b0;
    end else begin
      result_o       <= result_c;
      branch_taken_o <= branch_taken_c;
    end
  end

endmodule
