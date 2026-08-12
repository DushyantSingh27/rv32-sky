// Register file tests.
package regfile_test_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  import regfile_agent_pkg::*;
  import regfile_env_pkg::*;
  `include "uvm_macros.svh"
  `include "regfile_seq_lib.svh"

  class rf_base_test extends uvm_test;
    `uvm_component_utils(rf_base_test)

    regfile_env       env;
    regfile_env_cfg   env_cfg;
    regfile_agent_cfg agent_cfg;
    int unsigned      n_items = 500;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'($value$plusargs("N_ITEMS=%d", n_items));

      agent_cfg = regfile_agent_cfg::type_id::create("agent_cfg");
      agent_cfg.is_active = UVM_ACTIVE;
      if (!uvm_config_db#(virtual regfile_if)::get(this, "", "vif", agent_cfg.vif))
        `uvm_fatal("RF_TEST", "virtual interface 'vif' not set in config db")

      env_cfg = regfile_env_cfg::type_id::create("env_cfg");
      env_cfg.agent_cfg = agent_cfg;
      uvm_config_db#(regfile_env_cfg)::set(this, "env", "cfg", env_cfg);

      env = regfile_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      uvm_top.print_topology();
    endfunction
  endclass

  class rf_smoke_test extends rf_base_test;
    `uvm_component_utils(rf_smoke_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      rf_corner_seq corner;
      rf_random_seq rnd;

      phase.get_objection().set_drain_time(this, 100ns);
      phase.raise_objection(this);

      corner = rf_corner_seq::type_id::create("corner");
      corner.start(env.agent.seqr);

      rnd = rf_random_seq::type_id::create("rnd");
      rnd.n_items = n_items;
      rnd.start(env.agent.seqr);

      phase.drop_objection(this);
    endtask
  endclass

  class rf_full_test extends rf_base_test;
    `uvm_component_utils(rf_full_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      rf_corner_seq    corner;
      rf_sweep_seq     sweep;
      rf_collision_seq coll;
      rf_random_seq    rnd;

      phase.get_objection().set_drain_time(this, 100ns);
      phase.raise_objection(this);

      corner = rf_corner_seq::type_id::create("corner");
      corner.start(env.agent.seqr);

      sweep = rf_sweep_seq::type_id::create("sweep");
      sweep.start(env.agent.seqr);

      coll = rf_collision_seq::type_id::create("coll");
      coll.n_items = n_items / 4;
      coll.start(env.agent.seqr);

      rnd = rf_random_seq::type_id::create("rnd");
      rnd.n_items = n_items;
      rnd.start(env.agent.seqr);

      phase.drop_objection(this);
    endtask
  endclass

endpackage
