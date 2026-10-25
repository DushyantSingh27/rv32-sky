// Whole-core properties of rv32_core, read by yosys-slang.
//
//   PROP_PC   the fetch address is 4-byte aligned   imem_addr[1:0] == 0
//   PROP_MIS  a misaligned load or store never reaches MEM   !mem_misaligned_o
//
// Each property is compiled into its own job (-D PROP_PC / -D PROP_MIS), so
// one property's induction result cannot hide the other's.
//
// THE INSTRUCTION AND DATA STREAMS ARE FREE INPUTS: the solver chooses every
// bit of imem_rdata and dmem_rdata, every cycle. No memory model, no program.
//
// NO ASSUMES. Reset comes from `started`, whose initial value is 0, so the
// core is held in reset for step 0 and runs from step 1. That depends on
// yosys-slang honouring the initial value: checked first, by init_ctl.sv.
// Both properties are gated on rst_n - they are claims about the core OUT of
// reset - so a core stuck in reset would satisfy them vacuously; the cover
// job and the mutants are what show it is not.
//
// RISCV_FORMAL (the cover job only) brings out the rvfi ports, so trap
// retirements can be observed without hierarchical references. The two
// property jobs build WITHOUT it: they check exactly the synthesised core.
// slang defines SYNTHESIS itself, so the `ifndef SYNTHESIS trace ports and
// the RTL's own immediate assertions are absent from every job here.
//
// docs/results/0028.
module core_props
  import rv32_pkg::*;
(
  input logic        clk,
  input logic [31:0] imem_rdata,        // free
  input logic [31:0] dmem_rdata         // free
);
  logic started = 1'b0;
  always_ff @(posedge clk) started <= 1'b1;

  logic rst_n;
  always_comb rst_n = started;

  logic [XLEN-1:0] imem_addr, dmem_addr, dmem_wdata;
  logic            dmem_we;
  logic [3:0]      dmem_be;
  logic            periph_we;
  logic [XLEN-1:0] periph_addr, periph_wdata;
  logic            mem_misaligned_o, csr_illegal_o, irq_pending_o;
  logic [XLEN-1:0] mtvec_o, mepc_o;

`ifdef RISCV_FORMAL
  logic            rvfi_valid, rvfi_trap, rvfi_halt, rvfi_intr;
  logic [63:0]     rvfi_order;
  logic [31:0]     rvfi_insn;
  logic [1:0]      rvfi_mode, rvfi_ixl;
  logic [4:0]      rvfi_rs1_addr, rvfi_rs2_addr, rvfi_rd_addr;
  logic [XLEN-1:0] rvfi_rs1_rdata, rvfi_rs2_rdata, rvfi_rd_wdata;
  logic [XLEN-1:0] rvfi_pc_rdata, rvfi_pc_wdata;
  logic [XLEN-1:0] rvfi_mem_addr, rvfi_mem_rdata, rvfi_mem_wdata;
  logic [3:0]      rvfi_mem_rmask, rvfi_mem_wmask;
`endif

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
    .mem_misaligned_o (mem_misaligned_o),
    .csr_illegal_o    (csr_illegal_o),
    .mtvec_o          (mtvec_o),
    .mepc_o           (mepc_o),
    .irq_pending_o    (irq_pending_o)
`ifdef RISCV_FORMAL
    ,
    .rvfi_valid       (rvfi_valid),
    .rvfi_order       (rvfi_order),
    .rvfi_insn        (rvfi_insn),
    .rvfi_trap        (rvfi_trap),
    .rvfi_halt        (rvfi_halt),
    .rvfi_intr        (rvfi_intr),
    .rvfi_mode        (rvfi_mode),
    .rvfi_ixl         (rvfi_ixl),
    .rvfi_rs1_addr    (rvfi_rs1_addr),
    .rvfi_rs2_addr    (rvfi_rs2_addr),
    .rvfi_rs1_rdata   (rvfi_rs1_rdata),
    .rvfi_rs2_rdata   (rvfi_rs2_rdata),
    .rvfi_rd_addr     (rvfi_rd_addr),
    .rvfi_rd_wdata    (rvfi_rd_wdata),
    .rvfi_pc_rdata    (rvfi_pc_rdata),
    .rvfi_pc_wdata    (rvfi_pc_wdata),
    .rvfi_mem_addr    (rvfi_mem_addr),
    .rvfi_mem_rmask   (rvfi_mem_rmask),
    .rvfi_mem_wmask   (rvfi_mem_wmask),
    .rvfi_mem_rdata   (rvfi_mem_rdata),
    .rvfi_mem_wdata   (rvfi_mem_wdata)
`endif
  );

`ifdef PROP_PC
  always_comb if (rst_n) assert (imem_addr[1:0] == 2'b00);      // A_PC
`endif
`ifdef PROP_MIS
  always_comb if (rst_n) assert (!mem_misaligned_o);            // A_MIS
`endif

`ifdef RISCV_FORMAL
  // The trap paths the two properties depend on are LIVE. Each encoding below
  // is legal, so rvfi_trap on it can only be the misalignment trap
  // (rvfi_trap covers causes 0/2/4/6, rv32_core.sv). mret retires normally.
  logic [6:0] op;
  logic [2:0] f3;
  always_comb begin
    op = rvfi_insn[6:0];
    f3 = rvfi_insn[14:12];
  end
  always_comb begin
    cover (rvfi_valid && rvfi_trap && op == 7'b1101111);                  // C_JAL
    cover (rvfi_valid && rvfi_trap && op == 7'b1100111 && f3 == 3'b000);  // C_JALR
    cover (rvfi_valid && rvfi_trap && op == 7'b0000011 && f3 == 3'b010);  // C_LW
    cover (rvfi_valid && rvfi_trap && op == 7'b0100011 && f3 == 3'b010);  // C_SW
    cover (rvfi_valid && !rvfi_trap && rvfi_insn == 32'h3020_0073);       // C_MRET
  end
`endif
endmodule
