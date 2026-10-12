// Toggle-coverage limits probe. --coverage-max-width is described in --help as
// "Maximum array depth for coverage" -- the name says width, the text says
// depth, no default is given. This module carries both: packed vectors of
// increasing width, unpacked arrays of increasing depth, and one packed struct
// shaped like the core's pipeline registers.
//
// Every signal feeds the output 'red', so a signal with no toggle points was
// excluded by a limit, not removed as unused. Without that, the two
// explanations would produce the same absence.
module cov_wide (
  input  logic        clk,
  input  logic [31:0] seed,
  output logic        red
);
  typedef struct packed {
    logic [31:0]  a;
    logic [255:0] b;
    logic         v;
  } wide_s;                       // 289 bits

  logic [31:0]   w32;
  logic [255:0]  w256;
  logic [256:0]  w257;
  logic [1023:0] w1024;
  logic [4095:0] w4096;
  wide_s         ws;
  logic [31:0]   arr8  [8];
  logic [31:0]   arr64 [64];
  logic [31:0]   arr2k [2048];

  always_ff @(posedge clk) begin
    w32   <= seed;
    w256  <= {8{seed}};
    w257  <= {seed[0], {8{seed}}};
    w1024 <= {32{seed}};
    w4096 <= {128{seed}};
    ws    <= '{a: seed, b: {8{seed}}, v: seed[0]};
    arr8 [seed[2:0]]  <= seed;
    arr64[seed[5:0]]  <= seed;
    arr2k[seed[10:0]] <= seed;
  end

  assign red = (^w32) ^ (^w256) ^ (^w257) ^ (^w1024) ^ (^w4096) ^ (^ws)
             ^ (^arr8[seed[2:0]]) ^ (^arr64[seed[5:0]]) ^ (^arr2k[seed[10:0]]);
endmodule
