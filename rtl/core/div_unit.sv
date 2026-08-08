// Restoring divider, 1 bit per cycle, 32 iterations.
//
// RISC-V specifies exact results for the two pathological cases rather than
// trapping - both are detected before iteration begins:
//   division by zero: DIV/DIVU return all-ones, REM/REMU return the dividend
//   signed overflow (-2^31 / -1): DIV returns -2^31, REM returns 0
//
// Sign handling is magnitude division plus correction. The quotient takes the
// XOR of the operand signs; the remainder takes the sign of the DIVIDEND.
module div_unit
  import rv32_pkg::*;
(
  input  logic            clk,
  input  logic            rst_n,
  input  muldiv_op_e      op,
  input  logic [XLEN-1:0] a,
  input  logic [XLEN-1:0] b,
  input  logic            start,
  output logic            done,
  output logic [XLEN-1:0] result
);

  typedef enum logic [1:0] {
    DIV_IDLE = 2'b00,
    DIV_RUN  = 2'b01,
    DIV_DONE = 2'b10
  } div_state_e;

  div_state_e      state_q, state_d;

  logic            is_signed, want_rem;
  logic            neg_dividend, neg_divisor;
  logic [XLEN-1:0] a_mag, b_mag;
  logic            div_by_zero, sign_overflow;

  always_comb begin
    is_signed     = (op == MD_DIV) || (op == MD_REM);
    want_rem      = (op == MD_REM) || (op == MD_REMU);
    neg_dividend  = is_signed && a[XLEN-1];
    neg_divisor   = is_signed && b[XLEN-1];
    a_mag         = neg_dividend ? (~a + 32'd1) : a;
    b_mag         = neg_divisor  ? (~b + 32'd1) : b;
    div_by_zero   = (b == 32'd0);
    sign_overflow = is_signed && (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);
  end

  logic [31:0] quot_q,  quot_d;
  logic [32:0] rem_q,   rem_d;
  logic [31:0] divd_q,  divd_d;
  logic [31:0] divr_q,  divr_d;
  logic [5:0]  cnt_q,   cnt_d;
  logic        q_neg_q, q_neg_d;
  logic        r_neg_q, r_neg_d;
  logic        want_rem_q, want_rem_d;
  logic        special_q,  special_d;
  logic [31:0] special_val_q, special_val_d;

  logic [32:0] rem_shifted, rem_sub;
  logic        rem_ge;

  always_comb begin
    rem_shifted = {rem_q[31:0], divd_q[31]};
    rem_sub     = rem_shifted - {1'b0, divr_q};
    rem_ge      = (rem_shifted >= {1'b0, divr_q});
  end

  always_comb begin
    state_d       = state_q;
    quot_d        = quot_q;
    rem_d         = rem_q;
    divd_d        = divd_q;
    divr_d        = divr_q;
    cnt_d         = cnt_q;
    q_neg_d       = q_neg_q;
    r_neg_d       = r_neg_q;
    want_rem_d    = want_rem_q;
    special_d     = special_q;
    special_val_d = special_val_q;

    unique case (state_q)
      DIV_IDLE: begin
        if (start) begin
          want_rem_d = want_rem;
          if (div_by_zero) begin
            special_d     = 1'b1;
            special_val_d = want_rem ? a : 32'hFFFF_FFFF;
            state_d       = DIV_DONE;
          end else if (sign_overflow) begin
            special_d     = 1'b1;
            special_val_d = want_rem ? 32'd0 : 32'h8000_0000;
            state_d       = DIV_DONE;
          end else begin
            special_d = 1'b0;
            rem_d     = 33'd0;
            quot_d    = 32'd0;
            divd_d    = a_mag;
            divr_d    = b_mag;
            cnt_d     = 6'd0;
            q_neg_d   = neg_dividend ^ neg_divisor;
            r_neg_d   = neg_dividend;
            state_d   = DIV_RUN;
          end
        end
      end

      DIV_RUN: begin
        rem_d  = rem_ge ? rem_sub : rem_shifted;
        quot_d = {quot_q[30:0], rem_ge};
        divd_d = divd_q << 1;
        cnt_d  = cnt_q + 6'd1;
        if (cnt_q == 6'd31) state_d = DIV_DONE;
      end

      DIV_DONE: state_d = DIV_IDLE;
      default:  state_d = DIV_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q       <= DIV_IDLE;
      quot_q        <= 32'd0;
      rem_q         <= 33'd0;
      divd_q        <= 32'd0;
      divr_q        <= 32'd0;
      cnt_q         <= 6'd0;
      q_neg_q       <= 1'b0;
      r_neg_q       <= 1'b0;
      want_rem_q    <= 1'b0;
      special_q     <= 1'b0;
      special_val_q <= 32'd0;
    end else begin
      state_q       <= state_d;
      quot_q        <= quot_d;
      rem_q         <= rem_d;
      divd_q        <= divd_d;
      divr_q        <= divr_d;
      cnt_q         <= cnt_d;
      q_neg_q       <= q_neg_d;
      r_neg_q       <= r_neg_d;
      want_rem_q    <= want_rem_d;
      special_q     <= special_d;
      special_val_q <= special_val_d;
    end
  end

  logic [31:0] quot_final, rem_final;
  always_comb begin
    quot_final = q_neg_q ? (~quot_q       + 32'd1) : quot_q;
    rem_final  = r_neg_q ? (~rem_q[31:0]  + 32'd1) : rem_q[31:0];

    done = (state_q == DIV_DONE);

    if (special_q)            result = special_val_q;
    else if (want_rem_q)      result = rem_final;
    else                      result = quot_final;
  end

endmodule
