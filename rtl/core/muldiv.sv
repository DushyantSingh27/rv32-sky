// RV32M multiply/divide wrapper.
//
// Holds separate mul_unit and div_unit and presents one valid/ready interface.
// Full handshake on both sides - overkill standalone, correct for a pipeline
// where MEM may stall EX mid-operation, and the same protocol shape as AXI.
//
//   accept  when valid_i && ready_o
//   deliver when valid_o && ready_i
module muldiv
  import rv32_pkg::*;
(
  input  logic            clk,
  input  logic            rst_n,
  input  muldiv_op_e      op,
  input  logic [XLEN-1:0] a,
  input  logic [XLEN-1:0] b,
  input  logic            valid_i,
  output logic            ready_o,
  output logic [XLEN-1:0] result,
  output logic            valid_o,
  input  logic            ready_i
);

  typedef enum logic [1:0] {
    MD_IDLE = 2'b00,
    MD_BUSY = 2'b01,
    MD_HOLD = 2'b10
  } md_state_e;

  md_state_e state_q, state_d;

  logic is_div;
  always_comb is_div = (op == MD_DIV) || (op == MD_DIVU) ||
                       (op == MD_REM) || (op == MD_REMU);

  logic            is_div_q, is_div_d;
  logic [XLEN-1:0] result_q, result_d;

  logic            mul_start, div_start;
  logic            mul_done,  div_done;
  logic [XLEN-1:0] mul_result, div_result;

  always_comb begin
    mul_start = (state_q == MD_IDLE) && valid_i && !is_div;
    div_start = (state_q == MD_IDLE) && valid_i &&  is_div;
  end

  mul_unit u_mul (
    .clk    (clk),
    .rst_n  (rst_n),
    .op     (op),
    .a      (a),
    .b      (b),
    .start  (mul_start),
    .done   (mul_done),
    .result (mul_result)
  );

  div_unit u_div (
    .clk    (clk),
    .rst_n  (rst_n),
    .op     (op),
    .a      (a),
    .b      (b),
    .start  (div_start),
    .done   (div_done),
    .result (div_result)
  );

  always_comb begin
    state_d  = state_q;
    is_div_d = is_div_q;
    result_d = result_q;

    unique case (state_q)
      MD_IDLE: begin
        if (valid_i) begin
          is_div_d = is_div;
          state_d  = MD_BUSY;
        end
      end

      MD_BUSY: begin
        if (is_div_q ? div_done : mul_done) begin
          result_d = is_div_q ? div_result : mul_result;
          state_d  = MD_HOLD;
        end
      end

      MD_HOLD: if (ready_i) state_d = MD_IDLE;

      default: state_d = MD_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q  <= MD_IDLE;
      is_div_q <= 1'b0;
      result_q <= 32'd0;
    end else begin
      state_q  <= state_d;
      is_div_q <= is_div_d;
      result_q <= result_d;
    end
  end

  always_comb begin
    ready_o = (state_q == MD_IDLE);
    valid_o = (state_q == MD_HOLD);
    result  = result_q;
  end

`ifndef SYNTHESIS
  // Immediate assertions only - no SVA in rtl/ (PROJECT_INSTRUCTIONS 4.1).
  //
  // SYNCASYNCNET is suppressed for this block only. rst_n is asynchronous in
  // the design flops above; here it is read synchronously purely to hold the
  // assertions off during reset. That synchronous read is inside
  // `ifndef SYNTHESIS and never becomes hardware, so the mixed-usage warning
  // does not apply. The suppression is deliberately narrow - SYNCASYNCNET stays
  // enabled everywhere else, because the real version of this bug (a reset that
  // is genuinely async in one flop and sync in another) is one worth catching.
  /* verilator lint_off SYNCASYNCNET */
  always_ff @(posedge clk) begin
    if (rst_n && valid_o)
      assert (!$isunknown(result))
        else $error("muldiv: result is X while valid_o asserted");
    if (rst_n)
      assert (!(ready_o && valid_o))
        else $error("muldiv: ready_o and valid_o both asserted - state error");
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
