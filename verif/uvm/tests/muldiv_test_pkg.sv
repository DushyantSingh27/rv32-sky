// muldiv tests.
package muldiv_test_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  import muldiv_agent_pkg::*;
  import muldiv_env_pkg::*;
  `include "uvm_macros.svh"
  `include "muldiv_seq_lib.svh"

  class md_base_test extends uvm_test;
    `uvm_component_utils(md_base_test)

    muldiv_env       env;
    muldiv_env_cfg   env_cfg;
    muldiv_agent_cfg agent_cfg;
    int unsigned     n_items = 500;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'($value$plusargs("N_ITEMS=%d", n_items));

      agent_cfg = muldiv_agent_cfg::type_id::create("agent_cfg");
      agent_cfg.is_active = UVM_ACTIVE;
      if (!uvm_config_db#(virtual muldiv_if)::get(this, "", "vif", agent_cfg.vif))
        `uvm_fatal("MD_TEST", "virtual interface 'vif' not set in config db")

      env_cfg = muldiv_env_cfg::type_id::create("env_cfg");
      env_cfg.agent_cfg = agent_cfg;
      uvm_config_db#(muldiv_env_cfg)::set(this, "env", "cfg", env_cfg);

      env = muldiv_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      uvm_top.print_topology();
    endfunction
  endclass

  // Directed corners, then bulk random.
  class md_smoke_test extends md_base_test;
    `uvm_component_utils(md_smoke_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      md_corner_seq corner;
      md_random_seq rnd;

      phase.get_objection().set_drain_time(this, 200ns);
      phase.raise_objection(this);

      corner = md_corner_seq::type_id::create("corner");
      corner.start(env.agent.seqr);

      rnd = md_random_seq::type_id::create("rnd");
      rnd.n_items = n_items;
      rnd.start(env.agent.seqr);

      phase.drop_objection(this);
    endtask
  endclass

  // Coverage closure: every sequence.
  class md_full_test extends md_base_test;
    `uvm_component_utils(md_full_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      md_corner_seq       corner;
      md_mul_seq          mul;
      md_div_seq          dv;
      md_backpressure_seq bp;
      md_chain_seq        chain;
      md_random_seq       rnd;

      phase.get_objection().set_drain_time(this, 200ns);
      phase.raise_objection(this);

      corner = md_corner_seq::type_id::create("corner");
      corner.start(env.agent.seqr);

      mul = md_mul_seq::type_id::create("mul");
      mul.n_items = n_items / 4;
      mul.start(env.agent.seqr);

      dv = md_div_seq::type_id::create("dv");
      dv.n_items = n_items / 4;
      dv.start(env.agent.seqr);

      bp = md_backpressure_seq::type_id::create("bp");
      bp.n_items = n_items / 10;
      bp.start(env.agent.seqr);

      chain = md_chain_seq::type_id::create("chain");
      chain.n_items = n_items / 10;
      chain.start(env.agent.seqr);

      rnd = md_random_seq::type_id::create("rnd");
      rnd.n_items = n_items;
      rnd.start(env.agent.seqr);

      phase.drop_objection(this);
    endtask
  endclass

  // Dedicated heavy back-pressure test - stalls every result handshake.
  class md_backpressure_test extends md_base_test;
    `uvm_component_utils(md_backpressure_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      md_backpressure_seq bp;

      phase.get_objection().set_drain_time(this, 200ns);
      phase.raise_objection(this);

      bp = md_backpressure_seq::type_id::create("bp");
      bp.n_items = n_items;
      bp.start(env.agent.seqr);

      phase.drop_objection(this);
    endtask
  endclass

endpackage
