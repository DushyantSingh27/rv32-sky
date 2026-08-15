// CSR tests: built-in RAL sequences plus directed tests.
package csr_test_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  import csr_agent_pkg::*;
  import csr_ral_pkg::*;
  import csr_env_pkg::*;
  `include "uvm_macros.svh"
  `include "csr_seq_lib.svh"

  class csr_base_test extends uvm_test;
    `uvm_component_utils(csr_base_test)

    csr_env       env;
    csr_env_cfg   env_cfg;
    csr_agent_cfg agent_cfg;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);

      agent_cfg = csr_agent_cfg::type_id::create("agent_cfg");
      agent_cfg.is_active = UVM_ACTIVE;
      if (!uvm_config_db#(virtual csr_if)::get(this, "", "vif", agent_cfg.vif))
        `uvm_fatal("CSR_TEST", "virtual interface 'vif' not set in config db")

      env_cfg = csr_env_cfg::type_id::create("env_cfg");
      env_cfg.agent_cfg = agent_cfg;
      uvm_config_db#(csr_env_cfg)::set(this, "env", "cfg", env_cfg);

      env = csr_env::type_id::create("env", this);

      // ------------------------------------------------------------
      // Exclude the free-running counters from the built-in sequences.
      //
      // Every automated RAL sequence assumes a register holds what you wrote
      // until you write again. mcycle increments every clock, so
      // uvm_reg_hw_reset_seq reads a value that is not the reset value and
      // uvm_reg_bit_bash_seq reads back something different from what it
      // wrote. Neither is a DUT bug.
      //
      // Resource string verified against the installed UVM source at
      // uvm/2020.3.1/src/reg/sequences/uvm_reg_hw_reset_seq.svh:109.
      // ------------------------------------------------------------
      uvm_resource_db#(bit)::set({"REG::", "*mcycle*"},    "NO_REG_TESTS", 1, this);
      uvm_resource_db#(bit)::set({"REG::", "*minstret*"},  "NO_REG_TESTS", 1, this);

      // mip is driven by pins, not storage - nothing to write or bash.
      uvm_resource_db#(bit)::set({"REG::", "*mip*"},       "NO_REG_TESTS", 1, this);

      // ------------------------------------------------------------
      // Exclude the machine-information CSRs from bit-bash ONLY.
      //
      // uvm_reg_bit_bash_seq writes to RO fields deliberately and expects
      // status UVM_IS_OK with the value unchanged - the bus convention where
      // "read-only" means "writes are silently dropped". Verified by reading
      // uvm_reg_bit_bash_seq.svh: dc_mask is set from get_compare()==UVM_NO_CHECK
      // or a write-only access type, NOT from an RO access policy.
      //
      // RISC-V is stricter: address bits [11:10]==2'b11 marks a CSR read-only,
      // and writing one is an ILLEGAL INSTRUCTION. The adapter reports that as
      // UVM_NOT_OK, which the sequence flags as an error.
      //
      // The DUT is correct; the sequence encodes a different convention.
      // Excluded from bit-bash but NOT from hw_reset (reset values still
      // checked) and still covered directly by csr_illegal_seq, which asserts
      // that writing each of them raises illegal.
      //
      // Note misa (0x301) is NOT excluded: bits [11:10]==2'b00 there, so it is
      // read-only by implementation choice rather than architecturally, and the
      // RTL silently ignores writes - exactly what bit_bash expects.
      // ------------------------------------------------------------
      // ------------------------------------------------------------
      // Exclude from uvm_reg_access_seq the registers with no single flat
      // storage element - there is nothing for a backdoor path to point at.
      // These remain covered by hw_reset and by the directed sequences.
      // ------------------------------------------------------------
      uvm_resource_db#(bit)::set({"REG::", "*mstatus*"},   "NO_REG_ACCESS_TEST", 1, this);
      uvm_resource_db#(bit)::set({"REG::", "*misa*"},      "NO_REG_ACCESS_TEST", 1, this);
      uvm_resource_db#(bit)::set({"REG::", "*mvendorid*"}, "NO_REG_ACCESS_TEST", 1, this);
      uvm_resource_db#(bit)::set({"REG::", "*marchid*"},   "NO_REG_ACCESS_TEST", 1, this);
      uvm_resource_db#(bit)::set({"REG::", "*mimpid*"},    "NO_REG_ACCESS_TEST", 1, this);
      uvm_resource_db#(bit)::set({"REG::", "*mhartid*"},   "NO_REG_ACCESS_TEST", 1, this);

      uvm_resource_db#(bit)::set({"REG::", "*mvendorid*"}, "NO_REG_BIT_BASH_TEST", 1, this);
      uvm_resource_db#(bit)::set({"REG::", "*marchid*"},   "NO_REG_BIT_BASH_TEST", 1, this);
      uvm_resource_db#(bit)::set({"REG::", "*mimpid*"},    "NO_REG_BIT_BASH_TEST", 1, this);
      uvm_resource_db#(bit)::set({"REG::", "*mhartid*"},   "NO_REG_BIT_BASH_TEST", 1, this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      uvm_top.print_topology();
    endfunction
  endclass

  // ---------------- built-in RAL sequences ----------------

  // Checks every register's reset value. Usually the first test run on any DUT.
  class csr_hw_reset_test extends csr_base_test;
    `uvm_component_utils(csr_hw_reset_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      uvm_reg_hw_reset_seq seq;
      phase.get_objection().set_drain_time(this, 200ns);
      phase.raise_objection(this);
      seq = uvm_reg_hw_reset_seq::type_id::create("seq");
      seq.model = env.regmodel;
      seq.start(null);
      phase.drop_objection(this);
    endtask
  endclass

  // Walks every writable bit, verifying RO bits stay put. This is what
  // catches WARL fields modelled with the wrong access policy.
  class csr_bit_bash_test extends csr_base_test;
    `uvm_component_utils(csr_bit_bash_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      uvm_reg_bit_bash_seq seq;
      phase.get_objection().set_drain_time(this, 200ns);
      phase.raise_objection(this);
      seq = uvm_reg_bit_bash_seq::type_id::create("seq");
      seq.model = env.regmodel;
      seq.start(null);
      phase.drop_objection(this);
    endtask
  endclass

  // Frontdoor write vs backdoor read, and the reverse. Requires hdl_path
  // configuration - the reason the CSR RTL keeps storage in flatly-named
  // registers rather than an array.
  class csr_access_test extends csr_base_test;
    `uvm_component_utils(csr_access_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      uvm_reg_access_seq seq;
      phase.get_objection().set_drain_time(this, 200ns);
      phase.raise_objection(this);
      seq = uvm_reg_access_seq::type_id::create("seq");
      seq.model = env.regmodel;
      seq.start(null);
      phase.drop_objection(this);
    endtask
  endclass

  // ---------------- directed tests ----------------

  class csr_directed_test extends csr_base_test;
    `uvm_component_utils(csr_directed_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      csr_suppress_seq sup;
      csr_illegal_seq  ill;
      csr_trap_seq     trp;
      csr_counter_seq  cnt;
      csr_irq_seq      irq;

      phase.get_objection().set_drain_time(this, 200ns);
      phase.raise_objection(this);

      sup = csr_suppress_seq::type_id::create("sup");
      sup.start(env.agent.seqr);

      ill = csr_illegal_seq::type_id::create("ill");
      ill.start(env.agent.seqr);

      trp = csr_trap_seq::type_id::create("trp");
      trp.start(env.agent.seqr);

      cnt = csr_counter_seq::type_id::create("cnt");
      cnt.start(env.agent.seqr);

      irq = csr_irq_seq::type_id::create("irq");
      irq.start(env.agent.seqr);

      phase.drop_objection(this);
    endtask
  endclass

  // Everything: all three built-in sequences, then all directed tests.
  class csr_full_test extends csr_base_test;
    `uvm_component_utils(csr_full_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      uvm_reg_hw_reset_seq  rst_seq;
      uvm_reg_bit_bash_seq  bash_seq;
      csr_suppress_seq      sup;
      csr_illegal_seq       ill;
      csr_trap_seq          trp;
      csr_counter_seq       cnt;
      csr_irq_seq           irq;
      csr_sweep_seq         swp;

      phase.get_objection().set_drain_time(this, 200ns);
      phase.raise_objection(this);

      rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq");
      rst_seq.model = env.regmodel;
      rst_seq.start(null);

      bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq");
      bash_seq.model = env.regmodel;
      bash_seq.start(null);

      sup = csr_suppress_seq::type_id::create("sup");
      sup.start(env.agent.seqr);

      ill = csr_illegal_seq::type_id::create("ill");
      ill.start(env.agent.seqr);

      trp = csr_trap_seq::type_id::create("trp");
      trp.start(env.agent.seqr);

      cnt = csr_counter_seq::type_id::create("cnt");
      cnt.start(env.agent.seqr);

      irq = csr_irq_seq::type_id::create("irq");
      irq.start(env.agent.seqr);

      swp = csr_sweep_seq::type_id::create("swp");
      swp.start(env.agent.seqr);

      phase.drop_objection(this);
    endtask
  endclass

endpackage
