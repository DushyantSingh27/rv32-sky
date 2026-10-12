// Puts cov_leaf one level deeper in top_b than in top_a, so the same source
// lines are reached through two different hierarchy paths.
module cov_wrap (
  input  logic       clk,
  input  logic       sel,
  output logic [7:0] y
);
  cov_leaf inner (.clk(clk), .sel(sel), .y(y));
endmodule
