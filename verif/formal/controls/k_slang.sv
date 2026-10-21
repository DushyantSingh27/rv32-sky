// Formal flow CONTROLS, read by yosys-slang (read_slang). The decoder
// legality proof will put immediate assertions in an SV module that slang
// reads. If slang dropped them silently, every such proof would pass
// vacuously - k_slang_false is what would show it.
module k_slang_true (input logic clk, input logic a);
  always_comb assert (a == a);
endmodule

module k_slang_false (input logic clk, input logic a);
  always_comb assert (a == 1'b0);
endmodule
