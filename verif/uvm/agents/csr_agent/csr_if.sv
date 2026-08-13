// CSR block testbench interface.
interface csr_if (input logic clk, input logic rst_n);
  import rv32_pkg::*;

  logic [11:0]     csr_addr;
  csr_op_e         csr_op;
  logic [XLEN-1:0] csr_wdata;
  logic            csr_read;
  logic            csr_write;
  logic [XLEN-1:0] csr_rdata;
  logic            csr_illegal;

  logic            trap_valid;
  logic [XLEN-1:0] trap_epc;
  logic [XLEN-1:0] trap_cause;
  logic [XLEN-1:0] trap_tval;
  logic            mret;

  logic            irq_timer;
  logic            irq_software;
  logic            irq_external;

  logic [XLEN-1:0] mtvec_o;
  logic [XLEN-1:0] mepc_o;
  logic            irq_pending;
  logic            instr_retired;

  clocking drv_cb @(posedge clk);
    output csr_addr, csr_op, csr_wdata, csr_read, csr_write;
    output trap_valid, trap_epc, trap_cause, trap_tval, mret;
    output irq_timer, irq_software, irq_external, instr_retired;
    input  csr_rdata, csr_illegal, mtvec_o, mepc_o, irq_pending;
  endclocking

  // Reads are combinational off csr_addr, so sample on negedge once the
  // address has been driven and the read mux has settled.
  clocking mon_cb @(negedge clk);
    input csr_addr, csr_op, csr_wdata, csr_read, csr_write;
    input csr_rdata, csr_illegal;
    input trap_valid, mret, irq_pending;
  endclocking

  modport drv (clocking drv_cb, input rst_n);
  modport mon (clocking mon_cb, input rst_n);
endinterface
