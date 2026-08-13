// CSR environment: RAL model, predictor, coverage, env.
//
// Structurally different from envs 1-3. Those held an ad-hoc reference model
// in the scoreboard. Here a uvm_reg_block IS the model: it knows every
// register's address, fields, access policies and reset values, and a
// uvm_reg_predictor keeps it in sync with what actually happened on the pins.
//
// EXPLICIT prediction (predictor watching the monitor) rather than AUTO
// (model updates itself when RAL issues an access). Explicit is what you want
// whenever the DUT can change a register without RAL asking - which is true
// here: traps write mepc/mcause/mtval, mret updates mstatus, and the counters
// increment on their own.
package csr_env_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  import csr_agent_pkg::*;
  import csr_ral_pkg::*;
  `include "uvm_macros.svh"

  class csr_coverage extends uvm_subscriber #(csr_seq_item);
    `uvm_component_utils(csr_coverage)

    logic [11:0] cg_addr;
    csr_op_e     cg_op;
    bit          cg_rd, cg_wr, cg_ill, cg_ro_addr;

    covergroup cg_csr;
      option.per_instance = 1;

      cp_addr: coverpoint cg_addr {
        bins mstatus   = {12'h300};
        bins misa      = {12'h301};
        bins mie       = {12'h304};
        bins mtvec     = {12'h305};
        bins mstatush  = {12'h310};
        bins mscratch  = {12'h340};
        bins mepc      = {12'h341};
        bins mcause    = {12'h342};
        bins mtval     = {12'h343};
        bins mip       = {12'h344};
        bins mcycle    = {12'hB00};
        bins minstret  = {12'hB02};
        bins mcycleh   = {12'hB80};
        bins minstreth = {12'hB82};
        bins mvendorid = {12'hF11};
        bins marchid   = {12'hF12};
        bins mimpid    = {12'hF13};
        bins mhartid   = {12'hF14};
        bins undefined = default;
      }

      cp_op: coverpoint cg_op {
        bins rw = {CSR_RW};
        bins rs = {CSR_RS};
        bins rc = {CSR_RC};
      }

      // The suppression rules. rd==x0 suppresses the read; rs1==x0 or
      // uimm==0 suppresses the write - not "write the unchanged value", but
      // no write at all.
      cp_read:  coverpoint cg_rd { bins suppressed = {0}; bins active = {1}; }
      cp_write: coverpoint cg_wr { bins suppressed = {0}; bins active = {1}; }

      cp_illegal: coverpoint cg_ill { bins legal = {0}; bins illegal = {1}; }

      // Writing a read-only CSR (addr[11:10]==2'b11) must raise illegal,
      // not be silently dropped.
      cp_ro_write: coverpoint (cg_ro_addr && cg_wr) {
        bins no = {0}; bins yes = {1};
      }

      x_addr_op:     cross cp_addr, cp_op;
      x_read_write:  cross cp_read, cp_write;
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg_csr = new();
    endfunction

    function void write(csr_seq_item t);
      cg_addr    = t.addr;
      cg_op      = t.op;
      cg_rd      = t.do_read;
      cg_wr      = t.do_write;
      cg_ill     = t.illegal;
      cg_ro_addr = (t.addr[11:10] == 2'b11);
      cg_csr.sample();
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("CSR_COV",
        $sformatf("functional coverage = %0.2f%%", cg_csr.get_inst_coverage()), UVM_LOW)
    endfunction
  endclass

  class csr_env_cfg extends uvm_object;
    `uvm_object_utils(csr_env_cfg)
    csr_agent_cfg agent_cfg;

    function new(string name = "csr_env_cfg");
      super.new(name);
    endfunction
  endclass

  class csr_env extends uvm_env;
    `uvm_component_utils(csr_env)

    csr_env_cfg      cfg;
    csr_agent        agent;
    csr_coverage     cov;

    csr_reg_block    regmodel;
    csr_reg_adapter  adapter;
    uvm_reg_predictor #(csr_seq_item) predictor;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(csr_env_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("CSR_ENV", "csr_env_cfg not found in config db")
      uvm_config_db#(csr_agent_cfg)::set(this, "agent", "cfg", cfg.agent_cfg);

      agent = csr_agent::type_id::create("agent", this);
      cov   = csr_coverage::type_id::create("cov", this);

      regmodel = csr_reg_block::type_id::create("regmodel");
      regmodel.build();

      adapter   = csr_reg_adapter::type_id::create("adapter");
      predictor = uvm_reg_predictor#(csr_seq_item)::type_id::create("predictor", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.ap.connect(cov.analysis_export);

      if (cfg.agent_cfg.is_active == UVM_ACTIVE)
        regmodel.csr_map.set_sequencer(agent.seqr, adapter);

      // Explicit prediction: the model follows the pins, not RAL's intent.
      regmodel.csr_map.set_auto_predict(0);
      predictor.map     = regmodel.csr_map;
      predictor.adapter = adapter;
      agent.ap.connect(predictor.bus_in);
    endfunction
  endclass

endpackage
