// ALU environment: reference model, scoreboard, coverage collector, env.
package alu_env_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  import alu_agent_pkg::*;
  `include "uvm_macros.svh"

  // ==================================================================
  // REFERENCE MODEL
  //
  // Written from the RISC-V Unprivileged ISA specification, NOT from
  // rtl/core/alu.sv. This is the single most important discipline rule
  // in scoreboard construction: a predictor derived from the DUT
  // inherits the DUT's bugs and will happily agree with broken hardware.
  //
  // Spec points encoded here:
  //  - Shift amounts use the low 5 bits of the operand only (RV32).
  //  - SLT is a signed comparison; SLTU is unsigned.
  //  - SRA sign-extends; SRL does not.
  // ==================================================================
  function automatic logic [XLEN-1:0] alu_ref_result(alu_op_e op,
                                                     logic [XLEN-1:0] a,
                                                     logic [XLEN-1:0] b);
    logic [4:0] shamt = b[4:0];
    case (op)
      ALU_ADD:    return a + b;
      ALU_SUB:    return a - b;
      ALU_SLL:    return a << shamt;
      ALU_SRL:    return a >> shamt;
      ALU_SRA:    return $unsigned($signed(a) >>> shamt);
      ALU_SLT:    return {31'b0, ($signed(a) < $signed(b))};
      ALU_SLTU:   return {31'b0, (a < b)};
      ALU_XOR:    return a ^ b;
      ALU_OR:     return a | b;
      ALU_AND:    return a & b;
      ALU_PASS_B: return b;
      default:    return '0;
    endcase
  endfunction

  function automatic logic alu_ref_branch(branch_op_e branch_op,
                                          logic [XLEN-1:0] a,
                                          logic [XLEN-1:0] b);
    case (branch_op)
      BR_NONE: return 1'b0;
      BR_EQ:   return (a == b);
      BR_NE:   return (a != b);
      BR_LT:   return ($signed(a) <  $signed(b));
      BR_GE:   return ($signed(a) >= $signed(b));
      BR_LTU:  return (a <  b);
      BR_GEU:  return (a >= b);
      default: return 1'b0;
    endcase
  endfunction

  // ==================================================================
  // SCOREBOARD
  // ==================================================================
  class alu_scoreboard extends uvm_subscriber #(alu_seq_item);
    `uvm_component_utils(alu_scoreboard)

    int unsigned n_checked;
    int unsigned n_mismatch;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void write(alu_seq_item t);
      logic [XLEN-1:0] exp_result;
      logic            exp_branch;

      exp_result = alu_ref_result(t.op, t.a, t.b);
      exp_branch = alu_ref_branch(t.branch_op, t.a, t.b);
      n_checked++;

      if (t.result !== exp_result) begin
        n_mismatch++;
        `uvm_error("ALU_SCB",
          $sformatf("RESULT MISMATCH op=%s a=0x%08h b=0x%08h : expected 0x%08h, got 0x%08h",
                    t.op.name(), t.a, t.b, exp_result, t.result))
      end

      if (t.branch_taken !== exp_branch) begin
        n_mismatch++;
        `uvm_error("ALU_SCB",
          $sformatf("BRANCH MISMATCH branch_op=%s a=0x%08h b=0x%08h : expected %0b, got %0b",
                    t.branch_op.name(), t.a, t.b, exp_branch, t.branch_taken))
      end
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("ALU_SCB",
        $sformatf("checked %0d transactions, %0d mismatches", n_checked, n_mismatch),
        UVM_LOW)
      if (n_checked == 0)
        `uvm_error("ALU_SCB", "scoreboard saw zero transactions - testbench is not connected")
    endfunction
  endclass

  // ==================================================================
  // COVERAGE COLLECTOR
  // ==================================================================
  class alu_coverage extends uvm_subscriber #(alu_seq_item);
    `uvm_component_utils(alu_coverage)

    alu_op_e         cg_op;
    branch_op_e      cg_branch_op;
    opnd_class_e     cg_a_class, cg_b_class;
    logic [XLEN-1:0] cg_a, cg_b, cg_result;

    covergroup cg_alu;
      option.per_instance = 1;

      cp_op: coverpoint cg_op {
        bins ops[] = {ALU_ADD, ALU_SUB, ALU_SLL, ALU_SRL, ALU_SRA,
                      ALU_SLT, ALU_SLTU, ALU_XOR, ALU_OR, ALU_AND, ALU_PASS_B};
      }

      cp_branch_op: coverpoint cg_branch_op {
        bins brs[] = {BR_NONE, BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU};
      }

      cp_a_class: coverpoint cg_a_class;
      cp_b_class: coverpoint cg_b_class;

      // The shift-amount truncation trap: RV32 uses b[4:0] only, so a
      // shift by 33 must behave as a shift by 1, not 33 and not 0.
      cp_shamt: coverpoint cg_b[4:0] iff (cg_op inside {ALU_SLL, ALU_SRL, ALU_SRA}) {
        bins zero    = {0};
        bins one     = {1};
        bins mid[4]  = {[2:30]};
        bins max     = {31};
      }

      cp_b_ge_32: coverpoint (cg_b >= 32) iff (cg_op inside {ALU_SLL, ALU_SRL, ALU_SRA}) {
        bins in_range  = {0};
        bins truncated = {1};
      }

      cp_result_zero: coverpoint (cg_result == '0) {
        bins nonzero = {0};
        bins zero    = {1};
      }

      // The cross that catches signed/unsigned confusion. Only the
      // comparison and arithmetic ops are interesting here; bitwise
      // operations have no signedness, so they are excluded.
      x_op_operands: cross cp_op, cp_a_class, cp_b_class {
        ignore_bins not_signedness_sensitive =
          binsof(cp_op) intersect {ALU_XOR, ALU_OR, ALU_AND, ALU_PASS_B};
      }

      // branch_op is BR_NONE for every arithmetic instruction, so most of
      // this cross is unreachable by construction. Writing the ignore_bins
      // explicitly documents WHY the holes exist rather than leaving a
      // reader to wonder whether they are untested or impossible.
      x_op_branch: cross cp_op, cp_branch_op {
        ignore_bins arith_with_branch =
          binsof(cp_op) intersect {ALU_SLL, ALU_SRL, ALU_SRA, ALU_XOR,
                                   ALU_OR, ALU_AND, ALU_PASS_B} &&
          !binsof(cp_branch_op) intersect {BR_NONE};
      }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg_alu = new();
    endfunction

    function void write(alu_seq_item t);
      cg_op        = t.op;
      cg_branch_op = t.branch_op;
      cg_a_class   = t.a_class;
      cg_b_class   = t.b_class;
      cg_a         = t.a;
      cg_b         = t.b;
      cg_result    = t.result;
      cg_alu.sample();
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("ALU_COV",
        $sformatf("functional coverage = %0.2f%%", cg_alu.get_inst_coverage()), UVM_LOW)
    endfunction
  endclass

  // ==================================================================
  // ENVIRONMENT
  // ==================================================================
  class alu_env_cfg extends uvm_object;
    `uvm_object_utils(alu_env_cfg)
    alu_agent_cfg agent_cfg;

    function new(string name = "alu_env_cfg");
      super.new(name);
    endfunction
  endclass

  class alu_env extends uvm_env;
    `uvm_component_utils(alu_env)

    alu_env_cfg    cfg;
    alu_agent      agent;
    alu_scoreboard scb;
    alu_coverage   cov;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(alu_env_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("ALU_ENV", "alu_env_cfg not found in config db at this scope")

      uvm_config_db#(alu_agent_cfg)::set(this, "agent", "cfg", cfg.agent_cfg);

      agent = alu_agent::type_id::create("agent", this);
      scb   = alu_scoreboard::type_id::create("scb", this);
      cov   = alu_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.ap.connect(scb.analysis_export);
      agent.ap.connect(cov.analysis_export);
    endfunction
  endclass

endpackage
