// Full-core observation interface (UVM env 7).
//
// PASSIVE BY CONSTRUCTION. This interface carries no driver-facing signals:
// the instruction stream is pre-generated into a hex image and loaded by the
// TCM at time zero, so there is nothing to drive at simulation time. The
// agent is UVM_PASSIVE and the monitor watches the core's retirement trace.
//
// A driveable memory - an agent writing instructions through this interface
// at runtime - is the specified next step (docs/results/0019). It needs the
// TCM replaced by a model with a testbench write port, which is a bigger
// change than this skeleton.
//
// The trace ports already existed: they were built at M3.2 for Sail lockstep
// (docs/results/0013), which is why this environment has something real to
// observe on its first run.
interface core_if (input logic clk, input logic rst_n);
  import rv32_pkg::*;

  logic            trace_valid;
  logic [XLEN-1:0] trace_pc;
  logic            trace_rd_we;
  logic [4:0]      trace_rd_addr;
  logic [XLEN-1:0] trace_rd_data;
  logic            trace_mem_we;
  logic [XLEN-1:0] trace_mem_addr;
  logic [XLEN-1:0] trace_mem_wdata;

  // Boundary observation points, all produced by rv32_core and currently
  // unconsumed by the pipeline itself.
  logic            misaligned;
  logic            csr_illegal;
  logic [XLEN-1:0] mtvec;
  logic [XLEN-1:0] mepc;
  logic            irq_pending;

  logic            testctl_we;
  logic [XLEN-1:0] testctl_data;

  // Sampled on negedge: the trace port is registered off posedge, so a
  // posedge clocking block would race the update. Same reasoning as the
  // regfile interface, where the write lands on posedge and the read is
  // sampled half a cycle later.
  clocking mon_cb @(negedge clk);
    input trace_valid, trace_pc, trace_rd_we, trace_rd_addr, trace_rd_data;
    input trace_mem_we, trace_mem_addr, trace_mem_wdata;
    input misaligned, csr_illegal, mtvec, mepc, irq_pending;
    input testctl_we, testctl_data;
  endclocking

  modport mon (clocking mon_cb, input rst_n);
endinterface
