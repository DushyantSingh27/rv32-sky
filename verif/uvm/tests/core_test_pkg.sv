// Full-core tests (env 7).
//
// The test reads the program image itself. The hex file is the same one the
// TCM loads via +HEX=, so the monitor's instruction lookup and the DUT's
// memory are guaranteed to agree - they come from one file.
package core_test_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  import core_agent_pkg::*;
  import core_env_pkg::*;
  `include "uvm_macros.svh"

  class core_base_test extends uvm_test;
    `uvm_component_utils(core_base_test)

    core_env       env;
    core_env_cfg   env_cfg;
    core_agent_cfg agent_cfg;
    string         hexfile;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // Read the hex image into a dynamic array. One word per line, hex, as
    // produced by `od -An -tx4 -v -w4` in sw/tests/build.sh.
    function int unsigned load_image(string path, ref logic [31:0] img []);
      int fd, code, n;
      logic [31:0] word;
      logic [31:0] tmp [$];
      fd = $fopen(path, "r");
      if (fd == 0) begin
        `uvm_fatal("CORE_TEST", $sformatf("cannot open hex image '%s'", path))
        return 0;
      end
      forever begin
        code = $fscanf(fd, "%h\n", word);
        if (code != 1) break;
        tmp.push_back(word);
      end
      $fclose(fd);
      n = tmp.size();
      img = new[n];
      foreach (tmp[i]) img[i] = tmp[i];
      return n;
    endfunction

    function void build_phase(uvm_phase phase);
      int unsigned n;
      super.build_phase(phase);

      if (!$value$plusargs("HEX=%s", hexfile))
        `uvm_fatal("CORE_TEST", "no +HEX= given - nothing to run")

      agent_cfg = core_agent_cfg::type_id::create("agent_cfg");
      agent_cfg.is_active = UVM_PASSIVE;
      if (!uvm_config_db#(virtual core_if)::get(this, "", "vif", agent_cfg.vif))
        `uvm_fatal("CORE_TEST", "virtual interface 'vif' not set in config db")

      n = load_image(hexfile, agent_cfg.image);
      if (n == 0)
        `uvm_fatal("CORE_TEST", "hex image is empty")
      `uvm_info("CORE_TEST",
        $sformatf("loaded %0d words from %s", n, hexfile), UVM_LOW)

      env_cfg = core_env_cfg::type_id::create("env_cfg");
      env_cfg.agent_cfg   = agent_cfg;
      env_cfg.image_words = n;
      uvm_config_db#(core_env_cfg)::set(this, "env", "cfg", env_cfg);

      env = core_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      uvm_top.print_topology();
    endfunction
  endclass

  // Runs until the program stores to the test-control address, or the cycle
  // budget expires. There is no stimulus to sequence - the program IS the
  // stimulus - so the run phase only holds the objection open and watches for
  // termination.
  class core_run_test extends core_base_test;
    `uvm_component_utils(core_run_test)

    int unsigned max_cycles = 20000;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      int unsigned cyc = 0;
      void'($value$plusargs("MAX_CYCLES=%d", max_cycles));

      // Drain time: the monitor samples on negedge, so the final retirement
      // is observed half a cycle after the terminating store is seen.
      phase.get_objection().set_drain_time(this, 200ns);
      phase.raise_objection(this);

      wait (env.agent.cfg.vif.rst_n === 1'b1);

      while (cyc < max_cycles) begin
        @(env.agent.cfg.vif.mon_cb);
        cyc++;
        if (env.agent.cfg.vif.mon_cb.testctl_we) begin
          `uvm_info("CORE_TEST",
            $sformatf("program terminated at cycle %0d, stored 0x%08h",
                      cyc, env.agent.cfg.vif.mon_cb.testctl_data), UVM_LOW)
          // Stop the monitor before the halt loop retires anything.
          agent_cfg.done = 1'b1;
          break;
        end
      end

      if (cyc >= max_cycles)
        `uvm_error("CORE_TEST",
          $sformatf("TIMEOUT after %0d cycles with no store to test control", max_cycles))

      phase.drop_objection(this);
    endtask
  endclass

endpackage
