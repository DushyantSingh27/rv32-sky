// Formal flow CONTROLS, read by plain Yosys (read -formal). Each module's
// answer is known in advance; the point is to measure what SBY REPORTS for
// it, so that no real proof later relies on a status whose meaning was
// recalled rather than seen. docs/results/0028.
module k_cover_one (input clk);
  always @* cover (1'b1);                 // reachable by definition
endmodule

module k_cover_zero (input clk);
  always @* cover (1'b0);                 // unreachable by definition
endmodule

module k_assert_true (input clk, input a);
  always @* assert (a == a);              // holds for every input
endmodule

module k_assert_false (input clk, input a);
  always @* assert (a == 1'b0);           // fails for a = 1
endmodule

module k_vacuous (input clk, input a);
  always @* assume (1'b0);                // no trace satisfies this
  always @* assert (a == 1'b0);           // would fail, if anything were checked
endmodule
