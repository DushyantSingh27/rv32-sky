// RV32I 5-stage in-order core.
//
// M3.2 SCOPE: NO HAZARD HANDLING. No forwarding, no load-use interlock. A
// program with back-to-back dependent instructions computes wrong answers, and
// test programs carry explicit NOP padding to avoid it. That scaffold is
// removed at M3.3.
//
// The omission is deliberate. PROJECT_INSTRUCTIONS section 7 names big-bang
// integration as a failure mode: building the pipeline AND the hazard unit
// together means a failing program has eleven possible causes. Gating on a
// NOP-padded program proves the datapath first, so M3.3's failures can only be
// hazard failures.
//
// Branches resolve in EX because the ALU carries the comparison
// (PROJECT_CONTEXT 3.2), so a taken branch costs two cycles.
//
// The muldiv is NOT instantiated: RV32M decode is M4 per ADR-0003. A verified
// block sitting disconnected is a visible cost of scope discipline.
module rv32_core
  import rv32_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // TCM port A - instruction fetch
  output logic [XLEN-1:0] imem_addr,
  input  logic [31:0]     imem_rdata,

  // TCM port B - data
  output logic [XLEN-1:0] dmem_addr,
  output logic            dmem_we,
  output logic [3:0]      dmem_be,
  output logic [XLEN-1:0] dmem_wdata,
  input  logic [XLEN-1:0] dmem_rdata,

  // Peripheral writes (0x8000_0000 and up) - test control and console
  output logic            periph_we,
  output logic [XLEN-1:0] periph_addr,
  output logic [XLEN-1:0] periph_wdata,

  // Misaligned data access. NOT consumed in M3.2 - trap generation is M4.
  // Routed out rather than suppressed, matching the decoder's `illegal` flag
  // and the TCM's out-of-range outputs: a detected-but-unhandled condition
  // should be visible at the boundary, not silently dropped inside.
  output logic            mem_misaligned_o

`ifndef SYNTHESIS
  ,
  // Retirement trace. Simulation only - stripped by the guard, so it costs
  // nothing in silicon. This is what Sail lockstep compares against at M3.5,
  // and building it now makes lockstep plumbing rather than surgery.
  output logic            trace_valid,
  output logic [XLEN-1:0] trace_pc,
  output logic            trace_rd_we,
  output logic [4:0]      trace_rd_addr,
  output logic [XLEN-1:0] trace_rd_data,
  output logic            trace_mem_we,
  output logic [XLEN-1:0] trace_mem_addr,
  output logic [XLEN-1:0] trace_mem_wdata
`endif
);

  // ================= pipeline registers =================
  if_id_t  if_id;
  id_ex_t  id_ex_q;
  ex_mem_t ex_mem_q;
  mem_wb_t mem_wb_q;

  // ================= IF =================
  logic [XLEN-1:0] if_pc;
  logic            redirect_valid;
  logic [XLEN-1:0] redirect_pc;

  if_stage u_if (
    .clk            (clk),
    .rst_n          (rst_n),
    .stall          (stall),
    .redirect_valid (redirect_valid),
    .redirect_pc    (redirect_pc),
    .pc             (if_pc),
    .instr_in       (imem_rdata),
    .if_id          (if_id)
  );

  always_comb imem_addr = if_pc;

  // ================= ID =================
  ctrl_t           id_ctrl;
  instr_fmt_e      id_fmt;
  logic [XLEN-1:0] id_imm;
  logic [XLEN-1:0] id_rs1_data, id_rs2_data;

  decoder u_decoder (
    .instr (if_id.instr),
    .ctrl  (id_ctrl),
    .fmt   (id_fmt)
  );

  imm_gen u_imm_gen (
    .instr (if_id.instr[31:7]),
    .fmt   (id_fmt),
    .imm   (id_imm)
  );

  // Write-back into the register file happens from the WB stage below.
  logic            wb_reg_we;
  logic [4:0]      wb_rd_addr;
  logic [XLEN-1:0] wb_rd_data;

  regfile u_regfile (
    .clk      (clk),
    .rst_n    (rst_n),
    .rs1_addr (id_ctrl.rs1_addr),
    .rs1_data (id_rs1_data),
    .rs2_addr (id_ctrl.rs2_addr),
    .rs2_data (id_rs2_data),
    .rd_addr  (wb_rd_addr),
    .rd_data  (wb_rd_data),
    .rd_we    (wb_reg_we)
  );

  // ---------------- hazards ----------------
  fwd_sel_e fwd_a, fwd_b;
  logic     fwd_id_rs1, fwd_id_rs2, stall;

  hazard_unit u_hazard (
    .ex_rs1_addr       (id_ex_q.ctrl.rs1_addr),
    .ex_rs2_addr       (id_ex_q.ctrl.rs2_addr),
    .ex_rs1_used       (id_ex_q.ctrl.rs1_used),
    .ex_rs2_used       (id_ex_q.ctrl.rs2_used),
    .mem_rd_addr       (ex_mem_q.ctrl.rd_addr),
    .mem_reg_write     (ex_mem_q.ctrl.reg_write),
    .mem_valid         (ex_mem_q.valid),
    .wb_rd_addr        (mem_wb_q.ctrl.rd_addr),
    .wb_reg_write      (mem_wb_q.ctrl.reg_write),
    .wb_valid          (mem_wb_q.valid),
    .ex_stage_rd_addr  (id_ex_q.ctrl.rd_addr),
    .ex_stage_mem_read (id_ex_q.ctrl.mem_read),
    .ex_stage_valid    (id_ex_q.valid),
    .id_rs1_addr       (id_ctrl.rs1_addr),
    .id_rs2_addr       (id_ctrl.rs2_addr),
    .id_rs1_used       (id_ctrl.rs1_used),
    .id_rs2_used       (id_ctrl.rs2_used),
    .id_rf_rs1_addr    (id_ctrl.rs1_addr),
    .id_rf_rs2_addr    (id_ctrl.rs2_addr),
    .fwd_a             (fwd_a),
    .fwd_b             (fwd_b),
    .fwd_id_rs1        (fwd_id_rs1),
    .fwd_id_rs2        (fwd_id_rs2),
    .stall             (stall)
  );

  // WB->ID forwarding. Mandatory because the register file is read-first:
  // a value written in WB is invisible to a read in ID in the same cycle.
  logic [XLEN-1:0] id_rs1_fwd, id_rs2_fwd;
  always_comb begin
    id_rs1_fwd = fwd_id_rs1 ? wb_rd_data : id_rs1_data;
    id_rs2_fwd = fwd_id_rs2 ? wb_rd_data : id_rs2_data;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || ex_redirect_valid) begin
      id_ex_q <= '0;
    end else if (stall) begin
      // Bubble into EX. IF and ID hold their contents; the load in EX advances
      // to MEM, where MEM->EX can supply it next cycle.
      id_ex_q <= '0;
    end else begin
      id_ex_q.valid    <= if_id.valid;
      id_ex_q.pc       <= if_id.pc;
      id_ex_q.ctrl     <= id_ctrl;
      id_ex_q.imm      <= id_imm;
      id_ex_q.rs1_data <= id_rs1_fwd;
      id_ex_q.rs2_data <= id_rs2_fwd;
    end
  end

  // ================= EX =================
  logic [XLEN-1:0] ex_alu_a, ex_alu_b, ex_alu_result;
  logic            ex_branch_taken;

  // Forwarding is applied at the ALU OPERAND MUXES, so id_ex_q keeps holding
  // the architectural register values it read. That matters for the trace
  // port: forwarding is a microarchitectural detail, not an architectural one.
  logic [XLEN-1:0] ex_rs1_fwd, ex_rs2_fwd;
  always_comb begin
    unique case (fwd_a)
      FWD_MEM: ex_rs1_fwd = ex_mem_q.alu_result;
      FWD_WB:  ex_rs1_fwd = wb_rd_data;
      default: ex_rs1_fwd = id_ex_q.rs1_data;
    endcase
    unique case (fwd_b)
      FWD_MEM: ex_rs2_fwd = ex_mem_q.alu_result;
      FWD_WB:  ex_rs2_fwd = wb_rd_data;
      default: ex_rs2_fwd = id_ex_q.rs2_data;
    endcase
  end

  always_comb begin
    ex_alu_a = id_ex_q.ctrl.alu_src_a_pc  ? id_ex_q.pc  : ex_rs1_fwd;
    ex_alu_b = id_ex_q.ctrl.alu_src_b_imm ? id_ex_q.imm : ex_rs2_fwd;
  end

  alu u_alu (
    .op           (id_ex_q.ctrl.alu_op),
    .branch_op    (id_ex_q.ctrl.branch_op),
    .a            (ex_alu_a),
    .b            (ex_alu_b),
    .result       (ex_alu_result),
    .branch_taken (ex_branch_taken)
  );

  // Branch and jump targets. JALR masks bit 0 per the spec; JAL and branches
  // are PC-relative. The ALU produces the LINK value for jumps, not the
  // target - keeping it out of the branch-resolution path.
  // Branch and jump targets, computed combinationally in EX.
  logic [XLEN-1:0] ex_branch_target, ex_jalr_target;
  logic            ex_redirect_valid;
  logic [XLEN-1:0] ex_redirect_pc;

  always_comb begin
    ex_branch_target = id_ex_q.pc + id_ex_q.imm;
    // JALR reads rs1 for its target, so it needs the forwarded value.
    ex_jalr_target   = (ex_rs1_fwd + id_ex_q.imm) & ~32'd1;

    ex_redirect_valid = id_ex_q.valid &&
                        ((id_ex_q.ctrl.is_branch && ex_branch_taken) ||
                          id_ex_q.ctrl.is_jal || id_ex_q.ctrl.is_jalr);

    if      (id_ex_q.ctrl.is_jalr) ex_redirect_pc = ex_jalr_target;
    else                           ex_redirect_pc = ex_branch_target;
  end

  // Redirect is REGISTERED before reaching if_stage.
  //
  // HONEST HISTORY: this was added while chasing a redirect to 0xfffdb6ea, an
  // odd address impossible from either target expression. I diagnosed an
  // evaluation-order hazard between the combinational redirect and if_stage's
  // sequential logic. THAT DIAGNOSIS WAS WRONG. The real cause was in the test
  // program: it used address 0x100 for data, inside the instruction stream, so
  // a store overwrote a NOP and the fetch unit read 0xdeadbeef back as an
  // instruction - whose low bits encode a JAL.
  //
  // The registration is kept because it is defensible on its own merits: it
  // removes any dependence on evaluation order at the cost of a 3-cycle branch
  // penalty instead of 2. Revisit at M6 with the branch predictor, when branch
  // cost actually matters.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      redirect_valid <= 1'b0;
      redirect_pc    <= '0;
    end else begin
      redirect_valid <= ex_redirect_valid;
      redirect_pc    <= ex_redirect_pc;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_mem_q <= '0;
    end else begin
      ex_mem_q.valid      <= id_ex_q.valid;
      ex_mem_q.pc         <= id_ex_q.pc;
      ex_mem_q.ctrl       <= id_ex_q.ctrl;
      ex_mem_q.alu_result <= ex_alu_result;
      // Store data needs forwarding too. `sw x1, 0(x2)` immediately after a
      // write to x1 must store the NEW value, and rs2 here is the data, not
      // an ALU operand - so it takes the forwarded value directly.
      ex_mem_q.rs2_data   <= ex_rs2_fwd;
    end
  end

  // ================= MEM =================
  logic [3:0]      mem_byte_en;
  logic [XLEN-1:0] mem_store_aligned, mem_load_data;
  logic            mem_misaligned;
  logic            is_periph;

  lsu u_lsu (
    .addr               (ex_mem_q.alu_result[1:0]),
    .size               (ex_mem_q.ctrl.mem_size),
    .is_signed          (ex_mem_q.ctrl.mem_signed),
    .store_data         (ex_mem_q.rs2_data),
    .byte_en            (mem_byte_en),
    .store_data_aligned (mem_store_aligned),
    .load_data_raw      (dmem_rdata),
    .load_data          (mem_load_data),
    .misaligned         (mem_misaligned)
  );

  // Bit 31 selects peripheral vs memory - a single-bit test rather than a
  // range comparison.
  always_comb is_periph = ex_mem_q.alu_result[XLEN-1];

  always_comb begin
    dmem_addr    = ex_mem_q.alu_result;
    dmem_we      = ex_mem_q.valid && ex_mem_q.ctrl.mem_write && !is_periph;
    dmem_be      = mem_byte_en;
    dmem_wdata   = mem_store_aligned;

    periph_we    = ex_mem_q.valid && ex_mem_q.ctrl.mem_write && is_periph;
    periph_addr  = ex_mem_q.alu_result;
    periph_wdata = ex_mem_q.rs2_data;

    mem_misaligned_o = ex_mem_q.valid && mem_misaligned &&
                       (ex_mem_q.ctrl.mem_read || ex_mem_q.ctrl.mem_write);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_wb_q <= '0;
    end else begin
      mem_wb_q.valid      <= ex_mem_q.valid;
      mem_wb_q.ctrl       <= ex_mem_q.ctrl;
      mem_wb_q.alu_result <= ex_mem_q.alu_result;
      mem_wb_q.mem_data   <= mem_load_data;
      mem_wb_q.pc_plus4   <= ex_mem_q.pc + 32'd4;
    end
  end

  // ================= WB =================
  always_comb begin
    unique case (mem_wb_q.ctrl.wb_sel)
      WB_ALU:  wb_rd_data = mem_wb_q.alu_result;
      WB_MEM:  wb_rd_data = mem_wb_q.mem_data;
      WB_PC4:  wb_rd_data = mem_wb_q.pc_plus4;
      default: wb_rd_data = mem_wb_q.alu_result;
    endcase
    wb_rd_addr = mem_wb_q.ctrl.rd_addr;
    wb_reg_we  = mem_wb_q.valid && mem_wb_q.ctrl.reg_write;
  end

`ifndef SYNTHESIS
  // Redirect diagnostics: print every redirect with the instruction that
  // caused it, so a bad target identifies its own source.
  // Trace taken at WB - the commit point. An instruction that reaches here has
  // architecturally happened.
  // The instruction word is NOT carried through the pipeline. Sail lockstep at
  // M3.5 needs to know which instruction produced a mismatch, but the TCM is
  // not self-modifying in any test we run, so the PC uniquely determines it and
  // the harness looks it up. Carrying 32 bits through three pipeline registers
  // would be 96 flops of pure debug overhead.
  logic [XLEN-1:0] mem_wb_pc;
  logic            mem_wb_mem_we;
  logic [XLEN-1:0] mem_wb_mem_addr, mem_wb_mem_wdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_wb_pc <= '0;
      mem_wb_mem_we <= 1'b0; mem_wb_mem_addr <= '0; mem_wb_mem_wdata <= '0;
    end else begin
      mem_wb_pc        <= ex_mem_q.pc;
      mem_wb_mem_we    <= ex_mem_q.valid && ex_mem_q.ctrl.mem_write;
      mem_wb_mem_addr  <= ex_mem_q.alu_result;
      mem_wb_mem_wdata <= ex_mem_q.rs2_data;
    end
  end

  always_comb begin
    trace_valid     = mem_wb_q.valid;
    trace_pc        = mem_wb_pc;
    trace_rd_we     = wb_reg_we;
    trace_rd_addr   = wb_rd_addr;
    trace_rd_data   = wb_rd_data;
    trace_mem_we    = mem_wb_mem_we;
    trace_mem_addr  = mem_wb_mem_addr;
    trace_mem_wdata = mem_wb_mem_wdata;
  end
`endif

endmodule
