// ALU tests. Each test selects sequences and configures the environment;
// no test contains stimulus logic directly.
package alu_test_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  import alu_agent_pkg::*;
  import alu_env_pkg::*;
  `include "uvm_macros.svh"
  `include "alu_seq_lib.svh"

  class alu_base_test extends uvm_test;
    `uvm_component_utils(alu_base_test)

    alu_env       env;
    alu_env_cfg   env_cfg;
    alu_agent_cfg agent_cfg;
    int unsigned  n_items = 500;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'($value$plusargs("N_ITEMS=%d", n_items));

      agent_cfg = alu_agent_cfg::type_id::create("agent_cfg");
      agent_cfg.is_active = UVM_ACTIVE;
      if (!uvm_config_db#(virtual alu_if)::get(this, "", "vif", agent_cfg.vif))
        `uvm_fatal("ALU_TEST", "virtual interface 'vif' not set in config db")

      env_cfg = alu_env_cfg::type_id::create("env_cfg");
      env_cfg.agent_cfg = agent_cfg;
      uvm_config_db#(alu_env_cfg)::set(this, "env", "cfg", env_cfg);

      env = alu_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      uvm_top.print_topology();
    endfunction
  endclass

  // Directed corners, then bulk random. The default regression test.
  class alu_smoke_test extends alu_base_test;
    `uvm_component_utils(alu_smoke_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      alu_corner_seq corner;
      alu_random_seq rand_seq;

      // Drain time: the monitor samples on negedge, one half-cycle after the
      // driver drives on posedge. Without a drain interval the final
      // transaction is driven, the objection drops, and simulation ends
      // before the monitor ever sees it - so it is never scored.
      phase.get_objection().set_drain_time(this, 100ns);
      phase.raise_objection(this);

      corner = alu_corner_seq::type_id::create("corner");
      corner.start(env.agent.seqr);

      rand_seq = alu_random_seq::type_id::create("rand_seq");
      rand_seq.n_items = n_items;
      rand_seq.start(env.agent.seqr);

      phase.drop_objection(this);
    endtask
  endclass

  // Full coverage-closure run: every sequence, weighted toward the
  // hard-to-reach bins.
  class alu_full_test extends alu_base_test;
    `uvm_component_utils(alu_full_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      alu_corner_seq corner;
      alu_shift_seq  shift;
      alu_branch_seq branch;
      alu_random_seq rand_seq;

      // Drain time: the monitor samples on negedge, one half-cycle after the
      // driver drives on posedge. Without a drain interval the final
      // transaction is driven, the objection drops, and simulation ends
      // before the monitor ever sees it - so it is never scored.
      phase.get_objection().set_drain_time(this, 100ns);
      phase.raise_objection(this);

      corner = alu_corner_seq::type_id::create("corner");
      corner.start(env.agent.seqr);

      shift = alu_shift_seq::type_id::create("shift");
      shift.n_items = n_items / 4;
      shift.start(env.agent.seqr);

      branch = alu_branch_seq::type_id::create("branch");
      branch.n_items = n_items / 4;
      branch.start(env.agent.seqr);

      rand_seq = alu_random_seq::type_id::create("rand_seq");
      rand_seq.n_items = n_items;
      rand_seq.start(env.agent.seqr);

      phase.drop_objection(this);
    endtask
  endclass

endpackage
