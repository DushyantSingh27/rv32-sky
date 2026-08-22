// RV32I instruction decoder.
//
// SCOPE: RV32I only. RV32M decode is M4 (ADR-0003), which means the verified
// muldiv stays disconnected until then - a deliberate cost of scope discipline.
//
// Illegal instructions are DETECTED here but nothing consumes the flag until
// traps exist at M4. Detecting now avoids re-verifying the decoder later.
//
// x0 writes are NOT suppressed here. The register file discards them, verified
// across 25,097 transactions in env 3. One guard, in one place: mutation
// testing showed redundant guards can hide a missing one
// (docs/results/0011-mutation-testing.md).
module decoder
  import rv32_pkg::*;
(
  input  logic [31:0] instr,
  output ctrl_t       ctrl,
  output instr_fmt_e  fmt
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;

  always_comb begin
    opcode = instr[6:0];
    funct3 = instr[14:12];
    funct7 = instr[31:25];
  end

  // Shift instructions distinguish SRL from SRA by funct7 bit 5. For the
  // immediate forms, funct7 doubles as the upper shift-amount bits, and RV32
  // requires bits [31:26] to be zero - a non-zero value is illegal.
  logic arith_shift, shamt_valid;
  always_comb begin
    arith_shift = funct7[5];
    shamt_valid = (funct7[6] == 1'b0) && (funct7[4:0] == 5'b0);
  end

  always_comb begin
    // Safe defaults. Every field is assigned on every path - no latches.
    ctrl = '{
      rs1_addr:      instr[19:15],
      rs2_addr:      instr[24:20],
      rd_addr:       instr[11:7],
      rs1_used:      1'b0,
      rs2_used:      1'b0,
      alu_op:        ALU_ADD,
      branch_op:     BR_NONE,
      alu_src_a_pc:  1'b0,
      alu_src_b_imm: 1'b0,
      mem_read:      1'b0,
      mem_write:     1'b0,
      mem_size:      MEM_W,
      mem_signed:    1'b0,
      reg_write:     1'b0,
      wb_sel:        WB_ALU,
      is_branch:     1'b0,
      is_jal:        1'b0,
      is_jalr:       1'b0,
      csr_op:        CSR_NONE,
      csr_read:      1'b0,
      csr_write:     1'b0,
      csr_imm:       1'b0,
      is_ecall:      1'b0,
      is_ebreak:     1'b0,
      is_mret:       1'b0,
      illegal:       1'b0
    };
    fmt = FMT_NONE;

    unique case (opcode)

      // ---------------- register-register ----------------
      OP_OP: begin
        fmt           = FMT_R;
        ctrl.rs1_used = 1'b1;
        ctrl.rs2_used = 1'b1;
        ctrl.reg_write = 1'b1;
        unique case (funct3)
          3'b000: ctrl.alu_op = (funct7 == 7'b0100000) ? ALU_SUB : ALU_ADD;
          3'b001: ctrl.alu_op = ALU_SLL;
          3'b010: ctrl.alu_op = ALU_SLT;
          3'b011: ctrl.alu_op = ALU_SLTU;
          3'b100: ctrl.alu_op = ALU_XOR;
          3'b101: ctrl.alu_op = arith_shift ? ALU_SRA : ALU_SRL;
          3'b110: ctrl.alu_op = ALU_OR;
          3'b111: ctrl.alu_op = ALU_AND;
          default: ctrl.illegal = 1'b1;
        endcase
        // funct7 must be 0000000, or 0100000 for SUB and SRA only.
        if (!((funct7 == 7'b0000000) ||
              (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101))))
          ctrl.illegal = 1'b1;
      end

      // ---------------- register-immediate ----------------
      OP_OPIMM: begin
        fmt               = FMT_I;
        ctrl.rs1_used     = 1'b1;
        ctrl.alu_src_b_imm = 1'b1;
        ctrl.reg_write    = 1'b1;
        unique case (funct3)
          3'b000: ctrl.alu_op = ALU_ADD;   // ADDI
          3'b010: ctrl.alu_op = ALU_SLT;   // SLTI
          3'b011: ctrl.alu_op = ALU_SLTU;  // SLTIU
          3'b100: ctrl.alu_op = ALU_XOR;   // XORI
          3'b110: ctrl.alu_op = ALU_OR;    // ORI
          3'b111: ctrl.alu_op = ALU_AND;   // ANDI
          3'b001: begin                    // SLLI
            ctrl.alu_op = ALU_SLL;
            if (funct7 != 7'b0000000) ctrl.illegal = 1'b1;
          end
          3'b101: begin                    // SRLI / SRAI
            ctrl.alu_op = arith_shift ? ALU_SRA : ALU_SRL;
            if (!shamt_valid) ctrl.illegal = 1'b1;
          end
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // ---------------- upper immediate ----------------
      OP_LUI: begin
        fmt                = FMT_U;
        ctrl.alu_op        = ALU_PASS_B;
        ctrl.alu_src_b_imm = 1'b1;
        ctrl.reg_write     = 1'b1;
      end

      OP_AUIPC: begin
        fmt                = FMT_U;
        ctrl.alu_op        = ALU_ADD;
        ctrl.alu_src_a_pc  = 1'b1;
        ctrl.alu_src_b_imm = 1'b1;
        ctrl.reg_write     = 1'b1;
      end

      // ---------------- jumps ----------------
      // Target is computed in the IF stage; the ALU produces the LINK value.
      OP_JAL: begin
        fmt            = FMT_J;
        ctrl.is_jal    = 1'b1;
        ctrl.reg_write = 1'b1;
        ctrl.wb_sel    = WB_PC4;
      end

      OP_JALR: begin
        fmt                = FMT_I;
        ctrl.rs1_used      = 1'b1;
        ctrl.alu_src_b_imm = 1'b1;
        ctrl.is_jalr       = 1'b1;
        ctrl.reg_write     = 1'b1;
        ctrl.wb_sel        = WB_PC4;
        if (funct3 != 3'b000) ctrl.illegal = 1'b1;
      end

      // ---------------- branches ----------------
      OP_BRANCH: begin
        fmt           = FMT_B;
        ctrl.rs1_used = 1'b1;
        ctrl.rs2_used = 1'b1;
        ctrl.is_branch = 1'b1;
        unique case (funct3)
          3'b000:  ctrl.branch_op = BR_EQ;
          3'b001:  ctrl.branch_op = BR_NE;
          3'b100:  ctrl.branch_op = BR_LT;
          3'b101:  ctrl.branch_op = BR_GE;
          3'b110:  ctrl.branch_op = BR_LTU;
          3'b111:  ctrl.branch_op = BR_GEU;
          default: ctrl.illegal   = 1'b1;   // funct3 010 and 011 are unused
        endcase
      end

      // ---------------- loads ----------------
      OP_LOAD: begin
        fmt                = FMT_I;
        ctrl.rs1_used      = 1'b1;
        ctrl.alu_op        = ALU_ADD;      // address = rs1 + imm
        ctrl.alu_src_b_imm = 1'b1;
        ctrl.mem_read      = 1'b1;
        ctrl.reg_write     = 1'b1;
        ctrl.wb_sel        = WB_MEM;
        unique case (funct3)
          3'b000: begin ctrl.mem_size = MEM_B; ctrl.mem_signed = 1'b1; end  // LB
          3'b001: begin ctrl.mem_size = MEM_H; ctrl.mem_signed = 1'b1; end  // LH
          3'b010: begin ctrl.mem_size = MEM_W; ctrl.mem_signed = 1'b1; end  // LW
          3'b100: begin ctrl.mem_size = MEM_B; ctrl.mem_signed = 1'b0; end  // LBU
          3'b101: begin ctrl.mem_size = MEM_H; ctrl.mem_signed = 1'b0; end  // LHU
          default: ctrl.illegal = 1'b1;
        endcase
      end

      // ---------------- stores ----------------
      OP_STORE: begin
        fmt                = FMT_S;
        ctrl.rs1_used      = 1'b1;
        ctrl.rs2_used      = 1'b1;         // rs2 is the store DATA
        ctrl.alu_op        = ALU_ADD;
        ctrl.alu_src_b_imm = 1'b1;
        ctrl.mem_write     = 1'b1;
        unique case (funct3)
          3'b000:  ctrl.mem_size = MEM_B;
          3'b001:  ctrl.mem_size = MEM_H;
          3'b010:  ctrl.mem_size = MEM_W;
          default: ctrl.illegal  = 1'b1;
        endcase
      end

      // ---------------- FENCE ----------------
      // Decoded as a legal no-op. This core is single-hart, in-order and has
      // no store buffer, so ordering is already sequentially consistent.
      OP_MISCMEM: begin
        fmt = FMT_I;
        if (funct3 != 3'b000 && funct3 != 3'b001) ctrl.illegal = 1'b1;
      end

      // ---------------- SYSTEM ----------------
      // Zicsr plus the M-mode privileged instructions.
      //
      // READ AND WRITE SUPPRESSION ARE ASYMMETRIC. This is the trap:
      //   CSRRW  / CSRRWI      - read only when rd != x0, write ALWAYS
      //   CSRRS/C / CSRRSI/CI  - read always, write only when rs1/uimm != 0
      // csr.sv:33 documents csr_write as "rs1 != x0, or uimm != 0" for every
      // form. That rule silently breaks `csrw mscratch, x0` - the idiomatic
      // CSR-zeroing sequence, which assembles to csrrw x0, mscratch, x0 and
      // must write. Correct and wrong implementations agree on every CSR write
      // with a non-x0 source, so a test set without an x0 source cannot see it.
      //
      // csr_read is (rd != x0) for ALL six forms, stricter than the spec for
      // the S/C forms. Stated explicitly rather than left implicit: csr_rdata
      // feeds rd only (csr.sv:124) and the read-modify-write value uses the
      // internal rdata (csr.sv:131), so suppressing the delivered read when
      // rd==x0 is behaviourally identical. Holds only while no CSR in the file
      // has a read side effect. None currently does.
      OP_SYSTEM: begin
        fmt = FMT_I;                       // imm[11:0] carries the CSR address

        unique case (funct3)
          3'b000: begin                    // ECALL / EBREAK / MRET
            // All three require rs1 = x0 and rd = x0. The previous decode
            // checked only instr[31:20] and accepted `ecall` with garbage in
            // either field as legal; Sail traps on those.
            if (instr[19:15] != 5'b0 || instr[11:7] != 5'b0) begin
              ctrl.illegal = 1'b1;
            end else begin
              unique case (instr[31:20])
                12'h000: ctrl.is_ecall  = 1'b1;
                12'h001: ctrl.is_ebreak = 1'b1;
                12'h302: ctrl.is_mret   = 1'b1;
                default: ctrl.illegal   = 1'b1;   // WFI, SRET: M4/M5
              endcase
            end
          end

          3'b100: ctrl.illegal = 1'b1;     // reserved

          default: begin                   // the six CSR forms
            ctrl.csr_imm   = funct3[2];    // 101 / 110 / 111
            // rs1_used must be 0 for the immediate forms: instr[19:15] is a
            // uimm there, not a register number. Setting it would make the
            // hazard unit forward a producer's result into an immediate field.
            ctrl.rs1_used  = ~funct3[2];
            ctrl.reg_write = 1'b1;         // rd == x0 is discarded by the regfile
            ctrl.wb_sel    = WB_ALU;       // EX result mux supplies csr_rdata
            unique case (funct3[1:0])
              2'b01:   ctrl.csr_op = CSR_RW;
              2'b10:   ctrl.csr_op = CSR_RS;
              2'b11:   ctrl.csr_op = CSR_RC;
              default: ctrl.csr_op = CSR_NONE;   // unreachable
            endcase
            ctrl.csr_read  = (instr[11:7]  != 5'b0);
            ctrl.csr_write = (funct3[1:0] == 2'b01) || (instr[19:15] != 5'b0);
          end
        endcase
      end

      default: ctrl.illegal = 1'b1;
    endcase
  end

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(instr)) begin
      // Every RV32I opcode ends in 2'b11. Anything else is a 16-bit
      // compressed instruction, which is M4.
      if (instr[1:0] != 2'b11)
        assert (ctrl.illegal)
          else $error("decoder: non-RV32I opcode not flagged illegal (0x%08h)", instr);
      // A branch or store never writes a register.
      if (ctrl.is_branch || ctrl.mem_write)
        assert (!ctrl.reg_write)
          else $error("decoder: reg_write asserted for a branch or store");
      // A CSR instruction always writes rd; a privileged one never does.
      if (ctrl.csr_op != CSR_NONE)
        assert (ctrl.reg_write && !ctrl.illegal)
          else $error("decoder: CSR op without reg_write, or flagged illegal");
      if (ctrl.is_ecall || ctrl.is_ebreak || ctrl.is_mret)
        assert (!ctrl.reg_write && ctrl.csr_op == CSR_NONE)
          else $error("decoder: privileged instruction writing a register or a CSR");
      // The immediate forms take no register operand.
      if (ctrl.csr_imm) assert (!ctrl.rs1_used)
        else $error("decoder: rs1_used set on a CSR immediate form");
    end
  end
`endif

endmodule
