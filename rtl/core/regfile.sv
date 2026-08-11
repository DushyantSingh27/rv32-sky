// RV32I register file: 32 x 32-bit, 2 read ports, 1 write port.
//
// Three behaviours the RISC-V spec and this project's decisions pin down:
//
// 1. x0 IS HARDWIRED TO ZERO. Not "initialised to zero" - physically incapable
//    of holding anything else. Reads of x0 return zero; writes to x0 are
//    discarded. `addi x0, x0, 5` is a legal, architecturally-defined no-op and
//    compilers emit it deliberately.
//
// 2. READ-FIRST on a read/write collision. If a read port and the write port
//    target the same register in the same cycle, the read returns the OLD
//    value - the pre-write contents. There is no internal bypass.
//
//    Rationale: PROJECT_CONTEXT 3.2 already commits to full forwarding
//    (EX->EX, MEM->EX) plus a load-use interlock, so a forwarding network must
//    exist regardless. Adding WB->ID bypass inside the register file would
//    duplicate that mechanism in a second place - two things to verify, two
//    places a bug can hide. Keeping the register file dumb puts all hazard
//    resolution in one auditable module.
//
//    It also survives Decision D4: if the register file later becomes an ORRAM
//    macro instead of flip-flops, a compiled memory gives whatever
//    read-during-write behaviour it gives. A design already assuming read-first
//    survives the swap; one depending on internal bypass would need rework.
//
// 3. ALL REGISTERS RESET TO ZERO. Real CPUs generally do not reset the register
//    file - it costs 1024 reset connections for no architectural benefit, since
//    software must initialise registers anyway. Reset here is a deliberate
//    simulation-hygiene choice: undefined registers make X propagation easy,
//    and X debugging has already cost this project one cycle (see
//    docs/results/0005). Revisit at M7 if the area matters.
module regfile
  import rv32_pkg::*;
(
  input  logic            clk,
  input  logic            rst_n,

  // Read ports - combinational
  input  logic [4:0]      rs1_addr,
  output logic [XLEN-1:0] rs1_data,
  input  logic [4:0]      rs2_addr,
  output logic [XLEN-1:0] rs2_data,

  // Write port - synchronous
  input  logic [4:0]      rd_addr,
  input  logic [XLEN-1:0] rd_data,
  input  logic            rd_we
);

  // Registers 1..31. Index 0 is not stored - x0 is handled in the read mux,
  // so no flops are spent on a register that can only ever be zero.
  logic [XLEN-1:0] regs [1:32-1];

  // Write is suppressed for x0. Doing this at the write enable rather than
  // only at the read mux matters: a design that stores to entry 0 and masks it
  // on read looks correct until something reaches that entry another way.
  logic write_en;
  always_comb write_en = rd_we && (rd_addr != 5'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 1; i < 32; i++) regs[i] <= '0;
    end else if (write_en) begin
      regs[rd_addr] <= rd_data;
    end
  end

  // Read-first: these read the flop outputs directly, with no bypass from the
  // write port. A read colliding with a write to the same address returns the
  // pre-write value.
  always_comb rs1_data = (rs1_addr == 5'd0) ? '0 : regs[rs1_addr];
  always_comb rs2_data = (rs2_addr == 5'd0) ? '0 : regs[rs2_addr];

`ifndef SYNTHESIS
  // Immediate assertions only - no SVA in rtl/ (PROJECT_INSTRUCTIONS 4.1).
  //
  // SYNCASYNCNET suppressed for this block only. rst_n is asynchronous in the
  // design flops above; here it is read synchronously purely to hold the
  // assertions off during reset. That read is inside `ifndef SYNTHESIS and
  // never becomes hardware. The suppression stays narrow - the real version of
  // this warning (a reset genuinely async in one flop and sync in another) is
  // worth catching.
  /* verilator lint_off SYNCASYNCNET */
  always_ff @(posedge clk) begin
    if (rst_n) begin
      assert (!(rd_we && (rd_addr == 5'd0)) || (rs1_data == '0 || rs1_addr != 5'd0))
        else $error("regfile: x0 write leaked into a read");
      if (rs1_addr == 5'd0)
        assert (rs1_data == '0) else $error("regfile: x0 read returned non-zero on rs1");
      if (rs2_addr == 5'd0)
        assert (rs2_data == '0) else $error("regfile: x0 read returned non-zero on rs2");
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
