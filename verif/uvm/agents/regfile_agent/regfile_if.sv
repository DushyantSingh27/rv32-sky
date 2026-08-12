// Register file testbench interface.
//
// The DUT mixes timing domains: reads are combinational, the write is
// synchronous. One transaction therefore carries both a read request and a
// write request applied in the same cycle - which is exactly how the ID stage
// will drive it, and exactly where the read-during-write collision lives.
interface regfile_if (input logic clk, input logic rst_n);
  import rv32_pkg::*;

  logic [4:0]      rs1_addr;
  logic [XLEN-1:0] rs1_data;
  logic [4:0]      rs2_addr;
  logic [XLEN-1:0] rs2_data;
  logic [4:0]      rd_addr;
  logic [XLEN-1:0] rd_data;
  logic            rd_we;

  clocking drv_cb @(posedge clk);
    output rs1_addr, rs2_addr, rd_addr, rd_data, rd_we;
    input  rs1_data, rs2_data;
  endclocking

  // Monitor samples on negedge: the write has landed on the preceding posedge
  // and the combinational reads have settled. Sampling read data on posedge
  // would race the write.
  clocking mon_cb @(negedge clk);
    input rs1_addr, rs1_data, rs2_addr, rs2_data, rd_addr, rd_data, rd_we;
  endclocking

  modport drv (clocking drv_cb, input rst_n);
  modport mon (clocking mon_cb, input rst_n);
endinterface
