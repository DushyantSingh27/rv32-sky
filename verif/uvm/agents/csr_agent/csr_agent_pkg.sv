// CSR agent: sequence item, driver, monitor, sequencer, adapter, config, agent.
package csr_agent_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  `include "uvm_macros.svh"

  class csr_seq_item extends uvm_sequence_item;

    rand logic [11:0]     addr;
    rand csr_op_e         op;
    rand logic [XLEN-1:0] wdata;

    // Separate strobes, not derived. The spec's suppression rules -
    // rd==x0 suppresses the read, rs1==x0 or uimm==0 suppresses the write -
    // are decoded in the pipeline, so they must be independently drivable
    // here or they cannot be tested.
    rand logic            do_read;
    rand logic            do_write;

    // Side-channel stimulus, not part of the RAL bus.
    rand logic            trap_valid;
    rand logic [XLEN-1:0] trap_epc, trap_cause, trap_tval;
    rand logic            mret;
    rand logic            irq_timer, irq_software, irq_external;
    rand logic            instr_retired;

    // Observed
    logic [XLEN-1:0] rdata;
    logic            illegal;
    logic            irq_pending;

    `uvm_object_utils_begin(csr_seq_item)
      `uvm_field_int (addr,          UVM_ALL_ON | UVM_HEX)
      `uvm_field_enum(csr_op_e, op,  UVM_ALL_ON)
      `uvm_field_int (wdata,         UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (do_read,       UVM_ALL_ON)
      `uvm_field_int (do_write,      UVM_ALL_ON)
      `uvm_field_int (trap_valid,    UVM_ALL_ON)
      `uvm_field_int (mret,          UVM_ALL_ON)
      `uvm_field_int (rdata,         UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (illegal,       UVM_ALL_ON)
    `uvm_object_utils_end

    // Default: a plain CSR access with no side-channel activity. RAL traffic
    // goes through the adapter, which sets these explicitly.
    constraint c_default {
      soft trap_valid    == 1'b0;
      soft mret          == 1'b0;
      soft irq_timer     == 1'b0;
      soft irq_software  == 1'b0;
      soft irq_external  == 1'b0;
      soft instr_retired == 1'b0;
      soft do_read       == 1'b1;
      soft do_write      == 1'b1;
    }

    function new(string name = "csr_seq_item");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf("addr=0x%03h op=%s wdata=0x%08h rd=%0b wr=%0b -> rdata=0x%08h ill=%0b",
                       addr, op.name(), wdata, do_read, do_write, rdata, illegal);
    endfunction
  endclass

  // ------------------------------------------------------------------
  // ADAPTER
  //
  // Translates uvm_reg_bus_op <-> csr_seq_item. This is where RAL
  // environments usually break: reg2bus MUST take `const ref` or it fails to
  // override the pure virtual and the class stays abstract.
  //
  // A RAL read becomes CSR_RS with wdata=0 - that is the canonical RISC-V
  // read-without-side-effect (CSRRS rd, csr, x0), and with do_write low it
  // performs no write at all.
  // ------------------------------------------------------------------
  class csr_reg_adapter extends uvm_reg_adapter;
    `uvm_object_utils(csr_reg_adapter)

    function new(string name = "csr_reg_adapter");
      super.new(name);
      supports_byte_enable = 0;
      provides_responses   = 0;
    endfunction

    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
      csr_seq_item it = csr_seq_item::type_id::create("it");
      it.addr          = rw.addr[11:0];
      it.trap_valid    = 1'b0;
      it.mret          = 1'b0;
      it.irq_timer     = 1'b0;
      it.irq_software  = 1'b0;
      it.irq_external  = 1'b0;
      it.instr_retired = 1'b0;

      if (rw.kind == UVM_WRITE) begin
        it.op       = CSR_RW;
        it.wdata    = rw.data;
        it.do_read  = 1'b1;
        it.do_write = 1'b1;
      end else begin
        it.op       = CSR_RS;    // CSRRS rd, csr, x0 - read, no write
        it.wdata    = '0;
        it.do_read  = 1'b1;
        it.do_write = 1'b0;
      end
      return it;
    endfunction

    virtual function void bus2reg(uvm_sequence_item bus_item,
                                  ref uvm_reg_bus_op rw);
      csr_seq_item it;
      if (!$cast(it, bus_item)) begin
        `uvm_fatal("CSR_ADAPT", "bus2reg received a non-csr_seq_item")
        return;
      end
      rw.kind   = (it.op == CSR_RW && it.do_write) ? UVM_WRITE : UVM_READ;
      rw.addr   = it.addr;
      rw.data   = (rw.kind == UVM_WRITE) ? it.wdata : it.rdata;
      rw.status = it.illegal ? UVM_NOT_OK : UVM_IS_OK;
    endfunction
  endclass

  class csr_agent_cfg extends uvm_object;
    `uvm_object_utils(csr_agent_cfg)
    uvm_active_passive_enum is_active = UVM_ACTIVE;
    virtual csr_if          vif;

    function new(string name = "csr_agent_cfg");
      super.new(name);
    endfunction
  endclass

  class csr_driver extends uvm_driver #(csr_seq_item);
    `uvm_component_utils(csr_driver)

    csr_agent_cfg cfg;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(csr_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CSR_DRV", "csr_agent_cfg not found in config db")
      if (cfg.vif == null)
        `uvm_fatal("CSR_DRV", "virtual interface in cfg is null")
    endfunction

    task run_phase(uvm_phase phase);
      cfg.vif.drv_cb.csr_op     <= CSR_NONE;
      cfg.vif.drv_cb.csr_read   <= 1'b0;
      cfg.vif.drv_cb.csr_write  <= 1'b0;
      cfg.vif.drv_cb.trap_valid <= 1'b0;
      cfg.vif.drv_cb.mret       <= 1'b0;
      wait (cfg.vif.rst_n === 1'b1);
      @(cfg.vif.drv_cb);

      forever begin
        seq_item_port.get_next_item(req);
        @(cfg.vif.drv_cb);
        cfg.vif.drv_cb.csr_addr      <= req.addr;
        cfg.vif.drv_cb.csr_op        <= req.op;
        cfg.vif.drv_cb.csr_wdata     <= req.wdata;
        cfg.vif.drv_cb.csr_read      <= req.do_read;
        cfg.vif.drv_cb.csr_write     <= req.do_write;
        cfg.vif.drv_cb.trap_valid    <= req.trap_valid;
        cfg.vif.drv_cb.trap_epc      <= req.trap_epc;
        cfg.vif.drv_cb.trap_cause    <= req.trap_cause;
        cfg.vif.drv_cb.trap_tval     <= req.trap_tval;
        cfg.vif.drv_cb.mret          <= req.mret;
        cfg.vif.drv_cb.irq_timer     <= req.irq_timer;
        cfg.vif.drv_cb.irq_software  <= req.irq_software;
        cfg.vif.drv_cb.irq_external  <= req.irq_external;
        cfg.vif.drv_cb.instr_retired <= req.instr_retired;

        // Reads are combinational; sample after the address has settled.
        @(cfg.vif.drv_cb);
        req.rdata       = cfg.vif.drv_cb.csr_rdata;
        req.illegal     = cfg.vif.drv_cb.csr_illegal;
        req.irq_pending = cfg.vif.drv_cb.irq_pending;

        // Return to idle so a held csr_op does not write repeatedly.
        cfg.vif.drv_cb.csr_op     <= CSR_NONE;
        cfg.vif.drv_cb.csr_write  <= 1'b0;
        cfg.vif.drv_cb.trap_valid <= 1'b0;
        cfg.vif.drv_cb.mret       <= 1'b0;

        `uvm_info("CSR_DRV", $sformatf("drove %s", req.convert2string()), UVM_HIGH)
        seq_item_port.item_done(req);
      end
    endtask
  endclass

  class csr_monitor extends uvm_component;
    `uvm_component_utils(csr_monitor)

    csr_agent_cfg cfg;
    uvm_analysis_port #(csr_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(csr_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CSR_MON", "csr_agent_cfg not found in config db")
      if (cfg.vif == null)
        `uvm_fatal("CSR_MON", "virtual interface in cfg is null")
    endfunction

    task run_phase(uvm_phase phase);
      csr_seq_item tr;
      wait (cfg.vif.rst_n === 1'b1);

      forever begin
        @(cfg.vif.mon_cb);

        // Emit only real accesses. Same rule as envs 1-3: a monitor must
        // report what the DUT was actually asked to do, never idle cycles.
        if ($isunknown({cfg.vif.mon_cb.csr_addr, cfg.vif.mon_cb.csr_read,
                        cfg.vif.mon_cb.csr_write})) continue;
        if (cfg.vif.mon_cb.csr_op === CSR_NONE) continue;

        tr = csr_seq_item::type_id::create("tr");
        tr.addr        = cfg.vif.mon_cb.csr_addr;
        tr.op          = cfg.vif.mon_cb.csr_op;
        tr.wdata       = cfg.vif.mon_cb.csr_wdata;
        tr.do_read     = cfg.vif.mon_cb.csr_read;
        tr.do_write    = cfg.vif.mon_cb.csr_write;
        tr.rdata       = cfg.vif.mon_cb.csr_rdata;
        tr.illegal     = cfg.vif.mon_cb.csr_illegal;
        tr.trap_valid  = cfg.vif.mon_cb.trap_valid;
        tr.mret        = cfg.vif.mon_cb.mret;
        tr.irq_pending = cfg.vif.mon_cb.irq_pending;
        `uvm_info("CSR_MON", $sformatf("observed %s", tr.convert2string()), UVM_HIGH)
        ap.write(tr);
      end
    endtask
  endclass

  typedef uvm_sequencer #(csr_seq_item) csr_sequencer;

  class csr_agent extends uvm_agent;
    `uvm_component_utils(csr_agent)

    csr_agent_cfg cfg;
    csr_driver    drv;
    csr_monitor   mon;
    csr_sequencer seqr;

    uvm_analysis_port #(csr_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(csr_agent_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CSR_AGENT", "csr_agent_cfg not found in config db")
      uvm_config_db#(csr_agent_cfg)::set(this, "*", "cfg", cfg);

      mon = csr_monitor::type_id::create("mon", this);
      if (cfg.is_active == UVM_ACTIVE) begin
        drv  = csr_driver::type_id::create("drv", this);
        seqr = csr_sequencer::type_id::create("seqr", this);
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
