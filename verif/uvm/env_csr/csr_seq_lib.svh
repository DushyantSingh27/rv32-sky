// CSR directed sequence library.
//
// These cover behaviour the built-in RAL sequences cannot reach: side-channel
// stimulus (traps, mret, interrupts), the read/write suppression rules, and
// the free-running counters excluded from automated testing.

class csr_base_seq extends uvm_sequence #(csr_seq_item);
  `uvm_object_utils(csr_base_seq)

  function new(string name = "csr_base_seq");
    super.new(name);
  endfunction

  task access(logic [11:0] a, csr_op_e o, logic [XLEN-1:0] d,
              logic rd = 1'b1, logic wr = 1'b1);
    csr_seq_item it = csr_seq_item::type_id::create("it");
    start_item(it);
    it.addr = a; it.op = o; it.wdata = d;
    it.do_read = rd; it.do_write = wr;
    it.trap_valid = 1'b0; it.mret = 1'b0;
    it.trap_epc = '0; it.trap_cause = '0; it.trap_tval = '0;
    it.irq_timer = 1'b0; it.irq_software = 1'b0; it.irq_external = 1'b0;
    it.instr_retired = 1'b0;
    finish_item(it);
  endtask

  task idle(int n = 1);
    repeat (n) access(12'h340, CSR_NONE, '0, 1'b0, 1'b0);
  endtask
endclass

// Read and write suppression - the rules a naive design gets wrong.
class csr_suppress_seq extends csr_base_seq;
  `uvm_object_utils(csr_suppress_seq)
  function new(string name = "csr_suppress_seq");
    super.new(name);
  endfunction

  task body();
    `uvm_info(get_type_name(), "read/write suppression", UVM_LOW)

    // Seed mscratch.
    access(12'h340, CSR_RW, 32'hAAAA_5555);

    // WRITE SUPPRESSED: CSRRS with rs1==x0 must not modify, even though the
    // set-mask is non-zero. This is the rule most often implemented as
    // "write the unchanged value", which is observably different.
    access(12'h340, CSR_RS, 32'hFFFF_FFFF, 1'b1, 1'b0);
    access(12'h340, CSR_RS, 32'h0000_0000, 1'b1, 1'b0);   // must read AAAA5555

    // CSRRC with write suppressed - same rule.
    access(12'h340, CSR_RC, 32'hFFFF_FFFF, 1'b1, 1'b0);
    access(12'h340, CSR_RS, 32'h0000_0000, 1'b1, 1'b0);   // still AAAA5555

    // READ SUPPRESSED: rd==x0. rdata must be zero, state untouched.
    access(12'h340, CSR_RW, 32'h1234_5678, 1'b0, 1'b1);
    access(12'h340, CSR_RS, 32'h0000_0000, 1'b1, 1'b0);   // now 12345678

    // Both suppressed - a no-op.
    access(12'h340, CSR_RS, 32'hFFFF_FFFF, 1'b0, 1'b0);
    access(12'h340, CSR_RS, 32'h0000_0000, 1'b1, 1'b0);   // still 12345678

    // Set and clear with write ENABLED, to confirm the ops themselves work.
    access(12'h340, CSR_RW, 32'h0000_00FF);
    access(12'h340, CSR_RS, 32'h0000_FF00);               // -> 0000FFFF
    access(12'h340, CSR_RC, 32'h0000_00F0);               // -> 0000FF0F
    access(12'h340, CSR_RS, 32'h0000_0000, 1'b1, 1'b0);
  endtask
endclass

// Writes to read-only CSRs must raise illegal instruction.
class csr_illegal_seq extends csr_base_seq;
  `uvm_object_utils(csr_illegal_seq)
  function new(string name = "csr_illegal_seq");
    super.new(name);
  endfunction

  task body();
    `uvm_info(get_type_name(), "illegal access", UVM_LOW)
    // addr[11:10] == 2'b11 marks a CSR read-only.
    access(12'hF11, CSR_RW, 32'hDEAD_BEEF);   // mvendorid
    access(12'hF12, CSR_RW, 32'hDEAD_BEEF);   // marchid
    access(12'hF13, CSR_RS, 32'hFFFF_FFFF);   // mimpid
    access(12'hF14, CSR_RC, 32'hFFFF_FFFF);   // mhartid
    access(12'h301, CSR_RW, 32'h0000_0000);   // misa - read-only by choice

    // Reading them is legal.
    access(12'hF11, CSR_RS, '0, 1'b1, 1'b0);
    access(12'hF14, CSR_RS, '0, 1'b1, 1'b0);
    access(12'h301, CSR_RS, '0, 1'b1, 1'b0);

    // Unimplemented address must also be illegal.
    access(12'h3FF, CSR_RW, 32'h1);
    access(12'h7C0, CSR_RS, 32'h1);
  endtask
endclass

// Trap entry, mret, and the priority rule.
class csr_trap_seq extends csr_base_seq;
  `uvm_object_utils(csr_trap_seq)
  function new(string name = "csr_trap_seq");
    super.new(name);
  endfunction

  task trap(logic [XLEN-1:0] epc, cause, tval);
    csr_seq_item it = csr_seq_item::type_id::create("it");
    start_item(it);
    it.addr = 12'h340; it.op = CSR_NONE; it.wdata = '0;
    it.do_read = 1'b0; it.do_write = 1'b0;
    it.trap_valid = 1'b1; it.trap_epc = epc;
    it.trap_cause = cause; it.trap_tval = tval;
    it.mret = 1'b0;
    it.irq_timer = 1'b0; it.irq_software = 1'b0; it.irq_external = 1'b0;
    it.instr_retired = 1'b0;
    finish_item(it);
  endtask

  // A trap arriving in the same cycle as a software CSR write. The trap must
  // win: the return address matters and the instruction is being abandoned.
  // Getting this backwards corrupts mepc under interrupt load, which is
  // close to impossible to debug from software.
  task trap_during_write(logic [XLEN-1:0] epc, logic [11:0] a,
                         logic [XLEN-1:0] d);
    csr_seq_item it = csr_seq_item::type_id::create("it");
    start_item(it);
    it.addr = a; it.op = CSR_RW; it.wdata = d;
    it.do_read = 1'b1; it.do_write = 1'b1;
    it.trap_valid = 1'b1; it.trap_epc = epc;
    it.trap_cause = 32'd11; it.trap_tval = '0;
    it.mret = 1'b0;
    it.irq_timer = 1'b0; it.irq_software = 1'b0; it.irq_external = 1'b0;
    it.instr_retired = 1'b0;
    finish_item(it);
  endtask

  task do_mret();
    csr_seq_item it = csr_seq_item::type_id::create("it");
    start_item(it);
    it.addr = 12'h340; it.op = CSR_NONE; it.wdata = '0;
    it.do_read = 1'b0; it.do_write = 1'b0;
    it.trap_valid = 1'b0; it.mret = 1'b1;
    it.trap_epc = '0; it.trap_cause = '0; it.trap_tval = '0;
    it.irq_timer = 1'b0; it.irq_software = 1'b0; it.irq_external = 1'b0;
    it.instr_retired = 1'b0;
    finish_item(it);
  endtask

  task body();
    `uvm_info(get_type_name(), "trap entry, mret, priority", UVM_LOW)

    // Enable interrupts so MIE/MPIE movement is observable.
    access(12'h300, CSR_RW, 32'h0000_0008);      // mstatus.MIE = 1
    access(12'h300, CSR_RS, '0, 1'b1, 1'b0);

    // Trap: mepc/mcause/mtval captured, MPIE <= MIE, MIE <= 0.
    trap(32'h8000_1234, 32'd11, 32'hCAFE_0000);
    access(12'h341, CSR_RS, '0, 1'b1, 1'b0);     // mepc
    access(12'h342, CSR_RS, '0, 1'b1, 1'b0);     // mcause
    access(12'h343, CSR_RS, '0, 1'b1, 1'b0);     // mtval
    access(12'h300, CSR_RS, '0, 1'b1, 1'b0);     // MIE=0, MPIE=1

    // mret: MIE <= MPIE, MPIE <= 1.
    do_mret();
    access(12'h300, CSR_RS, '0, 1'b1, 1'b0);

    // mepc bit 0 is WARL - an odd epc must read back even.
    trap(32'h8000_1235, 32'd2, 32'd0);
    access(12'h341, CSR_RS, '0, 1'b1, 1'b0);

    // PRIORITY: trap concurrent with a software write to mepc.
    trap_during_write(32'h8000_ABCD, 12'h341, 32'h1111_1111);
    access(12'h341, CSR_RS, '0, 1'b1, 1'b0);     // must be 8000ABCC, not 11111110
  endtask
endclass

// Counters: excluded from the built-in RAL sequences because they change on
// their own. Tested directly instead.
class csr_counter_seq extends csr_base_seq;
  `uvm_object_utils(csr_counter_seq)
  function new(string name = "csr_counter_seq");
    super.new(name);
  endfunction

  task retire(int n);
    repeat (n) begin
      csr_seq_item it = csr_seq_item::type_id::create("it");
      start_item(it);
      it.addr = 12'h340; it.op = CSR_NONE; it.wdata = '0;
      it.do_read = 1'b0; it.do_write = 1'b0;
      it.trap_valid = 1'b0; it.mret = 1'b0;
      it.trap_epc = '0; it.trap_cause = '0; it.trap_tval = '0;
      it.irq_timer = 1'b0; it.irq_software = 1'b0; it.irq_external = 1'b0;
      it.instr_retired = 1'b1;
      finish_item(it);
    end
  endtask

  task body();
    `uvm_info(get_type_name(), "counters", UVM_LOW)

    // mcycle free-runs; two reads separated in time must differ.
    access(12'hB00, CSR_RS, '0, 1'b1, 1'b0);
    idle(10);
    access(12'hB00, CSR_RS, '0, 1'b1, 1'b0);

    // minstret only advances on retire.
    access(12'hB02, CSR_RW, 32'd0);
    idle(10);
    access(12'hB02, CSR_RS, '0, 1'b1, 1'b0);     // unchanged - no retires
    retire(5);
    access(12'hB02, CSR_RS, '0, 1'b1, 1'b0);     // now 5

    // 64-bit rollover across the mcycleh boundary.
    access(12'hB00, CSR_RW, 32'hFFFF_FFF0);
    access(12'hB80, CSR_RW, 32'd0);
    idle(25);
    access(12'hB80, CSR_RS, '0, 1'b1, 1'b0);     // high half must be 1
    access(12'hB00, CSR_RS, '0, 1'b1, 1'b0);

    // Same for minstret.
    access(12'hB02, CSR_RW, 32'hFFFF_FFFE);
    access(12'hB82, CSR_RW, 32'd0);
    retire(5);
    access(12'hB82, CSR_RS, '0, 1'b1, 1'b0);
  endtask
endclass

// Interrupt pins drive mip; irq_pending needs MIE, mie and mip together.
class csr_irq_seq extends csr_base_seq;
  `uvm_object_utils(csr_irq_seq)
  function new(string name = "csr_irq_seq");
    super.new(name);
  endfunction

  task irq(logic t, logic s, logic e);
    csr_seq_item it = csr_seq_item::type_id::create("it");
    start_item(it);
    it.addr = 12'h344; it.op = CSR_RS; it.wdata = '0;
    it.do_read = 1'b1; it.do_write = 1'b0;
    it.trap_valid = 1'b0; it.mret = 1'b0;
    it.trap_epc = '0; it.trap_cause = '0; it.trap_tval = '0;
    it.irq_timer = t; it.irq_software = s; it.irq_external = e;
    it.instr_retired = 1'b0;
    finish_item(it);
  endtask

  task body();
    `uvm_info(get_type_name(), "interrupts", UVM_LOW)

    access(12'h300, CSR_RW, 32'h0);              // MIE = 0
    access(12'h304, CSR_RW, 32'h0000_0888);      // mie: MSIE, MTIE, MEIE

    irq(1'b1, 1'b0, 1'b0);                       // mip.MTIP, but MIE=0
    irq(1'b0, 1'b1, 1'b0);
    irq(1'b0, 1'b0, 1'b1);
    irq(1'b1, 1'b1, 1'b1);

    access(12'h300, CSR_RW, 32'h0000_0008);      // MIE = 1
    irq(1'b1, 1'b0, 1'b0);                       // now pending
    irq(1'b0, 1'b0, 1'b0);                       // not pending

    access(12'h304, CSR_RW, 32'h0);              // mask everything off
    irq(1'b1, 1'b1, 1'b1);                       // masked - not pending
  endtask
endclass


// Every implemented address against every operation. x_addr_op is
// 18 addresses x 3 ops = 54 cells; RAL traffic alone only ever issues
// CSR_RW (writes) and CSR_RS (reads), so CSR_RC cells stay empty without
// this. The cells are reachable, not structurally impossible - so directed
// stimulus rather than ignore_bins is the right answer.
class csr_sweep_seq extends csr_base_seq;
  `uvm_object_utils(csr_sweep_seq)
  function new(string name = "csr_sweep_seq");
    super.new(name);
  endfunction

  task body();
    logic [11:0] addrs[] = '{12'h300, 12'h301, 12'h304, 12'h305, 12'h310,
                             12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
                             12'hB00, 12'hB02, 12'hB80, 12'hB82,
                             12'hF11, 12'hF12, 12'hF13, 12'hF14};
    `uvm_info(get_type_name(), "address x operation sweep", UVM_LOW)
    foreach (addrs[i]) begin
      access(addrs[i], CSR_RW, 32'h0000_00FF);
      access(addrs[i], CSR_RS, 32'h0000_0F00);
      access(addrs[i], CSR_RC, 32'h0000_00F0);
      // Same three with the write suppressed, so x_read_write and the
      // suppression coverpoints see every address too.
      access(addrs[i], CSR_RW, 32'hFFFF_FFFF, 1'b1, 1'b0);
      access(addrs[i], CSR_RS, 32'hFFFF_FFFF, 1'b1, 1'b0);
      access(addrs[i], CSR_RC, 32'hFFFF_FFFF, 1'b1, 1'b0);
      // And with the read suppressed.
      access(addrs[i], CSR_RW, 32'h0000_0001, 1'b0, 1'b1);
    end
    // Restore a sane state after bashing mtvec/mepc/counters.
    access(12'h305, CSR_RW, 32'h0000_0000);
    access(12'h341, CSR_RW, 32'h0000_0000);
    access(12'h300, CSR_RW, 32'h0000_0000);
  endtask
endclass
