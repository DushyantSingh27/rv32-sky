// M-mode Zicsr control and status registers.
//
// SCOPE: this block HOLDS state and updates it on command. It does not decide
// when to trap - trap detection lives in the pipeline (M4) and arrives here as
// trap_valid plus cause/epc/tval. Interrupt pins are driven by the CLINT (M5);
// this block only latches and reports them.
//
// THREE SPEC RULES THAT CATCH PEOPLE:
//
// 1. Read suppression. CSRRW with rd==x0 must NOT read the CSR. Decoded in the
//    pipeline and arrives as csr_read.
// 2. Write suppression. CSRRS/CSRRC with rs1==x0 (or uimm==0 for the immediate
//    forms) must NOT write - not "write the unchanged value", but perform no
//    write at all. Arrives as csr_write.
// 3. Writes to read-only CSRs are ILLEGAL INSTRUCTIONS, not silent drops.
//    Address bits [11:10] == 2'b11 marks a CSR read-only.
//
// WARL (Write Any, Read Legal) fields: writes are accepted and discarded, reads
// return the legal value. Used for mtvec.MODE (reads 0, direct only),
// mepc[0] (reads 0, IALIGN=16 with the C extension), and mstatus.MPP
// (reads 2'b11, M-mode is the only legal value here).
module csr
  import rv32_pkg::*;
(
  input  logic            clk,
  input  logic            rst_n,

  // Access port from the pipeline
  input  logic [11:0]     csr_addr,
  input  csr_op_e         csr_op,
  input  logic [XLEN-1:0] csr_wdata,
  input  logic            csr_read,      // rd  != x0
  input  logic            csr_write,     // rs1 != x0, or uimm != 0
  output logic [XLEN-1:0] csr_rdata,
  output logic            csr_illegal,

  // Trap entry / return, driven by the pipeline
  input  logic            trap_valid,
  input  logic [XLEN-1:0] trap_epc,
  input  logic [XLEN-1:0] trap_cause,
  input  logic [XLEN-1:0] trap_tval,
  input  logic            mret,

  // Interrupt pins (CLINT, M5)
  input  logic            irq_timer,
  input  logic            irq_software,
  input  logic            irq_external,

  // To the pipeline
  output logic [XLEN-1:0] mtvec_o,
  output logic [XLEN-1:0] mepc_o,
  output logic            irq_pending,

  input  logic            instr_retired
);

  // trap_epc[0] is intentionally discarded: mepc bit 0 is WARL and reads back
  // zero under IALIGN=16 (the C extension permits 16-bit-aligned instructions,
  // so only bit 0 is forced, not bits [1:0]). Named explicitly rather than
  // suppressed with a lint pragma, so the discard is visible as a spec rule.
  logic trap_epc_lsb_unused;
  always_comb trap_epc_lsb_unused = trap_epc[0];

  // ---------------- storage ----------------
  logic            mstatus_mie_q,  mstatus_mpie_q;
  logic [XLEN-1:0] mie_q;
  logic [XLEN-1:0] mtvec_q;
  logic [XLEN-1:0] mscratch_q;
  logic [XLEN-1:0] mepc_q;
  logic [XLEN-1:0] mcause_q;
  logic [XLEN-1:0] mtval_q;
  logic [63:0]     mcycle_q;
  logic [63:0]     minstret_q;

  // mip is driven by pins, not stored.
  logic [XLEN-1:0] mip;
  always_comb begin
    mip = '0;
    mip[IRQ_SOFT_BIT]  = irq_software;
    mip[IRQ_TIMER_BIT] = irq_timer;
    mip[IRQ_EXT_BIT]   = irq_external;
  end

  logic [XLEN-1:0] mstatus;
  always_comb begin
    mstatus = '0;
    mstatus[MSTATUS_MIE_BIT]              = mstatus_mie_q;
    mstatus[MSTATUS_MPIE_BIT]             = mstatus_mpie_q;
    mstatus[MSTATUS_MPP_LSB +: 2]         = 2'b11;   // WARL: M-mode only
  end

  // ---------------- read ----------------
  logic            addr_valid;
  logic [XLEN-1:0] rdata;

  always_comb begin
    addr_valid = 1'b1;
    unique case (csr_addr)
      CSR_MSTATUS:   rdata = mstatus;
      CSR_MISA:      rdata = MISA_VALUE;
      CSR_MIE:       rdata = mie_q;
      CSR_MTVEC:     rdata = mtvec_q;
      CSR_MSTATUSH:  rdata = '0;
      CSR_MSCRATCH:  rdata = mscratch_q;
      CSR_MEPC:      rdata = mepc_q;
      CSR_MCAUSE:    rdata = mcause_q;
      CSR_MTVAL:     rdata = mtval_q;
      CSR_MIP:       rdata = mip;
      CSR_MCYCLE:    rdata = mcycle_q[31:0];
      CSR_MCYCLEH:   rdata = mcycle_q[63:32];
      CSR_MINSTRET:  rdata = minstret_q[31:0];
      CSR_MINSTRETH: rdata = minstret_q[63:32];
      CSR_MVENDORID,
      CSR_MARCHID,
      CSR_MIMPID,
      CSR_MHARTID:   rdata = '0;
      default: begin
        rdata      = '0;
        addr_valid = 1'b0;
      end
    endcase
  end

  always_comb csr_rdata = csr_read ? rdata : '0;

  // ---------------- write value ----------------
  logic [XLEN-1:0] wval;
  always_comb begin
    unique case (csr_op)
      CSR_RW:  wval = csr_wdata;
      CSR_RS:  wval = rdata |  csr_wdata;
      CSR_RC:  wval = rdata & ~csr_wdata;
      default: wval = rdata;
    endcase
  end

  // Address bits [11:10] == 2'b11 means read-only. Writing one is an illegal
  // instruction, not a silent drop.
  logic is_readonly, do_write;
  always_comb begin
    is_readonly = (csr_addr[11:10] == 2'b11);
    do_write    = csr_write && (csr_op != CSR_NONE) && addr_valid && !is_readonly;
    csr_illegal = (csr_op != CSR_NONE) &&
                  (!addr_valid || (csr_write && is_readonly));
  end

  // ---------------- update ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstatus_mie_q  <= 1'b0;
      mstatus_mpie_q <= 1'b0;
      mie_q          <= '0;
      mtvec_q        <= '0;
      mscratch_q     <= '0;
      mepc_q         <= '0;
      mcause_q       <= '0;
      mtval_q        <= '0;
      mcycle_q       <= 64'd0;
      minstret_q     <= 64'd0;
    end else begin
      mcycle_q <= mcycle_q + 64'd1;
      if (instr_retired) minstret_q <= minstret_q + 64'd1;

      // Trap entry takes priority over a software CSR write in the same cycle.
      if (trap_valid) begin
        mepc_q         <= {trap_epc[XLEN-1:1], 1'b0};   // WARL: bit 0 reads 0
        mcause_q       <= trap_cause;
        mtval_q        <= trap_tval;
        mstatus_mpie_q <= mstatus_mie_q;
        mstatus_mie_q  <= 1'b0;
      end else if (mret) begin
        mstatus_mie_q  <= mstatus_mpie_q;
        mstatus_mpie_q <= 1'b1;
      end else if (do_write) begin
        unique case (csr_addr)
          CSR_MSTATUS: begin
            mstatus_mie_q  <= wval[MSTATUS_MIE_BIT];
            mstatus_mpie_q <= wval[MSTATUS_MPIE_BIT];
            // MPP is WARL and discarded - M-mode is the only legal value.
          end
          CSR_MIE:       mie_q      <= wval;
          // mtvec MODE is WARL: writes accepted, reads back 0 (direct only).
          CSR_MTVEC:     mtvec_q    <= {wval[XLEN-1:2], 2'b00};
          CSR_MSCRATCH:  mscratch_q <= wval;
          // mepc bit 0 is WARL: reads back 0 (IALIGN=16 with C).
          CSR_MEPC:      mepc_q     <= {wval[XLEN-1:1], 1'b0};
          CSR_MCAUSE:    mcause_q   <= wval;
          CSR_MTVAL:     mtval_q    <= wval;
          CSR_MCYCLE:    mcycle_q[31:0]    <= wval;
          CSR_MCYCLEH:   mcycle_q[63:32]   <= wval;
          CSR_MINSTRET:  minstret_q[31:0]  <= wval;
          CSR_MINSTRETH: minstret_q[63:32] <= wval;
          default: ;   // misa, mstatush, mip and the info CSRs ignore writes
        endcase
      end
    end
  end

  always_comb begin
    mtvec_o     = mtvec_q;
    mepc_o      = mepc_q;
    irq_pending = mstatus_mie_q && |(mie_q & mip);
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  always_ff @(posedge clk) begin
    if (rst_n) begin
      assert (mepc_q[0] == 1'b0)
        else $error("csr: mepc bit 0 is not zero");
      assert (mtvec_q[1:0] == 2'b00)
        else $error("csr: mtvec MODE is not zero");
      assert (trap_epc_lsb_unused === trap_epc[0]);   // keeps the signal live
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
