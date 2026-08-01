// M0 gate: UVM hello-world with functional coverage.
// Simulator-agnostic by construction - PROJECT_INSTRUCTIONS 4.4 portability rules.
// No vendor pragmas, no simulator ifdefs.
package m0_smoke_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  class m0_item extends uvm_sequence_item;
    rand bit [3:0] value;

    `uvm_object_utils_begin(m0_item)
      `uvm_field_int(value, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "m0_item");
      super.new(name);
    endfunction
  endclass

  class m0_cov extends uvm_component;
    `uvm_component_utils(m0_cov)

    bit [3:0] sampled;

    covergroup cg;
      // merge_instances=1 makes cross-run/cross-instance bin counts accumulate
      // into a single type-level result. Without it, type coverage is the
      // weighted AVERAGE of instances, which makes seed sweeps useless.
      type_option.merge_instances = 1;
      option.per_instance = 1;
      cp_value: coverpoint sampled {
        bins b[16] = {[0:15]};
      }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg = new();
    endfunction

    function void sample_value(bit [3:0] v);
      sampled = v;
      cg.sample();
    endfunction
  endclass

  class m0_smoke_test extends uvm_test;
    `uvm_component_utils(m0_smoke_test)

    m0_cov       cov;
    int unsigned n_items = 8;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      // Config via uvm_config_db, never hard-coded paths (4.4).
      void'(uvm_config_db#(int unsigned)::get(this, "", "n_items", n_items));
      cov = m0_cov::type_id::create("cov", this);
    endfunction

    task run_phase(uvm_phase phase);
      m0_item it;
      phase.raise_objection(this);

      `uvm_info("M0", $sformatf("UVM hello-world starting, n_items=%0d", n_items), UVM_LOW)
      `uvm_info("M0", $sformatf("UVM version reported: %s", uvm_revision_string()), UVM_LOW)

      for (int i = 0; i < n_items; i++) begin
        it = m0_item::type_id::create($sformatf("it_%0d", i));
        if (!it.randomize())
          `uvm_fatal("M0", $sformatf("randomize() failed on item %0d", i))
        cov.sample_value(it.value);
        `uvm_info("M0", $sformatf("item %0d value=%0d", i, it.value), UVM_MEDIUM)
      end

      `uvm_info("M0", $sformatf("instance coverage this run = %0.2f%%",
                                cov.cg.get_inst_coverage()), UVM_LOW)
      `uvm_info("M0", $sformatf("type coverage (merged) = %0.2f%%",
                                cov.cg.get_coverage()), UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass

endpackage
