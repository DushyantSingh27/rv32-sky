// muldiv agent: sequence item, driver, monitor, sequencer, config, agent.
package muldiv_agent_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  `include "uvm_macros.svh"

  typedef enum {
    OPND_ZERO,
    OPND_ONE,
    OPND_MINUS_ONE,
    OPND_MAX_POS,
    OPND_MIN_NEG,
    OPND_SMALL,
    OPND_RANDOM
  } md_opnd_class_e;

  // Derived from the observed value, never from stimulus intent. See
  // docs/results/0004 bug 3 - coverage that reads sequence-item metadata
  // measures the testbench, not the DUT.
  function automatic md_opnd_class_e md_classify(logic [XLEN-1:0] v);
    case (v)
      32'h0000_0000: return OPND_ZERO;
      32'h0000_0001: return OPND_ONE;
      32'hFFFF_FFFF: return OPND_MINUS_ONE;
      32'h7FFF_FFFF: return OPND_MAX_POS;
      32'h8000_0000: return OPND_MIN_NEG;
      default:       return (v < 32) ? OPND_SMALL : OPND_RANDOM;
    endcase
  endfunction

  class muldiv_seq_item extends uvm_sequence_item;

    rand muldiv_op_e      op;
    rand logic [XLEN-1:0] a;
    rand logic [XLEN-1:0] b;
    rand md_opnd_class_e  a_class;
    rand md_opnd_class_e  b_class;

    // Back-pressure control: how many cycles the testbench holds ready_i low
    // after the DUT raises valid_o. Zero means accept immediately.
    rand int unsigned     bp_cycles;

    // Filled by the monitor.
    logic [XLEN-1:0] result;
    int unsigned     latency;      // accept -> delivery (includes any stall)
    int unsigned     compute_cycles; // accept -> valid_o rising (DUT work only)
    bit              saw_backpressure;

    `uvm_object_utils_begin(muldiv_seq_item)
      `uvm_field_enum(muldiv_op_e,     op,        UVM_ALL_ON)
      `uvm_field_int (a,                          UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (b,                          UVM_ALL_ON | UVM_HEX)
      `uvm_field_enum(md_opnd_class_e, a_class,   UVM_ALL_ON)
      `uvm_field_enum(md_opnd_class_e, b_class,   UVM_ALL_ON)
      `uvm_field_int (bp_cycles,                  UVM_ALL_ON)
      `uvm_field_int (result,                     UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (latency,                    UVM_ALL_ON)
      `uvm_field_int (compute_cycles,             UVM_ALL_ON)
      `uvm_field_int (saw_backpressure,           UVM_ALL_ON)
    `uvm_object_utils_end

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

    // OPND_ZERO on b is weighted up relative to env 1: for divide operations
    // it is the div-by-zero case, which the spec defines rather than traps.
    constraint c_class_dist {
      a_class dist { OPND_RANDOM := 35, OPND_SMALL := 15,
                     OPND_ZERO := 10, OPND_ONE := 10, OPND_MINUS_ONE := 10,
                     OPND_MAX_POS := 10, OPND_MIN_NEG := 10 };
      b_class dist { OPND_RANDOM := 30, OPND_SMALL := 15,
                     OPND_ZERO := 15, OPND_ONE := 10, OPND_MINUS_ONE := 12,
                     OPND_MAX_POS := 8, OPND_MIN_NEG := 10 };
    }

    // ~20% of transactions apply back-pressure. Always-zero hides deadlocks;
    // always-high slows every run.
    constraint c_backpressure {
      bp_cycles dist { 0 := 80, [1:3] := 15, [4:10] := 5 };
    }

    function new(string name = "muldiv_seq_item");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf("op=%s a=0x%08h b=0x%08h -> result=0x%08h compute=%0d latency=%0d bp=%0d",
                       op.name(), a, b, result, compute_cycles, latency, bp_cycles);
    endfunction
  endclass

  class muldiv_agent_cfg extends uvm_object;
    `uvm_object_utils(muldiv_agent_cfg)
    uvm_active_passive_enum is_active = UVM_ACTIVE;
    virtual muldiv_if       vif;

    function new(string name = "muldiv_agent_cfg");
      super.new(name);
    endfunction
  endclass

  // ------------------------------------------------------------------
  // DRIVER
  //
  // The structural step up from env 1: one transaction spans many cycles.
  // The driver presents operands, waits for the DUT to accept, optionally
  // withholds ready_i to apply back-pressure, then waits for the result
  // before calling item_done. The completed item is returned as a response
  // so sequences can react to it.
  // ------------------------------------------------------------------
  class muldiv_driver extends uvm_driver #(muldiv_seq_item);
    `uvm_component_utils(muldiv_driver)

    muldiv_agent_cfg cfg;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(muldiv_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("MD_DRV", "muldiv_agent_cfg not found in config db")
      if (cfg.vif == null)
        `uvm_fatal("MD_DRV", "virtual interface in cfg is null")
    endfunction

    task run_phase(uvm_phase phase);
      muldiv_seq_item rsp;

      // Idle until reset releases.
      cfg.vif.drv_cb.valid_i <= 1'b0;
      cfg.vif.drv_cb.ready_i <= 1'b1;
      wait (cfg.vif.rst_n === 1'b1);
      @(cfg.vif.drv_cb);

      forever begin
        seq_item_port.get_next_item(req);

        // Present operands and hold valid_i until the DUT accepts.
        @(cfg.vif.drv_cb);
        cfg.vif.drv_cb.op      <= req.op;
        cfg.vif.drv_cb.a       <= req.a;
        cfg.vif.drv_cb.b       <= req.b;
        cfg.vif.drv_cb.valid_i <= 1'b1;
        cfg.vif.drv_cb.ready_i <= (req.bp_cycles == 0);

        do @(cfg.vif.drv_cb); while (cfg.vif.drv_cb.ready_o !== 1'b1);
        cfg.vif.drv_cb.valid_i <= 1'b0;

        // Wait for the result to appear.
        do @(cfg.vif.drv_cb); while (cfg.vif.drv_cb.valid_o !== 1'b1);

        // Apply back-pressure: hold ready_i low while valid_o is asserted.
        if (req.bp_cycles > 0) begin
          repeat (req.bp_cycles) @(cfg.vif.drv_cb);
          cfg.vif.drv_cb.ready_i <= 1'b1;
          @(cfg.vif.drv_cb);
        end

        // Capture the observed result INTO the request before cloning it.
        // Without this the response object carries an uninitialised result
        // field (X for logic), and any sequence using get_response() to feed
        // the result back as new stimulus propagates X through the DUT.
        req.result = cfg.vif.drv_cb.result;

        `uvm_info("MD_DRV", $sformatf("completed %s", req.convert2string()), UVM_HIGH)

        // Response sequence: hand the completed item back so a sequence can
        // make its next decision from the observed result.
        $cast(rsp, req.clone());
        rsp.set_id_info(req);
        seq_item_port.item_done(rsp);
      end
    endtask
  endclass

  // ------------------------------------------------------------------
  // MONITOR
  //
  // Tracks the protocol independently of the driver - it must work against a
  // passive agent too. Measures latency from accept to result.
  // ------------------------------------------------------------------
  class muldiv_monitor extends uvm_component;
    `uvm_component_utils(muldiv_monitor)

    muldiv_agent_cfg cfg;
    uvm_analysis_port #(muldiv_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(muldiv_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("MD_MON", "muldiv_agent_cfg not found in config db")
      if (cfg.vif == null)
        `uvm_fatal("MD_MON", "virtual interface in cfg is null")
    endfunction

    task run_phase(uvm_phase phase);
      muldiv_seq_item tr;
      int unsigned    cyc;
      int unsigned    compute;
      bit             bp;

      wait (cfg.vif.rst_n === 1'b1);

      forever begin
        @(cfg.vif.mon_cb);

        // Accept edge.
        if (cfg.vif.mon_cb.valid_i === 1'b1 && cfg.vif.mon_cb.ready_o === 1'b1) begin
          tr = muldiv_seq_item::type_id::create("tr");
          tr.op      = cfg.vif.mon_cb.op;
          tr.a       = cfg.vif.mon_cb.a;
          tr.b       = cfg.vif.mon_cb.b;
          tr.a_class = md_classify(tr.a);
          tr.b_class = md_classify(tr.b);
          cyc        = 0;
          compute    = 0;
          bp         = 1'b0;

          // Count until the result is delivered.
          forever begin
            @(cfg.vif.mon_cb);
            cyc++;
            if (cfg.vif.mon_cb.valid_o === 1'b1) begin
              // First cycle valid_o is seen = the DUT finished computing.
              // Anything after that is the testbench withholding ready_i.
              if (compute == 0) compute = cyc;
              if (cfg.vif.mon_cb.ready_i !== 1'b1) bp = 1'b1;
              else break;
            end
          end

          tr.result           = cfg.vif.mon_cb.result;
          tr.latency          = cyc;
          tr.compute_cycles   = compute;
          tr.saw_backpressure = bp;
          `uvm_info("MD_MON", $sformatf("observed %s", tr.convert2string()), UVM_HIGH)
          ap.write(tr);
        end
      end
    endtask
  endclass

  typedef uvm_sequencer #(muldiv_seq_item) muldiv_sequencer;

  class muldiv_agent extends uvm_agent;
    `uvm_component_utils(muldiv_agent)

    muldiv_agent_cfg cfg;
    muldiv_driver    drv;
    muldiv_monitor   mon;
    muldiv_sequencer seqr;

    uvm_analysis_port #(muldiv_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(muldiv_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("MD_AGENT", "muldiv_agent_cfg not found in config db")
      uvm_config_db#(muldiv_agent_cfg)::set(this, "*", "cfg", cfg);

      mon = muldiv_monitor::type_id::create("mon", this);
      if (cfg.is_active == UVM_ACTIVE) begin
        drv  = muldiv_driver::type_id::create("drv", this);
        seqr = muldiv_sequencer::type_id::create("seqr", this);
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
