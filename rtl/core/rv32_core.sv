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
  output logic            mem_misaligned_o,

  // CSR observation. Same rule as mem_misaligned_o above: detected but not yet
  // consumed, so routed to the boundary rather than suppressed with a lint
  // pragma. csr_illegal_o is a write to a read-only CSR or an access to an
  // unimplemented one - it becomes a trap cause at the next step. mtvec_o and
  // mepc_o are the redirect targets; irq_pending_o gates interrupt entry at
  // M5. All four stay as outputs afterwards, as testbench observation points.
  output logic            csr_illegal_o,
  output logic [XLEN-1:0] mtvec_o,
  output logic [XLEN-1:0] mepc_o,
  output logic            irq_pending_o

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
`ifdef RISCV_FORMAL
  ,
  // RISC-V Formal Interface (riscv-formal / SymbiYosys, M3.6).
  //
  // Absent unless RISCV_FORMAL is defined, so the synthesised path and every
  // existing harness compile the same core that Sail lockstep and ACT4
  // certified - the same discipline TCM_BYTES applies to the ACT4 memory size.
  // See docs/results/0026.
  output logic            rvfi_valid,
  output logic [63:0]     rvfi_order,
  output logic [31:0]     rvfi_insn,
  output logic            rvfi_trap,
  output logic            rvfi_halt,
  output logic            rvfi_intr,
  output logic [1:0]      rvfi_mode,
  output logic [1:0]      rvfi_ixl,
  output logic [4:0]      rvfi_rs1_addr,
  output logic [4:0]      rvfi_rs2_addr,
  output logic [XLEN-1:0] rvfi_rs1_rdata,
  output logic [XLEN-1:0] rvfi_rs2_rdata,
  output logic [4:0]      rvfi_rd_addr,
  output logic [XLEN-1:0] rvfi_rd_wdata,
  output logic [XLEN-1:0] rvfi_pc_rdata,
  output logic [XLEN-1:0] rvfi_pc_wdata,
  output logic [XLEN-1:0] rvfi_mem_addr,
  output logic [3:0]      rvfi_mem_rmask,
  output logic [3:0]      rvfi_mem_wmask,
  output logic [XLEN-1:0] rvfi_mem_rdata,
  output logic [XLEN-1:0] rvfi_mem_wdata
`endif
);

  // ================= pipeline registers =================
  if_id_t  if_id;
  id_ex_t  id_ex_q;
  ex_mem_t ex_mem_q;
  mem_wb_t mem_wb_q;

  // ---- forward declarations ----
  //
  // Six names, five declarations, all ASSIGNED further down beside the logic
  // that produces them. They are hoisted here because IEEE 1800-2017 does not
  // permit a reference to a module-scope variable before its declaration, and
  // slang enforces that.
  //
  // Both Verilator and Yosys tolerate the forward reference, which is why this
  // (phrased that way deliberately: a comment whose FIRST word is the name of
  // that simulator is parsed as a lint pragma, not prose - BADVLTPRAGMA,
  // measured 2026-09-27)
  // stood undetected for four milestones: rv32_core had never been read by
  // slang. The blocks hardened so far are the M0 counter, the ALU and the
  // register file - never the core - so the first time this file met the
  // standard 4.2 claims it is written in, it failed in eight places.
  //
  // NOT a formal-only fix. M6 reads the whole core through slang and would have
  // hit exactly these eight errors. Found by riscv-formal before a single check
  // had run. docs/results/0026.
  //
  // Each original declaration site keeps a marker comment pointing here, so the
  // explanation next to the logic is not lost.
  logic            stall;              // <- u_hazard produces, u_if consumes
  logic            ex_redirect_valid;  // <- EX redirect; u_if flush, id_ex_q clear
  logic            ex_trap_valid;      // <- EX trap encoder; u_csr consumes
  logic [XLEN-1:0] ex_trap_cause, ex_trap_tval;   // <- EX trap encoder; u_csr
  ctrl_t           ex_mem_ctrl_d;      // <- poisoned ctrl bundle; ex_mem_q

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
    // BOTH cycles of the redirect.
    //
    // ex_redirect_valid asserts while the branch is in EX; redirect_valid, its
    // registered form, reaches the PC one cycle LATER. In between, IF is still
    // fetching sequentially - so an instruction is latched into if_id during
    // the gap and flows through to retirement.
    //
    // Measured on t04 (docs/results/0015): at c20 exrv=1 squashes 0x4c; at c21
    // rv=1 redirects the PC but exrv has already dropped, and 0x54 is fetched;
    // at c22 if_id latches 0x54 with valid set. Squashing on either signal
    // covers both cycles.
    .flush          (ex_redirect_valid || redirect_valid),
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
  logic     fwd_id_rs1, fwd_id_rs2;   // stall: forward-declared above

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

  // RESET IS ASYNCHRONOUS; THE REDIRECT IS NOT.
  //
  // This block read `if (!rst_n || ex_redirect_valid)` from M3.2 until M3.6.
  // The sensitivity list promises two asynchronous events, posedge clk and
  // negedge rst_n; the reset branch then also fired on ex_redirect_valid,
  // which is in neither. That describes a flop with an asynchronous clear
  // driven by a signal the flop is not sensitive to, which is not hardware.
  //
  // Both Verilator and Yosys accepted it. slang rejects it outright:
  //   "condition cannot be matched to any signal from the event list"
  // Found by riscv-formal at M3.6, before a single check had run, and it
  // would have hit M6 hardening identically. docs/results/0026.
  //
  // Splitting the condition is BEHAVIOURALLY IDENTICAL - a redirect only ever
  // took effect at a clock edge - and now describes what the hardware is: one
  // async-reset flop with two synchronous clear terms.
  // PROJECT_INSTRUCTIONS 4.2, "async assert, sync deassert".
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      id_ex_q <= '0;
    end else if (ex_redirect_valid) begin
      // Squash the instruction arriving from ID behind a taken branch, a trap,
      // an mret or a fence.i. Synchronous, as it always effectively was.
      id_ex_q <= '0;
    end else if (stall) begin
      // Bubble into EX. IF and ID hold their contents; the load in EX advances
      // to MEM, where MEM->EX can supply it next cycle.
      id_ex_q <= '0;
    end else begin
      id_ex_q.valid    <= if_id.valid;
      id_ex_q.pc       <= if_id.pc;
      id_ex_q.instr    <= if_id.instr;
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

  // ---------------- CSR access, in EX ----------------
  //
  // WHY EX. Three properties of this pipeline, all read off the code below
  // rather than assumed:
  //   1. An instruction in EX is never squashed by an older one.
  //      ex_redirect_valid clears id_ex_q, which holds the instruction
  //      ARRIVING from ID - not the one executing. ex_mem_q is loaded
  //      unconditionally.
  //   2. A stalled instruction in EX advances anyway: `stall` writes '0 into
  //      id_ex_q, bubbling EX while IF/ID hold. So a CSR write executes
  //      EXACTLY ONCE - no double-write on a load-use interlock.
  //   3. Trap detection (next step) needs the EX-computed address, so the CSR
  //      write can be suppressed combinationally when the instruction traps.
  //
  // csr_addr is imm[11:0]. imm_gen runs on FMT_I for every SYSTEM encoding,
  // and sign extension does not disturb bits [11:0], so no ctrl_t field is
  // needed - see the note in rv32_pkg.sv.
  //
  // csr_write is gated on id_ex_q.valid. csr.sv has no valid input, and a '0
  // bubble happens to decode as CSR_NONE only because CSR_NONE is 2'b00.
  // Relying on that would silently break if the enum were reordered.
  logic [XLEN-1:0] ex_csr_wdata, ex_csr_rdata;

  always_comb begin
    // The immediate forms carry a 5-bit uimm in instr[19:15], which decode
    // placed in ctrl.rs1_addr. It is NOT a register number here - rs1_used is
    // 0 for these forms so the hazard unit never forwards into it.
    ex_csr_wdata = id_ex_q.ctrl.csr_imm ? {27'b0, id_ex_q.ctrl.rs1_addr}
                                        : ex_rs1_fwd;
  end

  csr u_csr (
    .clk           (clk),
    .rst_n         (rst_n),
    .csr_addr      (id_ex_q.imm[11:0]),
    .csr_op        (id_ex_q.ctrl.csr_op),
    .csr_wdata     (ex_csr_wdata),
    .csr_read      (id_ex_q.ctrl.csr_read),
    .csr_write     (id_ex_q.ctrl.csr_write && id_ex_q.valid),
    .csr_rdata     (ex_csr_rdata),
    .csr_illegal   (csr_illegal_o),
    // Trap entry, driven from the EX trap encoder below. mepc takes the PC of
    // the TRAPPING instruction, never PC+4 - measured six times against Sail
    // in sw/tests/probe_traps.S.
    .trap_valid    (ex_trap_valid),
    .trap_epc      (id_ex_q.pc),
    .trap_cause    (ex_trap_cause),
    .trap_tval     (ex_trap_tval),
    .mret          (id_ex_q.valid && id_ex_q.ctrl.is_mret && !ex_trap_valid),
    // No CLINT until M5.
    .irq_timer     (1'b0),
    .irq_software  (1'b0),
    .irq_external  (1'b0),
    .mtvec_o       (mtvec_o),
    .mepc_o        (mepc_o),
    .irq_pending   (irq_pending_o),
    .instr_retired (mem_wb_q.valid)
  );

  // A CSR read replaces the ALU result. Everything downstream - forwarding,
  // WB_ALU, the trace port - then works unchanged, because a CSR read becomes
  // indistinguishable from an ALU result.
  logic [XLEN-1:0] ex_result;
  always_comb begin
    ex_result = (id_ex_q.ctrl.csr_op != CSR_NONE) ? ex_csr_rdata
                                                  : ex_alu_result;
  end

  // Branch and jump targets. JALR masks bit 0 per the spec; JAL and branches
  // are PC-relative. The ALU produces the LINK value for jumps, not the
  // target - keeping it out of the branch-resolution path.
  // Branch and jump targets, computed combinationally in EX.
  logic [XLEN-1:0] ex_branch_target, ex_jalr_target;
  // ex_redirect_valid: forward-declared above
  logic [XLEN-1:0] ex_redirect_pc;

  // Synchronous trap detection, in EX. Causes and mtval values are MEASURED
  // against Sail, not assumed - sw/tests/probe_traps.S, docs/results/0018.
  logic            ex_taken_target_valid;
  logic [XLEN-1:0] ex_taken_target;
  // ex_trap_valid, ex_trap_cause, ex_trap_tval: forward-declared above
  logic            ex_ls_misaligned;

  always_comb begin
    ex_branch_target = id_ex_q.pc + id_ex_q.imm;
    // JALR reads rs1 for its target, so it needs the forwarded value.
    ex_jalr_target   = (ex_rs1_fwd + id_ex_q.imm) & ~32'd1;

    // The target this instruction WOULD redirect to, before any trap. Cause 0
    // is derived from it, so it is computed first and named explicitly rather
    // than depending on statement order within this block.
    ex_taken_target_valid = id_ex_q.valid &&
                            ((id_ex_q.ctrl.is_branch && ex_branch_taken) ||
                              id_ex_q.ctrl.is_jal || id_ex_q.ctrl.is_jalr);

    if      (id_ex_q.ctrl.is_jalr) ex_taken_target = ex_jalr_target;
    else                           ex_taken_target = ex_branch_target;

    // Misaligned data address, re-derived in EX from the ALU result. The MEM
    // stage computes the same condition from ex_mem_q via u_lsu; both call
    // is_misaligned() in rv32_pkg so the two can never drift apart.
    //
    // ex_alu_result, NOT ex_result: a load or store always has
    // csr_op == CSR_NONE so the two are equal here, but taking the pre-mux
    // value keeps the trap check off the CSR read path.
    ex_ls_misaligned = is_misaligned(ex_alu_result[1:0], id_ex_q.ctrl.mem_size);

    // TRAP PRIORITY, in RISC-V exception-priority order: fetch alignment
    // before decode, decode before execute, address faults last. An
    // instruction is never both a load and a store, so their relative order
    // is arbitrary.
    //
    // csr_illegal is gated on id_ex_q.valid HERE rather than inside csr.sv.
    // csr.sv has no valid input and computes it from csr_op != CSR_NONE,
    // which is only safe today because the whole id_ex_q struct is zeroed on
    // redirect. As a TRAP SOURCE it must be gated explicitly.
    ex_trap_valid = 1'b0;
    ex_trap_cause = '0;
    ex_trap_tval  = '0;

    if (id_ex_q.valid) begin
      if (ex_taken_target_valid && (ex_taken_target[1] != 1'b0)) begin
        ex_trap_valid = 1'b1;
        ex_trap_cause = 32'd0;                 // instruction address misaligned
        ex_trap_tval  = ex_taken_target;       // MEASURED: the target
      end else if (id_ex_q.ctrl.illegal || csr_illegal_o) begin
        ex_trap_valid = 1'b1;
        ex_trap_cause = 32'd2;                 // illegal instruction
        ex_trap_tval  = id_ex_q.instr;         // MEASURED: the instruction word
      end else if (id_ex_q.ctrl.is_ebreak) begin
        ex_trap_valid = 1'b1;
        ex_trap_cause = 32'd3;                 // breakpoint
        ex_trap_tval  = id_ex_q.pc;            // MEASURED: the PC
      end else if (id_ex_q.ctrl.is_ecall) begin
        ex_trap_valid = 1'b1;
        ex_trap_cause = 32'd11;                // environment call from M-mode
        ex_trap_tval  = '0;                    // MEASURED: zero
      end else if (id_ex_q.ctrl.mem_write && ex_ls_misaligned) begin
        ex_trap_valid = 1'b1;
        ex_trap_cause = 32'd6;                 // store address misaligned
        ex_trap_tval  = ex_alu_result;         // MEASURED: effective address
      end else if (id_ex_q.ctrl.mem_read && ex_ls_misaligned) begin
        ex_trap_valid = 1'b1;
        ex_trap_cause = 32'd4;                 // load address misaligned
        ex_trap_tval  = ex_alu_result;         // MEASURED: effective address
      end
    end

    // ONE redirect path, not two. A trap and a branch share the registered
    // redirect, the if_stage flush and the id_ex_q clear that M3.5 established
    // - a second, parallel redirect source is the exact shape of the bug that
    // took four wrong fixes to find.
    //
    // Trap outranks branch: a jump to a misaligned target traps INSTEAD of
    // jumping, so the priority is the semantics, not a tie-break.
    // mret redirects to mepc and is not a trap - it retires normally.
    ex_redirect_valid = ex_trap_valid ||
                        (id_ex_q.valid && id_ex_q.ctrl.is_mret) ||
                        (id_ex_q.valid && id_ex_q.ctrl.is_fencei) ||
                        ex_taken_target_valid;

    if      (ex_trap_valid)                             ex_redirect_pc = mtvec_o;
    else if (id_ex_q.valid && id_ex_q.ctrl.is_mret)     ex_redirect_pc = mepc_o;
    // fence.i re-fetches from PC+4. The preceding store is in MEM while
    // fence.i is in EX and writes on this cycle's posedge; the redirect is
    // registered, so the re-fetch reads the updated word. Mutually exclusive
    // with a taken branch, so its order relative to that line is unobservable.
    else if (id_ex_q.valid && id_ex_q.ctrl.is_fencei)   ex_redirect_pc = id_ex_q.pc + 32'd4;
    else                                                ex_redirect_pc = ex_taken_target;
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

`ifdef RISCV_FORMAL
  // ================= RVFI (formal only) =================
  //
  // THE SHADOW REGISTERS ARE ASSIGNED INSIDE THE EXISTING ex_mem_q AND
  // mem_wb_q always_ff BLOCKS, not in parallel blocks of their own. A parallel
  // block would need its own copies of the flush and stall conditions, and the
  // moment those drift RVFI describes a different pipeline than the one
  // running - every check would then fail in a way that looks like a core bug.
  // Riding the same always_ff makes identical control a structural property
  // rather than something to maintain.
  //
  // rvfi_valid is mem_wb_q.valid: the same commit point trace_valid uses, and
  // the one 800 instructions of Sail lockstep have already validated.

  // ---- EX-stage sources ----
  logic [XLEN-1:0] rvfi_ex_pc_wdata;
  logic            rvfi_ex_trap;      // causes 0/2/4/6 only - see below
  logic            rvfi_ex_anytrap;   // all six causes, drives rvfi_intr

  always_comb begin
    // The ACTUAL next PC. ex_redirect_pc already carries mtvec_o on a trap and
    // mepc_o on mret, so one mux covers branches, jumps, traps and returns.
    // Confirmed against nerv, which assigns rvfi_pc_wdata <= npc where npc is
    // csr_mtvec_value on a trap.
    rvfi_ex_pc_wdata = ex_redirect_valid ? ex_redirect_pc : (id_ex_q.pc + 32'd4);

    // rvfi_trap IS NARROWER THAN "this instruction trapped". The RVFI spec
    // defines it as: an instruction that cannot be decoded, a misaligned
    // access where PMAs disallow it, or a jump to a misaligned target - which
    // is causes 2, 4/6 and 0 here.
    //
    // ecall and ebreak are deliberately EXCLUDED. They execute correctly and
    // transfer control rather than violating anything, and nerv - riscv-formal's
    // own reference core - sets cycle_trap only for illegal instructions and
    // fetch faults.
    //
    // This exclusion is the part of the mapping most likely to be wrong, and
    // it is cheaply falsifiable: if a check complains about ecall or ebreak,
    // revisit rather than pre-solving it.
    rvfi_ex_trap = ex_trap_valid && (ex_trap_cause == 32'd0 ||
                                     ex_trap_cause == 32'd2 ||
                                     ex_trap_cause == 32'd4 ||
                                     ex_trap_cause == 32'd6);

    // rvfi_intr marks the FIRST instruction of a handler, so it must follow
    // ANY trap entry - including ecall and ebreak, which are excluded above.
    rvfi_ex_anytrap = ex_trap_valid;
  end

  // ---- shadow pipeline: EX -> MEM ----
  logic [31:0]     rvfi_m_insn;
  logic [XLEN-1:0] rvfi_m_pc_rdata, rvfi_m_pc_wdata;
  logic [4:0]      rvfi_m_rs1_addr, rvfi_m_rs2_addr;
  logic [XLEN-1:0] rvfi_m_rs1_rdata, rvfi_m_rs2_rdata;
  logic            rvfi_m_trap, rvfi_m_anytrap;

  // ---- shadow pipeline: MEM -> WB ----
  logic [31:0]     rvfi_w_insn;
  logic [XLEN-1:0] rvfi_w_pc_rdata, rvfi_w_pc_wdata;
  logic [4:0]      rvfi_w_rs1_addr, rvfi_w_rs2_addr;
  logic [XLEN-1:0] rvfi_w_rs1_rdata, rvfi_w_rs2_rdata;
  logic            rvfi_w_trap, rvfi_w_anytrap;
  logic [XLEN-1:0] rvfi_w_mem_addr, rvfi_w_mem_rdata, rvfi_w_mem_wdata;
  logic [3:0]      rvfi_w_mem_rmask, rvfi_w_mem_wmask;

  logic [63:0]     rvfi_order_q;
  logic            rvfi_intr_q;
`endif

  // FLUSH ON REDIRECT.
  //
  // The redirect is registered, so a taken branch has THREE instructions in
  // flight behind it. id_ex_q and if_id were flushed from the start; ex_mem_q
  // and mem_wb_q were not, so the third leaked through with `valid` still set.
  //
  // That is not cosmetic: wb_reg_we gates on mem_wb_q.valid, so a squashed
  // instruction's register write actually landed. It went unnoticed because in
  // these test programs the instruction behind a taken branch happened to
  // write a value that was legitimately rewritten moments later - a property
  // of the programs, not of the design.
  //
  // Found by Sail lockstep: the core's trace reported retirements Sail did not
  // have. No self-checking test could have caught it.
  // ex_mem_q is NOT flushed on ex_redirect_valid.
  //
  // ex_redirect_valid asserts while the BRANCH ITSELF is in EX. Clearing
  // ex_mem_q on it squashes the branch as it advances EX->MEM, so the branch
  // never retires - Sail lockstep showed the core's trace missing the branch
  // instruction entirely.
  //
  // The branch executed and must commit. Only the instructions BEHIND it are
  // speculative, and those are already handled: if_id and id_ex_q are cleared
  // on redirect, which covers the two instructions fetched after it.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_mem_q <= '0;
`ifdef RISCV_FORMAL
      // The shadow registers reset with the pipeline register they ride, for
      // the same reason they share its always_ff: identical control is a
      // structural property rather than one to maintain. Without this, slang
      // reports "asynchronous load value missing" for all nine, and the
      // opening cycles of every counterexample trace carry X on rvfi_*.
      rvfi_m_insn      <= '0;
      rvfi_m_pc_rdata  <= '0;
      rvfi_m_pc_wdata  <= '0;
      rvfi_m_rs1_addr  <= '0;
      rvfi_m_rs2_addr  <= '0;
      rvfi_m_rs1_rdata <= '0;
      rvfi_m_rs2_rdata <= '0;
      rvfi_m_trap      <= 1'b0;
      rvfi_m_anytrap   <= 1'b0;
`endif
    end else begin
      // POISONED, NOT SQUASHED, on a trap.
      //
      // MEASURED (probe_traps.S): Sail EMITS a trace record for the trapping
      // instruction - a PC with no register write. The misaligned lw at [48]
      // produces no `x6 <-` line; the jalr at [60] produces no `x8 <-`.
      //
      // So valid and pc are kept and the write-enables are cleared. Clearing
      // the whole struct would drop the record and leave the core's trace one
      // short per trap; leaving it alone would let the write land. Neither
      // matches the model.
      //
      // Suppressing mem_write here is what prevents a trapping store from
      // reaching the TCM: the memory request is combinational from ex_mem_q
      // and gated on ex_mem_q.valid && ctrl.mem_write.
      //
      // NOTE this is a control-bits-only bubble with valid still set - the
      // exact condition mutation A's csr_write valid-gate was kept as defence
      // against. A WAS re-run against it (2026-08-27) and still survives: the
      // poison is on ex_mem_q, the gate reads id_ex_q one stage upstream, so
      // this bubble cannot reach it. See docs/results/0018.
      ex_mem_q.valid      <= id_ex_q.valid;
      ex_mem_q.pc         <= id_ex_q.pc;
      ex_mem_q.ctrl       <= ex_mem_ctrl_d;
      ex_mem_q.alu_result <= ex_result;
      // Store data needs forwarding too. `sw x1, 0(x2)` immediately after a
      // write to x1 must store the NEW value, and rs2 here is the data, not
      // an ALU operand - so it takes the forwarded value directly.
      ex_mem_q.rs2_data   <= ex_rs2_fwd;
`ifdef RISCV_FORMAL
      // RVFI shadow registers - see the RVFI block above for why these ride
      // this always_ff rather than one of their own.
      rvfi_m_insn      <= id_ex_q.instr;
      rvfi_m_pc_rdata  <= id_ex_q.pc;
      rvfi_m_pc_wdata  <= rvfi_ex_pc_wdata;
      // RVFI permits an arbitrary rs address when the instruction reads no
      // source register, but if the address is NONZERO the rdata must be that
      // register's value. Zeroing the address when unused is the cheap side of
      // that trade - it removes any obligation for LUI, AUIPC and JAL.
      rvfi_m_rs1_addr  <= id_ex_q.ctrl.rs1_used ? id_ex_q.ctrl.rs1_addr : 5'd0;
      rvfi_m_rs2_addr  <= id_ex_q.ctrl.rs2_used ? id_ex_q.ctrl.rs2_addr : 5'd0;
      // POST-FORWARDING values, not the register-file reads. For an in-flight
      // producer the regfile has not been written yet, so the architecturally
      // correct value at read time is the forwarded one. Sampling id_rs1_data
      // instead would fail rvfi_reg_check on every back-to-back dependency -
      // and would look like a forwarding bug in logic that 800 instructions of
      // lockstep and seven M3.3 mutations already cover.
      //
      // GATED ON THE REPORTED ADDRESS, not merely on rs*_used. The checker
      // asserts, at rvfi_insn_check.sv:163-167,
      //     if (rs1_addr == 0) assert(rs1_rdata == 0);
      //     if (rs2_addr == 0) assert(rs2_rdata == 0);
      // so zeroing the ADDRESS above while reporting the data unconditionally
      // is self-contradictory: for an I-type, instr[24:20] is immediate bits,
      // so the rs2 read path carries a value belonging to no register, and it
      // was being reported as the contents of x0.
      //
      // The nonzero test also covers a genuine x0 read, where the
      // architectural value is 0 whatever the forwarding network produces.
      //
      // MEASURED 2026-09-27: 19 of 45 checks failed on exactly these two
      // assertions - every instruction that does not read rs2, plus lui,
      // auipc and jal which read neither. docs/results/0026.
      rvfi_m_rs1_rdata <= (id_ex_q.ctrl.rs1_used &&
                           id_ex_q.ctrl.rs1_addr != 5'd0) ? ex_rs1_fwd : '0;
      rvfi_m_rs2_rdata <= (id_ex_q.ctrl.rs2_used &&
                           id_ex_q.ctrl.rs2_addr != 5'd0) ? ex_rs2_fwd : '0;
      rvfi_m_trap      <= rvfi_ex_trap;
      rvfi_m_anytrap   <= rvfi_ex_anytrap;
`endif
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

  // The control bundle entering MEM, with the poison applied.
  //
  // The suppression lives in a combinational block rather than as trailing
  // overrides inside the always_ff. Both infer the same hardware - a mux
  // feeding a flop - but here the priority is a property of the code rather
  // than of statement order, per PROJECT_INSTRUCTIONS 4.2.
  // ex_mem_ctrl_d: forward-declared above
  always_comb begin
    ex_mem_ctrl_d = id_ex_q.ctrl;
    if (ex_trap_valid) begin
      ex_mem_ctrl_d.reg_write = 1'b0;
      ex_mem_ctrl_d.mem_read  = 1'b0;
      ex_mem_ctrl_d.mem_write = 1'b0;
    end
  end

  // mem_wb_q is NOT flushed on redirect. An instruction that has reached
  // MEM/WB executed BEFORE the branch and has already committed
  // architecturally - a branch cannot unwind it.
  //
  // Flushing it here was tried and reverted: it destroyed the loop counter's
  // decrement before the next iteration could forward it, so `bne x9, x0` in
  // t04 never saw x9 reach zero and the program spun for 10,000 cycles.
  // mem_wb_q also feeds WB->ID forwarding, which the read-first register file
  // makes mandatory.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_wb_q <= '0;
`ifdef RISCV_FORMAL
      rvfi_w_insn      <= '0;
      rvfi_w_pc_rdata  <= '0;
      rvfi_w_pc_wdata  <= '0;
      rvfi_w_rs1_addr  <= '0;
      rvfi_w_rs2_addr  <= '0;
      rvfi_w_rs1_rdata <= '0;
      rvfi_w_rs2_rdata <= '0;
      rvfi_w_trap      <= 1'b0;
      rvfi_w_anytrap   <= 1'b0;
      rvfi_w_mem_addr  <= '0;
      rvfi_w_mem_rdata <= '0;
      rvfi_w_mem_wdata <= '0;
      rvfi_w_mem_rmask <= 4'd0;
      rvfi_w_mem_wmask <= 4'd0;
`endif
    end else begin
      mem_wb_q.valid      <= ex_mem_q.valid;
      mem_wb_q.ctrl       <= ex_mem_q.ctrl;
      mem_wb_q.alu_result <= ex_mem_q.alu_result;
      mem_wb_q.mem_data   <= mem_load_data;
      mem_wb_q.pc_plus4   <= ex_mem_q.pc + 32'd4;
`ifdef RISCV_FORMAL
      rvfi_w_insn      <= rvfi_m_insn;
      rvfi_w_pc_rdata  <= rvfi_m_pc_rdata;
      rvfi_w_pc_wdata  <= rvfi_m_pc_wdata;
      rvfi_w_rs1_addr  <= rvfi_m_rs1_addr;
      rvfi_w_rs2_addr  <= rvfi_m_rs2_addr;
      rvfi_w_rs1_rdata <= rvfi_m_rs1_rdata;
      rvfi_w_rs2_rdata <= rvfi_m_rs2_rdata;
      rvfi_w_trap      <= rvfi_m_trap;
      rvfi_w_anytrap   <= rvfi_m_anytrap;

      // MEM-stage memory signals, captured as they cross into WB.
      // mem_byte_en serves BOTH directions (lsu.sv:47-50), so it is gated by
      // the access type rather than duplicated. Both masks are zero when there
      // is no access, which RVFI requires.
      // WORD-ALIGNED, not the byte address. riscv-formal's spec modules under
      // RISCV_FORMAL_ALIGNED_MEM compute
      //     spec_mem_addr  = addr & ~3
      //     spec_mem_rmask = mask << (addr - spec_mem_addr)
      // so the mask is positioned RELATIVE to rvfi_mem_addr. mem_byte_en is
      // already word-relative, so reporting the byte address here would have
      // disagreed with it for every halfword and byte access.
      //
      // Read out of insns/insn_lh.v before the first check ran. lh at offset 2
      // is the case where the byte and word readings diverge - insn_lw would
      // have passed under either and proved nothing. Failure mode #1.
      //
      // ex_mem_q.valid is in the gate so this matches rmask/wmask below. A
      // nonzero address with both masks zero is a contradiction, and it would
      // surface as a confusing counterexample rather than an obvious one.
      rvfi_w_mem_addr  <= (ex_mem_q.valid &&
                           (ex_mem_q.ctrl.mem_read || ex_mem_q.ctrl.mem_write))
                            ? {ex_mem_q.alu_result[XLEN-1:2], 2'b00} : '0;
      rvfi_w_mem_rmask <= (ex_mem_q.valid && ex_mem_q.ctrl.mem_read)
                            ? mem_byte_en : 4'd0;
      rvfi_w_mem_wmask <= (ex_mem_q.valid && ex_mem_q.ctrl.mem_write)
                            ? mem_byte_en : 4'd0;
      // Raw bus data, matching nerv (rvfi_mem_rdata <= dmem_rdata) rather than
      // the sign-extended load result that reaches the register file.
      rvfi_w_mem_rdata <= dmem_rdata;
      rvfi_w_mem_wdata <= mem_store_aligned;
`endif
    end
  end

`ifdef RISCV_FORMAL
  // ---- retirement counter and handler-entry flag ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rvfi_order_q <= 64'd0;
      rvfi_intr_q  <= 1'b0;
    end else begin
      // rvfi_order must be contiguous - no gaps, no index reused. One
      // increment per retirement.
      if (mem_wb_q.valid) rvfi_order_q <= rvfi_order_q + 64'd1;

      // rvfi_intr marks the first instruction of a handler. Setting it at the
      // retirement of a trapping instruction means the NEXT retirement carries
      // it: the same retirement-indexed delay nerv implements through
      // next_rvfi_intr, rather than a cycle-based one.
      if (mem_wb_q.valid) rvfi_intr_q <= rvfi_w_anytrap;
    end
  end

  always_comb begin
    rvfi_valid     = mem_wb_q.valid;
    rvfi_order     = rvfi_order_q;
    rvfi_insn      = rvfi_w_insn;
    rvfi_trap      = rvfi_w_trap;
    // rvfi_halt and rvfi_mode are CONSTANTS in this core, and riscv-formal
    // has no way to know that - checks.cfg sees two ordinary signals. Named
    // here so a later reader does not take them for live logic: halt is 0
    // because there is no halt state (no debug module, and wfi is a no-op -
    // 0025), and mode is 3 because M is the only privilege mode (D1,
    // ADR-0003). At M5, if S/U land, mode must track the CURRENT privilege
    // mode and stops being a constant. A comment naming the milestone rather
    // than a parameter for hardware that does not exist - same treatment as
    // mstatus.TW in 0025.
    rvfi_halt      = 1'b0;
    rvfi_intr      = rvfi_intr_q;
    rvfi_mode      = 2'd3;
    rvfi_ixl       = 2'd1;              // XLEN = 32
    rvfi_rs1_addr  = rvfi_w_rs1_addr;
    rvfi_rs2_addr  = rvfi_w_rs2_addr;
    rvfi_rs1_rdata = rvfi_w_rs1_rdata;
    rvfi_rs2_rdata = rvfi_w_rs2_rdata;
    // Report no write at all when none lands. Covers x0 and, more importantly,
    // a trapping instruction whose write was suppressed by the ex_mem_q poison
    // - it retires (Sail emits a record for it) but must show no register
    // write. See docs/results/0018.
    rvfi_rd_addr   = wb_reg_we ? wb_rd_addr : 5'd0;
    rvfi_rd_wdata  = (wb_reg_we && wb_rd_addr != 5'd0) ? wb_rd_data : '0;
    rvfi_pc_rdata  = rvfi_w_pc_rdata;
    rvfi_pc_wdata  = rvfi_w_pc_wdata;
    rvfi_mem_addr  = rvfi_w_mem_addr;
    rvfi_mem_rmask = rvfi_w_mem_rmask;
    rvfi_mem_wmask = rvfi_w_mem_wmask;
    rvfi_mem_rdata = rvfi_w_mem_rdata;
    rvfi_mem_wdata = rvfi_w_mem_wdata;
  end
`endif

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
