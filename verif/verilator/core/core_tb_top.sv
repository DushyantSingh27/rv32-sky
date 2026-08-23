// Verification top: core + TCM + peripheral decode.
// Lives in verif/ because it is a testbench fixture, not design.
module core_tb_top
  import rv32_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  output logic            testctl_we,
  output logic [XLEN-1:0] testctl_data,
  output logic            console_we,
  output logic [7:0]      console_char,
  output logic            misaligned,
  output logic            csr_illegal,
  output logic [XLEN-1:0] mtvec,
  output logic [XLEN-1:0] mepc,
  output logic            irq_pending,

  output logic            trace_valid,
  output logic [XLEN-1:0] trace_pc,
  output logic            trace_rd_we,
  output logic [4:0]      trace_rd_addr,
  output logic [XLEN-1:0] trace_rd_data,
  output logic            trace_mem_we,
  output logic [XLEN-1:0] trace_mem_addr,
  output logic [XLEN-1:0] trace_mem_wdata
);

  logic [XLEN-1:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata;
  logic [31:0]     imem_rdata;
  logic            dmem_we;
  logic [3:0]      dmem_be;
  logic            periph_we;
  logic [XLEN-1:0] periph_addr, periph_wdata;
  logic            a_oor, b_oor;

  rv32_core u_core (
    .clk              (clk),
    .rst_n            (rst_n),
    .imem_addr        (imem_addr),
    .imem_rdata       (imem_rdata),
    .dmem_addr        (dmem_addr),
    .dmem_we          (dmem_we),
    .dmem_be          (dmem_be),
    .dmem_wdata       (dmem_wdata),
    .dmem_rdata       (dmem_rdata),
    .periph_we        (periph_we),
    .periph_addr      (periph_addr),
    .periph_wdata     (periph_wdata),
    .mem_misaligned_o (misaligned),
    .csr_illegal_o    (csr_illegal),
    .mtvec_o          (mtvec),
    .mepc_o           (mepc),
    .irq_pending_o    (irq_pending),
    .trace_valid      (trace_valid),
    .trace_pc         (trace_pc),
    .trace_rd_we      (trace_rd_we),
    .trace_rd_addr    (trace_rd_addr),
    .trace_rd_data    (trace_rd_data),
    .trace_mem_we     (trace_mem_we),
    .trace_mem_addr   (trace_mem_addr),
    .trace_mem_wdata  (trace_mem_wdata)
  );

  tcm u_tcm (
    .clk            (clk),
    .a_addr         (imem_addr),
    .a_rdata        (imem_rdata),
    .b_addr         (dmem_addr),
    .b_we           (dmem_we),
    .b_be           (dmem_be),
    .b_wdata        (dmem_wdata),
    .b_rdata        (dmem_rdata),
    .a_out_of_range (a_oor),
    .b_out_of_range (b_oor)
  );

  always_comb begin
    testctl_we   = periph_we && (periph_addr == ADDR_TESTCTL);
    testctl_data = periph_wdata;
    console_we   = periph_we && (periph_addr == ADDR_CONSOLE);
    console_char = periph_wdata[7:0];
  end

endmodule
