// UVM RAL model for the M-mode CSR block.
//
// Field access policies encode the SPEC, not the implementation:
//   RW  - fully read-write
//   RO  - reads a fixed value, writes have no effect on the read-back
//
// WARL fields (mtvec.MODE, mepc[0], mstatus.MPP) are modelled RO because from
// the register model's point of view that is what they behave like: any write
// is accepted by the bus but the read-back is fixed. Modelling them RW would
// make uvm_reg_bit_bash_seq write a 1 and expect to read a 1 back, which is
// exactly the failure the spec mandates.
package csr_ral_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ---------------- simple fully-RW 32-bit CSRs ----------------
  class csr_reg_rw extends uvm_reg;
    `uvm_object_utils(csr_reg_rw)
    rand uvm_reg_field value;

    function new(string name = "csr_reg_rw");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      value = uvm_reg_field::type_id::create("value");
      value.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 1);
    endfunction
  endclass

  // ---------------- read-only CSRs ----------------
  class csr_reg_ro extends uvm_reg;
    `uvm_object_utils(csr_reg_ro)
    rand uvm_reg_field value;
    protected uvm_reg_data_t m_reset;

    function new(string name = "csr_reg_ro");
      super.new(name, 32, UVM_NO_COVERAGE);
      m_reset = 32'h0;
    endfunction

    function void set_reset_value(uvm_reg_data_t v);
      m_reset = v;
    endfunction

    virtual function void build();
      value = uvm_reg_field::type_id::create("value");
      value.configure(this, 32, 0, "RO", 0, m_reset, 1, 0, 1);
    endfunction
  endclass

  // ---------------- mstatus ----------------
  // Only MIE [3], MPIE [7] and MPP [12:11] are implemented. MPP is WARL and
  // always reads 2'b11, so it is modelled RO with that reset value.
  class csr_reg_mstatus extends uvm_reg;
    `uvm_object_utils(csr_reg_mstatus)
    rand uvm_reg_field rsvd0;   // [2:0]
    rand uvm_reg_field mie;     // [3]
    rand uvm_reg_field rsvd1;   // [6:4]
    rand uvm_reg_field mpie;    // [7]
    rand uvm_reg_field rsvd2;   // [10:8]
    rand uvm_reg_field mpp;     // [12:11] WARL, reads 2'b11
    rand uvm_reg_field rsvd3;   // [31:13]

    function new(string name = "csr_reg_mstatus");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      rsvd0 = uvm_reg_field::type_id::create("rsvd0");
      mie   = uvm_reg_field::type_id::create("mie");
      rsvd1 = uvm_reg_field::type_id::create("rsvd1");
      mpie  = uvm_reg_field::type_id::create("mpie");
      rsvd2 = uvm_reg_field::type_id::create("rsvd2");
      mpp   = uvm_reg_field::type_id::create("mpp");
      rsvd3 = uvm_reg_field::type_id::create("rsvd3");

      rsvd0.configure(this,  3,  0, "RO", 0, 3'h0,  1, 0, 1);
      mie  .configure(this,  1,  3, "RW", 0, 1'b0,  1, 1, 1);
      rsvd1.configure(this,  3,  4, "RO", 0, 3'h0,  1, 0, 1);
      mpie .configure(this,  1,  7, "RW", 0, 1'b0,  1, 1, 1);
      rsvd2.configure(this,  3,  8, "RO", 0, 3'h0,  1, 0, 1);
      mpp  .configure(this,  2, 11, "RO", 0, 2'b11, 1, 0, 1);
      rsvd3.configure(this, 19, 13, "RO", 0, 19'h0, 1, 0, 1);
    endfunction
  endclass

  // ---------------- mtvec ----------------
  // MODE [1:0] is WARL, direct mode only, always reads 0.
  class csr_reg_mtvec extends uvm_reg;
    `uvm_object_utils(csr_reg_mtvec)
    rand uvm_reg_field mode;   // [1:0]
    rand uvm_reg_field base;   // [31:2]

    function new(string name = "csr_reg_mtvec");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      mode = uvm_reg_field::type_id::create("mode");
      base = uvm_reg_field::type_id::create("base");
      mode.configure(this,  2, 0, "RO", 0, 2'b00, 1, 0, 1);
      base.configure(this, 30, 2, "RW", 0, 30'h0, 1, 1, 1);
    endfunction
  endclass

  // ---------------- mepc ----------------
  // Bit 0 is WARL and reads 0 (IALIGN=16 with the C extension).
  class csr_reg_mepc extends uvm_reg;
    `uvm_object_utils(csr_reg_mepc)
    rand uvm_reg_field lsb;    // [0]
    rand uvm_reg_field addr;   // [31:1]

    function new(string name = "csr_reg_mepc");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      lsb  = uvm_reg_field::type_id::create("lsb");
      addr = uvm_reg_field::type_id::create("addr");
      lsb .configure(this,  1, 0, "RO", 0, 1'b0,  1, 0, 1);
      addr.configure(this, 31, 1, "RW", 0, 31'h0, 1, 1, 1);
    endfunction
  endclass

  // ---------------- register block ----------------
  class csr_reg_block extends uvm_reg_block;
    `uvm_object_utils(csr_reg_block)

    rand csr_reg_mstatus mstatus;
    rand csr_reg_ro      misa;
    rand csr_reg_rw      mie;
    rand csr_reg_mtvec   mtvec;
    rand csr_reg_ro      mstatush;
    rand csr_reg_rw      mscratch;
    rand csr_reg_mepc    mepc;
    rand csr_reg_rw      mcause;
    rand csr_reg_rw      mtval;
    rand csr_reg_ro      mip;
    rand csr_reg_rw      mcycle;
    rand csr_reg_rw      minstret;
    rand csr_reg_rw      mcycleh;
    rand csr_reg_rw      minstreth;
    rand csr_reg_ro      mvendorid;
    rand csr_reg_ro      marchid;
    rand csr_reg_ro      mimpid;
    rand csr_reg_ro      mhartid;

    uvm_reg_map csr_map;

    function new(string name = "csr_reg_block");
      super.new(name, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      // MISA reports MXL=1 (RV32) with extensions C, I, M.
      uvm_reg_data_t misa_val = 32'h4000_1104;

      csr_map = create_map("csr_map", 'h0, 4, UVM_LITTLE_ENDIAN, 0);

      mstatus = csr_reg_mstatus::type_id::create("mstatus");
      mstatus.configure(this, null, "mstatus_q");
      mstatus.build();
      csr_map.add_reg(mstatus, 32'h300, "RW");

      misa = csr_reg_ro::type_id::create("misa");
      misa.set_reset_value(misa_val);
      misa.configure(this, null, "");
      misa.build();
      csr_map.add_reg(misa, 32'h301, "RO");

      mie = csr_reg_rw::type_id::create("mie");
      mie.configure(this, null, "mie_q");
      mie.build();
      csr_map.add_reg(mie, 32'h304, "RW");

      mtvec = csr_reg_mtvec::type_id::create("mtvec");
      mtvec.configure(this, null, "mtvec_q");
      mtvec.build();
      csr_map.add_reg(mtvec, 32'h305, "RW");

      mstatush = csr_reg_ro::type_id::create("mstatush");
      mstatush.configure(this, null, "");
      mstatush.build();
      csr_map.add_reg(mstatush, 32'h310, "RO");

      mscratch = csr_reg_rw::type_id::create("mscratch");
      mscratch.configure(this, null, "mscratch_q");
      mscratch.build();
      csr_map.add_reg(mscratch, 32'h340, "RW");

      mepc = csr_reg_mepc::type_id::create("mepc");
      mepc.configure(this, null, "mepc_q");
      mepc.build();
      csr_map.add_reg(mepc, 32'h341, "RW");

      mcause = csr_reg_rw::type_id::create("mcause");
      mcause.configure(this, null, "mcause_q");
      mcause.build();
      csr_map.add_reg(mcause, 32'h342, "RW");

      mtval = csr_reg_rw::type_id::create("mtval");
      mtval.configure(this, null, "mtval_q");
      mtval.build();
      csr_map.add_reg(mtval, 32'h343, "RW");

      mip = csr_reg_ro::type_id::create("mip");
      mip.configure(this, null, "");
      mip.build();
      csr_map.add_reg(mip, 32'h344, "RO");

      mcycle = csr_reg_rw::type_id::create("mcycle");
      mcycle.configure(this, null, "");
      mcycle.build();
      csr_map.add_reg(mcycle, 32'hB00, "RW");

      minstret = csr_reg_rw::type_id::create("minstret");
      minstret.configure(this, null, "");
      minstret.build();
      csr_map.add_reg(minstret, 32'hB02, "RW");

      mcycleh = csr_reg_rw::type_id::create("mcycleh");
      mcycleh.configure(this, null, "");
      mcycleh.build();
      csr_map.add_reg(mcycleh, 32'hB80, "RW");

      minstreth = csr_reg_rw::type_id::create("minstreth");
      minstreth.configure(this, null, "");
      minstreth.build();
      csr_map.add_reg(minstreth, 32'hB82, "RW");

      mvendorid = csr_reg_ro::type_id::create("mvendorid");
      mvendorid.configure(this, null, "");
      mvendorid.build();
      csr_map.add_reg(mvendorid, 32'hF11, "RO");

      marchid = csr_reg_ro::type_id::create("marchid");
      marchid.configure(this, null, "");
      marchid.build();
      csr_map.add_reg(marchid, 32'hF12, "RO");

      mimpid = csr_reg_ro::type_id::create("mimpid");
      mimpid.configure(this, null, "");
      mimpid.build();
      csr_map.add_reg(mimpid, 32'hF13, "RO");

      mhartid = csr_reg_ro::type_id::create("mhartid");
      mhartid.configure(this, null, "");
      mhartid.build();
      csr_map.add_reg(mhartid, 32'hF14, "RO");

      // ------------------------------------------------------------
      // Backdoor paths into the DUT's storage.
      //
      // Only registers with a single flat storage element get a path. The
      // others deliberately do not, and are excluded from uvm_reg_access_seq
      // in the test:
      //   mip        - combinational from the interrupt pins, no storage
      //   mstatus    - assembled from two separate bits plus constants
      //   mcycle/h,
      //   minstret/h - one 64-bit register split across two CSR addresses
      //   misa, mstatush, and the four info CSRs - constants
      //
      // This is why the RTL keeps storage in flatly-named registers rather
      // than an array: `uvm_hdl_read` resolves a literal hierarchical path,
      // so `mscratch_q` is addressable and `regs[7]` would not be.
      // ------------------------------------------------------------
      add_hdl_path("csr_tb_top.u_csr");

      mie     .add_hdl_path_slice("mie_q",      0, 32);
      mtvec   .add_hdl_path_slice("mtvec_q",    0, 32);
      mscratch.add_hdl_path_slice("mscratch_q", 0, 32);
      mepc    .add_hdl_path_slice("mepc_q",     0, 32);
      mcause  .add_hdl_path_slice("mcause_q",   0, 32);
      mtval   .add_hdl_path_slice("mtval_q",    0, 32);

      lock_model();
    endfunction
  endclass

endpackage
