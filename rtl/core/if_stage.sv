// Instruction fetch.
//
// Holds the PC, computes PC+4, and applies redirects. Branches resolve in EX
// (ALU comparison, PROJECT_CONTEXT 3.2), so a taken branch costs two cycles -
// the two instructions already fetched behind it are flushed by the stage that
// owns them, not here.
//
// The PC is always 4-byte aligned in M3.2. The C extension (M4) relaxes that
// to 2-byte, at which point pc[1] becomes meaningful.
module if_stage
  import rv32_pkg::*;
(
  input  logic            clk,
  input  logic            rst_n,

  input  logic            stall,          // hold the PC (M3.3 uses this)
  input  logic            redirect_valid, // branch or jump taken
  input  logic [XLEN-1:0] redirect_pc,

  output logic [XLEN-1:0] pc,             // address to fetch

  input  logic [31:0]     instr_in,       // from the TCM, combinational read
  output if_id_t          if_id
);

  logic [XLEN-1:0] pc_q, pc_d, pc_plus4;

  // pc_plus4 is local. The LINK value for JAL/JALR is computed in MEM from the
  // instruction's own PC, so exporting it from here duplicated the adder and
  // the export went unused.
  always_comb begin
    pc_plus4 = pc_q + 32'd4;
    if      (redirect_valid) pc_d = redirect_pc;
    else if (stall)          pc_d = pc_q;
    else                     pc_d = pc_plus4;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pc_q <= RESET_VECTOR;
    else        pc_q <= pc_d;
  end

  always_comb pc = pc_q;

  // IF/ID pipeline register. A redirect invalidates the instruction currently
  // being fetched, because it belongs to the not-taken path.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      if_id.valid <= 1'b0;
      if_id.pc    <= '0;
      if_id.instr <= 32'h0000_0013;   // NOP (addi x0, x0, 0)
    end else if (redirect_valid) begin
      if_id.valid <= 1'b0;
      if_id.pc    <= '0;
      if_id.instr <= 32'h0000_0013;
    end else if (!stall) begin
      if_id.valid <= 1'b1;
      if_id.pc    <= pc_q;
      if_id.instr <= instr_in;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  always_ff @(posedge clk) begin
    if (rst_n) begin
      assert (pc_q[1:0] == 2'b00)
        else $error("if_stage: PC 0x%08h is not 4-byte aligned", pc_q);
      if (redirect_valid)
        assert (redirect_pc[1:0] == 2'b00)
          else $error("if_stage: redirect target 0x%08h is not aligned (pc=0x%08h)",
                      redirect_pc, pc_q);
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
