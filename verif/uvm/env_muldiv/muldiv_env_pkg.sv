// muldiv environment: reference model, scoreboard, coverage collector, env.
package muldiv_env_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  import muldiv_agent_pkg::*;
  `include "uvm_macros.svh"

  // ==================================================================
  // REFERENCE MODEL
  //
  // Written from the RISC-V unprivileged ISA specification, chapter "M"
  // Standard Extension. NOT derived from rtl/core/mul_unit.sv or div_unit.sv.
  //
  // The two tables the spec defines and most implementations get wrong:
  //
  //   Divide by zero (RISC-V does NOT trap - it returns defined values):
  //     DIV  -> -1        DIVU -> 2^32-1
  //     REM  -> dividend  REMU -> dividend
  //
  //   Signed overflow, -2^31 / -1 (result does not fit in 32 bits):
  //     DIV  -> -2^31     REM  -> 0
  //
  // Sign rule: the quotient takes the XOR of the operand signs; the remainder
  // takes the sign of the DIVIDEND. So -7 % 2 = -1 and 7 % -2 = +1.
  // SystemVerilog's signed / and % already truncate toward zero, which matches
  // RISC-V - but the special cases must be handled BEFORE reaching them.
  // ==================================================================
  function automatic logic [XLEN-1:0] muldiv_ref(muldiv_op_e op,
                                                 logic [XLEN-1:0] a,
                                                 logic [XLEN-1:0] b);
    logic signed [63:0] sa64, sb64;
    logic        [63:0] ua64, ub64;
    logic signed [63:0] prod_ss, prod_su;
    logic        [63:0] prod_uu;

    sa64 = $signed(a);              // sign-extended to 64
    sb64 = $signed(b);
    ua64 = {32'd0, a};              // zero-extended to 64
    ub64 = {32'd0, b};

    case (op)
      MD_MUL: begin
        prod_ss = sa64 * sb64;
        return prod_ss[31:0];       // low half is identical either way
      end
      MD_MULH: begin
        prod_ss = sa64 * sb64;
        return prod_ss[63:32];
      end
      MD_MULHSU: begin
        prod_su = sa64 * $signed(ub64);   // a signed, b unsigned
        return prod_su[63:32];
      end
      MD_MULHU: begin
        prod_uu = ua64 * ub64;
        return prod_uu[63:32];
      end

      MD_DIV: begin
        if (b == 32'd0)                                    return 32'hFFFF_FFFF;
        if (a == 32'h8000_0000 && b == 32'hFFFF_FFFF)      return 32'h8000_0000;
        return $signed(a) / $signed(b);
      end
      MD_DIVU: begin
        if (b == 32'd0)                                    return 32'hFFFF_FFFF;
        return a / b;
      end
      MD_REM: begin
        if (b == 32'd0)                                    return a;
        if (a == 32'h8000_0000 && b == 32'hFFFF_FFFF)      return 32'd0;
        return $signed(a) % $signed(b);
      end
      MD_REMU: begin
        if (b == 32'd0)                                    return a;
        return a % b;
      end

      default: return 32'd0;
    endcase
  endfunction

  // ==================================================================
  // SCOREBOARD
  // ==================================================================
  class muldiv_scoreboard extends uvm_subscriber #(muldiv_seq_item);
    `uvm_component_utils(muldiv_scoreboard)

    int unsigned n_checked;
    int unsigned n_mismatch;
    int unsigned min_latency = 32'hFFFF_FFFF;
    int unsigned max_latency;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void write(muldiv_seq_item t);
      logic [XLEN-1:0] exp;
      exp = muldiv_ref(t.op, t.a, t.b);
      n_checked++;

      if (t.compute_cycles < min_latency) min_latency = t.compute_cycles;
      if (t.compute_cycles > max_latency) max_latency = t.compute_cycles;

      if (t.result !== exp) begin
        n_mismatch++;
        `uvm_error("MD_SCB",
          $sformatf("MISMATCH op=%s a=0x%08h b=0x%08h : expected 0x%08h, got 0x%08h (latency=%0d)",
                    t.op.name(), t.a, t.b, exp, t.result, t.latency))
      end
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("MD_SCB",
        $sformatf("checked %0d transactions, %0d mismatches, compute cycles min=%0d max=%0d",
                  n_checked, n_mismatch, min_latency, max_latency), UVM_LOW)
      if (n_checked == 0)
        `uvm_error("MD_SCB", "scoreboard saw zero transactions - testbench not connected")
    endfunction
  endclass

  // ==================================================================
  // COVERAGE COLLECTOR
  // ==================================================================
  class muldiv_coverage extends uvm_subscriber #(muldiv_seq_item);
    `uvm_component_utils(muldiv_coverage)

    muldiv_op_e      cg_op;
    md_opnd_class_e  cg_a_class, cg_b_class;
    logic [XLEN-1:0] cg_a, cg_b;
    int unsigned     cg_latency;
    bit              cg_bp;
    bit              cg_is_div;

    covergroup cg_md;
      option.per_instance = 1;

      cp_op: coverpoint cg_op {
        bins ops[] = {MD_MUL, MD_MULH, MD_MULHSU, MD_MULHU,
                      MD_DIV, MD_DIVU, MD_REM,    MD_REMU};
      }

      cp_a_class: coverpoint cg_a_class;
      cp_b_class: coverpoint cg_b_class;

      // RISC-V defines exact results here rather than trapping.
      cp_divisor_zero: coverpoint (cg_b == 32'd0) iff (cg_is_div) {
        bins nonzero = {0};
        bins zero    = {1};
      }

      // -2^31 / -1: the only signed division that overflows 32 bits.
      cp_signed_overflow: coverpoint
        ((cg_a == 32'h8000_0000) && (cg_b == 32'hFFFF_FFFF))
        iff (cg_op inside {MD_DIV, MD_REM}) {
        bins normal   = {0};
        bins overflow = {1};
      }

      // Covered, not asserted. Asserting an exact cycle count would make the
      // environment brittle to any microarchitecture change - and the
      // multiplier may well change at M6 if area demands it.
      //
      // Samples compute_cycles (accept -> valid_o), NOT total latency.
      // Total latency includes testbench back-pressure, so a bin meant to
      // flag pathological behaviour would fire on normal operation.
      // Back-pressure has its own coverpoint.
      cp_latency: coverpoint cg_latency {
        bins immediate = {[1:5]};      // special-case early exit
        bins mul_range = {[6:20]};     // radix-4, ~17 cycles
        bins div_range = {[21:40]};    // restoring, ~33 cycles

        // illegal_bins, not bins or ignore_bins. This is an ERROR DETECTOR,
        // not a coverage target: nothing in the design should ever take more
        // than ~34 cycles, so the bin exists to fire if something hangs.
        //
        // As a plain bin it could never be filled without provoking a failure,
        // permanently capping coverage. ignore_bins would be wrong too - the
        // value is not impossible, just pathological. illegal_bins removes it
        // from the denominator AND raises a runtime error if it is ever hit.
        //
        // Distinction worth keeping: most bins answer "did we test this?"
        // (empty = untested). A few answer "did this go wrong?" (empty =
        // healthy). Mixing both kinds in one covergroup makes the percentage
        // meaningless.
        illegal_bins pathological = {[41:$]};
      }

      cp_backpressure: coverpoint cg_bp {
        bins none    = {0};
        bins applied = {1};
      }

      x_op_operands: cross cp_op, cp_a_class, cp_b_class;

      // Catches a divide finishing in multiply time, or vice versa.
      //
      // Half these cells are unreachable by construction, so they are ignored
      // explicitly rather than left as permanent holes:
      //   multiplies always complete in 6-20 cycles - they have no early-exit
      //     path and cannot reach div_range
      //   divides either exit immediately (div-by-zero, signed overflow) or
      //     run all 32 iterations - they cannot land in mul_range
      // Naming the impossible combinations is the point: any hole REMAINING
      // after these exclusions is a genuine coverage gap.
      x_op_latency: cross cp_op, cp_latency {
        ignore_bins mul_cannot_be_slow =
          binsof(cp_op) intersect {MD_MUL, MD_MULH, MD_MULHSU, MD_MULHU} &&
          binsof(cp_latency) intersect {[21:40], [41:$]};
        ignore_bins mul_has_no_early_exit =
          binsof(cp_op) intersect {MD_MUL, MD_MULH, MD_MULHSU, MD_MULHU} &&
          binsof(cp_latency) intersect {[1:5]};
        ignore_bins div_never_in_mul_range =
          binsof(cp_op) intersect {MD_DIV, MD_DIVU, MD_REM, MD_REMU} &&
          binsof(cp_latency) intersect {[6:20]};
        ignore_bins div_not_slow =
          binsof(cp_op) intersect {MD_DIV, MD_DIVU, MD_REM, MD_REMU} &&
          binsof(cp_latency) intersect {[41:$]};
      }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg_md = new();
    endfunction

    function void write(muldiv_seq_item t);
      cg_op      = t.op;
      cg_a       = t.a;
      cg_b       = t.b;
      cg_a_class = t.a_class;
      cg_b_class = t.b_class;
      cg_latency = t.compute_cycles;   // DUT work, excluding back-pressure
      cg_bp      = t.saw_backpressure;
      cg_is_div  = (t.op inside {MD_DIV, MD_DIVU, MD_REM, MD_REMU});
      cg_md.sample();
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("MD_COV",
        $sformatf("functional coverage = %0.2f%%", cg_md.get_inst_coverage()), UVM_LOW)
    endfunction
  endclass

  // ==================================================================
  // ENVIRONMENT
  // ==================================================================
  class muldiv_env_cfg extends uvm_object;
    `uvm_object_utils(muldiv_env_cfg)
    muldiv_agent_cfg agent_cfg;

    function new(string name = "muldiv_env_cfg");
      super.new(name);
    endfunction
  endclass

  class muldiv_env extends uvm_env;
    `uvm_component_utils(muldiv_env)

    muldiv_env_cfg    cfg;
    muldiv_agent      agent;
    muldiv_scoreboard scb;
    muldiv_coverage   cov;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(muldiv_env_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("MD_ENV", "muldiv_env_cfg not found in config db")
      uvm_config_db#(muldiv_agent_cfg)::set(this, "agent", "cfg", cfg.agent_cfg);

      agent = muldiv_agent::type_id::create("agent", this);
      scb   = muldiv_scoreboard::type_id::create("scb", this);
      cov   = muldiv_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.ap.connect(scb.analysis_export);
      agent.ap.connect(cov.analysis_export);
    endfunction
  endclass

endpackage
