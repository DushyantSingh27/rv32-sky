// Register file agent: sequence item, driver, monitor, sequencer, config, agent.
package regfile_agent_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  `include "uvm_macros.svh"

  // Data patterns worth targeting. Uniform 32-bit randomization essentially
  // never produces an all-ones or walking-one value.
  typedef enum {
    PAT_ZERO,
    PAT_ONES,
    PAT_WALKING_ONE,
    PAT_ALTERNATING,
    PAT_RANDOM
  } rf_pattern_e;

  class regfile_seq_item extends uvm_sequence_item;

    rand logic [4:0]      rs1_addr;
    rand logic [4:0]      rs2_addr;
    rand logic [4:0]      rd_addr;
    rand logic [XLEN-1:0] rd_data;
    rand logic            rd_we;
    rand rf_pattern_e     pattern;
    rand int unsigned     walk_bit;

    // Filled by the monitor from observed pins.
    logic [XLEN-1:0] rs1_data;
    logic [XLEN-1:0] rs2_data;

    `uvm_object_utils_begin(regfile_seq_item)
      `uvm_field_int (rs1_addr,               UVM_ALL_ON)
      `uvm_field_int (rs2_addr,               UVM_ALL_ON)
      `uvm_field_int (rd_addr,                UVM_ALL_ON)
      `uvm_field_int (rd_data,                UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (rd_we,                  UVM_ALL_ON)
      `uvm_field_enum(rf_pattern_e, pattern,  UVM_ALL_ON)
      `uvm_field_int (rs1_data,               UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (rs2_data,               UVM_ALL_ON | UVM_HEX)
    `uvm_object_utils_end

    constraint c_walk { walk_bit inside {[0:31]}; }

    constraint c_solve { solve pattern before rd_data; solve walk_bit before rd_data; }

    constraint c_data {
      (pattern == PAT_ZERO)        -> rd_data == 32'h0000_0000;
      (pattern == PAT_ONES)        -> rd_data == 32'hFFFF_FFFF;
      (pattern == PAT_WALKING_ONE) -> rd_data == (32'd1 << walk_bit);
      (pattern == PAT_ALTERNATING) -> rd_data inside {32'hAAAA_AAAA, 32'h5555_5555};
    }

    constraint c_pattern_dist {
      pattern dist { PAT_RANDOM := 50, PAT_WALKING_ONE := 20,
                     PAT_ZERO := 10, PAT_ONES := 10, PAT_ALTERNATING := 10 };
    }

    // Write enable mostly on - the register file is far more interesting when
    // it holds data than when it is empty.
    constraint c_we { rd_we dist { 1'b1 := 80, 1'b0 := 20 }; }

    // x0 gets deliberate weight on all three address ports. It is the most
    // commonly-wrong part of any register file.
    constraint c_addr_dist {
      rs1_addr dist { 5'd0 := 10, [5'd1:5'd31] := 90 };
      rs2_addr dist { 5'd0 := 10, [5'd1:5'd31] := 90 };
      rd_addr  dist { 5'd0 := 10, [5'd1:5'd31] := 90 };
    }

    function new(string name = "regfile_seq_item");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf("rs1=x%0d->0x%08h rs2=x%0d->0x%08h  wr%0s x%0d=0x%08h",
                       rs1_addr, rs1_data, rs2_addr, rs2_data,
                       rd_we ? "" : "(disabled)", rd_addr, rd_data);
    endfunction
  endclass

  class regfile_agent_cfg extends uvm_object;
    `uvm_object_utils(regfile_agent_cfg)
    uvm_active_passive_enum is_active = UVM_ACTIVE;
    virtual regfile_if      vif;

    function new(string name = "regfile_agent_cfg");
      super.new(name);
    endfunction
  endclass

  class regfile_driver extends uvm_driver #(regfile_seq_item);
    `uvm_component_utils(regfile_driver)

    regfile_agent_cfg cfg;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(regfile_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("RF_DRV", "regfile_agent_cfg not found in config db")
      if (cfg.vif == null)
        `uvm_fatal("RF_DRV", "virtual interface in cfg is null")
    endfunction

    task run_phase(uvm_phase phase);
      cfg.vif.drv_cb.rd_we <= 1'b0;
      wait (cfg.vif.rst_n === 1'b1);
      @(cfg.vif.drv_cb);

      forever begin
        seq_item_port.get_next_item(req);
        @(cfg.vif.drv_cb);
        cfg.vif.drv_cb.rs1_addr <= req.rs1_addr;
        cfg.vif.drv_cb.rs2_addr <= req.rs2_addr;
        cfg.vif.drv_cb.rd_addr  <= req.rd_addr;
        cfg.vif.drv_cb.rd_data  <= req.rd_data;
        cfg.vif.drv_cb.rd_we    <= req.rd_we;
        `uvm_info("RF_DRV", $sformatf("drove %s", req.convert2string()), UVM_HIGH)
        seq_item_port.item_done();
      end
    endtask
  endclass

  class regfile_monitor extends uvm_component;
    `uvm_component_utils(regfile_monitor)

    regfile_agent_cfg cfg;
    uvm_analysis_port #(regfile_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(regfile_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("RF_MON", "regfile_agent_cfg not found in config db")
      if (cfg.vif == null)
        `uvm_fatal("RF_MON", "virtual interface in cfg is null")
    endfunction

    task run_phase(uvm_phase phase);
      regfile_seq_item tr;
      wait (cfg.vif.rst_n === 1'b1);

      forever begin
        @(cfg.vif.mon_cb);

        // Skip cycles where no stimulus has been applied. rst_n rises on a
        // posedge and the next negedge arrives 5 ns later, before the driver
        // has driven anything - so the address pins are still X from
        // initialisation. Sampling that cycle produces a transaction nobody
        // drove, and the scoreboard cannot index its model with an X address.
        //
        // Same failure class as env 1's drain-time phantoms and env 2's
        // unpopulated response object: the monitor must emit only what the
        // DUT was actually asked to do.
        if ($isunknown({cfg.vif.mon_cb.rs1_addr, cfg.vif.mon_cb.rs2_addr,
                        cfg.vif.mon_cb.rd_addr,  cfg.vif.mon_cb.rd_we}))
          continue;

        tr = regfile_seq_item::type_id::create("tr");
        tr.rs1_addr = cfg.vif.mon_cb.rs1_addr;
        tr.rs1_data = cfg.vif.mon_cb.rs1_data;
        tr.rs2_addr = cfg.vif.mon_cb.rs2_addr;
        tr.rs2_data = cfg.vif.mon_cb.rs2_data;
        tr.rd_addr  = cfg.vif.mon_cb.rd_addr;
        tr.rd_data  = cfg.vif.mon_cb.rd_data;
        tr.rd_we    = cfg.vif.mon_cb.rd_we;
        `uvm_info("RF_MON", $sformatf("observed %s", tr.convert2string()), UVM_HIGH)
        ap.write(tr);
      end
    endtask
  endclass

  typedef uvm_sequencer #(regfile_seq_item) regfile_sequencer;

  class regfile_agent extends uvm_agent;
    `uvm_component_utils(regfile_agent)

    regfile_agent_cfg cfg;
    regfile_driver    drv;
    regfile_monitor   mon;
    regfile_sequencer seqr;

    uvm_analysis_port #(regfile_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(regfile_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("RF_AGENT", "regfile_agent_cfg not found in config db")
      uvm_config_db#(regfile_agent_cfg)::set(this, "*", "cfg", cfg);

      mon = regfile_monitor::type_id::create("mon", this);
      if (cfg.is_active == UVM_ACTIVE) begin
        drv  = regfile_driver::type_id::create("drv", this);
        seqr = regfile_sequencer::type_id::create("seqr", this);
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
