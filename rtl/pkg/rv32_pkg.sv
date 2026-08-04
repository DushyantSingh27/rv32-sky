// RV32 shared types and constants. Grown incrementally, one block at a time.
package rv32_pkg;

  localparam int unsigned XLEN = 32;

  // ALU operations. PASS_B is for LUI only - the JAL/JALR link value is PC+4,
  // which uses ALU_ADD.
  typedef enum logic [3:0] {
    ALU_ADD    = 4'd0,
    ALU_SUB    = 4'd1,
    ALU_SLL    = 4'd2,
    ALU_SRL    = 4'd3,
    ALU_SRA    = 4'd4,
    ALU_SLT    = 4'd5,
    ALU_SLTU   = 4'd6,
    ALU_XOR    = 4'd7,
    ALU_OR     = 4'd8,
    ALU_AND    = 4'd9,
    ALU_PASS_B = 4'd10
  } alu_op_e;

  // Branch comparison. BR_NONE means this is not a branch instruction.
  typedef enum logic [2:0] {
    BR_NONE = 3'd0,
    BR_EQ   = 3'd1,
    BR_NE   = 3'd2,
    BR_LT   = 3'd3,
    BR_GE   = 3'd4,
    BR_LTU  = 3'd5,
    BR_GEU  = 3'd6
  } branch_op_e;

endpackage
