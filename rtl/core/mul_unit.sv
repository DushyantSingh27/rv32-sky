// Radix-4 sequential multiplier, 2 bits per cycle, 16 iterations.
//
// Signed handling uses magnitude multiply plus sign correction: take absolute
// values according to each operand's signedness, multiply the magnitudes, then
// negate the 64-bit product if exactly one operand was negative. This is easier
// to verify than sign-extended Booth recoding, and the magnitude of -2^31 is
// 2^31, which fits in an unsigned 32-bit value - so the awkward corner is safe.
//
// Simple start/done handshake. Full valid/ready lives in the muldiv wrapper.
module mul_unit
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

  // MUL_LOAD registers the operands before the magnitude negations and the
  // 64-bit 3x precompute run on them. Previously all of that was combinational
  // from the input ports. Costs one cycle: multiply goes from 17 to 18.
  typedef enum logic [1:0] {
    MUL_IDLE = 2'b00,
    MUL_LOAD = 2'b01,
    MUL_RUN  = 2'b10,
    MUL_DONE = 2'b11
  } mul_state_e;

  logic [XLEN-1:0] a_in_q, b_in_q;
  muldiv_op_e      op_q;

  mul_state_e      state_q, state_d;

  logic            a_is_signed, b_is_signed;
  logic            neg_a, neg_b;
  logic [XLEN-1:0] a_mag, b_mag;

  always_comb begin
    // MUL's low 32 bits are identical under either interpretation, so treating
    // it as signed costs nothing and keeps the decode simple.
    a_is_signed = (op_q == MD_MUL) || (op_q == MD_MULH) || (op_q == MD_MULHSU);
    b_is_signed = (op_q == MD_MUL) || (op_q == MD_MULH);
    neg_a       = a_is_signed && a_in_q[XLEN-1];
    neg_b       = b_is_signed && b_in_q[XLEN-1];
    a_mag       = neg_a ? (~a_in_q + 32'd1) : a_in_q;
    b_mag       = neg_b ? (~b_in_q + 32'd1) : b_in_q;
  end

  logic [63:0] acc_q,    acc_d;
  logic [63:0] mcand_q,  mcand_d;    // a_mag  << 2i
  logic [63:0] mcand3_q, mcand3_d;   // 3*a_mag << 2i, precomputed once
  logic [31:0] mplier_q, mplier_d;
  logic [4:0]  cnt_q,    cnt_d;
  logic        res_neg_q, res_neg_d;
  logic        hi_q,      hi_d;

  // Radix-4: two multiplier bits per cycle select 0, 1x, 2x or 3x the
  // multiplicand. 3x is precomputed at load so each cycle needs one adder.
  logic [63:0] addend;
  always_comb begin
    unique case (mplier_q[1:0])
      2'b00:   addend = 64'd0;
      2'b01:   addend = mcand_q;
      2'b10:   addend = mcand_q << 1;
      2'b11:   addend = mcand3_q;
      default: addend = 64'd0;
    endcase
  end

  logic [63:0] product;
  always_comb product = res_neg_q ? (~acc_q + 64'd1) : acc_q;

  always_comb begin
    state_d   = state_q;
    acc_d     = acc_q;
    mcand_d   = mcand_q;
    mcand3_d  = mcand3_q;
    mplier_d  = mplier_q;
    cnt_d     = cnt_q;
    res_neg_d = res_neg_q;
    hi_d      = hi_q;

    unique case (state_q)
      MUL_IDLE: begin
        if (start) state_d = MUL_LOAD;
      end

      MUL_LOAD: begin
        begin
          acc_d     = 64'd0;
          mcand_d   = {32'd0, a_mag};
          mcand3_d  = {32'd0, a_mag} + ({32'd0, a_mag} << 1);
          mplier_d  = b_mag;
          cnt_d     = 5'd0;
          res_neg_d = neg_a ^ neg_b;
          hi_d      = (op_q != MD_MUL);
          state_d   = MUL_RUN;
        end
      end

      MUL_RUN: begin
        acc_d    = acc_q + addend;
        mcand_d  = mcand_q  << 2;
        mcand3_d = mcand3_q << 2;
        mplier_d = mplier_q >> 2;
        cnt_d    = cnt_q + 5'd1;
        if (cnt_q == 5'd15) state_d = MUL_DONE;
      end

      MUL_DONE: state_d = MUL_IDLE;
      default:  state_d = MUL_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q   <= MUL_IDLE;
      acc_q     <= 64'd0;
      mcand_q   <= 64'd0;
      mcand3_q  <= 64'd0;
      mplier_q  <= 32'd0;
      cnt_q     <= 5'd0;
      a_in_q    <= 32'd0;
      b_in_q    <= 32'd0;
      op_q      <= MD_MUL;
      res_neg_q <= 1'b0;
      hi_q      <= 1'b0;
    end else begin
      state_q   <= state_d;
      acc_q     <= acc_d;
      mcand_q   <= mcand_d;
      mcand3_q  <= mcand3_d;
      mplier_q  <= mplier_d;
      cnt_q     <= cnt_d;
      if (start) begin
        a_in_q <= a;
        b_in_q <= b;
        op_q   <= op;
      end
      res_neg_q <= res_neg_d;
      hi_q      <= hi_d;
    end
  end

  always_comb begin
    done   = (state_q == MUL_DONE);
    result = hi_q ? product[63:32] : product[31:0];
  end

endmodule
