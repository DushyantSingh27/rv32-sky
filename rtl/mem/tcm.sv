// Tightly-coupled memory: 8 KB, unified instruction and data.
//
// DUAL-PORT for M3.2. In simulation a dual-port memory is free - it is an
// array with two readers. The area cost is real only at hardening, and
// sky130's pre-built SRAM macros are SINGLE-port, so M7 needs either
// arbitration between fetch and data access, or the I-cache from
// PROJECT_CONTEXT 3.3 Phase 2. Recorded as a deferred problem, not solved.
//
// Port A: instruction fetch, read-only, word-aligned.
// Port B: data access, read/write with byte enables.
//
// Both reads are COMBINATIONAL, matching a register-file-style memory rather
// than a synchronous SRAM. That is a simulation convenience which will change
// at M7; a real SRAM read arrives a cycle later and needs the pipeline to
// account for it.
module tcm
  import rv32_pkg::*;
(
  input  logic                    clk,

  // Port A - instruction fetch
  input  logic [XLEN-1:0]         a_addr,
  output logic [31:0]             a_rdata,

  // Port B - data
  input  logic [XLEN-1:0]         b_addr,
  input  logic                    b_we,
  input  logic [3:0]              b_be,
  input  logic [XLEN-1:0]         b_wdata,
  output logic [XLEN-1:0]         b_rdata,

  // Out-of-range detection. NOT consumed in M3.2 - trap generation is M4,
  // same approach as the decoder's `illegal` flag. Produced here because a
  // memory that silently ignores the upper address bits aliases 0x00002000
  // onto 0x00000000 and returns the wrong instruction with no complaint.
  // Narrowing the ports to hide the unused bits would conceal exactly that.
  output logic                    a_out_of_range,
  output logic                    b_out_of_range
);

  localparam int unsigned WORDS = TCM_SIZE_BYTES / 4;

  logic [31:0] mem [0:WORDS-1];

  logic [$clog2(WORDS)-1:0] a_word, b_word;
  always_comb begin
    a_word = a_addr[TCM_ADDR_BITS-1:2];
    b_word = b_addr[TCM_ADDR_BITS-1:2];

    // Anything above the TCM, or not word-aligned on the fetch port.
    a_out_of_range = (a_addr[XLEN-1:TCM_ADDR_BITS] != '0) || (a_addr[1:0] != 2'b00);
    b_out_of_range = (b_addr[XLEN-1:TCM_ADDR_BITS] != '0);
  end

  always_comb begin
    a_rdata = mem[a_word];
    b_rdata = mem[b_word];
  end

  always_ff @(posedge clk) begin
    if (b_we) begin
      if (b_be[0]) mem[b_word][7:0]   <= b_wdata[7:0];
      if (b_be[1]) mem[b_word][15:8]  <= b_wdata[15:8];
      if (b_be[2]) mem[b_word][23:16] <= b_wdata[23:16];
      if (b_be[3]) mem[b_word][31:24] <= b_wdata[31:24];
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (a_out_of_range)
      $error("tcm: instruction fetch out of range or misaligned: 0x%08h", a_addr);
    if (b_we && b_out_of_range)
      $error("tcm: data write out of range: 0x%08h", b_addr);
  end

  // Program loading via $readmemh, NOT exported DPI.
  //
  // An exported DPI function requires the C side to call svSetScope with the
  // module instance path before invoking it, or it aborts with "scope wasn't
  // set". $readmemh needs no scope machinery, is universally supported, and
  // the filename arrives as a plusarg so the harness controls it.
  string hexfile;
  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0000_0013;   // NOP
    if ($value$plusargs("HEX=%s", hexfile)) begin
      $readmemh(hexfile, mem);
      $display("tcm: loaded %s", hexfile);
    end else begin
      $display("tcm: no +HEX= given, memory is all NOPs");
    end
  end
`endif

endmodule
