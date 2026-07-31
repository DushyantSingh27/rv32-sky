// M0 gate: testbench top. No DUT - this proves the UVM library links,
// phasing runs, the factory works, and coverage is collected.
module m0_smoke_tb_top;

  import uvm_pkg::*;
  import m0_smoke_pkg::*;
  `include "uvm_macros.svh"

  int unsigned n_items = 8;

  initial begin
    void'($value$plusargs("N_ITEMS=%d", n_items));
    uvm_config_db#(int unsigned)::set(null, "*", "n_items", n_items);
    run_test("m0_smoke_test");
  end

endmodule
