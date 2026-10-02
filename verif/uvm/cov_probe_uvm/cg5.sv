// cg5.sv — does the interface-scope covergroup still accumulate when the
//          sampling call comes from a uvm_subscriber?
//
// cg4 (2026-09-29) measured, with no UVM involved:
//     A  module scope                  100.00 %
//     B  class scope                     0.00 %
//     C  interface via virtual iface   100.00 %
//
// C is the result that would give section 5.3 its functional coverage back.
// But cg4 had no UVM in it, deliberately - one variable at a time. Every real
// collector in this project declares its covergroup inside a uvm_subscriber,
// which is UVM's required idiom, and that is the shape that has to work.
//
// A uvm_subscriber IS a class, and the covergroup now lives outside it, so
// this SHOULD behave exactly as cg4's scope C did. "Should" is what
// PROJECT_INSTRUCTIONS 2.4 exists to stop: five wrong hypotheses on one M3.2
// bug, four wrong fixes on the M3.5 branch squash.
//
// EXPERIMENT DESIGN
// =================
// Same three scopes as cg4, so the two files are directly comparable, and the
// only difference between them is that the sampling now happens inside a real
// UVM component reached through uvm_config_db, driven over an analysis port.
//
//   A  module scope, in tb_top              - control, cg4 read 100.00
//   B  class scope, inside the subscriber   - control, cg4 read 0.00
//   C  interface scope, sampled via vif     - the measurement, cg4 read 100.00
//
// Identical coverpoint, identical 16-value stimulus, identical explicit
// .sample() calls from the same call site at the same instant. If A and B do
// not reproduce cg4, C is uninterpretable and the difference is UVM itself
// rather than the covergroup's scope.
//
// The analysis port is used rather than calling write() directly: it costs
// nothing and makes the path identical to a real collector's.

`timescale 1ns/1ps

// ---------------------------------------------------------------------- C
interface cov_if;
  logic [3:0] val;

  covergroup cg_iface;
    option.per_instance = 1;
    cp_val: coverpoint val { bins b[16] = {[0:15]}; }
  endgroup

  cg_iface ci = new();
endinterface


package cg5_pkg;

  import uvm_pkg::*;
`include "uvm_macros.svh"

  // ------------------------------------------------------------------ B + C
  // A real uvm_subscriber, exactly as every coverage collector in this project
  // is written. It holds BOTH covergroups so the two are sampled from the same
  // call site with the same value - the only difference between them is where
  // each is declared.
  class cg5_collector extends uvm_subscriber #(int);
    `uvm_component_utils(cg5_collector)

    virtual cov_if vif;
    logic [3:0]    cval;

    covergroup cg_cls;
      option.per_instance = 1;
      cp_val: coverpoint cval { bins b[16] = {[0:15]}; }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg_cls = new();
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db #(virtual cov_if)::get(this, "", "vif", vif))
        `uvm_fatal("CG5", "no virtual interface in the config DB")
    endfunction

    // The subscriber's analysis write. A real collector samples a transaction
    // here; this one samples an int, which is the same shape with the DUT
    // removed.
    function void write(int t);
      cval    = t[3:0];
      vif.val = t[3:0];
      cg_cls.sample();      // scope B - inside this class
      vif.ci.sample();      // scope C - in the interface, through the vif
    endfunction

    function real cls_cov();   return cg_cls.get_inst_coverage();   endfunction
    function real iface_cov(); return vif.ci.get_inst_coverage();   endfunction
  endclass


  class cg5_test extends uvm_test;
    `uvm_component_utils(cg5_test)

    cg5_collector            col;
    uvm_analysis_port #(int) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      col = cg5_collector::type_id::create("col", this);
      ap  = new("ap", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      ap.connect(col.analysis_export);
    endfunction

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      for (int i = 0; i < 16; i++) ap.write(i);
      #1;
      phase.drop_objection(this);
    endtask

    // Reported from the test rather than printed inline, so the numbers appear
    // after UVM's own end-of-test output rather than buried in it.
    function void report_phase(uvm_phase phase);
      real a, b, c;
      super.report_phase(phase);
      a = cg5_tb_top.cm.get_inst_coverage();
      b = col.cls_cov();
      c = col.iface_cov();

      $display("");
      $display("======== cg5 covergroup scope probe, UNDER UVM ========");
      $display("  16 values through an analysis port into a uvm_subscriber");
      $display("");
      $display("  A  module scope                  %6.2f %%   (cg4: 100.00, control)", a);
      $display("  B  class scope, in subscriber    %6.2f %%   (cg4:   0.00, control)", b);
      $display("  C  interface via virtual iface   %6.2f %%   (cg4: 100.00) <-- MEASUREMENT", c);
      $display("");

      if (a < 99.99 || b > 0.01) begin
        $display("  CONTROLS DID NOT REPRODUCE cg4.");
        $display("  The difference is UVM itself, not the covergroup's scope.");
        $display("  C is uninterpretable; investigate before changing 5.3.");
      end else if (c > 99.99) begin
        $display("  RESULT: CONFIRMED under UVM.");
        $display("  Interface-scope covergroups accumulate when sampled from a");
        $display("  uvm_subscriber. Functional coverage is recoverable by");
        $display("  re-hosting each collector's covergroup in a coverage");
        $display("  interface. Section 5.3 regains the metric.");
      end else if (c < 0.01) begin
        $display("  RESULT: DOES NOT SURVIVE UVM.");
        $display("  cg4's scope C worked without UVM and fails with it, so the");
        $display("  limitation is not simply about class scope. Functional");
        $display("  coverage stays unavailable and cg4's result does not");
        $display("  generalise to the collectors.");
      end else begin
        $display("  RESULT: PARTIAL (%0.2f %%). Neither outcome - investigate.", c);
      end
      $display("=======================================================");
      $display("");
    endfunction
  endclass

endpackage


module cg5_tb_top;

  import uvm_pkg::*;
`include "uvm_macros.svh"
  import cg5_pkg::*;

  // ------------------------------------------------------------------ A
  logic [3:0] mval;

  covergroup cg_mod;
    option.per_instance = 1;
    cp_val: coverpoint mval { bins b[16] = {[0:15]}; }
  endgroup

  cg_mod cm = new();

  cov_if u_if ();

  initial begin
    // Module-scope control, sampled before the UVM phases so it is complete
    // and independent of anything UVM does.
    for (int i = 0; i < 16; i++) begin
      mval = i[3:0];
      cm.sample();
    end

    uvm_config_db #(virtual cov_if)::set(null, "*", "vif", u_if);
    run_test("cg5_test");
  end

endmodule
