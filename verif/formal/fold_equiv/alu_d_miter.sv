// Class D check for alu.sv:45 (docs/results/0028). alu_c is alu.sv with the
// class A/B/C folds only; alu_f is the fully folded file. They differ ONLY in
// the ALU_PASS_B fold, so this isolates it.
//
//   -D FREE   no constraint on op: must FAIL (op 11-15 now returns b, not 0)
//   default   op restricted to the decoded range: must PASS
//
// The restriction is an implication inside the assertion, not an assume.
// Combinational with free inputs, so a PASS is complete for that range.
module alu_d_miter
  import rv32_pkg::*;
(
  input alu_op_e         op,
  input branch_op_e      branch_op,
  input logic [XLEN-1:0] a,
  input logic [XLEN-1:0] b
);
  logic [XLEN-1:0] r_c, r_f;
  logic            t_c, t_f;
  alu_c u_c (.op(op), .branch_op(branch_op), .a(a), .b(b), .result(r_c), .branch_taken(t_c));
  alu_f u_f (.op(op), .branch_op(branch_op), .a(a), .b(b), .result(r_f), .branch_taken(t_f));
`ifdef FREE
  always_comb assert (r_c == r_f && t_c == t_f);                          // A_EQ
`else
  always_comb if (op <= ALU_PASS_B) assert (r_c == r_f && t_c == t_f);    // A_EQ
`endif
endmodule
