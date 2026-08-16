// Verification wrapper: decoder + imm_gen wired as the pipeline will wire them.
//
// COMBINED rather than testing imm_gen standalone. `fmt` is a decoder output,
// so supplying it by hand would leave the decoder-to-imm_gen connection
// unverified - and that connection is exactly where a format mismatch would
// hide. Lives in verif/ because it is a measurement fixture, not design.
module decode_top
  import rv32_pkg::*;
(
  input  logic [31:0]     instr,
  output ctrl_t           ctrl,
  output instr_fmt_e      fmt,
  output logic [XLEN-1:0] imm
);

  decoder u_decoder (
    .instr (instr),
    .ctrl  (ctrl),
    .fmt   (fmt)
  );

  imm_gen u_imm_gen (
    .instr (instr[31:7]),
    .fmt   (fmt),
    .imm   (imm)
  );

endmodule
