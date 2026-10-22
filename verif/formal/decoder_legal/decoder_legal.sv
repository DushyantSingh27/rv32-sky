// Decoder legality - a COMPLETE proof, for all 2^32 instruction words, that
// the decoder never emits an out-of-range control encoding.
//
// WHY. Six of the twelve unreachable lines in docs/results/0028 are `default`
// arms that only an out-of-range encoding could reach: alu.sv (alu_op 11-15,
// branch_op 7), lsu.sv (mem_size 2'b11, three arms), rv32_core.sv (wb_sel
// 2'b11). Those fields reach the units from the decoder through the pipeline
// registers, which carry the decoder's output, zero, or that output with
// three 1-bit enables cleared (read 2026-10-21, rv32_core.sv). This module
// proves the decoder half.
//
// COMPLETE, not bounded: the decoder is combinational and `instr` is a free
// input, so one step covers every instruction word.
//
// Fields are read BY NAME through ctrl_t. No hand-written bit map - the
// 0017 failure.
//
// Read by yosys-slang. Immediate assertions reach the solver through it:
// MEASURED 2026-10-21, verif/formal/controls K6/K7.
module decoder_legal
  import rv32_pkg::*;
(
  input logic [31:0] instr          // free: the solver chooses every bit
);
  ctrl_t      ctrl;
  instr_fmt_e fmt;

  decoder u_dut (.instr(instr), .ctrl(ctrl), .fmt(fmt));

  always_comb begin
    assert (ctrl.alu_op <= ALU_PASS_B);     // A_ALU   alu.sv default, op 11-15
    assert (ctrl.branch_op != 3'd7);        // A_BR    alu.sv default, branch_op 7
    assert (ctrl.mem_size != 2'b11);        // A_SIZE  lsu.sv defaults, size 2'b11
    assert (ctrl.wb_sel != 2'b11);          // A_WB    rv32_core.sv WB default
  end

  // Reachability. Run as a separate cover job: each field must still reach
  // its largest legal value, or the assertions above could hold because the
  // decoder's output is stuck.
  always_comb begin
    cover (ctrl.alu_op == ALU_PASS_B);
    cover (ctrl.branch_op == BR_GEU);
    cover (ctrl.mem_size == MEM_W);
    cover (ctrl.wb_sel == WB_PC4);
  end
endmodule
