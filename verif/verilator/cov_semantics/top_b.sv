// Top B: the same cov_leaf, reached as top_b.u_wrap.inner.
module top_b;
  logic        clk = 1'b0;
  logic        sel;
  logic [7:0]  y;
  logic [31:0] seed;
  int          sel_arg;

  cov_wrap u_wrap (.clk(clk), .sel(sel), .y(y));

  initial begin
    if (!$value$plusargs("SEL=%d", sel_arg)) sel_arg = 0;
    sel  = (sel_arg != 0);
    seed = 32'h0000_0001;
    repeat (64) begin
      #5 clk = 1'b1;
      #5 clk = 1'b0;
      seed = seed * 32'd1103515245 + 32'd12345;
    end
    $display("%m done: SEL=%0d y=%02h%s", sel_arg, y, "");
    $finish;
  end
endmodule
