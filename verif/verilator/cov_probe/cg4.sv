// cg4.sv — where can a covergroup live under Verilator and still accumulate?
//
// WHY THIS FILE EXISTS
// ====================
// ADR-0006 dropped functional coverage from PROJECT_CONTEXT section 5.3 on the
// strength of a three-file probe called cg3.sv:
//
//     module-scope inst = 100.00%
//     class-scope  inst =   0.00%
//
// cg3.sv is NOT IN THE REPO. Those numbers are recorded in ADR-0006 and in the
// section 9 ledger, but the source that produced them is gone, so the single
// most consequential tool limitation in this project rested on a measurement
// that could not be re-run. Section 5.3: a result that cannot be reproduced is
// not reported.
//
// This file replaces cg3 and answers the open question at the same time.
//
// THE OPEN QUESTION
// =================
// Class scope is UVM's idiom - every coverage collector declares its covergroup
// inside a uvm_subscriber - which is why the class-scope failure cost every
// environment its functional coverage. But virtual interfaces are ALSO a UVM
// idiom: every component already reaches the DUT through one.
//
// So: does a covergroup declared in an INTERFACE accumulate when sampled from
// class context through a virtual interface handle? If it does, the collectors
// can re-host their covergroups in the interface - a mechanical change, not an
// architectural one - and section 5.3 gets its metric back.
//
// EXPERIMENT DESIGN
// =================
// Three covergroups, ONE variable: where the covergroup is declared.
//   - identical coverpoint (4-bit value, 16 explicit bins)
//   - identical stimulus (the same 16 values, in the same order)
//   - identical sampling (explicit .sample(), no clocked @(posedge))
//   - identical option.per_instance
//
// The first two reproduce cg3 as CONTROLS. If they do not match ADR-0006, the
// third result is uninterpretable and the ADR needs revisiting rather than the
// section 5.3 row.
//
// NO UVM, deliberately, exactly as cg3 had none. Whether this works through a
// uvm_subscriber is a SECOND question; testing both at once would make a
// failure unattributable.
//
// Explicit .sample() rather than a clocked covergroup because that is what a
// UVM collector does - it samples on a transaction, not on an edge. Using an
// edge-triggered covergroup here would test a shape the environments do not
// use.

`timescale 1ns/1ps

// ---------------------------------------------------------------- SCOPE C
// The measurement. A covergroup declared in an interface, reached from a class
// through a virtual interface handle.
interface cov_if;
  logic [3:0] val;

  covergroup cg_iface;
    option.per_instance = 1;
    cp_val: coverpoint val { bins b[16] = {[0:15]}; }
  endgroup

  cg_iface ci = new();
endinterface


// ---------------------------------------------------------------- SCOPE B
// Negative control. cg3 measured this at 0.00%.
class cls_sampler;
  logic [3:0] cval;

  covergroup cg_cls;
    option.per_instance = 1;
    cp_val: coverpoint cval { bins b[16] = {[0:15]}; }
  endgroup

  virtual cov_if vif;

  function new(virtual cov_if v);
    cg_cls = new();
    vif    = v;
  endfunction

  // Drives and samples BOTH the class-scope covergroup and, through the
  // virtual interface, the interface-scope one. Same call site, same value,
  // same instant - so the two results differ only in where the covergroup is
  // declared.
  function void feed(logic [3:0] v);
    cval        = v;
    vif.val     = v;
    cg_cls.sample();
    vif.ci.sample();
  endfunction
endclass


module cg4;

  // -------------------------------------------------------------- SCOPE A
  // Positive control. cg3 measured this at 100.00%.
  logic [3:0] mval;

  covergroup cg_mod;
    option.per_instance = 1;
    cp_val: coverpoint mval { bins b[16] = {[0:15]}; }
  endgroup

  cg_mod cm = new();

  cov_if u_if ();

  cls_sampler cs;

  real a, b, c;

  initial begin
    cs = new(u_if);

    for (int i = 0; i < 16; i++) begin
      mval = i[3:0];
      cm.sample();        // scope A - module
      cs.feed(i[3:0]);    // scope B - class, and scope C - interface
    end

    a = cm.get_inst_coverage();
    b = cs.cg_cls.get_inst_coverage();
    c = u_if.ci.get_inst_coverage();

    $display("");
    $display("=========== cg4 covergroup scope probe ===========");
    $display("  16 values sampled into each, identical coverpoint");
    $display("");
    $display("  A  module scope                  %6.2f %%   (cg3: 100.00, control)", a);
    $display("  B  class scope                   %6.2f %%   (cg3:   0.00, control)", b);
    $display("  C  interface via virtual iface   %6.2f %%   <-- THE MEASUREMENT", c);
    $display("");

    if (a < 99.99 || b > 0.01) begin
      $display("  CONTROLS DID NOT REPRODUCE ADR-0006.");
      $display("  The scope C result is uninterpretable; revisit the ADR.");
    end else if (c > 99.99) begin
      $display("  RESULT: interface-scope covergroups DO accumulate.");
      $display("  Functional coverage is recoverable by re-hosting the");
      $display("  collectors' covergroups in the interface. Section 5.3");
      $display("  regains the metric. Next question: does it still work when");
      $display("  the sampling call comes from a uvm_subscriber?");
    end else if (c < 0.01) begin
      $display("  RESULT: interface-scope covergroups DO NOT accumulate either.");
      $display("  Functional coverage is permanently unavailable under this");
      $display("  Verilator. Section 5.3 drops the metric rather than leaving");
      $display("  it under investigation, and the vplan's traceability is");
      $display("  closed as waived rather than pending.");
    end else begin
      $display("  RESULT: PARTIAL (%0.2f %%). Neither outcome. Investigate -", c);
      $display("  a partial figure means some bins registered and others did");
      $display("  not, which neither hypothesis predicts.");
    end
    $display("==================================================");
    $display("");
    $finish;
  end

endmodule
