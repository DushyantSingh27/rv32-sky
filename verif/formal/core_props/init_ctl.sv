// Control for core_props: does yosys-slang honour a variable's initial value
// in the BMC base case?
//
// core_props.sv resets the core from `logic started = 1'b0;` with no assume.
// If the initial value were dropped, `started` would be free at step 0 and
// the base case would begin from an arbitrary state instead of a reset.
//
//   init_zero  r starts 0 and holds    assert(!r)  must PASS
//   init_one   r starts 1 and holds    assert(!r)  must FAIL
//
// init_zero is the discriminating one: with the initial value dropped, r is
// free and init_zero FAILS. init_one shows the assertion is live.
module init_zero (input logic clk);
  logic r = 1'b0;
  always_ff @(posedge clk) r <= r;
  always_comb assert (!r);
endmodule

module init_one (input logic clk);
  logic r = 1'b1;
  always_ff @(posedge clk) r <= r;
  always_comb assert (!r);
endmodule
