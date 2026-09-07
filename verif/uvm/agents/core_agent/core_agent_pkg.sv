// Full-core agent (UVM env 7): sequence item, monitor, agent.
//
// PASSIVE. No driver and no sequencer: the instruction stream is loaded into
// the TCM at time zero and there is nothing to drive at simulation time. A
// passive agent is a legitimate UVM configuration, not a stub - envs 1-4 are
// all active, so this is a structure the earlier environments do not show.
package core_agent_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  `include "uvm_macros.svh"

  // Opcode class, derived from the retired instruction word. Classified here
  // rather than carried from stimulus: the same rule envs 1-3 follow, that
  // coverage must measure what the DUT actually did, not what a sequence
  // intended. There is no stimulus object here at all, so the point is
  // structural rather than a choice.
  typedef enum {
    OPC_LOAD, OPC_STORE, OPC_OPIMM, OPC_OP, OPC_BRANCH,
    OPC_JAL, OPC_JALR, OPC_LUI, OPC_AUIPC, OPC_SYSTEM,
    OPC_MISCMEM, OPC_OTHER
  } opc_class_e;

  function automatic opc_class_e classify_opcode(logic [31:0] instr);
    case (instr[6:0])
      OP_LOAD:    return OPC_LOAD;
      OP_STORE:   return OPC_STORE;
      OP_OPIMM:   return OPC_OPIMM;
      OP_OP:      return OPC_OP;
      OP_BRANCH:  return OPC_BRANCH;
      OP_JAL:     return OPC_JAL;
      OP_JALR:    return OPC_JALR;
      OP_LUI:     return OPC_LUI;
      OP_AUIPC:   return OPC_AUIPC;
      OP_SYSTEM:  return OPC_SYSTEM;
      OP_MISCMEM: return OPC_MISCMEM;
      default:    return OPC_OTHER;
    endcase
  endfunction

  // How control flow reached this instruction. SEQUENTIAL means pc == prev+4;
  // REDIRECT means anything else - a taken branch, a jump, or a trap. This is
  // the only pipeline-state information visible from the retirement port, and
  // it is what makes the coverage cross meaningful rather than a plain
  // opcode histogram.
  typedef enum { FLOW_FIRST, FLOW_SEQUENTIAL, FLOW_REDIRECT } flow_e;

  class core_seq_item extends uvm_sequence_item;

    logic [XLEN-1:0] pc;
    logic [XLEN-1:0] prev_pc;
    // The PRECEDING instruction's opcode. A redirect is caused by the
    // instruction that RETIRED BEFORE this one, so the legality check needs
    // that opcode, not this one. The first version checked t.opc and flagged
    // every correct taken branch: at a loop, 0x48 (the branch) retires, then
    // 0x40 (an addi) retires as the target, and the addi was blamed.
    opc_class_e      prev_opc;
    logic [31:0]     instr;
    opc_class_e      opc;
    flow_e           flow;

    logic            rd_we;
    logic [4:0]      rd_addr;
    logic [XLEN-1:0] rd_data;

    logic            mem_we;
    logic [XLEN-1:0] mem_addr;
    logic [XLEN-1:0] mem_wdata;

    // mtvec at the time of retirement, read from the DUT boundary. The
    // scoreboard needs it to tell a TRAP ENTRY from an illegal redirect: any
    // instruction may redirect if it traps, so a jump to mtvec is legal from
    // any predecessor while a jump anywhere else is not.
    logic [XLEN-1:0] mtvec;

    `uvm_object_utils_begin(core_seq_item)
      `uvm_field_int (pc,                     UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (prev_pc,                UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (instr,                  UVM_ALL_ON | UVM_HEX)
      `uvm_field_enum(opc_class_e, opc,       UVM_ALL_ON)
      `uvm_field_enum(flow_e,      flow,      UVM_ALL_ON)
      `uvm_field_int (rd_we,                  UVM_ALL_ON)
      `uvm_field_int (rd_addr,                UVM_ALL_ON)
      `uvm_field_int (rd_data,                UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (mem_we,                 UVM_ALL_ON)
      `uvm_field_int (mem_addr,               UVM_ALL_ON | UVM_HEX)
    `uvm_object_utils_end

    function new(string name = "core_seq_item");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf("pc=0x%08h instr=0x%08h %s %s%s",
                       pc, instr, opc.name(), flow.name(),
                       rd_we ? $sformatf(" x%0d <= 0x%08h", rd_addr, rd_data)
                             : "");
    endfunction
  endclass

  class core_agent_cfg extends uvm_object;
    `uvm_object_utils(core_agent_cfg)
    uvm_active_passive_enum is_active = UVM_PASSIVE;
    virtual core_if         vif;

    // Set by the test when the program stores to the test-control address.
    // The monitor stops observing at that point.
    //
    // WHY THIS EXISTS. Relying on drain time instead let the monitor keep
    // sampling into the HALT LOOP, which retires sw/sw/beq forever. t04
    // reported 90 retirements against Sail's 80, and two halt-loop
    // retirements were scored as invariant violations. Architecturally the
    // program is over at the terminating store; anything after it is the
    // testbench watching a machine that has finished.
    bit done = 1'b0;

    // The program image, mirrored so the monitor can look an instruction up
    // by PC. The core does not carry the instruction word through the
    // pipeline - 96 flops of pure debug overhead, per rv32_core.sv - so the
    // trace port reports a PC and the word is recovered here. Valid only
    // because no test program is self-modifying.
    logic [31:0] image [];

    function new(string name = "core_agent_cfg");
      super.new(name);
    endfunction

    function logic [31:0] instr_at(logic [XLEN-1:0] addr);
      int unsigned idx = addr >> 2;
      if (idx < image.size()) return image[idx];
      return 32'h0000_0013;   // NOP
    endfunction
  endclass

  class core_monitor extends uvm_component;
    `uvm_component_utils(core_monitor)

    core_agent_cfg cfg;
    uvm_analysis_port #(core_seq_item) ap;

    int unsigned n_observed;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(core_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CORE_MON", "core_agent_cfg not found in config db")
      if (cfg.vif == null)
        `uvm_fatal("CORE_MON", "virtual interface in cfg is null")
    endfunction

    task run_phase(uvm_phase phase);
      core_seq_item    tr;
      logic [XLEN-1:0] prev     = '0;
      opc_class_e      prev_opc = OPC_OTHER;
      bit              seen     = 1'b0;

      wait (cfg.vif.rst_n === 1'b1);

      forever begin
        @(cfg.vif.mon_cb);

        // ONE TRANSACTION PER RETIRED INSTRUCTION, never per clock. Envs 1
        // and 3 both scored transactions nobody drove by sampling every edge;
        // trace_valid is the retirement strobe and gating on it is the whole
        // correctness argument for this monitor.
        if (cfg.done) break;
        if (cfg.vif.mon_cb.trace_valid !== 1'b1) continue;
        if ($isunknown(cfg.vif.mon_cb.trace_pc)) continue;

        tr = core_seq_item::type_id::create("tr");
        tr.pc        = cfg.vif.mon_cb.trace_pc;
        tr.instr     = cfg.instr_at(tr.pc);
        tr.opc       = classify_opcode(tr.instr);
        tr.prev_pc   = prev;
        tr.prev_opc  = prev_opc;
        tr.flow      = !seen                        ? FLOW_FIRST
                     : (tr.pc == prev + 32'd4)      ? FLOW_SEQUENTIAL
                                                    : FLOW_REDIRECT;
        tr.rd_we     = cfg.vif.mon_cb.trace_rd_we;
        tr.rd_addr   = cfg.vif.mon_cb.trace_rd_addr;
        tr.rd_data   = cfg.vif.mon_cb.trace_rd_data;
        tr.mem_we    = cfg.vif.mon_cb.trace_mem_we;
        tr.mem_addr  = cfg.vif.mon_cb.trace_mem_addr;
        tr.mem_wdata = cfg.vif.mon_cb.trace_mem_wdata;
        tr.mtvec     = cfg.vif.mon_cb.mtvec;

        prev     = tr.pc;
        prev_opc = tr.opc;
        seen     = 1'b1;
        n_observed++;

        `uvm_info("CORE_MON", tr.convert2string(), UVM_HIGH)
        ap.write(tr);
      end
    endtask

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("CORE_MON",
        $sformatf("observed %0d retired instructions", n_observed), UVM_LOW)
    endfunction
  endclass

  class core_agent extends uvm_agent;
    `uvm_component_utils(core_agent)

    core_agent_cfg cfg;
    core_monitor   mon;

    uvm_analysis_port #(core_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(core_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CORE_AGENT", "core_agent_cfg not found in config db")
      uvm_config_db#(core_agent_cfg)::set(this, "*", "cfg", cfg);

      mon = core_monitor::type_id::create("mon", this);
      // No driver, no sequencer: nothing to drive. See the file header.
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      mon.ap.connect(ap);
    endfunction
  endclass

endpackage
