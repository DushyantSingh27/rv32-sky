// Top A: cov_leaf at top_a.u_leaf, plus the width/depth probe.
module top_a;
  logic        clk = 1'b0;
  logic        sel;
  logic [7:0]  y;
  logic [31:0] seed;
  logic        red;
  int          sel_arg;

  cov_leaf u_leaf (.clk(clk), .sel(sel), .y(y));
  cov_wide u_wide (.clk(clk), .seed(seed), .red(red));

  initial begin
    if (!$value$plusargs("SEL=%d", sel_arg)) sel_arg = 0;
    sel  = (sel_arg != 0);
    seed = 32'h0000_0001;
    repeat (64) begin
      #5 clk = 1'b1;
      #5 clk = 1'b0;
      seed = seed * 32'd1103515245 + 32'd12345;
    end
    $display("%m done: SEL=%0d y=%02h%s", sel_arg, y, $sformatf(" red=%0b", red));
    $finish;
  end
endmodule
