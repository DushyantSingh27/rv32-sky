// Class D check for lsu.sv:50 (docs/results/0028). lsu_c is lsu.sv with the
// class A/B/C folds only; lsu_f is the fully folded file. They differ ONLY in
// the byte_en MEM_W fold, so this isolates it.
//
//   -D FREE   no constraint on size: must FAIL (2'b11 now enables all bytes)
//   default   size restricted to the decoded range: must PASS
module lsu_d_miter
  import rv32_pkg::*;
(
  input logic [1:0]      addr,
  input logic [1:0]      size,
  input logic            is_signed,
  input logic [XLEN-1:0] store_data,
  input logic [XLEN-1:0] load_data_raw
);
  logic [3:0]      be_c, be_f;
  logic [XLEN-1:0] sd_c, sd_f, ld_c, ld_f;
  logic            mis_c, mis_f;
  lsu_c u_c (.addr(addr), .size(size), .is_signed(is_signed), .store_data(store_data),
             .byte_en(be_c), .store_data_aligned(sd_c), .load_data_raw(load_data_raw),
             .load_data(ld_c), .misaligned(mis_c));
  lsu_f u_f (.addr(addr), .size(size), .is_signed(is_signed), .store_data(store_data),
             .byte_en(be_f), .store_data_aligned(sd_f), .load_data_raw(load_data_raw),
             .load_data(ld_f), .misaligned(mis_f));
  logic same;
  always_comb same = (be_c == be_f) && (sd_c == sd_f) && (ld_c == ld_f) && (mis_c == mis_f);
`ifdef FREE
  always_comb assert (same);                                 // A_EQ
`else
  always_comb if (size != 2'b11) assert (same);              // A_EQ
`endif
endmodule
