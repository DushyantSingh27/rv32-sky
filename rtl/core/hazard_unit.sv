// Forwarding and interlock control.
//
// THREE FORWARDING PATHS, and WB->ID is MANDATORY here rather than optional.
//
// The register file is read-first: a read colliding with a write to the same
// address returns the PRE-WRITE value, verified across 6,009 collisions in
// UVM env 3 (docs/results/0008). The register file is read in ID and written
// in WB, so without WB->ID forwarding a value written in WB is invisible to an
// instruction reading in ID in the same cycle - and programs silently compute
// wrong answers three instructions after every write.
//
// PRIORITY: EX->EX beats MEM->EX. Both may match the same register when two
// writes land close together; EX->EX carries the NEWER value. Getting this
// backwards produces a core that works until back-to-back writes to one
// register occur, which casual testing does not reach.
//
// x0 NEVER forwards. Writes to x0 are discarded by the register file, so
// forwarding one would make x0 briefly non-zero.
module hazard_unit
  import rv32_pkg::*;
(
  // Consumer: the instruction currently in EX
  input  logic [4:0] ex_rs1_addr,
  input  logic [4:0] ex_rs2_addr,
  input  logic       ex_rs1_used,
  input  logic       ex_rs2_used,

  // Producer in MEM (one ahead)
  input  logic [4:0] mem_rd_addr,
  input  logic       mem_reg_write,
  input  logic       mem_valid,

  // Producer in WB (two ahead)
  input  logic [4:0] wb_rd_addr,
  input  logic       wb_reg_write,
  input  logic       wb_valid,

  // Load in EX - its data is not available until MEM
  input  logic [4:0] ex_stage_rd_addr,
  input  logic       ex_stage_mem_read,
  input  logic       ex_stage_valid,

  // Consumer in ID, for the load-use check
  input  logic [4:0] id_rs1_addr,
  input  logic [4:0] id_rs2_addr,
  input  logic       id_rs1_used,
  input  logic       id_rs2_used,

  // ID-stage register read, for WB->ID forwarding
  input  logic [4:0] id_rf_rs1_addr,
  input  logic [4:0] id_rf_rs2_addr,

  output fwd_sel_e   fwd_a,
  output fwd_sel_e   fwd_b,
  output logic       fwd_id_rs1,
  output logic       fwd_id_rs2,
  output logic       stall
);

  logic mem_produces, wb_produces;
  always_comb begin
    mem_produces = mem_valid && mem_reg_write && (mem_rd_addr != 5'd0);
    wb_produces  = wb_valid  && wb_reg_write  && (wb_rd_addr  != 5'd0);
  end

  // EX operand forwarding. MEM first, then WB, so the LAST assignment wins -
  // no. Written as an explicit priority chain instead, so the ordering is
  // visible rather than depending on assignment order.
  always_comb begin
    if      (ex_rs1_used && mem_produces && (mem_rd_addr == ex_rs1_addr)) fwd_a = FWD_MEM;
    else if (ex_rs1_used && wb_produces  && (wb_rd_addr  == ex_rs1_addr)) fwd_a = FWD_WB;
    else                                                                 fwd_a = FWD_NONE;

    if      (ex_rs2_used && mem_produces && (mem_rd_addr == ex_rs2_addr)) fwd_b = FWD_MEM;
    else if (ex_rs2_used && wb_produces  && (wb_rd_addr  == ex_rs2_addr)) fwd_b = FWD_WB;
    else                                                                 fwd_b = FWD_NONE;
  end

  // WB->ID forwarding, forced by the read-first register file.
  always_comb begin
    fwd_id_rs1 = wb_produces && (wb_rd_addr == id_rf_rs1_addr);
    fwd_id_rs2 = wb_produces && (wb_rd_addr == id_rf_rs2_addr);
  end

  // LOAD-USE INTERLOCK.
  //
  // A load produces its data in MEM, but the next instruction needs it in EX -
  // one stage too early. No forwarding path moves data backwards in time, so
  // the only fix is a one-cycle stall: hold IF and ID, bubble EX, and let the
  // load reach MEM/WB where MEM->EX can supply it.
  always_comb begin
    stall = ex_stage_valid && ex_stage_mem_read && (ex_stage_rd_addr != 5'd0) &&
            ((id_rs1_used && (id_rs1_addr == ex_stage_rd_addr)) ||
             (id_rs2_used && (id_rs2_addr == ex_stage_rd_addr)));
  end

endmodule
