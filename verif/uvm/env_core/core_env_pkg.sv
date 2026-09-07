// Full-core environment (UVM env 7): scoreboard, coverage, env.
//
// WHAT THIS CHECKS, AND WHAT IT DOES NOT.
//
// The scoreboard holds INVARIANTS, not a reference model. It cannot tell a
// correct `add` from a wrong one - Sail lockstep does that offline
// (docs/results/0015), and wiring Sail in as an online predictor is the
// specified next step for this environment, not part of this skeleton.
//
// What it does check is a different category: properties that must hold for
// ANY correct RV32I core regardless of what the program computes. Those are
// invisible to a data-flow checksum, which is the method every result before
// M3.5 relied on. A retirement stream that writes x0, retires a misaligned
// PC, or jumps to an address no instruction could target is broken no matter
// what value ends up in the accumulator.
//
// State this plainly rather than letting the environment imply more than it
// verifies: this is a STRUCTURAL UVM environment with invariant checking, not
// a verified core. See docs/results/0019.
package core_env_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  import core_agent_pkg::*;
  `include "uvm_macros.svh"

  class core_scoreboard extends uvm_subscriber #(core_seq_item);
    `uvm_component_utils(core_scoreboard)

    // mtvec, captured from the DUT boundary. A redirect to this address is a
    // trap entry and is legal from any instruction.
    logic [XLEN-1:0] mtvec_seen;

    function bit is_trap_target(logic [XLEN-1:0] pc);
      return (mtvec_seen != '0) && (pc == mtvec_seen);
    endfunction

    int unsigned n_checked;
    int unsigned n_violations;
    int unsigned n_redirects;

    // Program bounds, so "retired outside the image" is detectable.
    int unsigned image_words;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void write(core_seq_item t);
      n_checked++;
      if (t.mtvec != '0) mtvec_seen = t.mtvec;

      // ---- x0 IS NEVER ARCHITECTURALLY WRITTEN ----
      // The register file discards writes to x0 (env 3, 25,097 transactions),
      // but the TRACE port reports what the writeback stage attempted. A
      // non-zero value delivered to x0 means the discard is the only thing
      // preventing corruption, and forwarding logic does not consult the
      // register file - the M3.3 x0-forwarding bug lived exactly there.
      // NO x0-WRITE CHECK.
      //
      // A first version flagged `t.rd_we && t.rd_addr == 0 && t.rd_data != 0`
      // and fired on `addi x0, x0, 999` in t03/t04 - the instruction those
      // programs deliberately contain to test that x0 never forwards.
      //
      // trace_rd_we reports the writeback stage's ATTEMPT; the register file
      // discards it (verified across 25,097 transactions in env 3). The trace
      // port cannot observe architectural x0 state, so the invariant is not
      // measurable from here. Removed rather than weakened: a check that
      // cannot see what it claims to check is worse than no check.

      // ---- EVERY RETIRED PC IS 4-BYTE ALIGNED ----
      // IALIGN is 32 without the C extension. A misaligned retired PC means
      // the fetch unit followed a target it should have trapped on.
      if (t.pc[1:0] != 2'b00) begin
        n_violations++;
        `uvm_error("CORE_SCB",
          $sformatf("MISALIGNED PC: 0x%08h retired", t.pc))
      end

      // ---- EVERY RETIRED PC IS INSIDE THE PROGRAM IMAGE ----
      // The TCM initialises to NOP, so execution running off the end of the
      // program does not fault - it silently executes NOPs to the top of
      // memory. That is exactly how mutation T6 manifested, and a checksum
      // cannot see it.
      if (image_words != 0 && (t.pc >> 2) >= image_words) begin
        n_violations++;
        `uvm_error("CORE_SCB",
          $sformatf("PC OUT OF IMAGE: 0x%08h retired, image is %0d words",
                    t.pc, image_words))
      end

      // ---- CONTROL FLOW ONLY LEAVES pc+4 FROM AN INSTRUCTION THAT CAN ----
      // A redirect must follow a branch, a jump, or a SYSTEM instruction
      // (ecall/ebreak/mret vector or return). Any other opcode redirecting
      // means an instruction changed control flow that has no business doing
      // so - a decoder or pipeline fault a value-based check cannot detect.
      if (t.flow == FLOW_REDIRECT) begin
        n_redirects++;
        // ANY instruction can redirect if it TRAPS. A misaligned load or
        // store vectors to mtvec from an OPC_LOAD/OPC_STORE, and an illegal
        // instruction traps from whatever opcode it decoded as. The first
        // version allowed only branch/jump/SYSTEM and fired 4 times on
        // t06_traps against a core verified at 800 instructions against Sail.
        //
        // A redirect INTO mtvec is a trap entry; a redirect into mepc is an
        // mret return. Both are legal from any predecessor. What remains
        // checkable is the non-trap case: a redirect that is neither, from an
        // instruction that cannot change control flow.
        if (!(t.prev_opc inside {OPC_BRANCH, OPC_JAL, OPC_JALR, OPC_SYSTEM}) &&
            !is_trap_target(t.pc)) begin
          n_violations++;
          `uvm_error("CORE_SCB",
            $sformatf("ILLEGAL REDIRECT: pc=0x%08h followed 0x%08h (%s), which cannot change control flow",
                      t.pc, t.prev_pc, t.prev_opc.name()))
        end
      end

      // ---- A STORE NEVER WRITES A REGISTER; A BRANCH NEVER DOES EITHER ----
      if (t.rd_we && t.rd_addr != 5'd0 &&
          (t.opc == OPC_STORE || t.opc == OPC_BRANCH)) begin
        n_violations++;
        `uvm_error("CORE_SCB",
          $sformatf("REG WRITE FROM %s: pc=0x%08h x%0d <= 0x%08h",
                    t.opc.name(), t.pc, t.rd_addr, t.rd_data))
      end

      // ---- A MEMORY WRITE COMES ONLY FROM A STORE ----
      if (t.mem_we && t.opc != OPC_STORE) begin
        n_violations++;
        `uvm_error("CORE_SCB",
          $sformatf("MEM WRITE FROM %s: pc=0x%08h mem[0x%08h] <= 0x%08h",
                    t.opc.name(), t.pc, t.mem_addr, t.mem_wdata))
      end
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("CORE_SCB",
        $sformatf("checked %0d retirements, %0d redirects, %0d invariant violations",
                  n_checked, n_redirects, n_violations), UVM_LOW)
      if (n_checked == 0)
        `uvm_error("CORE_SCB", "scoreboard saw zero retirements - testbench is not connected")
      // A run with no redirect exercised no branch or jump, which means the
      // control-flow invariants above were never tested. Same discipline as
      // env 3's zero-collision check.
      if (n_redirects == 0)
        `uvm_error("CORE_SCB",
          "ZERO redirects observed - the control-flow invariants are UNTESTED")
    endfunction
  endclass

  class core_coverage extends uvm_subscriber #(core_seq_item);
    `uvm_component_utils(core_coverage)

    opc_class_e cg_opc;
    flow_e      cg_flow;
    bit         cg_rd_we;
    bit         cg_mem_we;
    logic [4:0] cg_rd_addr;

    covergroup cg_core;
      option.per_instance = 1;

      cp_opcode: coverpoint cg_opc {
        bins classes[] = {OPC_LOAD, OPC_STORE, OPC_OPIMM, OPC_OP, OPC_BRANCH,
                          OPC_JAL, OPC_JALR, OPC_LUI, OPC_AUIPC, OPC_SYSTEM,
                          OPC_MISCMEM};
        // OPC_OTHER is an illegal opcode retiring. Not a coverage target -
        // an error detector, empty when healthy. Same distinction as env 2's
        // pathological-latency bin.
        illegal_bins bad = {OPC_OTHER};
      }

      // The only pipeline state visible from the retirement port.
      cp_flow: coverpoint cg_flow {
        bins first      = {FLOW_FIRST};
        bins sequential = {FLOW_SEQUENTIAL};
        bins redirect   = {FLOW_REDIRECT};
      }

      cp_rd_we:  coverpoint cg_rd_we  { bins no = {0}; bins yes = {1}; }
      cp_mem_we: coverpoint cg_mem_we { bins no = {0}; bins yes = {1}; }

      cp_rd_x0: coverpoint (cg_rd_we && cg_rd_addr == 5'd0) {
        bins no = {0}; bins yes = {1};
      }

      // INSTRUCTION TYPE x PIPELINE STATE - the cross PROJECT_CONTEXT 5.2
      // names for this environment, at the resolution the retirement port
      // makes available.
      //
      // Only branches, jumps and SYSTEM instructions can be followed by a
      // redirect, so every other opcode crossed with redirect is unreachable
      // by construction. Named explicitly so any REMAINING hole is a genuine
      // gap rather than a structural impossibility.
      x_opcode_flow: cross cp_opcode, cp_flow {
        ignore_bins cannot_redirect =
          binsof(cp_opcode) intersect {OPC_LOAD, OPC_STORE, OPC_OPIMM, OPC_OP,
                                       OPC_LUI, OPC_AUIPC, OPC_MISCMEM} &&
          binsof(cp_flow) intersect {FLOW_REDIRECT};
      }

      // Which opcodes write a register. Catches a decoder that grants
      // reg_write to an instruction that must not have it.
      x_opcode_rd: cross cp_opcode, cp_rd_we {
        ignore_bins never_writes =
          binsof(cp_opcode) intersect {OPC_STORE, OPC_BRANCH} &&
          binsof(cp_rd_we) intersect {1};
      }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg_core = new();
    endfunction

    function void write(core_seq_item t);
      cg_opc     = t.opc;
      cg_flow    = t.flow;
      cg_rd_we   = t.rd_we;
      cg_mem_we  = t.mem_we;
      cg_rd_addr = t.rd_addr;
      cg_core.sample();
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("CORE_COV",
        $sformatf("functional coverage = %0.2f%%", cg_core.get_inst_coverage()),
        UVM_LOW)
    endfunction
  endclass

  class core_env_cfg extends uvm_object;
    `uvm_object_utils(core_env_cfg)
    core_agent_cfg agent_cfg;
    int unsigned   image_words;

    function new(string name = "core_env_cfg");
      super.new(name);
    endfunction
  endclass

  class core_env extends uvm_env;
    `uvm_component_utils(core_env)

    core_env_cfg     cfg;
    core_agent       agent;
    core_scoreboard  scb;
    core_coverage    cov;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(core_env_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CORE_ENV", "core_env_cfg not found in config db")
      uvm_config_db#(core_agent_cfg)::set(this, "agent", "cfg", cfg.agent_cfg);

      agent = core_agent::type_id::create("agent", this);
      scb   = core_scoreboard::type_id::create("scb", this);
      cov   = core_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      scb.image_words = cfg.image_words;
      agent.ap.connect(scb.analysis_export);
      agent.ap.connect(cov.analysis_export);
    endfunction
  endclass

endpackage
