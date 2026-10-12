// Coverage-semantics probe: the module whose points are compared across runs
// and across tops. Two arms on separate lines, selected by a constant input,
// so two runs with different SEL cover DIFFERENT lines. A probe in which both
// runs cover the same lines could not tell overwrite from accumulate.
module cov_leaf (
  input  logic       clk,
  input  logic       sel,
  output logic [7:0] y
);
  always_ff @(posedge clk) begin
    if (sel) begin
      y <= 8'hA5;
    end else begin
      y <= 8'h5A;
    end
  end
endmodule
