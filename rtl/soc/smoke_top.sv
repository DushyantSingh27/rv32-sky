// M0 smoke design: synthesis top level. Flat ports outside, interface inside.
module smoke_top
  import smoke_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,
  input  logic             start,
  input  logic             stop,
  output logic             result_valid,
  output logic [CNT_W-1:0] result_value
);

  smoke_if bus ();

  always_comb begin
    bus.start = start;
    bus.stop  = stop;
  end

  assign result_valid = bus.result.valid;
  assign result_value = bus.result.value;

  smoke_counter u_smoke_counter (
    .clk   (clk),
    .rst_n (rst_n),
    .bus   (bus)
  );

endmodule
