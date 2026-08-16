// RV32I immediate generation.
//
// Separated from the decoder because the B and J bit orderings are the most
// bug-prone part of RV32I decode and deserve exhaustive isolated testing.
//
// WHY B AND J LOOK SCRAMBLED: the ISA fixes each immediate bit to a CONSTANT
// instruction bit position wherever possible. imm[10:5] is always inst[30:25];
// the sign bit is always inst[31]. Only a few bits need selecting, so the
// immediate mux is mostly hardwired - shallower logic, less area. Ugly on
// paper, cheap in gates.
//
// B and J immediates are always even (bit 0 hardwired zero) because branch and
// jump targets are at least 2-byte aligned.
// Takes instr[31:7] only, NOT the full word. Bits [6:0] are the opcode, and
// the format is decided by the decoder and passed in as `fmt`. Narrowing the
// port makes that dependency explicit: an attempt to decide the format here
// would fail to compile rather than silently duplicating decode logic in two
// places. Mutation testing on the register file (docs/results/0011) showed
// that redundant guards can hide a missing one.
module imm_gen
  import rv32_pkg::*;
(
  input  logic [31:7]     instr,
  input  instr_fmt_e      fmt,
  output logic [XLEN-1:0] imm
);

  logic [XLEN-1:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  always_comb begin
    // I-type: inst[31:20], sign-extended.
    imm_i = {{20{instr[31]}}, instr[31:20]};

    // S-type: split across inst[31:25] and inst[11:7].
    imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};

    // B-type: bit 11 comes from inst[7], bit 0 is hardwired zero.
    imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};

    // U-type: inst[31:12] into the upper 20 bits, low 12 zero. NOT sign-extended.
    imm_u = {instr[31:12], 12'b0};

    // J-type: bit 11 from inst[20], bit 0 hardwired zero.
    imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    unique case (fmt)
      FMT_I:   imm = imm_i;
      FMT_S:   imm = imm_s;
      FMT_B:   imm = imm_b;
      FMT_U:   imm = imm_u;
      FMT_J:   imm = imm_j;
      default: imm = '0;      // R-format has no immediate
    endcase
  end

endmodule
