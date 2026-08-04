// RV32I ALU with integrated branch comparison (decision: option A).
// Purely combinational. Flat ports - six signals do not justify an interface.
module alu
  import rv32_pkg::*;
(
  input  alu_op_e         op,
  input  branch_op_e      branch_op,
  input  logic [XLEN-1:0] a,
  input  logic [XLEN-1:0] b,
  output logic [XLEN-1:0] result,
  output logic            branch_taken
);

  // ---------------------------------------------------------------------
  // Shared comparison. SLT, SLTU and all six branch forms derive from these
  // three signals, so synthesis shares one comparator rather than building
  // several. This is the reason branch comparison lives inside the ALU.
  // ---------------------------------------------------------------------
  logic eq, lt_signed, lt_unsigned;

  always_comb begin
    eq          = (a == b);
    lt_signed   = ($signed(a) < $signed(b));
    lt_unsigned = (a < b);
  end

  // Shift amount is the low 5 bits ONLY. RV32I mandates this - a shift by 32
  // or more is a shift by (amount mod 32), not zero. Classic bug source.
  logic [4:0] shamt;
  always_comb shamt = b[4:0];

  always_comb begin
    unique case (op)
      ALU_ADD:    result = a + b;
      ALU_SUB:    result = a - b;
      ALU_SLL:    result = a << shamt;
      ALU_SRL:    result = a >> shamt;
      ALU_SRA:    result = $unsigned($signed(a) >>> shamt);
      ALU_SLT:    result = {{(XLEN-1){1'b0}}, lt_signed};
      ALU_SLTU:   result = {{(XLEN-1){1'b0}}, lt_unsigned};
      ALU_XOR:    result = a ^ b;
      ALU_OR:     result = a | b;
      ALU_AND:    result = a & b;
      ALU_PASS_B: result = b;
      default:    result = '0;
    endcase
  end

  always_comb begin
    unique case (branch_op)
      BR_NONE: branch_taken = 1'b0;
      BR_EQ:   branch_taken = eq;
      BR_NE:   branch_taken = !eq;
      BR_LT:   branch_taken = lt_signed;
      BR_GE:   branch_taken = !lt_signed;
      BR_LTU:  branch_taken = lt_unsigned;
      BR_GEU:  branch_taken = !lt_unsigned;
      default: branch_taken = 1'b0;
    endcase
  end

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown({op, branch_op, a, b}))
      assert (!$isunknown(result))
        else $error("alu: result is X for op=%0d", op);
  end
`endif

endmodule
