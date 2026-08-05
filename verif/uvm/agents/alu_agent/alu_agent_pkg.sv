// ALU agent: sequence item, driver, monitor, sequencer, config, agent.
package alu_agent_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  `include "uvm_macros.svh"

  // ------------------------------------------------------------------
  // Operand equivalence classes. Random 32-bit values essentially never
  // hit the interesting corners, so we bias toward them explicitly.
  // ------------------------------------------------------------------
  typedef enum {
    OPND_ZERO,       // 32'h0000_0000
    OPND_ONE,        // 32'h0000_0001
    OPND_MINUS_ONE,  // 32'hFFFF_FFFF
    OPND_MAX_POS,    // 32'h7FFF_FFFF
    OPND_MIN_NEG,    // 32'h8000_0000
    OPND_SMALL,      // < 32, exercises shift amounts
    OPND_RANDOM
  } opnd_class_e;

  // Derive the operand class from the value itself. This is the only
  // correct source for coverage: the class field in a sequence item is
  // stimulus intent, which the monitor cannot see on the pins. Coverage
  // must measure what the DUT received, not what the sequence meant.
  function automatic opnd_class_e classify_operand(logic [XLEN-1:0] v);
    case (v)
      32'h0000_0000: return OPND_ZERO;
      32'h0000_0001: return OPND_ONE;
      32'hFFFF_FFFF: return OPND_MINUS_ONE;
      32'h7FFF_FFFF: return OPND_MAX_POS;
      32'h8000_0000: return OPND_MIN_NEG;
      default:       return (v < 32) ? OPND_SMALL : OPND_RANDOM;
    endcase
  endfunction

  class alu_seq_item extends uvm_sequence_item;

    rand alu_op_e         op;
    rand branch_op_e      branch_op;
    rand logic [XLEN-1:0] a;
    rand logic [XLEN-1:0] b;
    rand opnd_class_e     a_class;
    rand opnd_class_e     b_class;

    // Outputs - filled by the monitor, not randomized.
    logic [XLEN-1:0] result;
    logic            branch_taken;

    `uvm_object_utils_begin(alu_seq_item)
      `uvm_field_enum(alu_op_e,     op,           UVM_ALL_ON)
      `uvm_field_enum(branch_op_e,  branch_op,    UVM_ALL_ON)
      `uvm_field_int (a,                          UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (b,                          UVM_ALL_ON | UVM_HEX)
      `uvm_field_enum(opnd_class_e, a_class,      UVM_ALL_ON)
      `uvm_field_enum(opnd_class_e, b_class,      UVM_ALL_ON)
      `uvm_field_int (result,                     UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (branch_taken,               UVM_ALL_ON)
    `uvm_object_utils_end

    // Class drives value. Solve order matters: pick the class first,
    // then constrain the value to match it.
    constraint c_solve_order {
      solve a_class before a;
      solve b_class before b;
    }

    constraint c_a_value {
      (a_class == OPND_ZERO)      -> a == 32'h0000_0000;
      (a_class == OPND_ONE)       -> a == 32'h0000_0001;
      (a_class == OPND_MINUS_ONE) -> a == 32'hFFFF_FFFF;
      (a_class == OPND_MAX_POS)   -> a == 32'h7FFF_FFFF;
      (a_class == OPND_MIN_NEG)   -> a == 32'h8000_0000;
      (a_class == OPND_SMALL)     -> a < 32;
    }

    constraint c_b_value {
      (b_class == OPND_ZERO)      -> b == 32'h0000_0000;
      (b_class == OPND_ONE)       -> b == 32'h0000_0001;
      (b_class == OPND_MINUS_ONE) -> b == 32'hFFFF_FFFF;
      (b_class == OPND_MAX_POS)   -> b == 32'h7FFF_FFFF;
      (b_class == OPND_MIN_NEG)   -> b == 32'h8000_0000;
      (b_class == OPND_SMALL)     -> b < 32;
    }

    // Weight the corners heavily. Pure uniform 32-bit randomization would
    // hit 32'h8000_0000 roughly once every 4 billion transactions.
    constraint c_class_dist {
      a_class dist { OPND_RANDOM := 40, OPND_SMALL := 15,
                     OPND_ZERO := 10, OPND_ONE := 10, OPND_MINUS_ONE := 10,
                     OPND_MAX_POS := 8, OPND_MIN_NEG := 7 };
      b_class dist { OPND_RANDOM := 40, OPND_SMALL := 15,
                     OPND_ZERO := 10, OPND_ONE := 10, OPND_MINUS_ONE := 10,
                     OPND_MAX_POS := 8, OPND_MIN_NEG := 7 };
    }

    function new(string name = "alu_seq_item");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf("op=%s branch_op=%s a=0x%08h b=0x%08h -> result=0x%08h bt=%0b",
                       op.name(), branch_op.name(), a, b, result, branch_taken);
    endfunction
  endclass

  class alu_agent_cfg extends uvm_object;
    `uvm_object_utils(alu_agent_cfg)
    uvm_active_passive_enum is_active = UVM_ACTIVE;
    virtual alu_if          vif;

    function new(string name = "alu_agent_cfg");
      super.new(name);
    endfunction
  endclass

  class alu_driver extends uvm_driver #(alu_seq_item);
    `uvm_component_utils(alu_driver)

    alu_agent_cfg cfg;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(alu_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("ALU_DRV", "alu_agent_cfg not found in config db at this scope")
      if (cfg.vif == null)
        `uvm_fatal("ALU_DRV", "virtual interface in cfg is null")
    endfunction

    task run_phase(uvm_phase phase);
      bit tog = 1'b0;
      forever begin
        seq_item_port.get_next_item(req);
        @(cfg.vif.drv_cb);
        tog = ~tog;
        cfg.vif.drv_cb.op         <= req.op;
        cfg.vif.drv_cb.branch_op  <= req.branch_op;
        cfg.vif.drv_cb.a          <= req.a;
        cfg.vif.drv_cb.b          <= req.b;
        cfg.vif.drv_cb.drv_toggle <= tog;
        `uvm_info("ALU_DRV", $sformatf("drove %s", req.convert2string()), UVM_HIGH)
        seq_item_port.item_done();
      end
    endtask
  endclass

  class alu_monitor extends uvm_component;
    `uvm_component_utils(alu_monitor)

    alu_agent_cfg                 cfg;
    uvm_analysis_port #(alu_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(alu_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("ALU_MON", "alu_agent_cfg not found in config db at this scope")
      if (cfg.vif == null)
        `uvm_fatal("ALU_MON", "virtual interface in cfg is null")
    endfunction

    task run_phase(uvm_phase phase);
      alu_seq_item tr;
      bit last_tog = 1'b0;
      forever begin
        @(cfg.vif.mon_cb);
        // Emit only on a real transaction, not on every negedge.
        if (cfg.vif.mon_cb.drv_toggle === last_tog) continue;
        last_tog = cfg.vif.mon_cb.drv_toggle;

        tr = alu_seq_item::type_id::create("tr");
        tr.op           = cfg.vif.mon_cb.op;
        tr.branch_op    = cfg.vif.mon_cb.branch_op;
        tr.a            = cfg.vif.mon_cb.a;
        tr.b            = cfg.vif.mon_cb.b;
        tr.a_class      = classify_operand(tr.a);
        tr.b_class      = classify_operand(tr.b);
        tr.result       = cfg.vif.mon_cb.result;
        tr.branch_taken = cfg.vif.mon_cb.branch_taken;
        `uvm_info("ALU_MON", $sformatf("observed %s", tr.convert2string()), UVM_HIGH)
        ap.write(tr);
      end
    endtask
  endclass

  typedef uvm_sequencer #(alu_seq_item) alu_sequencer;

  class alu_agent extends uvm_agent;
    `uvm_component_utils(alu_agent)

    alu_agent_cfg cfg;
    alu_driver    drv;
    alu_monitor   mon;
    alu_sequencer seqr;

    uvm_analysis_port #(alu_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(alu_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("ALU_AGENT", "alu_agent_cfg not found in config db at this scope")

      // Push cfg down so driver and monitor find it at their own scope.
      uvm_config_db#(alu_agent_cfg)::set(this, "*", "cfg", cfg);

      mon = alu_monitor::type_id::create("mon", this);
      if (cfg.is_active == UVM_ACTIVE) begin
        drv  = alu_driver::type_id::create("drv", this);
        seqr = alu_sequencer::type_id::create("seqr", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      mon.ap.connect(ap);
      if (cfg.is_active == UVM_ACTIVE)
        drv.seq_item_port.connect(seqr.seq_item_export);
    endfunction
  endclass

endpackage
